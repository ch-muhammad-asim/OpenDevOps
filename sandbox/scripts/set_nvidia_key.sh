#!/usr/bin/env bash
# Set or rotate the NVIDIA API key Hermes uses (NVIDIA API Catalog,
# integrate.api.nvidia.com). Run on the server.
#
#   sandbox/scripts/set_nvidia_key.sh                 # prompts (input hidden)
#   sandbox/scripts/set_nvidia_key.sh < key-file      # or pipe it in
#
# The key goes straight into OpenShell's credential store as the `nvidia`
# provider. It is never written to disk, printed, or put on a command line,
# and Hermes only ever sees a placeholder: the OpenShell supervisor adds the
# real key to requests for integrate.api.nvidia.com (sandbox/providers/
# hermes-nvidia.yaml) and nothing else.
#
# Options: --no-restart  don't restart the Hermes processes (new processes
#                        pick the provider up; running ones keep the old env)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSHELL="${OPENSHELL:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
PROVIDER="${PROVIDER:-nvidia}"
PROFILE="$HERE/providers/hermes-nvidia.yaml"
RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

if [ -t 0 ]; then
  read -rs -p "NVIDIA API key (nvapi-..., input hidden): " NVIDIA_API_KEY; echo
else
  IFS= read -r NVIDIA_API_KEY
fi
# Accept a raw key or a line like "API: nvapi-...".
NVIDIA_API_KEY="${NVIDIA_API_KEY#API:}"; NVIDIA_API_KEY="${NVIDIA_API_KEY//[[:space:]]/}"
case "$NVIDIA_API_KEY" in nvapi-?*) ;; *) echo "error: that doesn't look like an NVIDIA key (nvapi-...)" >&2; exit 1 ;; esac
export NVIDIA_API_KEY

echo "==> Provider profile hermes-nvidia"
"$OPENSHELL" profile lint -f "$PROFILE" >/dev/null
"$OPENSHELL" profile list 2>/dev/null | grep -q '^hermes-nvidia ' || "$OPENSHELL" profile import -f "$PROFILE" >/dev/null

echo "==> Storing the key in OpenShell (provider '$PROVIDER')"
if "$OPENSHELL" provider get "$PROVIDER" >/dev/null 2>&1; then
  "$OPENSHELL" provider update "$PROVIDER" --from-existing --wait >/dev/null
else
  "$OPENSHELL" provider create --name "$PROVIDER" --type hermes-nvidia --from-existing >/dev/null
fi
unset NVIDIA_API_KEY

echo "==> Attaching it to sandbox '$SANDBOX_NAME'"
"$OPENSHELL" sandbox provider list "$SANDBOX_NAME" 2>/dev/null | grep -q "^$PROVIDER " \
  || "$OPENSHELL" sandbox provider attach "$SANDBOX_NAME" "$PROVIDER" --wait >/dev/null

if [ "$RESTART" = 1 ]; then
  echo "==> Restarting the Hermes processes (not the sandbox) so they see the provider"
  # start-hermes is the sandbox's main process; the restart policy starts it
  # again. Open browser chats reconnect after a reload.
  "$OPENSHELL" sandbox exec -n "$SANDBOX_NAME" --no-tty -- sh -c \
    'for p in /proc/[0-9]*; do case "$(tr "\0" " " < "$p/cmdline" 2>/dev/null)" in "/bin/bash /usr/local/bin/start-hermes"*) kill -TERM "${p#/proc/}" ;; esac; done' </dev/null
  healthy=0
  for _ in $(seq 1 30); do
    sleep 4
    curl -s -m 5 "http://${HERMES_ADDR:-172.31.250.10}:${API_PORT:-8642}/health" | grep -q '"ok"' && { healthy=1; break; }
  done
  [ "$healthy" = 1 ] || { echo "error: Hermes did not come back within 2 minutes; check: openshell logs $SANDBOX_NAME" >&2; exit 1; }
  # A Hermes restart drops the tunnel's forward session; a session that
  # reconnected that way was seen to stall new WebSockets (2026-10-30), so
  # start the tunnel's forwards fresh.
  if docker inspect hermes-tunnel >/dev/null 2>&1; then
    echo "==> Restarting hermes-tunnel so the dashboard forwards start fresh"
    docker restart -t 2 hermes-tunnel >/dev/null
    for _ in $(seq 1 30); do
      sleep 2
      curl -s -m 5 "http://${HERMES_ADDR:-172.31.250.10}:${API_PORT:-8642}/health" | grep -q '"ok"' && break
    done
  fi
fi

echo "==> Check: Hermes sees a placeholder, not the key"
"$OPENSHELL" sandbox exec -n "$SANDBOX_NAME" --no-tty -- sh -c \
  'case "$NVIDIA_API_KEY" in openshell:resolve:*) echo "  OK  NVIDIA_API_KEY is an OpenShell placeholder" ;; "") echo "  FAIL  NVIDIA_API_KEY not set in the sandbox"; exit 1 ;; *) echo "  FAIL  the sandbox sees a real key"; exit 1 ;; esac' </dev/null
echo "Done. Rotate any time by running this script again with the new key."
