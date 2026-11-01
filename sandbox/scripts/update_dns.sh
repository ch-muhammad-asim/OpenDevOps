#!/usr/bin/env bash
# Point the Cloudflare A record for Hermes at the server's public IP (proxied).
# Use after a server restart that changed the IP (README "Server restarted /
# IP changed").
#
#   sandbox/scripts/update_dns.sh              # IP from sandbox/site.env
#   sandbox/scripts/update_dns.sh --detect     # on the server: its own public IP
#   sandbox/scripts/update_dns.sh --dry-run    # show what would change
#
# Token: CLOUDFLARE_API_TOKEN_FILE (default ~/Desktop/sandbox/creds/cloudflare/dns/api,
# chmod 600; the first "cfat_..." or bare token in the file) or
# CLOUDFLARE_API_TOKEN. Needs Zone:DNS:Edit and Zone:Zone:Read on the zone. The token is never
# printed or put on a command line (it goes to curl in a private header file).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Values given in the environment win over sandbox/site.env.
env_ip="${HERMES_ORIGIN_IP:-}"; env_host="${HERMES_HOST:-}"; env_zone="${CLOUDFLARE_ZONE:-}"
# shellcheck source=/dev/null
[ -r "$HERE/site.env" ] && . "$HERE/site.env"
SITE_HOST="${HERMES_HOST:-}"  # the host sandbox/site.env describes (the VM)
HOST="${env_host:-${HERMES_HOST:-hermes.saqlainmushtaq.com}}"
ZONE="${env_zone:-${CLOUDFLARE_ZONE:-${HOST#*.}}}"
IP="${env_ip:-${HERMES_ORIGIN_IP:-}}"
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --detect) IP="$(curl -fsS -m 10 https://checkip.amazonaws.com | tr -d '[:space:]')" ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
python3 -I -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$IP" 2>/dev/null \
  || { echo "error: no valid IPv4 address (set HERMES_ORIGIN_IP in site.env or use --detect)" >&2; exit 2; }

umask 077
hdr="$(mktemp)"; trap 'rm -f "$hdr"' EXIT
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  token="$CLOUDFLARE_API_TOKEN"
else
  f="${CLOUDFLARE_API_TOKEN_FILE:-$HOME/Desktop/sandbox/creds/cloudflare/dns/api}"
  mode="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || true)"  # GNU || macOS
  if [ -e "$f" ] && [ "$mode" != 600 ] && [ "$mode" != 400 ]; then
    echo "error: $f must be chmod 600 (it is ${mode:-unknown})" >&2; exit 2
  fi
  token="$(grep -o -m1 'cfat_[A-Za-z0-9_-]*' "$f" 2>/dev/null || grep -m1 -E '^[A-Za-z0-9_-]{30,}$' "$f" 2>/dev/null || true)"
fi
[ -n "$token" ] || { echo "error: no Cloudflare API token found" >&2; exit 2; }
printf 'Authorization: Bearer %s\n' "$token" > "$hdr"; unset token

api() {
  curl -fsS -m 20 -H @"$hdr" -H 'Content-Type: application/json' "$@" 2>/dev/null \
    || { echo "error: Cloudflare API call failed (check the token and its Zone:DNS:Edit permission)" >&2; exit 1; }
}
# field NAME: value from the first result (empty if none); count: number of results.
field() { python3 -I -c 'import json,sys; r=json.loads(sys.stdin.read() or "{}").get("result"); r=(r[0] if r else None) if isinstance(r,list) else r; print((r or {}).get(sys.argv[1],""))' "$1"; }
count() { python3 -I -c 'import json,sys; r=json.loads(sys.stdin.read() or "{}").get("result") or []; print(len(r) if isinstance(r,list) else 1)'; }

zones="$(api "https://api.cloudflare.com/client/v4/zones?name=$ZONE")"
zone_id="$(printf '%s' "$zones" | field id)"
[ -n "$zone_id" ] || { echo "error: zone $ZONE not found for this token" >&2; exit 1; }
rec="$(api "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$HOST")"
n="$(printf '%s' "$rec" | count)"
[ "$n" -le 1 ] || { echo "error: $n A records exist for $HOST; fix them by hand in the dashboard" >&2; exit 1; }
rec_id="$(printf '%s' "$rec" | field id)"
cur="$(printf '%s' "$rec" | field content)"
prox="$(printf '%s' "$rec" | field proxied)"

echo "A $HOST: current=${cur:-none} proxied=${prox:-n/a} -> wanted=$IP proxied=True"
if [ "$cur" = "$IP" ] && [ "$prox" = True ]; then echo "Already correct; nothing to do."; exit 0; fi
[ "$DRY" = 1 ] && { echo "(dry run: no change made)"; exit 0; }

body="{\"type\":\"A\",\"name\":\"$HOST\",\"content\":\"$IP\",\"proxied\":true,\"ttl\":1}"
if [ -n "$rec_id" ]; then
  api -X PATCH --data "$body" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$rec_id" >/dev/null
else
  api -X POST --data "$body" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" >/dev/null
fi
echo "Updated: A $HOST -> $IP (proxied)."
# site.env describes the VM host only; other hosts (e.g. hermes-gke) are not kept there.
if [ "$HOST" = "$SITE_HOST" ] && [ "$IP" != "${HERMES_ORIGIN_IP:-}" ]; then
  echo "Also set HERMES_ORIGIN_IP=$IP in sandbox/site.env."
fi
