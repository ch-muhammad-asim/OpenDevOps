#!/usr/bin/env bash
# Generate traffic that triggers every planted issue in the three sample apps,
# so traces, errors and the service graph show up in Grafana Tempo.
#
# Usage: scripts/load.sh [public|local] [rounds]
#   public  https://tempo-{nextjs,nodejs,python}.<DOMAIN>   (default; DOMAIN=saqlainmushtaq.com)
#   local   the apps/local Docker Compose stack on 127.0.0.1
#   rounds  number of rounds (default 20); a round takes ~0.5-3 s (longer while a timeout or CPU hog runs)
# Override any target with NEXTJS_URL, NODEJS_URL, PYTHON_URL.
set -euo pipefail

MODE="${1:-public}"
ROUNDS="${2:-20}"
DOMAIN="${DOMAIN:-saqlainmushtaq.com}"

case "$MODE" in
  public)
    NEXTJS_URL="${NEXTJS_URL:-https://tempo-nextjs.${DOMAIN}}"
    NODEJS_URL="${NODEJS_URL:-https://tempo-nodejs.${DOMAIN}}"
    PYTHON_URL="${PYTHON_URL:-https://tempo-python.${DOMAIN}}" ;;
  local)
    NEXTJS_URL="${NEXTJS_URL:-http://127.0.0.1:13000}"
    NODEJS_URL="${NODEJS_URL:-http://127.0.0.1:13001}"
    PYTHON_URL="${PYTHON_URL:-http://127.0.0.1:18000}" ;;
  *) echo "usage: $0 [public|local] [rounds]" >&2; exit 2 ;;
esac
[[ "$ROUNDS" =~ ^[0-9]+$ && "$ROUNDS" -gt 0 ]] || { echo "rounds must be a positive integer" >&2; exit 2; }

declare -A COUNT=()
# hit METHOD URL [BODY]: one request, prints the status code, never fails the script.
hit() {
  local method="$1" url="$2" body="${3:-}" code
  if [[ -n "$body" ]]; then
    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -X "$method" -H 'content-type: application/json' -d "$body" "$url" || true)
  else
    code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -X "$method" "$url" || true)
  fi
  COUNT["$code"]=$(( ${COUNT["$code"]:-0} + 1 ))
  printf '  %-4s %-3s %s\n' "$method" "$code" "${url#*//}"
}

echo "Targets: nextjs=$NEXTJS_URL nodejs=$NODEJS_URL python=$PYTHON_URL rounds=$ROUNDS"
for app in "$NEXTJS_URL" "$NODEJS_URL" "$PYTHON_URL"; do
  curl -sf -m 10 -o /dev/null "$app/healthz" || { echo "not healthy: $app/healthz" >&2; exit 1; }
done

for ((r = 1; r <= ROUNDS; r++)); do
  echo "round $r/$ROUNDS"
  # Healthy baseline (most traffic), so errors and latency stand out against it.
  hit GET "$NEXTJS_URL/"
  hit GET "$NODEJS_URL/orders/$(( (r % 6) + 1 ))"
  hit GET "$PYTHON_URL/inventory/items"
  # nextjs: N+1 HTTP fan-out (spans all 3 services), unhandled exception, cascading timeout.
  hit GET "$NEXTJS_URL/api/dashboard"
  hit POST "$NEXTJS_URL/api/checkout" '{}'
  (( r % 3 == 0 )) && hit GET "$NEXTJS_URL/api/stock/$(( (r % 10) + 1 ))"
  # nodejs: memory leak (every /orders call), cross-service error, bad body, CPU hog.
  hit GET "$NODEJS_URL/orders"
  hit GET "$NODEJS_URL/orders/7"
  hit POST "$NODEJS_URL/orders" '{"customer":"demo"}'
  (( r % 4 == 0 )) && hit GET "$NEXTJS_URL/api/report"
  # python: N+1 SQL, unhandled KeyError, slow endpoint, CPU hog.
  hit GET "$PYTHON_URL/inventory/report"
  hit GET "$PYTHON_URL/inventory/items/SKU-999"
  (( r % 5 == 0 )) && hit GET "$PYTHON_URL/inventory/fib?n=30"
  # Concurrent requests during a CPU hog: their latency jumps because the event loop is blocked
  # (the nextjs call shows it as a long client span over a short nodejs server span).
  # (Background requests run in subshells, so they print but are not in the final counts.)
  if (( r % 5 == 0 )); then
    hit GET "$NODEJS_URL/orders/report" &
    sleep 0.2
    hit GET "$NODEJS_URL/orders/1" &
    hit GET "$NEXTJS_URL/api/dashboard" &
    wait
  fi
done

echo "Done. Status codes:"
for code in "${!COUNT[@]}"; do echo "  $code: ${COUNT[$code]}"; done | sort
echo "Expected: mostly 200, plus 500 (unhandled exceptions), 502 (order 7), 504 (stock timeout)."
echo "Allow about 30 s before searching in Tempo (ingest + metrics-generator flush)."
