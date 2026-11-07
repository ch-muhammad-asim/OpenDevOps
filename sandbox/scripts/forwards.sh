#!/usr/bin/env bash
# Start the host-loopback forwards to the Hermes sandbox (dashboard and API on
# 127.0.0.1) if they are missing. A reboot drops them: they are host processes,
# not containers. The public path (Traefik -> hermes-tunnel) does not use them
# and recovers by itself; these are for on-server use (curl, a browser over an
# SSH tunnel). Idempotent: forwards that answer are left alone.
#
#   sandbox/scripts/forwards.sh            # once, by hand
#   systemctl --user start hermes-forwards # the same, through the boot unit (sandbox/systemd/)
#
# Waits up to WAIT_SECONDS (default 300) for the gateway and the sandbox. Right
# after a boot the gateway can report the sandbox `Ready` before its supervisor
# has reconnected, so each forward is retried until its port answers.
set -uo pipefail

OPENSHELL="${OPENSHELL:-openshell}"
GATEWAY_NAME="${GATEWAY_NAME:-hermes-gw}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
WAIT_SECONDS="${WAIT_SECONDS:-300}"
PORTS="${DASHBOARD_PORT:-9119} ${API_PORT:-8642}"

log() { printf '%s\n' "$*"; }
command -v "$OPENSHELL" >/dev/null || { log "forwards.sh: $OPENSHELL not found in PATH" >&2; exit 1; }
"$OPENSHELL" gateway select "$GATEWAY_NAME" >/dev/null 2>&1 || true

deadline=$((SECONDS + WAIT_SECONDS))
# Capture output before grepping: with pipefail, `grep -q` closing the pipe early
# would make the pipeline fail at random.
until state="$("$OPENSHELL" sandbox get "$SANDBOX_NAME" 2>/dev/null)" && grep -q 'Phase: Ready' <<<"$state"; do
  [ "$SECONDS" -lt "$deadline" ] || { log "forwards.sh: sandbox $SANDBOX_NAME not Ready after ${WAIT_SECONDS}s" >&2; exit 1; }
  sleep 5
done
log "sandbox $SANDBOX_NAME is Ready"

answers() {  # prints the HTTP code of 127.0.0.1:$1 (000 = nothing answers)
  curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$1/" 2>/dev/null || true
}

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
ok=1
for port in $PORTS; do
  code="$(answers "$port")"
  if [ "$code" != 000 ]; then
    log "127.0.0.1:$port already answers HTTP $code"
    continue
  fi
  for attempt in $(seq 1 "$((WAIT_SECONDS / 15))"); do
    "$OPENSHELL" forward stop "$port" "$SANDBOX_NAME" >/dev/null 2>&1 || true
    # Output to a file, not $(...): the daemonized forward keeps a $(...) pipe
    # open, which would block the script forever.
    if "$OPENSHELL" forward start "127.0.0.1:$port" "$SANDBOX_NAME" -d </dev/null >"$err" 2>&1; then
      for _ in 1 2 3 4 5 6; do
        code="$(answers "$port")"
        [ "$code" != 000 ] && break
        sleep 2
      done
      [ "$code" != 000 ] && break
      log "attempt $attempt: forward :$port started but nothing answers yet"
    else
      log "attempt $attempt: forward start :$port failed: $(tail -n 1 "$err")"
    fi
    sleep 10
  done
  if [ "$code" != 000 ]; then
    log "forward 127.0.0.1:$port -> $SANDBOX_NAME started, answers HTTP $code"
  else
    log "forwards.sh: 127.0.0.1:$port still does not answer" >&2
    ok=0
  fi
done
[ "$ok" = 1 ]
