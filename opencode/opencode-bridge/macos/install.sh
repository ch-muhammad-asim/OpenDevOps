#!/usr/bin/env bash
# Thin adapter: tested OpenCode bridge launcher remains in ../hermes-desktop.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(uname -s)" != "Darwin" ]; then echo "This entry point is for macOS." >&2; exit 1; fi
export BRIDGE_HOST=127.0.0.1
export BRIDGE_PORT="${BRIDGE_PORT:-18383}"
export OPENCODE_BRIDGE_FREE_ONLY=1
export OPENCODE_BRIDGE_MODELS=""
exec "$HERE/../../hermes-desktop/install-opencode-bridge.sh" "$@"
