#!/usr/bin/env bash
# Real-browser check of the Hermes Chat page (see browser_check.js). Run it
# from a normal internet connection (Cloudflare challenges cloud IPs):
#
#   read -rs HERMES_DASHBOARD_PASSWORD; export HERMES_DASHBOARD_PASSWORD
#   sandbox/scripts/browser_check.sh                 # 3 min idle, no model call
#   LLM_CHECKS=1 sandbox/scripts/browser_check.sh    # also asks the model (2 prompts; 4 with SWITCH_CHECK=1)
#   IDLE_SECONDS=600 sandbox/scripts/browser_check.sh  # 10 min idle per round (keepalive soak)
#   SWITCH_CHECK=1 sandbox/scripts/browser_check.sh    # also switch model in the side panel and back
#                                                      # (changes the live default for 1-2 min; always restored;
#                                                      # SWITCH_MODEL / SWITCH_IDLE_SECONDS / SWITCH_RESTORE_MODEL)
#
# Behind an extra HTTP basic-auth layer (the GKE deployment), also export
# HERMES_EDGE_USERNAME and HERMES_EDGE_PASSWORD (read -rs) and HERMES_URL.
#
# Needs Node.js and Chrome/Chromium (CHROME=/path/to/chrome to choose one).
# Installs playwright-core 1.50.1 once into ~/.cache/hermes-browser-check.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[ -r "$HERE/site.env" ] && . "$HERE/site.env"
URL="${HERMES_URL:-https://${HERMES_HOST:-hermes.saqlainmushtaq.com}}"
CACHE="${BROWSER_CHECK_CACHE:-$HOME/.cache/hermes-browser-check}"
[ -n "${HERMES_DASHBOARD_PASSWORD:-}" ] || { echo "set HERMES_DASHBOARD_PASSWORD (read -rs ...)" >&2; exit 2; }
command -v node >/dev/null && command -v npm >/dev/null || { echo "Node.js and npm are required" >&2; exit 2; }

if [ -z "${CHROME:-}" ]; then
  for c in google-chrome google-chrome-stable chromium chromium-browser; do
    command -v "$c" >/dev/null && { CHROME="$(command -v "$c")"; break; }
  done
fi
[ -n "${CHROME:-}" ] || { echo "no Chrome/Chromium found; set CHROME=/path/to/chrome" >&2; exit 2; }
export CHROME HERMES_DASHBOARD_USERNAME="${HERMES_DASHBOARD_USERNAME:-admin}"

if [ ! -d "$CACHE/node_modules/playwright-core" ]; then
  mkdir -p "$CACHE"
  npm install --prefix "$CACHE" --no-audit --no-fund --silent playwright-core@1.50.1 >/dev/null
fi
echo "Browser check: $URL (idle ${IDLE_SECONDS:-180} s per round, model questions: $([ "${LLM_CHECKS:-0}" = 1 ] && echo on || echo off), model switch: $([ "${SWITCH_CHECK:-0}" = 1 ] && echo on || echo off))"
NODE_PATH="$CACHE/node_modules" node "$HERE/scripts/browser_check.js" "$URL" "${IDLE_SECONDS:-180}"
