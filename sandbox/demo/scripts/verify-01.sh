#!/usr/bin/env bash
# UC 01: the agent answers through the approved model endpoints only.
#
#   sandbox/demo/scripts/verify-01.sh [--with-llm]
#
# Exec path (no LLM needed): Hermes's Python reaches the OpenCode bridge on
# the allowed routes (ALLOWED in the log); an unlisted route on the same host
# is refused by the L7 rules (HTTP 403, DENIED in the log); the Hermes API
# requires its key. --with-llm also sends the DEMO-01 prompt through the API.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== verify-01: allowed chat via the OpenCode bridge =="
t0="$(now)"

section "1. Allowed routes (Hermes Python -> OpenCode bridge, host.openshell.internal:18383)"
out="$(sbx_py <<EOF
import urllib.request as u
for path in ("/v1/models", "/health"):
    try:
        print(path, "HTTP", u.urlopen("$BRIDGE" + path, timeout=15).status)
    except Exception as e:
        print(path, "ERROR", e)
EOF
)"
expect_has "GET /v1/models allowed (HTTP 200)" "$(printf '%s\n' "$out" | grep '^/v1/models')" "HTTP 200"
expect_has "GET /health allowed (HTTP 200)" "$(printf '%s\n' "$out" | grep '^/health')" "HTTP 200"
expect_log "ALLOWED NET:OPEN by policy opencode_bridge" "$t0" \
  'NET:OPEN \[INFO\] ALLOWED .*python3\.14.* -> host\.openshell\.internal:18383 \[policy:opencode_bridge'
expect_log "ALLOWED GET /v1/models (L7)" "$t0" \
  'HTTP:GET \[INFO\] ALLOWED GET http://host\.openshell\.internal:18383/v1/models \[policy:opencode_bridge engine:l7\]'

section "2. Unlisted route on the same host is refused (L7 rules)"
t1="$(now)"
out="$(sbx_py <<EOF
import urllib.request as u
try:
    r = u.urlopen(u.Request("$BRIDGE/v1/admin/demo-01", data=b"{}", method="POST"), timeout=15)
    print("HTTP", r.status)
except Exception as e:
    print("REFUSED", e)
EOF
)"
expect_has "POST /v1/admin/demo-01 refused (HTTP 403)" "$out" "HTTP Error 403"
expect_log "DENIED POST /v1/admin/demo-01 (L7)" "$t1" \
  'HTTP:POST \[MED\] DENIED POST http://host\.openshell\.internal:18383/v1/admin/demo-01'

section "3. Hermes API on the server (${HERMES_ADDR}:${API_PORT:-8642})"
code="$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$API/v1/models")"
[ "$code" = 401 ] && pass "API without key -> 401" || fail "API without key -> $code (expected 401)"
code="$(api_curl -m 15 -o /dev/null -w '%{http_code}' "$API/v1/models")"
[ "$code" = 200 ] && pass "API with key -> 200" || fail "API with key -> $code (expected 200)"

section "4. Prompt path (DEMO-01)"
t2="$(now)"
llm_step "DEMO-01 answered" "DEMO-01: In one sentence, what is a software sandbox? Do not use any tools." '[a-z]'
if [ "$LLM_SENT" -eq 1 ]; then
  # Even when the quota is exhausted the request itself reaches the endpoint.
  # The default model is on NVIDIA (provider rule); the OpenCode bridge is the
  # alternative. Either allowed route proves the model call went through policy.
  expect_log "ALLOWED POST /v1/chat/completions (L7, NVIDIA provider or bridge)" "$t2" \
    'HTTP:POST \[INFO\] ALLOWED POST (https://integrate\.api\.nvidia\.com|http://host\.openshell\.internal:18383)/v1/chat/completions'
fi

finish
