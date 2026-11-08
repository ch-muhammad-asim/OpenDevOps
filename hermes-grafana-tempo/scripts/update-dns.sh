#!/usr/bin/env bash
# Create or update a proxied Cloudflare A record (idempotent).
#   CF_TOKEN_FILE=/path/to/token scripts/update-dns.sh <host> <ipv4>
#   CF_TOKEN_FILE=... DRY_RUN=1 scripts/update-dns.sh <host> <ipv4>
# CF_TOKEN_FILE: file holding a Cloudflare API token with Zone:DNS:Edit + Zone:Zone:Read
# (first "cfat_..." token or bare token line; chmod 600). The token is never printed or put
# on a command line: curl reads it from a private header file.
# CF_ZONE: zone name (default: the host without its first label).
set -euo pipefail

HOST="${1:?usage: update-dns.sh <host> <ipv4>}"
IP="${2:?usage: update-dns.sh <host> <ipv4>}"
ZONE="${CF_ZONE:-${HOST#*.}}"
: "${CF_TOKEN_FILE:?set CF_TOKEN_FILE to a Cloudflare DNS-edit token file}"

python3 -I -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$IP" 2>/dev/null \
  || { echo "error: not an IPv4 address: $IP" >&2; exit 2; }
[ -r "$CF_TOKEN_FILE" ] || { echo "error: CF_TOKEN_FILE not readable" >&2; exit 2; }
mode="$(stat -c %a "$CF_TOKEN_FILE" 2>/dev/null || stat -f %Lp "$CF_TOKEN_FILE")"
case "$mode" in 600|400) ;; *) echo "error: CF_TOKEN_FILE must be chmod 600 (is $mode)" >&2; exit 2 ;; esac

umask 077
hdr="$(mktemp)"; trap 'rm -f "$hdr"' EXIT
token="$(grep -o -m1 'cfat_[A-Za-z0-9_-]*' "$CF_TOKEN_FILE" || grep -m1 -E '^[A-Za-z0-9_-]{30,}$' "$CF_TOKEN_FILE" || true)"
[ -n "$token" ] || { echo "error: no token found in CF_TOKEN_FILE" >&2; exit 2; }
printf 'Authorization: Bearer %s\n' "$token" > "$hdr"; unset token

api() { curl -fsS -m 20 -H @"$hdr" -H 'Content-Type: application/json' "$@" \
  || { echo "error: Cloudflare API call failed" >&2; exit 1; }; }
jget() { python3 -I -c 'import json,sys; r=json.load(sys.stdin)["result"]; r=r[0] if isinstance(r,list) and r else (r or {}); print(r.get(sys.argv[1],"") if isinstance(r,dict) else "")' "$1"; }
jcount() { python3 -I -c 'import json,sys; r=json.load(sys.stdin)["result"] or []; print(len(r))'; }

zone_id="$(api "https://api.cloudflare.com/client/v4/zones?name=$ZONE" | jget id)"
[ -n "$zone_id" ] || { echo "error: zone $ZONE not found for this token" >&2; exit 1; }
rec="$(api "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$HOST")"
[ "$(printf '%s' "$rec" | jcount)" -le 1 ] || { echo "error: several A records for $HOST; fix by hand" >&2; exit 1; }
rec_id="$(printf '%s' "$rec" | jget id)"; cur="$(printf '%s' "$rec" | jget content)"; prox="$(printf '%s' "$rec" | jget proxied)"

if [ "$cur" = "$IP" ] && [ "$prox" = True ]; then echo "A $HOST: already correct (proxied)"; exit 0; fi
[ "${DRY_RUN:-0}" = 1 ] && { echo "A $HOST: would set to the load balancer address (proxied)"; exit 0; }
body="{\"type\":\"A\",\"name\":\"$HOST\",\"content\":\"$IP\",\"proxied\":true,\"ttl\":1}"
if [ -n "$rec_id" ]; then
  api -X PATCH --data "$body" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$rec_id" >/dev/null
else
  api -X POST --data "$body" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" >/dev/null
fi
echo "A $HOST: updated (proxied)"
