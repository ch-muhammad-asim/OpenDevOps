#!/usr/bin/env bash
# UC 08: resource abuse is contained by the sandbox's cgroup limits.
#
#   sandbox/demo/scripts/verify-08.sh
#
# Never touches the live `hermes` sandbox. Creates a THROWAWAY sandbox
# `hermes-abuse` (same image, same policy file, same limits: 2 CPUs, 4 GiB,
# 2048 PIDs, /tmp = 512 MiB tmpfs, no data volume), runs four bounded tests
# in it, and always deletes it (trap):
#   fork bomb  - forks until the PID cap refuses (EAGAIN), then kills all
#   memory hog - a child allocates up to 6 GiB; the cgroup OOM-kills it
#   disk fill  - writes into /tmp until ENOSPC at 512 MiB, then deletes
#   CPU burn   - 4 busy workers for 10 s use at most ~2 CPUs
# Host load/memory and live Hermes, Traefik, bridge and tunnel health are
# recorded before and after. Needs >= 6 GiB available memory and >= 3 GiB
# free disk, otherwise it refuses to start.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== verify-08: resource abuse (throwaway sandbox $ABUSE_SANDBOX) =="
[ "$ABUSE_SANDBOX" != "$SANDBOX_NAME" ] || { echo "refusing: ABUSE_SANDBOX equals the live sandbox"; exit 1; }
MIN_MEM_MIB=6144
MIN_DISK_MIB=3072

abuse_container() {
  docker ps --format '{{.Names}}' | grep -E "^openshell-default--$ABUSE_SANDBOX-[0-9a-f]{8}-[0-9a-f-]+$" | head -1
}
live_container() {
  docker ps --format '{{.Names}}' | grep -E "^openshell-default--$SANDBOX_NAME-[0-9a-f]{8}-[0-9a-f-]+$" | head -1
}
cleanup() {
  if "$OPENSHELL" sandbox get "$ABUSE_SANDBOX" >/dev/null 2>&1; then
    "$OPENSHELL" sandbox delete "$ABUSE_SANDBOX" >/dev/null 2>&1
    for _ in $(seq 1 30); do "$OPENSHELL" sandbox get "$ABUSE_SANDBOX" >/dev/null 2>&1 || break; sleep 2; done
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
# Run a Python program (stdin) in the throwaway sandbox, bounded twice.
abuse_py() { SBX_TIMEOUT=150 sbx_exec "$ABUSE_SANDBOX" timeout -k 5 120 "$PY" -I -; }

section "1. Preconditions and host health (before)"
mem="$(mem_avail_mib)"; disk="$(disk_free_mib /)"
if [ "$mem" -lt "$MIN_MEM_MIB" ] || [ "$disk" -lt "$MIN_DISK_MIB" ]; then
  fail "host too small to run safely: available memory ${mem} MiB (need $MIN_MEM_MIB), free disk ${disk} MiB (need $MIN_DISK_MIB)"
  finish; exit 1
fi
pass "host has room: available memory ${mem} MiB >= $MIN_MEM_MIB, free disk ${disk} MiB >= $MIN_DISK_MIB"
health_checks
lc="$(live_container)"
live_before="$(docker inspect -f '{{.RestartCount}} {{.State.StartedAt}}' "$lc" 2>/dev/null)"

section "2. Create $ABUSE_SANDBOX"
cleanup
"$OPENSHELL" sandbox create --name "$ABUSE_SANDBOX" --from "$SANDBOX_IMAGE" --policy "$POLICY_FILE" \
  --driver-config-json '{"docker":{"mounts":[{"type":"tmpfs","target":"/tmp","size_bytes":536870912}]}}' \
  --no-credential-warnings --no-auto-providers --cpu 2 --memory 4Gi --detach \
  -- /bin/sh -c 'sleep 86400' </dev/null >/dev/null 2>&1
ready=0
for _ in $(seq 1 45); do
  "$OPENSHELL" sandbox list 2>/dev/null | grep -E "^${ABUSE_SANDBOX}[[:space:]]" | grep -q Ready && { ready=1; break; }
  sleep 2
done
if [ "$ready" -ne 1 ]; then fail "$ABUSE_SANDBOX did not become Ready"; finish; exit 1; fi
pass "$ABUSE_SANDBOX Ready"
ac="$(abuse_container)"
lim="$(docker inspect -f 'net={{.HostConfig.NetworkMode}} mem={{.HostConfig.Memory}} pids={{.HostConfig.PidsLimit}} cpus={{.HostConfig.NanoCpus}}' "$ac" 2>/dev/null)"
expect_has "limits: no network, 4 GiB, 2048 PIDs, 2 CPUs" "$lim" "net=none mem=4294967296 pids=2048 cpus=2000000000"
out="$(sbx_in "$ABUSE_SANDBOX" sh -c 'id -u; df -m /tmp | tail -1')"
expect_has "/tmp is a 512 MiB tmpfs, uid 10000" "$out" "tmpfs"

section "3. Fork bomb (bounded by the PID cap)"
out="$(abuse_py <<'EOF'
import errno, os, signal, time
kids, err, t0 = [], None, time.time()
while len(kids) < 4000 and time.time() - t0 < 60:   # 4000 > cap of 2048
    try:
        pid = os.fork()
    except OSError as e:
        err = e; break
    if pid == 0:
        try: os.execv("/bin/sleep", ["sleep", "120"])
        finally: os._exit(1)
    kids.append(pid)
for p in kids:
    try: os.kill(p, signal.SIGKILL)
    except OSError: pass
for p in kids:
    try: os.waitpid(p, 0)
    except OSError: pass
why = errno.errorcode.get(getattr(err, "errno", 0), repr(err)) if err else "none"
print(f"forked={len(kids)} stopped_by={why} secs={time.time() - t0:.1f}")
EOF
)"
expect_has "fork refused at the PID cap (EAGAIN)" "$out" "stopped_by=EAGAIN"
n="$(printf '%s' "$out" | sed -n 's/.*forked=\([0-9]*\).*/\1/p')"
[ -n "$n" ] && [ "$n" -lt 2048 ] && pass "processes created: $n < 2048" || fail "processes created: ${n:-?}"
left="$(sbx_in "$ABUSE_SANDBOX" sh -c 'ls -d /proc/[0-9]* | wc -l')"
[ "${left//[^0-9]/}" -lt 20 ] 2>/dev/null && pass "all children killed (${left//[^0-9]/} processes left)" || fail "processes left: $left"

section "4. Memory hog (OOM kill inside the 4 GiB cgroup)"
out="$(abuse_py <<'EOF'
import subprocess, sys, time
child = r'''
chunks, mib = [], 0
while mib < 6144:
    b = bytearray(64 * 1024 * 1024)
    for i in range(0, len(b), 4096): b[i] = 1
    chunks.append(b); mib += 64
    print(mib, flush=True)
print("NOT_KILLED", flush=True)
'''
t0 = time.time()
p = subprocess.Popen([sys.executable, "-I", "-c", child], stdout=subprocess.PIPE, text=True)
last = "0"
for line in p.stdout:
    last = line.strip()
try:
    rc = p.wait(timeout=60)
except subprocess.TimeoutExpired:
    p.kill(); rc = "timeout"
print(f"child_rc={rc} reached_mib={last} secs={time.time() - t0:.1f} parent=alive")
EOF
)"
expect_has "allocating child killed by SIGKILL (rc -9), parent survives" "$out" "child_rc=-9"
expect_lacks "child never exceeded the limit" "$out" "NOT_KILLED"
oom="$(docker inspect -f '{{.State.OOMKilled}}' "$ac" 2>/dev/null)"
[ "$oom" = true ] && pass "docker reports OOMKilled=true for $ABUSE_SANDBOX only" || info "docker OOMKilled flag: ${oom:-?}"
[ "$(docker inspect -f '{{.State.OOMKilled}}' "$lc" 2>/dev/null)" = false ] && pass "live sandbox not OOM-killed" || fail "live sandbox OOMKilled flag set"

section "5. Disk fill (/tmp tmpfs, ENOSPC at 512 MiB)"
out="$(abuse_py <<'EOF'
import errno, os
path, buf = "/tmp/demo-08-fill.bin", b"\0" * (16 * 1024 * 1024)
written, err = 0, None
try:
    with open(path, "wb") as f:
        while written < 1024 * 1024 * 1024:   # stop at 1 GiB in any case
            written += f.write(buf); f.flush()
except OSError as e:
    err = e
finally:
    try: os.unlink(path)
    except OSError: pass
code = errno.errorcode.get(err.errno) if err else "none"
print(f"written_mib={written // 1048576} error={code} removed={not os.path.exists(path)}")
EOF
)"
expect_has "write stops with ENOSPC" "$out" "error=ENOSPC"
expect_has "about 512 MiB written, file removed" "$out" "written_mib=512 " "written_mib=496 " "written_mib=50"

section "6. CPU burn (capped at 2 CPUs)"
out="$(abuse_py <<'EOF'
import os, time
secs, workers, kids = 10, 4, []
t0 = time.time()
for _ in range(workers):
    pid = os.fork()
    if pid == 0:
        end = time.time() + secs
        while time.time() < end: pass
        os._exit(0)
    kids.append(pid)
for p in kids: os.waitpid(p, 0)
wall = time.time() - t0
c = os.times(); cpu = c.children_user + c.children_system
print(f"workers={workers} wall={wall:.1f}s cpu={cpu:.1f}s cpus_used={cpu / wall:.2f}")
EOF
)"
used="$(printf '%s' "$out" | sed -n 's/.*cpus_used=\([0-9.]*\).*/\1/p')"
if [ -n "$used" ] && awk -v u="$used" 'BEGIN { exit !(u <= 2.3) }'; then
  pass "4 busy workers used $used CPUs (limit 2)"; show "$out" 1
else
  fail "CPU use not capped: ${out}"
fi

section "7. Delete $ABUSE_SANDBOX and check the host (after)"
cleanup
"$OPENSHELL" sandbox get "$ABUSE_SANDBOX" >/dev/null 2>&1 && fail "$ABUSE_SANDBOX still exists" || pass "$ABUSE_SANDBOX deleted"
[ -z "$(abuse_container)" ] && pass "no $ABUSE_SANDBOX container left" || fail "container left: $(abuse_container)"
health_checks
live_after="$(docker inspect -f '{{.RestartCount}} {{.State.StartedAt}}' "$lc" 2>/dev/null)"
[ -n "$live_before" ] && [ "$live_after" = "$live_before" ] && pass "live sandbox container not restarted" \
  || fail "live sandbox container changed: '$live_before' -> '$live_after'"

finish
