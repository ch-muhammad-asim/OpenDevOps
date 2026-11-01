#!/usr/bin/env bash
# Put Hermes behind Traefik on ports 80/443 (HTTPS via Cloudflare).
# Run after scripts/up.sh. Idempotent: safe to re-run.
#
#   sandbox/scripts/https_up.sh
#
# No certificate or token is required. Cloudflare's edge serves the
# browser-trusted certificate; Traefik serves its built-in one on :443.
# Optional: put a Cloudflare Origin Certificate in
# ~/.config/hermes-sandbox/tls/origin.pem + origin.key (chmod 600) and re-run
# to enable Cloudflare SSL mode "Full (strict)".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_HOST="${HERMES_HOST:-hermes.saqlainmushtaq.com}"
NETWORK="${NETWORK:-openshell_default}"
TRAEFIK_TLS_DIR="${TRAEFIK_TLS_DIR:-$HOME/.config/hermes-sandbox/tls}"
TRAEFIK_UID="${TRAEFIK_UID:-$(id -u)}"
TRAEFIK_GID="${TRAEFIK_GID:-$(id -g)}"
export TRAEFIK_TLS_DIR TRAEFIK_UID TRAEFIK_GID

TRAEFIK_COMPOSE="$HERE/traefik/docker-compose.yml"
TUNNEL_COMPOSE="$HERE/tunnel/docker-compose.yml"
ORIGIN_TEMPLATE="$HERE/traefik/tls-origin.yml.tmpl"
ORIGIN_DYNAMIC="$HERE/traefik/dynamic/tls-origin.yml"

log() { printf '\n==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

docker network inspect "$NETWORK" >/dev/null 2>&1 \
  || die "Docker network $NETWORK not found; run sandbox/scripts/up.sh first"

log "Checking the optional Cloudflare Origin Certificate in $TRAEFIK_TLS_DIR"
# The folder is always mounted (read-only), so make sure it exists.
mkdir -p "$TRAEFIK_TLS_DIR"
chmod 700 "$TRAEFIK_TLS_DIR"
cert="$TRAEFIK_TLS_DIR/origin.pem"
key="$TRAEFIK_TLS_DIR/origin.key"
if [ -f "$cert" ] && [ -f "$key" ]; then
  key_mode="$(stat -c '%a' "$key")"
  [ "$key_mode" = 600 ] || [ "$key_mode" = 400 ] \
    || die "$key has mode $key_mode; run: chmod 600 $key"
  if [ ! -r "$cert" ] || [ ! -r "$key" ]; then
    die "cannot read $cert / $key as $(id -un)"
  fi
  # Catch mismatched or wrong-host files now instead of as Cloudflare 525/526.
  [ "$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null)" = "$(openssl pkey -in "$key" -pubout 2>/dev/null)" ] \
    || die "origin.pem and origin.key do not belong together"
  openssl x509 -in "$cert" -noout -checkhost "$HERMES_HOST" 2>/dev/null | grep -q "does match" \
    || die "origin.pem does not cover $HERMES_HOST"
  cp "$ORIGIN_TEMPLATE" "$ORIGIN_DYNAMIC"
  echo "Origin certificate found: Traefik will serve it (Cloudflare 'Full (strict)' OK)."
  openssl x509 -in "$cert" -noout -subject -enddate 2>/dev/null || true
elif [ -e "$cert" ] || [ -e "$key" ]; then
  die "only one of origin.pem / origin.key exists in $TRAEFIK_TLS_DIR; add the other or remove it"
else
  rm -f "$ORIGIN_DYNAMIC"
  echo "No origin certificate: Traefik uses its built-in certificate (use Cloudflare SSL mode 'Full')."
fi

# The old nginx proxy (before Traefik) published port 80; remove it if present.
if docker inspect hermes-proxy >/dev/null 2>&1; then
  log "Removing the old hermes-proxy container (replaced by Traefik)"
  docker rm -f hermes-proxy >/dev/null
fi

log "Starting hermes-tunnel (OpenShell forwards to Hermes, no host ports)"
docker compose -f "$TUNNEL_COMPOSE" up -d --build
docker builder prune -af >/dev/null 2>&1 || true  # don't keep build cache around

log "Starting Traefik on ports 80 and 443"
docker compose -f "$TRAEFIK_COMPOSE" up -d

log "Waiting for Traefik to report healthy"
status=""
for _ in $(seq 1 30); do
  status="$(docker inspect -f '{{.State.Health.Status}}' hermes-traefik 2>/dev/null || true)"
  [ "$status" = healthy ] && break
  sleep 2
done
[ "$status" = healthy ] || die "Traefik is '$status'; check: docker logs hermes-traefik"
docker compose -f "$TRAEFIK_COMPOSE" ps

cat <<EOF

Traefik is serving https://$HERMES_HOST (via Cloudflare).
Next steps:
  1. AWS security group: allow inbound TCP 443 and 80 (Cloudflare connects to them).
  2. Cloudflare DNS: A record "${HERMES_HOST%%.*}" -> this server, Proxied (orange cloud).
  3. Cloudflare SSL/TLS mode: "Full" (or "Full (strict)" with an origin certificate).
  4. Check from outside: curl -sSI https://$HERMES_HOST/   and   curl -sSI http://$HERMES_HOST/
     Then log in at https://$HERMES_HOST/ and open /chat.
  Logs: docker logs -f hermes-traefik
EOF
