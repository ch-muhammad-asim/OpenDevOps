#!/usr/bin/env bash
# Stop the Hermes sandbox and port forwards. Keeps Traefik, the tunnel (it
# reconnects when the sandbox is back), the hermes-data volume and gateway
# state unless --purge is given.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSHELL="${OPENSHELL:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
DATA_VOLUME="${DATA_VOLUME:-hermes-data}"

for port in "${DASHBOARD_PORT:-9119}" "${API_PORT:-8642}"; do
  "$OPENSHELL" forward stop "$port" "$SANDBOX_NAME" 2>/dev/null || true
done
"$OPENSHELL" sandbox delete "$SANDBOX_NAME" 2>/dev/null || true

if [ "${1:-}" = "--purge" ]; then
  # Traefik first, then the tunnel (it owns the hermes_edge network and joins
  # the gateway's network), then the gateway.
  docker compose -f "$HERE/traefik/docker-compose.yml" down 2>/dev/null || true
  docker compose -f "$HERE/tunnel/docker-compose.yml" down 2>/dev/null || true
  docker compose -f "$HERE/openshell/docker-compose.yml" down
  docker volume rm "$DATA_VOLUME" 2>/dev/null || true
  echo "Traefik, tunnel and gateway stopped; $DATA_VOLUME removed. /var/lib/openshell is root-owned; remove it with sudo if wanted."
fi
