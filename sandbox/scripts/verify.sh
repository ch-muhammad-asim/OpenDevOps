#!/usr/bin/env bash
# End-to-end checks for the Hermes OpenShell sandbox. Run on the server.
#
#   HERMES_DASHBOARD_PASSWORD='...' sandbox/scripts/verify.sh
# (Public HTTPS checks: sandbox/scripts/verify_https.sh, from your laptop.)
#
# The password is optional; without it the login test is skipped.
# Reads API_SERVER_KEY and the dashboard username from HERMES_ENV_FILE.
set -uo pipefail

OPENSHELL="${OPENSHELL:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
HERMES_ENV_FILE="${HERMES_ENV_FILE:-$HOME/.config/hermes-sandbox/hermes.env}"
# Reach Hermes through the hermes-tunnel container (supervised forwards on
# the private hermes_edge network) rather than the host-side forwards from
# up.sh, which do not survive a gateway restart. Override with 127.0.0.1.
HERMES_ADDR="${HERMES_ADDR:-172.31.250.10}"
DASH="http://${HERMES_ADDR}:${DASHBOARD_PORT:-9119}"
API="http://${HERMES_ADDR}:${API_PORT:-8642}"
PY=/opt/hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3.14

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $3, got $2)"; fi; }
envval() { grep -m1 "^$1=" "$HERMES_ENV_FILE" | cut -d= -f2-; }
sbx() { timeout 60 "$OPENSHELL" sandbox exec -n "$SANDBOX_NAME" --no-tty -- "$@" 2>&1; }
code() { curl -s -m 20 -o /dev/null -w '%{http_code}' "$@"; }

API_KEY="$(envval API_SERVER_KEY)"
USERNAME="$(envval HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"

echo "1. OpenShell"
"$OPENSHELL" status 2>&1 | grep -q 'Connected' && ok "gateway connected" || bad "gateway connected"
"$OPENSHELL" sandbox list 2>&1 | grep -E "^$SANDBOX_NAME\b" | grep -q Ready && ok "sandbox Ready" || bad "sandbox Ready"

echo "2. Hermes inside the sandbox"
case "$(sbx /opt/hermes/bin/hermes --version)" in *v0.22.5*) ok "Hermes Agent v0.22.5" ;; *) bad "Hermes Agent v0.22.5" ;; esac
check "runs as uid 10000 (not root)" "$(sbx id -u | tr -d '\r')" "10000"

# Capture output first: the probed commands are expected to fail, and with
# pipefail their exit status would hide a successful grep.
denied() { local out; out="$(sbx sh -c "$2")"; case "$out" in *'Permission denied'*) ok "$1" ;; *) bad "$1: $out" ;; esac; }

echo "3. Filesystem policy (Landlock)"
denied "cannot write Hermes code (/opt/hermes)" 'touch /opt/hermes/x'
# Unix permissions allow both of these; only Landlock can refuse them.
denied "cannot read a world-readable file outside the policy" 'cat /var/lib/dpkg/status'
denied "cannot write a hermes-owned dir outside the policy (/opt/data)" 'touch /opt/data/x'
out="$(sbx sh -c 'touch /sandbox/hermes/.w && rm /sandbox/hermes/.w && echo W')"
case "$out" in *W*) ok "can write HERMES_HOME" ;; *) bad "can write HERMES_HOME: $out" ;; esac
out="$(sbx sh -c 'test -f /sandbox/hermes/config.yaml && echo Y')"
case "$out" in *Y*) ok "config.yaml seeded on the hermes-data volume" ;; *) bad "config.yaml seeded" ;; esac

echo "4. Network policy (deny by default)"
probe() {
  sbx "$PY" -c "import urllib.request as u
try: print(u.urlopen('$1', timeout=15).status)
except Exception as e: print('DENIED', e)"
}
expect() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: $2" ;; esac; }
expect "Hermes Python -> OpenCode bridge allowed" "$(probe http://host.openshell.internal:18383/v1/models)" 200
expect "Hermes Python -> internet denied" "$(probe https://example.com/)" DENIED
expect "Hermes Python -> gateway port denied" "$(probe http://host.openshell.internal:8080/)" DENIED
expect "cloud metadata endpoint denied" "$(probe http://169.254.169.254/latest/meta-data/)" DENIED
out="$(sbx curl -s -m 10 -o /dev/null -w '%{http_code}' http://host.openshell.internal:18383/v1/models)"
case "$out" in 200) bad "curl run on its own -> bridge should be denied (binary-scoped rule)" ;; *) ok "curl run on its own -> bridge denied (rule is scoped to Hermes Python)" ;; esac

echo "5. Dashboard (port ${DASHBOARD_PORT:-9119})"
check "unauthenticated request redirects to /login" "$(code "$DASH/")" "302"
check "API without session is rejected" "$(code "$DASH/api/auth/me")" "401"
if [ -n "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
  # Send the password on stdin so it never shows up in `ps` output.
  login_code="$(printf '{"provider":"basic","username":"%s","password":"%s"}' "$USERNAME" "$HERMES_DASHBOARD_PASSWORD" \
    | code -H 'Content-Type: application/json' --data @- "$DASH/auth/password-login")"
  check "login with the stored credentials" "$login_code" "200"
  check "login with a wrong password is refused" \
    "$(code -H 'Content-Type: application/json' -d "{\"provider\":\"basic\",\"username\":\"$USERNAME\",\"password\":\"wrong\"}" "$DASH/auth/password-login")" "401"
  # Chat page: opens a terminal (PTY) over WebSocket and asks a question.
  # Runs in a throwaway Hermes container, which has the `websockets` package.
  chat_out="$(printf '%s' "$HERMES_DASHBOARD_PASSWORD" | timeout 300 docker run --rm -i --network host \
    -e HERMES_DASHBOARD_USERNAME="$USERNAME" -e LLM_CHECKS="${LLM_CHECKS:-0}" \
    -v "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/chat_e2e.py:/t/chat_e2e.py:ro" \
    --entrypoint sh "${HERMES_IMAGE:-nousresearch/hermes-agent:v0.22.5}" -c \
    'read -r HERMES_DASHBOARD_PASSWORD; export HERMES_DASHBOARD_PASSWORD; /opt/hermes/.venv/bin/python -I /t/chat_e2e.py "$0"' "$DASH" 2>&1)"
  case "$chat_out" in
    *"answer received"*) ok "web Chat page: new session gets a PTY and answers" ;;
    *"no prompt sent"*) ok "web Chat page: new session gets a PTY (no model call; LLM_CHECKS=1 to ask)" ;;
    *"chat session: started"*) bad "web Chat page: PTY session started but the model did not answer (check the model endpoint/quota)" ;;
    *) bad "web Chat page: ${chat_out: -300}" ;;
  esac
else
  echo "  SKIP  login and Chat page tests (set HERMES_DASHBOARD_PASSWORD)"
fi

echo "6. Hermes API (port ${API_PORT:-8642})"
check "health endpoint" "$(code "$API/health")" "200"
check "request without API key is rejected" "$(code "$API/v1/models")" "401"
# The API key goes in a private header file, never on curl's command line.
AUTH_HDR="$(mktemp)"; chmod 600 "$AUTH_HDR"; trap 'rm -f "$AUTH_HDR"' EXIT
printf 'Authorization: Bearer %s\n' "$API_KEY" > "$AUTH_HDR"
check "request with API key is accepted" "$(code -H @"$AUTH_HDR" "$API/v1/models")" "200"
# Real model call: costs quota, so only with LLM_CHECKS=1.
if [ "${LLM_CHECKS:-0}" = 1 ]; then
  reply=$(curl -s -m 240 -H @"$AUTH_HDR" -H 'Content-Type: application/json' "$API/v1/chat/completions" \
    -d '{"model":"hermes-agent","max_tokens":20,"messages":[{"role":"user","content":"E2E-CHECK: Reply with exactly: SANDBOX_OK"}]}')
  case "$reply" in *SANDBOX_OK*) ok "chat answered end to end by the configured model" ;; *) bad "chat end to end: ${reply:0:200}" ;; esac
else
  echo "  SKIP  chat answer from the model (set LLM_CHECKS=1; uses model quota)"
fi

echo "7. Traefik (public entry point)"
# Traefik only answers Cloudflare's IP ranges, so a direct request from this
# server must be refused. Public HTTPS is checked by verify_https.sh from a
# normal internet connection (Cloudflare challenges scripts on cloud IPs).
check "Traefik :80 refuses non-Cloudflare clients" \
  "$(code -H "Host: ${HERMES_HOST:-hermes.saqlainmushtaq.com}" http://127.0.0.1/)" "403"
check "Traefik :443 refuses non-Cloudflare clients" \
  "$(code -k --resolve "${HERMES_HOST:-hermes.saqlainmushtaq.com}:443:127.0.0.1" "https://${HERMES_HOST:-hermes.saqlainmushtaq.com}/")" "403"

echo "8. Host hygiene"
disk="$(curl -s -m 20 "$DASH/api/status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("disk", {}).get("pressure", "unknown"))' 2>/dev/null)"
check "Hermes disk pressure ok (no 'disk is filling up' banner)" "${disk:-unknown}" "ok"
check "model bridge published on loopback only" \
  "$(docker port sourcecheck-bridge 2>/dev/null | awk '{print $NF}' | sort -u | tr '\n' ' ')" "127.0.0.1:18383 "

echo "9. Cleanup"
# Delete only the sessions these tests created (matched by their exact
# prompts), so they don't clutter the dashboard's Sessions list.
cleanup="$(sbx sh -c 'export HERMES_HOME=/sandbox/hermes HOME=/sandbox/hermes; cd /tmp
/opt/hermes/bin/hermes sessions export --format jsonl --only user-prompts --yes /tmp/verify-prompts.jsonl >/dev/null 2>&1
/opt/hermes/.venv/bin/python -I -c "
import json
markers = (\"E2E-CHECK:\", \"What is 17+25? Reply with only the number.\", \"Reply with exactly: SANDBOX_OK\")
ids = set()
for line in open(\"/tmp/verify-prompts.jsonl\"):
    row = json.loads(line)
    if any(m in row.get(\"text\", \"\") for m in markers):
        ids.add(row[\"session_id\"])
print(\"\n\".join(sorted(ids)))
" 2>/dev/null | while read -r id; do [ -n "$id" ] && /opt/hermes/bin/hermes sessions delete --yes "$id" >/dev/null 2>&1 && echo deleted; done
rm -f /tmp/verify-prompts.jsonl')"
echo "  INFO  removed $(printf '%s\n' "$cleanup" | grep -c deleted) test session(s)"

echo
echo "Result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
