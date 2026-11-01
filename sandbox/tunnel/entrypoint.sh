#!/bin/sh
# Keep two OpenShell port forwards into the Hermes sandbox alive:
#   :9119  Hermes dashboard (built-in web UI, /chat, WebSockets)
#   :8642  Hermes API (OpenAI-compatible, Bearer key)
# They listen only on BIND_ADDRESS, this container's address on the private
# hermes_edge network shared with Traefik (not on openshell_default).
#
# Self-healing: each forward is restarted when it exits, and a health loop
# checks it every HEALTH_INTERVAL seconds: the dashboard must answer a
# WebSocket upgrade request (any HTTP answer, e.g. 403 from Hermes's auth
# layer, proves the forward reaches Hermes; no answer = hung/dead forward) and
# the API must answer /health. After three failures in a row (~45 s, so a
# briefly busy Hermes doesn't cost every open chat) the forward and any
# stale listener are killed and a fresh forward starts. This catches a hung or
# dead forward; long-lived sockets are covered by scripts/browser_check.sh.
set -eu

: "${OPENSHELL_GATEWAY_ENDPOINT:=http://gateway:8080}"
: "${SANDBOX_NAME:=hermes}"
: "${DASHBOARD_PORT:=9119}"
: "${API_PORT:=8642}"
: "${BIND_ADDRESS:=0.0.0.0}"
: "${HEALTH_INTERVAL:=15}"
export OPENSHELL_GATEWAY_ENDPOINT HOME=/tmp
PROBE_HOST="$BIND_ADDRESS"; [ "$PROBE_HOST" = 0.0.0.0 ] && PROBE_HOST=127.0.0.1

log() { echo "[hermes-tunnel] $*" >&2; }

# Kill whatever still listens on PORT (a hung or stopped ssh from an old
# forward would otherwise keep the port and block every new forward).
# SIGKILL works even on a stopped process; the SIGCONT first is harmless.
free_port() {
  for pid in $(lsof -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true); do
    log "port :$1 still held by pid $pid; killing it"
    kill -CONT "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
}

keep_forward() {
  while true; do
    free_port "$1"
    openshell forward start "$BIND_ADDRESS:$1" "$SANDBOX_NAME" </dev/null \
      || log "forward :$1 exited; retrying in 5s"
    sleep 5
  done
}

# Prints an HTTP status code, or 000 when nothing answered within 10 s.
probe() {
  case "$1" in
    "$DASHBOARD_PORT")
      curl -s -o /dev/null -m 10 -w '%{http_code}' \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
        "http://$PROBE_HOST:$1/api/ws" 2>/dev/null || true ;;
    *)
      curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$PROBE_HOST:$1/health" 2>/dev/null || true ;;
  esac
}

restart_forward() {
  free_port "$1"
  for pid in $(pgrep -f "openshell forward start $BIND_ADDRESS:$1 " || true); do
    kill -CONT "$pid" 2>/dev/null || true; kill -KILL "$pid" 2>/dev/null || true
  done
}

# check PORT FAILS -> prints the new consecutive-failure count.
check() {
  code="$(probe "$1")"
  case "$code" in
    000|"")
      n=$(($2 + 1))
      log "health: :$1 did not answer (code ${code:-none}, $n/3)"
      if [ "$n" -ge 3 ]; then log "health: restarting forward :$1"; restart_forward "$1"; n=0; fi
      echo "$n" ;;
    *) echo 0 ;;
  esac
}

health_loop() {
  fails_d=0; fails_a=0
  sleep "$HEALTH_INTERVAL"
  while true; do
    fails_d="$(check "$DASHBOARD_PORT" "$fails_d")"
    fails_a="$(check "$API_PORT" "$fails_a")"
    sleep "$HEALTH_INTERVAL"
  done
}

# Stop cleanly on docker stop/restart (PID 1 ignores SIGTERM by default).
trap 'kill 0 2>/dev/null; exit 0' TERM INT

keep_forward "$DASHBOARD_PORT" &
keep_forward "$API_PORT" &
health_loop &
# Exit (and let Docker restart us) as soon as any supervisor loop dies.
# shellcheck disable=SC3045  # BusyBox ash (the image's /bin/sh) supports wait -n
wait -n
exit 1
