#!/usr/bin/env bash
# Write the Hermes dashboard/API credentials for the deployed cluster to an env file (mode 600).
# Values come from Kubernetes Secrets and are never printed; only the file path is echoed.
#
#   DOMAIN=<domain> hermes/dashboard-env.sh ~/Desktop/sandbox/creds/hermes/hermes-gke-dashboard.env
#
# Source it with: set -a; . <file>; set +a   (HERMES_URL, HERMES_DASHBOARD_USERNAME,
# HERMES_DASHBOARD_PASSWORD, API_SERVER_KEY)
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-${HERMES_ENV_FILE:-}}"
[ -n "$OUT" ] || { echo "usage: DOMAIN=<domain> hermes/dashboard-env.sh <output-env-file>" >&2; exit 2; }
DOMAIN="${DOMAIN:-${ZONE:-example.com}}"
URL="${HERMES_URL:-https://hermes-gke.$DOMAIN}"

kubectl -n hermes get secret hermes-dashboard-auth >/dev/null 2>&1 \
  || { echo "error: Secret hermes/hermes-dashboard-auth not found (deploy Hermes first)" >&2; exit 1; }
kubectl -n hermes get secret hermes-api-server >/dev/null 2>&1 \
  || { echo "error: Secret hermes/hermes-api-server not found (deploy Hermes first)" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
umask 077
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
{
  printf '# Hermes dashboard for %s (generated %s by hermes/dashboard-env.sh)\n' "$URL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'HERMES_DASHBOARD_USERNAME=%s\n' "$(kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.username}' | base64 -d)"
  printf 'HERMES_DASHBOARD_PASSWORD=%s\n' "$(kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.password}' | base64 -d)"
  printf 'API_SERVER_KEY=%s\n' "$(kubectl -n hermes get secret hermes-api-server -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d)"
  printf 'HERMES_URL=%s\n' "$URL"
} >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$OUT"
trap - EXIT
chmod 600 "$OUT"
echo "wrote $OUT (mode 600, values not printed)"
