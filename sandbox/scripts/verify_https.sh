#!/usr/bin/env bash
# End-to-end HTTPS checks for Hermes behind Cloudflare + Traefik.
# Runs from ANY machine (laptop or server) with bash, curl, openssl, python3.
#
#   sandbox/scripts/verify_https.sh                      # public checks only
#   HERMES_DASHBOARD_PASSWORD='...' HERMES_API_KEY='...' sandbox/scripts/verify_https.sh
#   sandbox/scripts/verify_https.sh --cleanup            # on the server: delete test chat sessions
#
# Tip: avoid putting secrets in shell history, e.g.
#   read -rs HERMES_DASHBOARD_PASSWORD; export HERMES_DASHBOARD_PASSWORD
#
# Environment:
#   HERMES_URL                 public URL       (default https://$HERMES_HOST from sandbox/site.env)
#   ORIGIN_IP                  server public IP (default HERMES_ORIGIN_IP from sandbox/site.env;
#                              on the server itself it is detected automatically)
#   CF_PROXIED                 1 = DNS must point at Cloudflare, not the origin (default 1)
#   HERMES_DASHBOARD_PASSWORD  optional: enables login + Chat (WebSocket) tests
#   HERMES_DASHBOARD_USERNAME  optional (default: from HERMES_ENV_FILE if readable, else admin)
#   HERMES_API_KEY             optional: enables API tests
#   BROWSER_CHECK              1 (default) runs the real-browser section when Node.js + Chrome exist; 0 skips
#   BROWSER_IDLE_SECONDS       idle time per browser round (default 180); CHROME: browser binary
#   SWITCH_CHECK=1             browser section also switches the model in the side panel and back
#                              (SWITCH_MODEL, default openai/gpt-oss-20b). Changes the live default for
#                              everyone for 1-2 min; always restores SWITCH_RESTORE_MODEL (nemotron)
#   --cleanup                  run when nobody is mid-chat: it also deletes empty (untyped) chat sessions
#
# Gate (PASS/FAIL): everything seen through Cloudflare, plus "the origin never
# serves the dashboard to a non-Cloudflare client". Origin TLS details are
# informational (WARN), because the edge is the browser-facing certificate.
# Secrets are passed via env/stdin/temp files only, never on a command line.
set -uo pipefail

# One place for the hostname and server IP: sandbox/site.env (update it after
# an IP change; see README "Server restarted / IP changed").
SITE_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/site.env"
# shellcheck source=/dev/null
[ -r "$SITE_ENV" ] && . "$SITE_ENV"
HERMES_URL="${HERMES_URL:-https://${HERMES_HOST:-hermes.saqlainmushtaq.com}}"
HERMES_URL="${HERMES_URL%/}"
HOST="${HERMES_URL#*://}"; HOST="${HOST%%/*}"; HOST="${HOST%%:*}"
ORIGIN_IP="${ORIGIN_IP:-${HERMES_ORIGIN_IP:-}}"
# On an EC2 server, ask the instance metadata service (works only on the host).
if [ -z "$ORIGIN_IP" ]; then
  tok="$(curl -s -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null)"
  ORIGIN_IP="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null)"
fi
[ -n "$ORIGIN_IP" ] || { echo "Set ORIGIN_IP or HERMES_ORIGIN_IP in sandbox/site.env (server public IP)" >&2; exit 2; }
CF_PROXIED="${CF_PROXIED:-1}"
EDGE_MIN_DAYS="${EDGE_MIN_DAYS:-14}"
ORIGIN_MIN_DAYS="${ORIGIN_MIN_DAYS:-30}"
HERMES_ENV_FILE="${HERMES_ENV_FILE:-$HOME/.config/hermes-sandbox/hermes.env}"
HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:v0.22.5}"
OPENSHELL="${OPENSHELL:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UA="${UA:-hermes-verify-https/1.0}"
CF_ORIGIN_CA_URLS="https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem"

pass=0; fail=0; warn=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
wrn()  { printf '  WARN  %s\n' "$1"; warn=$((warn + 1)); }
skip() { printf '  SKIP  %s\n' "$1"; }
info() { printf '  INFO  %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $3, got $2)"; fi; }

# Portable timeout (macOS has no `timeout`; perl is everywhere).
to() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else perl -e 'alarm shift; exec @ARGV' "$@"; fi
}

# Delete only the chat sessions these tests created (matched by their exact
# prompts). Needs the OpenShell CLI, i.e. run it on the server.
cleanup_sessions() {
  local out
  out="$(to 600 "$OPENSHELL" sandbox exec -n "$SANDBOX_NAME" --no-tty -- sh -c 'export HERMES_HOME=/sandbox/hermes HOME=/sandbox/hermes; cd /tmp
# Never trust an export left behind by an earlier, interrupted run.
rm -f /tmp/verify-prompts.jsonl /tmp/verify-with-prompts /tmp/verify-with-prompts.tmp
/opt/hermes/bin/hermes sessions export --format jsonl --only user-prompts --yes /tmp/verify-prompts.jsonl >/dev/null 2>&1 \
  || { echo "export failed; deleting nothing" >&2; rm -f /tmp/verify-prompts.jsonl; exit 0; }
/opt/hermes/.venv/bin/python -I -c "
import json
markers = (\"E2E-CHECK:\", \"What is 17+25? Reply with only the number.\", \"Reply with exactly: SANDBOX_OK\")
ids = set()
for line in open(\"/tmp/verify-prompts.jsonl\"):
    row = json.loads(line)
    if row.get(\"text\", \"\").lstrip().startswith(markers):
        ids.add(row[\"session_id\"])
print(\"\n\".join(sorted(ids)))
" 2>/dev/null | while read -r id; do [ -n "$id" ] && /opt/hermes/bin/hermes sessions delete --yes "$id" >/dev/null 2>&1 && echo deleted; done
# Chat/idle/browser checks open terminals without typing: those sessions are
# empty. Delete sessions with no user message at all (nothing to lose).
# Fail closed: without a readable export, delete nothing.
[ -s /tmp/verify-prompts.jsonl ] || { echo "export failed; skipping empty-session cleanup" >&2; rm -f /tmp/verify-prompts.jsonl; exit 0; }
/opt/hermes/.venv/bin/python -I -c "
import json
print(\"\n\".join({json.loads(l)[\"session_id\"] for l in open(\"/tmp/verify-prompts.jsonl\")}))
" > /tmp/verify-with-prompts.tmp 2>/dev/null && [ -s /tmp/verify-with-prompts.tmp ] \
  || { echo "could not read session prompts; skipping empty-session cleanup" >&2; rm -f /tmp/verify-prompts.jsonl /tmp/verify-with-prompts.tmp; exit 0; }
mv /tmp/verify-with-prompts.tmp /tmp/verify-with-prompts
/opt/hermes/bin/hermes sessions list --limit 500 2>/dev/null | grep -o "local-[0-9a-f]*" | while read -r id; do
  grep -q "^$id" /tmp/verify-with-prompts || { /opt/hermes/bin/hermes sessions delete --yes "$id" >/dev/null 2>&1 && echo deleted; }
done
rm -f /tmp/verify-prompts.jsonl /tmp/verify-with-prompts' 2>&1)"
  info "removed $(printf '%s\n' "$out" | grep -c deleted) test session(s)"
}

if [ "${1:-}" = "--cleanup" ]; then
  command -v "$OPENSHELL" >/dev/null 2>&1 \
    || { echo "--cleanup needs the OpenShell CLI: run it on the server" >&2; exit 2; }
  cleanup_sessions
  exit 0
fi

for tool in curl openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 2; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
umask 077

USERNAME="${HERMES_DASHBOARD_USERNAME:-}"
if [ -z "$USERNAME" ] && [ -r "$HERMES_ENV_FILE" ]; then
  USERNAME="$(grep -m1 '^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' "$HERMES_ENV_FILE" | cut -d= -f2-)"
fi
USERNAME="${USERNAME:-admin}"

# curl helpers: status code, and "code redirect_url" (body saved to $TMP/body).
code() { curl -s -m 30 -o /dev/null -w '%{http_code}' "$@"; }
code_loc() { curl -s -m 30 -o "$TMP/body" -w '%{http_code} %{redirect_url}' "$@"; }

# Days until a PEM certificate (first one in file $1) expires.
days_left() {
  local end
  end="$(openssl x509 -in "$1" -noout -enddate 2>/dev/null | cut -d= -f2-)"
  [ -n "$end" ] || { echo -1; return; }
  python3 -I -c 'import sys, datetime as d
t = d.datetime.strptime(sys.argv[1], "%b %d %H:%M:%S %Y GMT").replace(tzinfo=d.timezone.utc)
print(int((t - d.datetime.now(d.timezone.utc)).total_seconds() // 86400))' "$end"
}

# openssl s_client to <ip-or-host> with SNI $HOST; output in file $2; extra args after.
tls_probe() {
  local target="$1" outfile="$2"; shift 2
  to 20 openssl s_client -connect "$target:443" -servername "$HOST" "$@" </dev/null >"$outfile" 2>&1
}
verify_code() { grep -m1 'Verify return code' "$1" | sed -E 's/.*Verify return code: ([0-9]+).*/\1/'; }
# OpenSSL versions print the protocol differently ("Protocol: TLSv1.3" or
# "New, TLSv1.3, Cipher is ..."); accept either.
proto_of() { grep -m1 -E 'Protocol *:|^New, TLSv' "$1" | grep -Eo 'TLSv1(\.[0-3])?' | head -n1; }

# Is a legacy protocol (flag $2: -tls1 / -tls1_1) refused by target $1?
legacy_proto() {
  local out
  out="$(to 15 openssl s_client -connect "$1:443" -servername "$HOST" "$2" -cipher 'DEFAULT:@SECLEVEL=0' </dev/null 2>&1)"
  case "$out" in
    *'no protocols available'*|*'nknown option'*|*'ption unknown'*) echo unsupported ;;
    *'Cipher is (NONE)'*|*'alert protocol version'*|*'wrong version'*|*'unsupported protocol'*|*'handshake failure'*) echo refused ;;
    *'BEGIN CERTIFICATE'*) echo accepted ;;
    *) echo refused ;;
  esac
}

# Judge a direct-to-origin response: the dashboard must never be served.
# $1 = label, $2 = "code redirect_url", body in $TMP/body.
origin_verdict() {
  local label="$1" c="${2%% *}" loc="${2#* }"
  [ "$loc" = "$2" ] && loc=""
  case "$c" in
    000) ok "$label: not reachable (filtered/closed)" ;;
    403) ok "$label: 403 refused (Cloudflare-only allow-list)" ;;
    404) ok "$label: 404 (no route for this request)" ;;
    301|302|303|307|308)
      case "$loc" in
        https://*/login*|*/login*) bad "$label: redirects to the dashboard login ($c -> $loc)" ;;
        https://*) ok "$label: redirects to HTTPS ($c -> $loc)" ;;
        *) bad "$label: unexpected redirect ($c -> $loc)" ;;
      esac ;;
    2*) if grep -qi 'hermes' "$TMP/body" 2>/dev/null; then bad "$label: serves dashboard content ($c)"
        else bad "$label: serves content ($c)"; fi ;;
    4*) ok "$label: refused ($c)" ;;
    *) wrn "$label: unexpected status $c" ;;
  esac
}

echo "Target: $HERMES_URL (host $HOST, origin $ORIGIN_IP)"

echo "1. DNS"
# Cloudflare ranges, source: https://www.cloudflare.com/ips/ (checked 2026-10-30)
dns="$(python3 -I - "$HOST" "$ORIGIN_IP" <<'PY'
import ipaddress, socket, sys
CF = """173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
2a06:98c0::/29 2c0f:f248::/32""".split()
nets = [ipaddress.ip_network(n) for n in CF]
try:
    ips = sorted({a[4][0] for a in socket.getaddrinfo(sys.argv[1], 443, proto=socket.IPPROTO_TCP)})
except socket.gaierror:
    ips = []
for ip in ips:
    a = ipaddress.ip_address(ip)
    tag = "cloudflare" if any(a in n for n in nets) else ("origin" if ip == sys.argv[2] else "other")
    print(ip, tag)
PY
)"
if [ -z "$dns" ]; then
  bad "$HOST resolves"
else
  ok "$HOST resolves to: $(printf '%s' "$dns" | awk '{print $1}' | paste -sd' ' -)"
  if [ "$CF_PROXIED" = "1" ]; then
    if printf '%s\n' "$dns" | grep -qv ' cloudflare$'; then
      bad "all addresses are Cloudflare (proxied): $(printf '%s\n' "$dns" | grep -v ' cloudflare$' | paste -sd' ' -)"
    else
      ok "all addresses are Cloudflare ranges (origin IP hidden)"
    fi
  fi
fi

echo "2. Edge TLS (via Cloudflare, browser-trusted)"
edge="$TMP/edge.txt"
tls_probe "$HOST" "$edge" -verify_hostname "$HOST"
if grep -q 'BEGIN CERTIFICATE' "$edge"; then
  check "certificate chain + hostname verify (openssl verify code)" "$(verify_code "$edge")" "0"
  info "issuer: $(openssl x509 -in "$edge" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  d="$(days_left "$edge")"
  if [ "$d" -gt "$EDGE_MIN_DAYS" ]; then ok "expires in $d days (> $EDGE_MIN_DAYS)"; else bad "expires in $d days (<= $EDGE_MIN_DAYS)"; fi
  p="$(proto_of "$edge")"
  case "$p" in TLSv1.2|TLSv1.3) ok "negotiated $p" ;; *) bad "negotiated protocol is ${p:-unknown} (want >= TLSv1.2)" ;; esac
  for f in -tls1 -tls1_1; do
    case "$(legacy_proto "$HOST" "$f")" in
      refused) ok "edge refuses ${f#-}" ;;
      accepted) wrn "edge accepts ${f#-} (set Cloudflare Minimum TLS Version to 1.2)" ;;
      *) skip "edge ${f#-} probe (local openssl cannot offer it)" ;;
    esac
  done
else
  bad "TLS handshake with $HOST:443: $(tail -n 2 "$edge" | tr '\n' ' ')"
fi

echo "3. Origin (direct to $ORIGIN_IP, bypassing Cloudflare)"
orig="$TMP/origin.txt"
tls_probe "$ORIGIN_IP" "$orig"
if grep -q 'BEGIN CERTIFICATE' "$orig"; then
  subj="$(openssl x509 -in "$orig" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  iss="$(openssl x509 -in "$orig" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  od="$(days_left "$orig")"
  info "origin cert subject: $subj | issuer: $iss | expires in $od days"
  case "$subj$iss" in
    *'TRAEFIK DEFAULT CERT'*)
      wrn "origin presents Traefik's self-signed default cert: works with Cloudflare SSL mode Full, not Full (strict)" ;;
    *'CloudFlare Origin'*)
      roots="$TMP/cf-origin-roots.pem"
      for u in $CF_ORIGIN_CA_URLS; do curl -fsS -m 20 "$u" >>"$roots" 2>/dev/null; done
      if grep -q 'BEGIN CERTIFICATE' "$roots" 2>/dev/null; then
        tls_probe "$ORIGIN_IP" "$TMP/origin-ca.txt" -CAfile "$roots" -verify_hostname "$HOST"
        vc="$(verify_code "$TMP/origin-ca.txt")"
        if [ "$vc" = "0" ] && [ "$od" -gt "$ORIGIN_MIN_DAYS" ]; then
          ok "Cloudflare Origin cert valid for $HOST (Origin CA verify OK, $od days left): Full (strict) ready"
        else
          wrn "Cloudflare Origin cert: verify code ${vc:-?} against Origin CA roots, $od days left (want 0 and > $ORIGIN_MIN_DAYS)"
        fi
      else
        wrn "could not download Cloudflare Origin CA roots to verify the origin cert"
      fi ;;
    *)
      tls_probe "$ORIGIN_IP" "$TMP/origin-pub.txt" -verify_hostname "$HOST"
      if [ "$(verify_code "$TMP/origin-pub.txt")" = "0" ]; then ok "origin cert publicly trusted for $HOST"
      else wrn "origin cert is not valid for $HOST (verify code $(verify_code "$TMP/origin-pub.txt"))"; fi ;;
  esac
  # The exact check for Cloudflare SSL mode "Full (strict)": Cloudflare only
  # trusts certificates from its Origin CA (or public CAs) for $HOST.
  roots="$TMP/cf-origin-roots.pem"
  [ -s "$roots" ] || for u in $CF_ORIGIN_CA_URLS; do curl -fsS -m 20 "$u" >>"$roots" 2>/dev/null; done
  cr_out="$(curl --resolve "$HOST:443:$ORIGIN_IP" --cacert "$roots" -sS -o /dev/null -m 20 -w '%{http_code}' "https://$HOST/" 2>&1)"
  cr_rc=$?
  if [ "$cr_rc" = 0 ]; then
    ok "curl --resolve $HOST:443:$ORIGIN_IP: origin certificate verified for $HOST (HTTP $cr_out); Full (strict) works"
  elif [ "$cr_rc" = 60 ] || [ "$cr_rc" = 35 ]; then
    cr_err="$(printf '%s\n' "$cr_out" | grep -m1 'curl: (' | sed 's/^curl: //')"
    wrn "curl --resolve $HOST:443:$ORIGIN_IP: origin certificate NOT trusted (${cr_err:-rc=$cr_rc}): Cloudflare 'Full (strict)' would give 526; install the Cloudflare Origin Certificate (README Step 6)"
  else
    wrn "curl --resolve $HOST:443:$ORIGIN_IP failed (rc=$cr_rc: ${cr_out:0:120})"
  fi
  for f in -tls1 -tls1_1; do
    case "$(legacy_proto "$ORIGIN_IP" "$f")" in
      refused) ok "origin refuses ${f#-}" ;;
      accepted) wrn "origin accepts ${f#-} (Traefik tls options minVersion should be VersionTLS12)" ;;
      *) skip "origin ${f#-} probe (local openssl cannot offer it)" ;;
    esac
  done
  origin_verdict "origin https://$ORIGIN_IP/ (Host $HOST)" \
    "$(code_loc -k --resolve "$HOST:443:$ORIGIN_IP" "https://$HOST/")"
else
  ok "origin 443 not reachable directly (expected with a Cloudflare-only firewall/SG; the edge checks prove Cloudflare reaches it)"
  why="$(grep -m1 -iE 'errno|refused|timed out|error' "$orig" | cut -c1-160)"
  info "openssl: ${why:-no TCP connection within 20s (port filtered)}"
fi
origin_verdict "origin http://$ORIGIN_IP/ (Host $HOST)" \
  "$(code_loc -H "Host: $HOST" "http://$ORIGIN_IP/")"
origin_verdict "origin http://$ORIGIN_IP/ (Host $HOST, spoofed X-Forwarded-Proto: https)" \
  "$(code_loc -H "Host: $HOST" -H 'X-Forwarded-Proto: https' "http://$ORIGIN_IP/")"
origin_verdict "origin http://$ORIGIN_IP/login (spoofed X-Forwarded-Proto: https)" \
  "$(code_loc -H "Host: $HOST" -H 'X-Forwarded-Proto: https' "http://$ORIGIN_IP/login")"
origin_verdict "origin http://$ORIGIN_IP/ (bare IP, no Host)" "$(code_loc "http://$ORIGIN_IP/")"

echo "4. HTTP -> HTTPS redirect (via Cloudflare)"
r="$(code_loc "http://$HOST/")"
case "$r" in
  "301 https://$HOST/"|"308 https://$HOST/") ok "http://$HOST/ -> ${r}" ;;
  *) bad "http://$HOST/ should 301/308 to https://$HOST/ (got: $r)" ;;
esac

echo "5. Security headers (https://$HOST/login)"
edge_code="$(code "$HERMES_URL/login")"
case "$edge_code" in
  52[0-9]) info "Cloudflare returns $edge_code: it cannot reach the origin on 443 (Traefik not running, or AWS SG/firewall blocks Cloudflare)" ;;
  000) info "no answer from Cloudflare within 30s" ;;
esac
curl -s -m 30 -D "$TMP/h" -o /dev/null "$HERMES_URL/login"
tr -d '\r' <"$TMP/h" >"$TMP/hdr"
hsts="$(grep -i '^strict-transport-security:' "$TMP/hdr" | grep -Eio 'max-age=[0-9]+' | cut -d= -f2 | head -n1)"
# Traefik sends 1 year; Cloudflare's own HSTS setting (6 months is common)
# replaces it at the edge. Require at least 6 months.
if [ -n "$hsts" ] && [ "$hsts" -ge 15552000 ]; then ok "Strict-Transport-Security max-age=$hsts (>= 6 months)"
else bad "Strict-Transport-Security max-age >= 15552000 (got: ${hsts:-missing})"; fi
if grep -qi '^x-content-type-options: *nosniff' "$TMP/hdr"; then ok "X-Content-Type-Options: nosniff"
else bad "X-Content-Type-Options: nosniff missing"; fi
if grep -Eqi '^x-frame-options: *(deny|sameorigin)' "$TMP/hdr" || grep -Eqi '^content-security-policy:.*frame-ancestors' "$TMP/hdr"; then
  ok "frame protection (X-Frame-Options or CSP frame-ancestors)"
else bad "frame protection header missing"; fi

echo "6. Dashboard over HTTPS"
r="$(code_loc "$HERMES_URL/")"
case "$r" in 302*/login*) ok "unauthenticated / -> 302 to /login" ;; *) bad "unauthenticated / should 302 to /login (got: $r)" ;; esac
r="$(code_loc "$HERMES_URL/chat")"
case "$r" in 30[1278]*/login*) ok "unauthenticated /chat -> redirect to login" ;; *) bad "unauthenticated /chat should redirect to login (got: $r)" ;; esac
r="$(code_loc "$HERMES_URL/login")"
if [ "${r%% *}" = "200" ] && grep -Eio '<title>[^<]*' "$TMP/body" | grep -qi hermes; then
  ok "/login 200 with 'Hermes' in the title"
else bad "/login 200 with 'Hermes' title (got: ${r%% *})"; fi
check "API without session is rejected" "$(code "$HERMES_URL/api/auth/me")" "401"
if [ -n "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
  # JSON is built by python from env and sent on stdin: no password on argv.
  login_code="$(HERMES_DASHBOARD_USERNAME="$USERNAME" python3 -I -c 'import json, os
print(json.dumps({"provider": "basic", "username": os.environ["HERMES_DASHBOARD_USERNAME"],
                  "password": os.environ["HERMES_DASHBOARD_PASSWORD"]}))' \
    | curl -s -m 20 -o /dev/null -w '%{http_code}' -D "$TMP/lh" -c "$TMP/jar" \
        -H 'Content-Type: application/json' --data @- "$HERMES_URL/auth/password-login")"
  check "login with the dashboard password" "$login_code" "200"
  if tr -d '\r' <"$TMP/lh" | grep -i '^set-cookie:' | grep -qi '; *secure'; then ok "session cookie has the Secure flag"
  else bad "session cookie has the Secure flag"; fi
  check "/api/auth/me with the session cookie" "$(code -b "$TMP/jar" "$HERMES_URL/api/auth/me")" "200"
  check "login with a wrong password is refused" \
    "$(code -H 'Content-Type: application/json' -d "{\"provider\":\"basic\",\"username\":\"$USERNAME\",\"password\":\"wrong\"}" "$HERMES_URL/auth/password-login")" "401"
else
  skip "login tests (set HERMES_DASHBOARD_PASSWORD)"
fi

echo "7. Hermes API over HTTPS"
if [ -n "${HERMES_API_KEY:-}" ]; then
  printf 'Authorization: Bearer %s\n' "$HERMES_API_KEY" >"$TMP/auth"   # header file: key stays off argv
  check "/v1/models without API key is rejected" "$(code "$HERMES_URL/v1/models")" "401"
  check "/v1/models with a wrong API key is rejected" "$(code -H 'Authorization: Bearer wrong' "$HERMES_URL/v1/models")" "401"
  check "/v1/models with the API key is accepted" "$(code -H @"$TMP/auth" "$HERMES_URL/v1/models")" "200"
else
  check "/v1/models without API key is rejected" "$(code "$HERMES_URL/v1/models")" "401"
  skip "authenticated API test (set HERMES_API_KEY)"
fi

echo "8. Chat page over HTTPS/WSS (Start new session)"
chat_ran=0
if [ -n "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
  # CHAT_RUNNER=python forces a local python3 (skips the 4 GB Hermes image).
  if [ "${CHAT_RUNNER:-auto}" != python ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    # Throwaway Hermes container (has `websockets`); password goes in on stdin.
    chat_out="$(printf '%s\n' "$HERMES_DASHBOARD_PASSWORD" | to 300 docker run --rm -i \
      -e HERMES_DASHBOARD_USERNAME="$USERNAME" -e LLM_CHECKS="${LLM_CHECKS:-0}" \
      -v "$SCRIPT_DIR/chat_e2e.py:/t/chat_e2e.py:ro" \
      --entrypoint sh "$HERMES_IMAGE" -c \
      'IFS= read -r HERMES_DASHBOARD_PASSWORD; export HERMES_DASHBOARD_PASSWORD; /opt/hermes/.venv/bin/python -I /t/chat_e2e.py "$0"' "$HERMES_URL" 2>&1)"
    chat_ran=1
  elif python3 -c 'import websockets' >/dev/null 2>&1; then
    chat_out="$(HERMES_DASHBOARD_USERNAME="$USERNAME" HERMES_DASHBOARD_PASSWORD="$HERMES_DASHBOARD_PASSWORD" \
      to 300 python3 "$SCRIPT_DIR/chat_e2e.py" "$HERMES_URL" 2>&1)"
    chat_ran=1
  else
    skip "Chat test: needs docker or a local python3 with the 'websockets' package"
  fi
  if [ "$chat_ran" = 1 ]; then
    case "$chat_out" in
      *"answer received"*) ok "Chat over wss: new session gets a PTY and answers" ;;
      *"no prompt sent"*) ok "Chat over wss: login, WebSocket and PTY session start (no model call; LLM_CHECKS=1 to ask)" ;;
      *"chat session: started"*) ok "Chat over wss: login, WebSocket and PTY session start"
        wrn "Chat over wss: no answer from the model (endpoint down or out of quota; not a sandbox/HTTPS fault)" ;;
      *) bad "Chat over wss: ${chat_out: -300}" ;;
    esac
  fi
else
  skip "Chat test (set HERMES_DASHBOARD_PASSWORD)"
fi

echo "9. Chat stays connected while idle (Cloudflare drops sockets idle > 100 s)"
if [ -n "${HERMES_DASHBOARD_PASSWORD:-}" ]; then
  soak="${SOAK_SECONDS:-130}"
  soak_out=""; soak_ran=0
  if [ "${CHAT_RUNNER:-auto}" != python ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    soak_out="$(printf '%s\n' "$HERMES_DASHBOARD_PASSWORD" | to $((soak + 120)) docker run --rm -i \
      -e HERMES_DASHBOARD_USERNAME="$USERNAME" \
      -v "$SCRIPT_DIR/ws_soak.py:/t/ws_soak.py:ro" \
      --entrypoint sh "$HERMES_IMAGE" -c \
      'IFS= read -r HERMES_DASHBOARD_PASSWORD; export HERMES_DASHBOARD_PASSWORD; /opt/hermes/.venv/bin/python -I /t/ws_soak.py "$0" "$1"' "$HERMES_URL" "$soak" 2>&1)"
    soak_ran=1
  elif python3 -c 'import websockets' >/dev/null 2>&1; then
    soak_out="$(HERMES_DASHBOARD_USERNAME="$USERNAME" HERMES_DASHBOARD_PASSWORD="$HERMES_DASHBOARD_PASSWORD" \
      to $((soak + 120)) python3 "$SCRIPT_DIR/ws_soak.py" "$HERMES_URL" "$soak" 2>&1)"
    soak_ran=1
  else
    skip "idle WebSocket test: needs docker or a local python3 with 'websockets'"
  fi
  if [ "$soak_ran" = 1 ]; then
    for name in "chat terminal /api/pty" "side panel /api/ws" "events /api/events"; do
      line="$(printf '%s\n' "$soak_out" | grep -F "$name:" | head -1)"
      case "$line" in PASS*) ok "${line#PASS  }" ;; *) bad "$name: ${line:-${soak_out: -200}}" ;; esac
    done
  fi
else
  skip "idle WebSocket test (set HERMES_DASHBOARD_PASSWORD)"
fi

echo "10. Hermes disk status (dashboard banner)"
disk="$(curl -sS -m 30 -A "$UA" "$HERMES_URL/api/status" 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin).get("disk") or {}; print(d.get("pressure","unknown"), d.get("free_mb","?"), d.get("used_percent","?"))' 2>/dev/null)"
read -r d_press d_free d_used <<<"${disk:-unknown ? ?}"
if [ "$d_press" = ok ]; then ok "disk pressure ok (${d_free} MB free, ${d_used}% used): no 'disk is filling up' banner"
else bad "disk pressure ${d_press} (${d_free} MB free, ${d_used}% used): run sandbox/scripts/housekeeping.sh on the server"; fi

echo "11. Real browser (Chrome): chat, side panel, idle, reload"
if [ "${BROWSER_CHECK:-1}" = 1 ] && [ -n "${HERMES_DASHBOARD_PASSWORD:-}" ] && command -v node >/dev/null 2>&1 \
   && { [ -n "${CHROME:-}" ] || command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1 \
        || command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; }; then
  bc_out="$(HERMES_URL="$HERMES_URL" HERMES_DASHBOARD_USERNAME="$USERNAME" IDLE_SECONDS="${BROWSER_IDLE_SECONDS:-180}" \
    bash "$SCRIPT_DIR/browser_check.sh" 2>&1)"
  mapped=0
  while IFS= read -r line; do
    case "$line" in
      "  PASS  "*) ok "${line#  PASS  }"; mapped=$((mapped + 1)) ;;
      "  FAIL  "*) bad "${line#  FAIL  }"; mapped=$((mapped + 1)) ;;
    esac
  done <<<"$bc_out"
  [ "$mapped" -gt 0 ] || bad "browser check produced no result: ${bc_out: -200}"
  chat_ran=1
else
  skip "real-browser check (needs HERMES_DASHBOARD_PASSWORD, Node.js and Chrome; BROWSER_CHECK=0 skips it)"
fi

echo "12. Cleanup"
if [ "$chat_ran" = 1 ]; then
  if command -v "$OPENSHELL" >/dev/null 2>&1 && "$OPENSHELL" sandbox list 2>/dev/null | grep -qE "^$SANDBOX_NAME\b"; then
    cleanup_sessions
  else
    info "remove the test chat session on the server with:"
    info "  ssh cloud_user@$ORIGIN_IP 'cd ~/OpenDevOps && sandbox/scripts/verify_https.sh --cleanup'"
  fi
else
  info "no chat sessions created"
fi

echo
echo "Result: $pass passed, $fail failed, $warn warnings"
[ "$fail" -eq 0 ]
