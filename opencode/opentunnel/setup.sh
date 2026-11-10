#!/usr/bin/env bash
# Tested workflow on Ubuntu GCP VM (2026-11-10): OpenCode 2.2.6,
# OpenTunnel 0.6.2, local HTTP demo, route creation, and model reply "OK".
set -euo pipefail

OPENCODE_VERSION="${OPENCODE_VERSION:-2.2.6}"
DEMO_PORT="${DEMO_PORT:-3000}"
DEMO_DIR="${DEMO_DIR:-$HOME/opentunnel-demo}"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.cargo/bin:$PATH"

echo "=== Installing dependencies ==="
sudo apt-get update -qq
sudo apt-get install -y curl ca-certificates python3

echo "=== Installing OpenCode $OPENCODE_VERSION ==="
curl -fsSL https://opencode.ai/v2/install | bash -s -- --version "$OPENCODE_VERSION"

echo "=== Installing OpenTunnel ==="
curl -fsSL https://opentunnel.xyz/install | sh

echo "=== Installing Herdr ==="
curl -fsSL https://herdr.dev/install.sh | sh
hash -r
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.cargo/bin:$PATH"

echo "=== Verifying installations ==="
command -v opencode
command -v opentunnel
opencode --version
opentunnel --version
if command -v herdr >/dev/null 2>&1; then
  echo "Herdr installed at: $(command -v herdr)"
else
  echo "Herdr installer completed. Start a new shell or follow installer PATH instructions."
fi

echo "=== Starting local demo HTTP server ==="
mkdir -p "$DEMO_DIR"
printf 'Hello from OpenTunnel!\n' > "$DEMO_DIR/index.html"
if ! curl --max-time 2 -fsS "http://127.0.0.1:$DEMO_PORT/" >/dev/null 2>&1; then
  nohup python3 -m http.server "$DEMO_PORT" \
    --bind 127.0.0.1 --directory "$DEMO_DIR" \
    > "$DEMO_DIR/server.log" 2>&1 < /dev/null &
  sleep 2
fi
curl --max-time 5 -fsS "http://127.0.0.1:$DEMO_PORT/"
echo

echo "=== Creating / checking public OpenTunnel route ==="
opentunnel route add "$DEMO_PORT"
echo
echo "=== Testing anonymous OpenCode model (optional) ==="
opencode auth list || true
if opencode run -m opencode/deepseek-v4.1-flash-free "Reply OK only"; then
  echo "OpenCode test succeeded."
else
  echo "WARNING: OpenCode model request failed; check upstream free-tier quota/provider. OpenTunnel is independent."
fi

echo "=== Setup complete ==="
echo "The tunnel exposes the demo server publicly. Do not publish private services without authentication."
echo 'For future interactive shells, add $HOME/.local/bin and $HOME/.opencode/bin to PATH if required.'
