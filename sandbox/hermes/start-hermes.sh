#!/bin/bash
# Runs the two long-lived Hermes processes that s6-overlay supervises in the
# stock image: the web dashboard and the messaging/API gateway. If either
# exits, the other is stopped so OpenShell's restart policy restarts both.
set -euo pipefail

# OpenShell starts this script with TERM=dumb, and the dashboard's chat PTY
# inherits it. The TUI's colour check (chalk) treats "dumb" as no colour
# before it looks at COLORTERM, so the banner and text came out plain. Give
# it the same terminal a plain install gets in a browser terminal. LANG only
# gives the agent's shell tools a UTF-8 locale (no effect on colour).
case "${TERM:-dumb}" in dumb | unknown) export TERM=xterm-256color ;; esac
export COLORTERM="${COLORTERM:-truecolor}"
export LANG="${LANG:-C.UTF-8}"

export HOME="${HERMES_HOME:-/sandbox/hermes}"
mkdir -p "$HOME"
cd "$HOME"

# The stock image seeds config.yaml in its root-only s6 hook, which OpenShell
# skips. Seed it here once; later dashboard edits are kept.
[ -f config.yaml ] || cp /opt/hermes-sandbox/config.yaml config.yaml

# The side panel's "Switch model" saves its pick (provider and model) as the
# default, easily a fallback model by mistake. Restore every key of the
# seeded `model:` block (provider, default, base_url, key_env) on each start.
awk '/^model:/{m=1;next} /^[^ #]/{m=0} m && /^  [a-z_]+:/{k=$1; sub(/:$/,"",k); v=$2; gsub(/^["\x27]|["\x27]$/,"",v); print k, v}' \
  /opt/hermes-sandbox/config.yaml |
while read -r key value; do
  [ -n "$value" ] && hermes config set "model.$key" "$value" >/dev/null \
    || echo "[start-hermes] could not restore model.$key" >&2
done

# 0.0.0.0 makes Hermes enforce dashboard login. The sandbox has no network
# interface, so the port is reachable only through `openshell forward`.
hermes dashboard \
  --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" \
  --port "${HERMES_DASHBOARD_PORT:-9119}" \
  --no-open --skip-build &
dashboard=$!

hermes gateway run &
gateway=$!

trap 'kill "$dashboard" "$gateway" 2>/dev/null || true' EXIT INT TERM

status=0
wait -n "$dashboard" "$gateway" || status=$?
echo "[start-hermes] a Hermes process exited (status $status); stopping the other" >&2
exit "$status"
