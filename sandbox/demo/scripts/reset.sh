#!/usr/bin/env bash
# Restore a clean demo state. Idempotent; run it before and after a demo.
#
#   sandbox/demo/scripts/reset.sh
#
# 1. Deletes demo files: /sandbox/hermes/workspace/demo-*, /tmp/demo-* and
#    npm debug logs (/sandbox/.npm/_logs). The workspace folder itself stays.
# 2. Kills stray demo processes in the sandbox (command line has /tmp/demo-
#    or demo-listener, or is a demo web server on port 18999).
# 3. Deletes the throwaway sandbox `hermes-abuse` (verify-08.sh) if present.
# 4. Deletes Hermes sessions with a user prompt starting with `DEMO-`.
# 5. Checks the live policy equals sandbox/hermes/policy.yaml; on drift it
#    re-applies the file (`openshell policy set --wait`) and reports it.
#    Set RESET_NO_REAPPLY=1 to only report drift.
# 6. Health checks (gateway, sandbox, Hermes /health, Traefik, bridge, tunnel).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== reset: restore a clean demo state =="

section "1. Demo files"
out="$(sbx_sh 'n=$(ls -d /sandbox/hermes/workspace/demo-* /tmp/demo-* 2>/dev/null | wc -l)
rm -rf /sandbox/hermes/workspace/demo-* /tmp/demo-* /sandbox/.npm/_logs
echo "removed=$n left=$(ls -d /sandbox/hermes/workspace/demo-* /tmp/demo-* 2>/dev/null | wc -l)"')"
case "$out" in *"left=0"*) pass "no demo-* files left (${out%% *})" ;; *) fail "demo files: $out" ;; esac

section "2. Stray demo processes"
out="$(sbx_py <<'EOF'
import os, signal
me = {os.getpid(), os.getppid()}
killed = []
for pid in filter(str.isdigit, os.listdir("/proc")):
    if int(pid) in me:
        continue
    try:
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
    except OSError:
        continue
    if "/tmp/demo-" in cmd or "demo-listener" in cmd or ("http.server" in cmd and "18999" in cmd):
        try:
            os.kill(int(pid), signal.SIGKILL); killed.append(pid)
        except OSError:
            pass
print(f"killed={len(killed)}")
EOF
)"
case "$out" in killed=*) pass "no stray demo processes ($out)" ;; *) fail "process cleanup: $out" ;; esac

section "3. Throwaway sandbox $ABUSE_SANDBOX"
if "$OPENSHELL" sandbox get "$ABUSE_SANDBOX" >/dev/null 2>&1; then
  "$OPENSHELL" sandbox delete "$ABUSE_SANDBOX" >/dev/null 2>&1
  for _ in $(seq 1 30); do "$OPENSHELL" sandbox get "$ABUSE_SANDBOX" >/dev/null 2>&1 || break; sleep 2; done
  info "deleted leftover sandbox $ABUSE_SANDBOX"
fi
"$OPENSHELL" sandbox get "$ABUSE_SANDBOX" >/dev/null 2>&1 && fail "$ABUSE_SANDBOX still exists" || pass "$ABUSE_SANDBOX absent"

section "4. DEMO- chat sessions"
out="$(SBX_TIMEOUT=180 sbx_sh 'export HERMES_HOME=/sandbox/hermes HOME=/sandbox/hermes
f=/tmp/demo-reset-prompts.jsonl
/opt/hermes/bin/hermes sessions export --format jsonl --only user-prompts --yes "$f" >/dev/null 2>&1 || echo EXPORT_FAILED
'"$PY"' -I -c "
import json, sys
ids = set()
for line in open(sys.argv[1]):
    row = json.loads(line)
    if row.get(\"text\", \"\").lstrip().startswith(\"DEMO-\"):
        ids.add(row[\"session_id\"])
print(\"\n\".join(sorted(ids)))
" "$f" 2>/dev/null | while read -r id; do
  [ -n "$id" ] && /opt/hermes/bin/hermes sessions delete --yes "$id" >/dev/null 2>&1 && echo "deleted $id"
done
rm -f "$f"')"
case "$out" in
  *EXPORT_FAILED*) fail "could not export Hermes sessions"; show "$out" ;;
  *) pass "DEMO- sessions removed: $(printf '%s\n' "$out" | grep -c '^deleted')" ;;
esac

section "5. Live policy = $(basename "$(dirname "$POLICY_FILE")")/$(basename "$POLICY_FILE")"
before="$(policy_hash)"
if policy_matches_file; then
  pass "live policy matches the file (hash ${before:0:12})"
elif [ "${RESET_NO_REAPPLY:-0}" = 1 ]; then
  fail "POLICY DRIFT: live policy (hash ${before:0:12}) differs from $POLICY_FILE (not re-applied)"
else
  info "POLICY DRIFT: live hash ${before:0:12} differs from $POLICY_FILE, re-applying"
  "$OPENSHELL" policy set "$SANDBOX_NAME" --policy "$POLICY_FILE" --wait 2>&1 | tail -3 | sed 's/^/        | /'
  after="$(policy_hash)"
  if policy_matches_file; then pass "policy re-applied (hash ${before:0:12} -> ${after:0:12})"
  else fail "policy still differs after re-apply (hash ${after:0:12})"; fi
fi

section "6. Health"
health_checks

finish
