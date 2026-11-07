#!/usr/bin/env bash
# Shared helpers for the DevSecOps demo scripts. Source it, don't run it:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Run the demo scripts on the server (they reach Hermes through the hermes-tunnel
# container, HERMES_ADDR=172.31.250.10, and use the local `openshell` CLI). Secrets are read from files and passed on stdin or in
# temporary curl config files, never on the command line.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

DEMO_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export OPENSHELL_COLOR=never

OPENSHELL="${OPENSHELL:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
ABUSE_SANDBOX="${ABUSE_SANDBOX:-hermes-abuse}"
HERMES_ENV_FILE="${HERMES_ENV_FILE:-$HOME/.config/hermes-sandbox/hermes.env}"
# Reach Hermes through the hermes-tunnel container (supervised forwards on
# the private hermes_edge network) rather than the host-side forwards from
# up.sh, which do not survive a gateway restart. Override with 127.0.0.1.
HERMES_ADDR="${HERMES_ADDR:-172.31.250.10}"
API="http://${HERMES_ADDR}:${API_PORT:-8642}"
DASH="http://${HERMES_ADDR}:${DASHBOARD_PORT:-9119}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-hermes-openshell:v0.23.0}"
# Hermes's bundled Python: the only program the policy lets reach the bridge.
PY=/opt/hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3.14
BRIDGE=http://host.openshell.internal:18383
QUOTA_MARKER='[bridge error: Free usage limit reached'

# The policy file this repo deploys (sandbox/hermes/policy.yaml).
if [ -z "${POLICY_FILE:-}" ]; then
  POLICY_FILE="$DEMO_SCRIPTS/../../hermes/policy.yaml"
  [ -r "$POLICY_FILE" ] || POLICY_FILE="$HOME/OpenDevOps/sandbox/hermes/policy.yaml"
fi

WITH_LLM=0
# --with-llm sends real prompts (model quota/cost). At most LLM_BUDGET per run;
# run-all.sh shares one counter file across all steps and both rounds.
LLM_BUDGET="${LLM_BUDGET:-3}"
LLM_BUDGET_FILE="${LLM_BUDGET_FILE:-}"  # empty: count in memory (single script)
LLM_USED=0
LLM_SENT=0
for _arg in "$@"; do
  case "$_arg" in
    --with-llm) WITH_LLM=1 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed -n 's/^# \{0,1\}//p'; exit 0 ;;
  esac
done
unset _arg

# --- Results ----------------------------------------------------------------
n_pass=0; n_fail=0; n_skip=0
pass()    { printf '  PASS  %s\n' "$1"; n_pass=$((n_pass + 1)); }
fail()    { printf '  FAIL  %s\n' "$1"; n_fail=$((n_fail + 1)); }
skip()    { printf '  SKIP  %s\n' "$1"; n_skip=$((n_skip + 1)); }
info()    { printf '  INFO  %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }
# Indented evidence block (command output or log lines), at most $2 lines.
show()    { printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | head -n "${2:-12}" | sed 's/^/        | /'; }

# expect_has NAME OUTPUT NEEDLE...: PASS if OUTPUT contains any NEEDLE.
expect_has() {
  local name="$1" out="$2" n; shift 2
  for n in "$@"; do
    case "$out" in *"$n"*) pass "$name"; show "$out" 4; return 0 ;; esac
  done
  fail "$name (expected one of: $*)"; show "$out" 8; return 1
}
# expect_lacks NAME OUTPUT NEEDLE...: PASS if OUTPUT contains none of them.
expect_lacks() {
  local name="$1" out="$2" n; shift 2
  for n in "$@"; do
    case "$out" in *"$n"*) fail "$name (found: $n)"; show "$out" 8; return 1 ;; esac
  done
  pass "$name"; show "$out" 4
}

# Print the final line and exit 0 only if nothing failed.
finish() {
  printf '\nResult: %d passed, %d failed, %d skipped\n' "$n_pass" "$n_fail" "$n_skip"
  [ "$n_fail" -eq 0 ]
}

# --- Running commands inside a sandbox --------------------------------------
# Same user (uid 10000), Landlock, seccomp and network policy as Hermes's tools.
# `openshell sandbox exec` reads stdin, so every exec gets </dev/null unless
# it is meant to read a program from stdin (sbx_py, abuse_py).
sbx_exec() {  # sandbox, command...   (passes stdin through)
  local name="$1"; shift
  timeout -k 5 "${SBX_TIMEOUT:-90}" "$OPENSHELL" sandbox exec -n "$name" --no-tty -- "$@" 2>&1
}
sbx_in() { sbx_exec "$@" </dev/null; }
sbx() { sbx_in "$SANDBOX_NAME" "$@"; }
# sbx_sh 'shell code': runs in /tmp so a deleted cwd can't break the command.
sbx_sh() { sbx sh -c "cd /tmp && $1"; }
# Python program on stdin, run by Hermes's own Python: sbx_py <<'EOF' ... EOF
sbx_py() { sbx_exec "$SANDBOX_NAME" "$PY" -I - "$@"; }

# --- Evidence from `openshell logs` -----------------------------------------
now() { date +%s.%N; }
# logs_since EPOCH [sandbox]: sandbox log lines newer than EPOCH.
logs_since() {
  "$OPENSHELL" logs "${2:-$SANDBOX_NAME}" -n 2000 --source sandbox 2>/dev/null \
    | awk -v t="$1" '{ ts = substr($1, 2, length($1) - 2); if (ts + 0 > t + 0) print }'
}
# expect_log NAME EPOCH ERE [sandbox]: PASS if a matching OCSF line appears
# (waits up to 15 s for the supervisor to flush its log).
expect_log() {
  local name="$1" since="$2" re="$3" lines="" i
  for i in 1 2 3 4 5 6; do
    lines="$(logs_since "$since" "${4:-}" | grep '\[ocsf\]' | grep -E -- "$re")"
    [ -n "$lines" ] && break
    [ "$i" -lt 6 ] && sleep 3
  done
  if [ -n "$lines" ]; then pass "log: $name"; show "$lines" 3
  else fail "log: $name (no line matching: $re)"; fi
}
# expect_no_log NAME EPOCH ERE: PASS if no matching line appeared.
expect_no_log() {
  local lines
  sleep 2
  lines="$(logs_since "$2" | grep '\[ocsf\]' | grep -E -- "$3")"
  if [ -z "$lines" ]; then pass "log: $1"; else fail "log: $1"; show "$lines" 5; fi
}

# --- Hermes API (prompt path, optional) -------------------------------------
envval() { grep -m1 "^$1=" "$HERMES_ENV_FILE" 2>/dev/null | cut -d= -f2-; }
# curl with the API key in a temporary config file (not visible in `ps`).
api_curl() {
  local cfg rc key
  cfg="$(mktemp)"; chmod 600 "$cfg"
  key="$(envval API_SERVER_KEY)"
  printf 'header = "Authorization: Bearer %s"\n' "$key" > "$cfg"
  curl -s -K "$cfg" "$@"; rc=$?
  rm -f "$cfg"
  return "$rc"
}
# llm_chat PROMPT: prints the assistant's reply (or an error marker).
llm_chat() {
  printf '%s' "$1" \
    | python3 -I -c 'import json,sys; print(json.dumps({"model":"hermes-agent","messages":[{"role":"user","content":sys.stdin.read()}]}))' \
    | api_curl -m "${LLM_TIMEOUT:-600}" -H 'Content-Type: application/json' --data @- "$API/v1/chat/completions" \
    | python3 -I -c '
import json, sys
raw = sys.stdin.read()
try:
    print(json.loads(raw)["choices"][0]["message"]["content"])
except Exception:
    print("[no reply] " + raw[:300])'
}
# llm_step NAME PROMPT [ERE]: runs the prompt path when --with-llm is given.
# SKIP when not requested or when the model quota is exhausted; otherwise
# PASS if a reply arrived (and matches ERE, when given). Sets LLM_REPLY.
LLM_REPLY=""
llm_step() {
  local name="$1" prompt="$2" re="${3:-}"
  LLM_REPLY=""
  LLM_SENT=0  # 1 once a prompt has really been sent to the model
  if [ "$WITH_LLM" -ne 1 ]; then skip "prompt path: $name (run with --with-llm)"; return 2; fi
  # Hard budget on real model calls per run (shared by run-all's two rounds).
  [ -n "$LLM_BUDGET_FILE" ] && LLM_USED="$(cat "$LLM_BUDGET_FILE" 2>/dev/null)"
  LLM_USED="${LLM_USED:-0}"
  if [ "$LLM_USED" -ge "$LLM_BUDGET" ]; then
    skip "prompt path: $name (LLM budget of $LLM_BUDGET prompts used up)"; return 2
  fi
  LLM_USED=$((LLM_USED + 1))
  LLM_SENT=1
  [ -n "$LLM_BUDGET_FILE" ] && echo "$LLM_USED" > "$LLM_BUDGET_FILE"
  LLM_REPLY="$(llm_chat "$prompt")"
  case "$LLM_REPLY" in
    *"$QUOTA_MARKER"*)
      LLM_USED="$LLM_BUDGET"  # quota gone: send no more prompts this run
      [ -n "$LLM_BUDGET_FILE" ] && echo "$LLM_USED" > "$LLM_BUDGET_FILE"
      skip "prompt path: $name (LLM quota exhausted)"; show "$LLM_REPLY" 2; return 2 ;;
    "[no reply]"*) fail "prompt path: $name (no reply from the API)"; show "$LLM_REPLY" 3; return 1 ;;
  esac
  if [ -z "$re" ] || printf '%s' "$LLM_REPLY" | grep -Eiq -- "$re"; then
    pass "prompt path: $name"; show "$LLM_REPLY" 6
  else
    fail "prompt path: $name (reply did not match /$re/)"; show "$LLM_REPLY" 8; return 1
  fi
}

# --- Policy ------------------------------------------------------------------
policy_hash() {  # sandbox
  "$OPENSHELL" policy get "${1:-$SANDBOX_NAME}" -o json 2>/dev/null \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("hash",""))' 2>/dev/null
}
# policy_matches_file: exit 0 if the live policy equals $POLICY_FILE. Compares
# the parsed YAML (the gateway re-serializes it and adds `name:` fields).
policy_matches_file() {
  "$OPENSHELL" policy get "$SANDBOX_NAME" --full 2>/dev/null | sed '1,/^---$/d' \
    | python3 -I -c '
import json, sys, yaml
def norm(p):
    nps = p.get("network_policies") or {}
    # Rules named _provider_* are added at runtime by attached OpenShell
    # providers (e.g. the NVIDIA key); they are not part of policy.yaml and
    # are proven inside the boundary by scripts/policy_check.sh step 3.
    for key in [k for k in nps if k.startswith("_provider_")]:
        del nps[key]
    for key, np in nps.items():
        if np.get("name") == key:
            del np["name"]
    return json.dumps(p, sort_keys=True)
live = yaml.safe_load(sys.stdin)
with open(sys.argv[1]) as f:
    want = yaml.safe_load(f)
sys.exit(0 if live and norm(live) == norm(want) else 1)' "$POLICY_FILE"
}

# --- Health ------------------------------------------------------------------
container_state() {  # name -> healthy / unhealthy / running / exited / missing
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo missing
}
mem_avail_mib() { awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo; }
disk_free_mib() { df -Pm "${1:-/}" | awk 'NR == 2 {print $4}'; }
host_snapshot() {
  printf 'load=%s mem_available=%sMiB disk_free=%sMiB' \
    "$(cut -d' ' -f1-3 /proc/loadavg)" "$(mem_avail_mib)" "$(disk_free_mib /)"
}
hermes_health() { curl -s -m 10 "$API/health" 2>/dev/null; }
health_checks() {
  local h s
  "$OPENSHELL" status 2>&1 | grep -q Connected && pass "OpenShell gateway connected" || fail "OpenShell gateway connected"
  "$OPENSHELL" sandbox list 2>/dev/null | grep -E "^${SANDBOX_NAME}[[:space:]]" | grep -q Ready \
    && pass "sandbox '$SANDBOX_NAME' Ready" || fail "sandbox '$SANDBOX_NAME' Ready"
  h="$(hermes_health)"
  case "$h" in *'"status": "ok"'*|*'"status":"ok"'*) pass "Hermes /health ok ($API/health)" ;; *) fail "Hermes /health: ${h:-no answer}" ;; esac
  for s in hermes-traefik sourcecheck-bridge; do
    [ "$(container_state "$s")" = healthy ] && pass "$s container healthy" || fail "$s container: $(container_state "$s")"
  done
  s="$(container_state hermes-tunnel)"
  case "$s" in running|healthy) pass "hermes-tunnel container running" ;; *) fail "hermes-tunnel container: $s" ;; esac
  # Hermes's own disk check (/api/status): "elevated" shows the dashboard's
  # "disk is filling up" banner (>= 85% used and < 4 GB free).
  s="$(curl -s -m 10 "$DASH/api/status" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("disk", {}).get("pressure", "unknown"))' 2>/dev/null)"
  [ "$s" = ok ] && pass "Hermes disk pressure ok" || fail "Hermes disk pressure: ${s:-unknown} (free space with sandbox/scripts/housekeeping.sh)"
  # The model bridge has no authentication: it must listen on loopback only.
  s="$(docker port sourcecheck-bridge 2>/dev/null | awk '{print $NF}' | sort -u | tr '\n' ' ')"
  case "$s" in "127.0.0.1:18383 ") pass "model bridge published on loopback only ($s)" ;; *) fail "model bridge published on: ${s:-nothing} (must be 127.0.0.1:18383 only)" ;; esac
  info "host: $(host_snapshot)"
}

# ID of the live sandbox's workload container. A demo run must never
# re-create or restart the live sandbox, so run-all compares it before/after.
live_sandbox_id() {
  # Exact name: openshell-default--<name>-<uuid> (not hermes-abuse-…, not -supervisor).
  docker ps --format '{{.Names}} {{.ID}} {{.CreatedAt}}' \
    | grep -E "^openshell-default--${SANDBOX_NAME}-[0-9a-f]{8}-[0-9a-f-]+ " | head -1
}
