#!/usr/bin/env bash
# End-to-end checks for the OpenCode bridge that the Hermes sandbox uses as
# its free-model provider (`opencode-bridge`). Run on the server.
#
#   sandbox/opencode/test_bridge.sh                 # no model calls
#   LLM_CHECKS=1 sandbox/opencode/test_bridge.sh    # + 2 real prompts (free quota)
#
# Checks, in the order a request travels (see README.md, "Architecture"):
#   1. the bridge container: healthy, published on 127.0.0.1:18383 only;
#   2. the bridge on the host: /health, /v1/models lists OpenCode free models;
#   3. the OpenShell policy: the opencode_bridge rule is in the effective
#      policy, Hermes's Python may call the 3 allowed routes, other routes and
#      other programs are refused;
#   4. Hermes's config: the opencode-bridge provider points at the bridge;
#   5. (LLM_CHECKS=1) a prompt straight to the bridge, and one from Hermes
#      inside the sandbox through the opencode-bridge provider. This does not
#      change Hermes's default model.
set -uo pipefail

export PATH="$HOME/.local/bin:$PATH" OPENSHELL_COLOR=never
OPENSHELL="${OPENSHELL:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
BRIDGE_CONTAINER="${BRIDGE_CONTAINER:-sourcecheck-bridge}"
BRIDGE_PORT="${BRIDGE_PORT:-18383}"
HOST_URL="http://127.0.0.1:$BRIDGE_PORT"
SBX_URL="http://host.openshell.internal:$BRIDGE_PORT"
MODEL="${OPENCODE_MODEL:-opencode/mimo-v2.6-flash-free}"
# Hermes's bundled Python: the only program the policy lets reach the bridge.
PY=/opt/hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3.14
HERMES=/opt/hermes/bin/hermes
QUOTA_MARKER='Free usage limit reached'
case "$BRIDGE_PORT" in ''|*[!0-9]*) echo "BRIDGE_PORT must be a number" >&2; exit 2 ;; esac
case "$MODEL" in *[!A-Za-z0-9._/-]*) echo "OPENCODE_MODEL has unexpected characters" >&2; exit 2 ;; esac

pass=0; fail=0; skip=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skp()  { printf '  SKIP  %s\n' "$1"; skip=$((skip + 1)); }
sbx()  { timeout "${2:-60}" "$OPENSHELL" sandbox exec -n "$SANDBOX_NAME" --no-tty -- sh -c "$1" 2>&1; }
# HTTP status of a request made by Hermes's Python inside the sandbox
# (403 = refused by the policy's REST rules, DENIED = connection refused).
sbx_code() {
  sbx "$PY -c \"import urllib.request as u, urllib.error as e
r = u.Request('$SBX_URL$2', method='$1', data=(b'{}' if '$1' == 'POST' else None), headers={'Content-Type': 'application/json'})
try: print(u.urlopen(r, timeout=15).status)
except e.HTTPError as x: print(x.code)
except Exception as x: print('DENIED', x)\""
}

echo "1. Bridge container ($BRIDGE_CONTAINER)"
state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$BRIDGE_CONTAINER" 2>/dev/null)"
[ "$state" = healthy ] && ok "container healthy" || bad "container state: ${state:-missing}"
ports="$(docker port "$BRIDGE_CONTAINER" 2>/dev/null | awk '{print $NF}' | sort -u | tr '\n' ' ')"
[ "$ports" = "127.0.0.1:$BRIDGE_PORT " ] && ok "published on 127.0.0.1:$BRIDGE_PORT only (no auth, never public)" \
  || bad "published on: ${ports:-nothing} (must be 127.0.0.1:$BRIDGE_PORT only)"

echo "2. Bridge on the host ($HOST_URL)"
health="$(curl -s -m 10 "$HOST_URL/health")"
case "$health" in *'"ok"'*) ok "/health ok" ;; *) bad "/health: ${health:0:200}" ;; esac
models="$(curl -s -m 20 "$HOST_URL/v1/models" | python3 -c 'import json,sys; print(" ".join(m["id"] for m in json.load(sys.stdin)["data"]))' 2>/dev/null)"
n="$(wc -w <<<"$models")"
[ "$n" -gt 0 ] && ok "/v1/models lists $n models" || bad "/v1/models returned no models"
case " $models " in *" $MODEL "*) ok "Hermes's bridge model $MODEL is offered" ;; *) bad "$MODEL not in /v1/models: $models" ;; esac

echo "3. OpenShell policy (sandbox $SANDBOX_NAME)"
policy="$("$OPENSHELL" policy get "$SANDBOX_NAME" --full 2>&1)"
case "$policy" in *"Status:"*Effective*opencode_bridge*"port: $BRIDGE_PORT"*) ok "opencode_bridge rule is in the effective policy" ;; *) bad "opencode_bridge rule missing from the effective policy" ;; esac
check_sbx() { local got; got="$(sbx_code "$2" "$3" | tail -1 | tr -d '\r')"; case "$got" in "$4") ok "$1 ($got)" ;; *) bad "$1: expected $4, got ${got:0:160}" ;; esac; }
check_sbx "Hermes Python -> GET /health allowed" GET /health 200
check_sbx "Hermes Python -> GET /v1/models allowed" GET /v1/models 200
check_sbx "Hermes Python -> GET /config refused (route not in the rule)" GET /config 403
check_sbx "Hermes Python -> POST /v1/admin/shutdown refused" POST /v1/admin/shutdown 403
out="$(sbx "curl -s -m 10 -o /dev/null -w '%{http_code}' $SBX_URL/v1/models" | tail -1)"
# 000 = the connection was refused; anything else (200, an error message,
# no output) is either a leak or an inconclusive check.
case "$out" in
  200) bad "curl on its own reached the bridge (rule should be scoped to Hermes Python)" ;;
  000) ok "curl on its own -> bridge refused (rule is scoped to Hermes Python)" ;;
  *) bad "curl check inconclusive: ${out:0:120}" ;;
esac

echo "4. Hermes provider config"
cfg="$(sbx "cat /sandbox/hermes/config.yaml")"
case "$cfg" in *opencode-bridge:*"base_url: $SBX_URL/v1"*) ok "provider opencode-bridge -> $SBX_URL/v1" ;; *) bad "provider opencode-bridge not configured for $SBX_URL/v1" ;; esac
key="$(sbx 'test -n "${OPENCODE_BRIDGE_API_KEY:-}" && echo set' | tail -1)"
[ "$key" = set ] && ok "OPENCODE_BRIDGE_API_KEY is set (placeholder; the bridge has no auth)" || bad "OPENCODE_BRIDGE_API_KEY missing in the sandbox"

echo "5. Model answers (LLM_CHECKS=1, uses OpenCode free quota)"
if [ "${LLM_CHECKS:-0}" = 1 ]; then
  reply="$(curl -s -m 180 -H 'Content-Type: application/json' "$HOST_URL/v1/chat/completions" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: BRIDGE_OK\"}]}")"
  case "$reply" in
    *BRIDGE_OK*) ok "bridge answered directly ($MODEL)" ;;
    *"$QUOTA_MARKER"*) bad "bridge: OpenCode free quota used up (account-wide; wait for the reset)" ;;
    *) bad "bridge direct: ${reply:0:200}" ;;
  esac
  # One-shot Hermes chat inside the sandbox on the opencode-bridge provider.
  # Flags only: Hermes's saved default model is not changed. Hermes falls back
  # to the NVIDIA models when the bridge fails or is busy (429), so the answer
  # alone doesn't prove the bridge served it: also count the bridge's
  # successful completions in its log before and after.
  served() { docker logs "$BRIDGE_CONTAINER" 2>&1 | grep -c 'POST /v1/chat/completions HTTP/1.1" 200'; }
  before="$(served)"
  reply="$(sbx "cd /tmp && HERMES_HOME=/sandbox/hermes HOME=/sandbox/hermes $HERMES chat -Q --provider opencode-bridge -m '$MODEL' -q 'Reply with exactly: HERMES_BRIDGE_OK'" 240)"
  after="$(served)"
  case "$reply" in
    *"Fallback activated"*) bad "Hermes -> bridge: Hermes fell back to another model (bridge failed or busy)" ;;
    *HERMES_BRIDGE_OK*)
      if [ "$after" -gt "$before" ]; then ok "Hermes in the sandbox answered through the bridge"
      else bad "Hermes answered, but the bridge served no completion (fallback model?)"; fi ;;
    *"$QUOTA_MARKER"*) bad "Hermes -> bridge: OpenCode free quota used up" ;;
    *) bad "Hermes -> bridge: $(tail -c 300 <<<"$reply")" ;;
  esac
  # Delete only the session this test created (matched by its prompt), so it
  # doesn't clutter the dashboard's Sessions list.
  n="$(sbx 'export HERMES_HOME=/sandbox/hermes HOME=/sandbox/hermes; cd /tmp
/opt/hermes/bin/hermes sessions export --format jsonl --only user-prompts --yes /tmp/bridge-prompts.jsonl >/dev/null 2>&1
/opt/hermes/.venv/bin/python -I -c "
import json
for line in open(\"/tmp/bridge-prompts.jsonl\"):
    row = json.loads(line)
    if \"Reply with exactly: HERMES_BRIDGE_OK\" in row.get(\"text\", \"\"):
        print(row[\"session_id\"])
" 2>/dev/null | sort -u | while read -r id; do [ -n "$id" ] && /opt/hermes/bin/hermes sessions delete --yes "$id" >/dev/null 2>&1 && echo deleted; done
rm -f /tmp/bridge-prompts.jsonl' 120 | grep -c deleted)"
  printf '  INFO  removed %s test session(s)\n' "$n"
else
  skp "model answers (set LLM_CHECKS=1; 2 prompts on the OpenCode free quota)"
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
