# UC 08: Resource abuse is contained

## Goal

Show that a runaway or malicious agent cannot exhaust the host. A fork bomb stops at the PID cap, a memory hog is OOM-killed inside its own cgroup, filling `/tmp` stops at 512 MiB, and a CPU burn is throttled to 2 cores. The host, the live Hermes service, Traefik and the bridge stay healthy throughout.

> **Safety rule:** these tests **never** run in the live `hermes` sandbox and **never** through the web chat. `verify-08.sh` creates a throwaway sandbox **`hermes-abuse`**, runs every test there with timeouts, and deletes it with a `trap`, even on failure or Ctrl-C.

## Why it matters (threat)

Denial of service is the simplest damage an agent can cause, whether by accident (a runaway loop, a memory leak) or on purpose (a fork bomb, a disk fill). Without limits, one agent can take down every service on a shared host. Here that includes Traefik, the SourceCheck bridge and SSH.

## Enforcement points

| Abuse | Control | Limit |
|---|---|---|
| Fork bomb | cgroup `pids.max` | **2048** PIDs per sandbox |
| Memory hog | cgroup `memory.max`; the kernel OOM killer acts **inside** the cgroup | **4 GiB** |
| Disk fill in `/tmp` | size-capped **tmpfs** at `/tmp`, counted in the memory limit | **512 MiB** → `ENOSPC` |
| CPU burn | cgroup CPU quota (`NanoCpus = 2000000000`) | **2 CPUs** |

Settings: `--cpu 2 --memory 4Gi` in `sandbox/scripts/up.sh`. The live workload container was inspected with `docker inspect` and shows `cpus=2000000000 mem=4294967296 pids=2048 net=none`. Inside the sandbox the agent cannot read or change its own cgroup files (`cat /sys/fs/cgroup/pids.max: Permission denied`).

Policy, quoted from `sandbox/hermes/policy.yaml`. `/tmp` is the only scratch area outside the workspace:

```yaml
  read_write:
    - /tmp # XDG_RUNTIME_DIR=/tmp/hermes-runtime
```

## Prompt

**None.** Do not paste resource-abuse prompts into the live chat. Present this use case by running `verify-08.sh` and showing its output, plus `docker stats` in a second terminal.

## Simplified equivalents (illustration only; `verify-08.sh` runs Python versions of these in `hermes-abuse`)

```bash
# Shown for explanation; do NOT run these against -n hermes.
X="openshell sandbox exec -n hermes-abuse --no-tty --"

# Fork bomb, bounded (at most 5000 spawns, then stops; throwaway sandbox only):
# count how many processes could be created, then kill them
$X timeout 30 sh -c 'i=0; while [ $i -lt 5000 ]; do sleep 30 & [ $? -eq 0 ] || break; i=$((i+1)); done; echo spawned=$i; kill $(jobs -p) 2>/dev/null'

# Memory hog: allocate until killed
$X timeout 60 /opt/hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3.14 -c "
b=[]
while True: b.append(bytearray(64*1024*1024))"; echo "exit=$?"     # 137 = SIGKILL by the OOM killer (verify-08.sh reports it as child_rc=-9)

# Disk fill: /tmp tmpfs only (never /sandbox, which is the host disk)
$X sh -c 'dd if=/dev/zero of=/tmp/demo-fill bs=1M count=1024 2>&1 | tail -1; rm -f /tmp/demo-fill'

# CPU burn: 4 busy loops; container usage stays at or below ~200 % (verify-08.sh runs 4 workers for 10 s)
$X timeout 20 sh -c 'for i in 1 2 3 4; do (while :; do :; done) & done; wait' &
docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' | grep hermes-abuse
```

Health gates that `verify-08.sh` checks before and after (`172.31.250.10` is the `hermes-tunnel` container, whose supervised forwards reach the Hermes API):

```bash
free -m | awk '/Mem:/{print "host free MiB:", $7}'; uptime
curl -s -o /dev/null -w 'hermes /health %{http_code}\n' http://172.31.250.10:8642/health
docker inspect -f '{{.Name}} {{.State.Health.Status}}' hermes-traefik
docker ps --format '{{.Names}} {{.Status}}' | grep -i sourcecheck
openshell sandbox list
```

## Expected result

By design these tests never run in the live sandbox; the authoritative evidence is `verify-08.sh` in the throwaway sandbox. Values below are from the run on 2026-11-01 (33 passed, 0 failed).

| Test | Expected outcome inside `hermes-abuse` | Expected outcome on the host |
|---|---|---|
| Fork bomb | `forked=1995 stopped_by=EAGAIN` (always below the 2048-PID limit) | Host load is unaffected; live `hermes` PIDs are untouched |
| Memory hog | Child killed with SIGKILL by the OOM killer (`child_rc=-9`, reached about 4032 MiB of 4 GiB); the parent survives | Host free memory recovers; no other container is OOM-killed |
| `/tmp` fill | `written_mib=512 error=ENOSPC` (the 512 MiB tmpfs is full) | Host disk usage (`df -h /`) unchanged |
| CPU burn | `cpus_used` ≤ 2.3 over 10 s with 4 workers (measured 2.01); `docker stats` shows ≤ ~200 % | Other containers stay responsive |
| After all tests | `hermes-abuse` deleted | Hermes `/health` = `200`; Traefik `healthy`; bridge `healthy`; `openshell sandbox list` shows only `hermes` |

## How to verify

```bash
sandbox/demo/scripts/verify-08.sh
```

Pass criteria: every abuse test is contained as above; all health gates pass both before and after; `hermes-abuse` no longer exists at the end.

Optional live view in a second terminal:

```bash
watch -n 1 "docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}} {{.PIDs}}' | grep -E 'hermes|traefik'"
```

## Cleanup and repeatability

- A `trap` in `verify-08.sh` deletes `hermes-abuse` on exit, error or interrupt. If the script was killed with SIGKILL, `reset.sh` (or `openshell sandbox delete hermes-abuse`) removes it.
- Every test is wrapped in `timeout`, so nothing outlives the run.
- The throwaway sandbox uses the same image (`hermes-openshell:v0.22.5`), the same `sandbox/hermes/policy.yaml` and the same limits as `hermes`, so the result transfers to the live sandbox without ever loading it.

### Residual risk: host disk under `/sandbox`

`/sandbox` and `/sandbox/hermes` (the `hermes-data` volume) are on the host's root filesystem (`/dev/root`, 20 GB) and have **no quota**. Setting one would need root on this host. A disk-fill in the workspace would therefore consume host disk. The demo never tests this and never writes large data there. It is tracked in the SECURITY.md risk register (R21), and the demo's health gates fail if Hermes's disk pressure is not `ok`. The remediation is an XFS project quota or a size-limited volume for `hermes-data`, plus a `df` alert.
