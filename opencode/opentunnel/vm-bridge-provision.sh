#!/usr/bin/env bash
# 🆓 Provision the OpenCode → Hermes bridge on a fresh Ubuntu VM (headless).
# ✅ Idempotent: safe to re-run. Run with sudo on the VM.
#
# What it does:
#   🧱 base packages (python3, curl, git, jq, openssl)
#   👤 unprivileged service user `bridge` + /srv/bridge/workspace
#   ⚙️ OpenCode CLI installed into /srv/bridge/.opencode
#   📥 bridge source from opencode/hermes-desktop/opencode_bridge.py
#   🗂️ workspace fixtures used to prove filesystem visibility
#   🔐 bearer token in /etc/opencode-bridge.env (root:root 0600, never printed)
#   🧾 systemd unit `opencode-bridge` on 127.0.0.1:${BRIDGE_PORT:-18383}
#   🩺 health check at the end
set -euo pipefail

BRIDGE_USER="bridge"
BRIDGE_HOME="/srv/bridge"
WORKSPACE="$BRIDGE_HOME/workspace"
SRC_DIR="/opt/bridge"
ENV_FILE="/etc/opencode-bridge.env"
PORT="${BRIDGE_PORT:-18383}"
# Latest OpenCode v2 on each provisioning run; optionally pin for controlled rollouts.
OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"
MODEL="${BRIDGE_MODEL:-opencode/deepseek-v4.1-flash-free}"
REPO_URL="https://github.com/ch-muhammad-asim/OpenDevOps.git"
SOURCE_PATH="opencode/hermes-desktop/opencode_bridge.py"

log() { printf '\n==> %s\n' "$*"; }

log "1/8 base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 curl git jq ca-certificates unzip >/dev/null

log "2/8 service user ($BRIDGE_USER)"
if ! id "$BRIDGE_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$BRIDGE_HOME" --shell /bin/bash "$BRIDGE_USER"
fi
install -d -o "$BRIDGE_USER" -g "$BRIDGE_USER" -m 0755 "$WORKSPACE"

log "3/8 OpenCode CLI (as $BRIDGE_USER)"
# Always run the v2 installer so re-provisioning upgrades an existing binary.
# The old URL (/install) targets the v1 release line; v2 has a dedicated installer.
# A running service is restarted later in this script after the new binary is installed.
sudo -u "$BRIDGE_USER" env HOME="$BRIDGE_HOME" OPENCODE_VERSION="$OPENCODE_VERSION" bash -c '
  set -euo pipefail
  if [ "$OPENCODE_VERSION" = latest ]; then
    curl -fsSL https://opencode.ai/v2/install | bash
  else
    curl -fsSL https://opencode.ai/v2/install | bash -s -- --version "$OPENCODE_VERSION"
  fi
' >/tmp/opencode-install.log 2>&1 \
  || { tail -30 /tmp/opencode-install.log; exit 1; }
OC_BIN="$BRIDGE_HOME/.opencode/bin/opencode"
"$OC_BIN" --version

log "4/8 fetch the bridge source (pinned to the reviewed file)"
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone --depth 1 "$REPO_URL" "$SRC_DIR" -q
else
  git -C "$SRC_DIR" fetch --depth 1 origin main -q && git -C "$SRC_DIR" reset --hard origin/main -q
fi
install -d -m 0755 "$SRC_DIR/run"
install -m 0644 "$SRC_DIR/$SOURCE_PATH" "$SRC_DIR/run/opencode_bridge.py"
python3 -m py_compile "$SRC_DIR/run/opencode_bridge.py"
echo "bridge source: $(sha256sum "$SRC_DIR/run/opencode_bridge.py" | cut -c1-16)…"

log "5/8 workspace fixtures (the files the bridge must be able to see)"
install -d -o "$BRIDGE_USER" -g "$BRIDGE_USER" -m 0755 "$WORKSPACE/notes" "$WORKSPACE/data"
MARKER="BRIDGE-FS-VISIBILITY-$RANDOM$RANDOM"
cat >"$WORKSPACE/hello.txt" <<EOF
marker=$MARKER
written_by=vm-bridge-provisioner
host=$(hostname)
EOF
cat >"$WORKSPACE/notes/deploy.md" <<'EOF'
# Deploy notes
- service: opencode-bridge
- port: 18383
- runbook: systemctl status opencode-bridge
EOF
printf 'service,status,port\nopencode-bridge,running,18383\nhermes,client,-\n' >"$WORKSPACE/data/services.csv"
chown -R "$BRIDGE_USER:$BRIDGE_USER" "$WORKSPACE"
echo "$MARKER" >"$BRIDGE_HOME/.marker"
chmod 600 "$BRIDGE_HOME/.marker"

log "6/8 bridge API key (generated once, never printed)"
if [ ! -s "$ENV_FILE" ]; then
  ( umask 077
    printf 'OPENCODE_BRIDGE_API_KEY=%s\n' "$(openssl rand -hex 32)" >"$ENV_FILE" )
  chown root:root "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
fi

log "7/8 systemd service"
# 🔐 The bearer token is supplied through EnvironmentFile only — never on the command
# line, where `ps aux` would expose it to every local user.
cat >/etc/systemd/system/opencode-bridge.service <<EOF
[Unit]
Description=OpenCode bridge (OpenAI-compatible) for Hermes
After=network-online.target

[Service]
Type=simple
User=$BRIDGE_USER
Group=$BRIDGE_USER
Environment=HOME=$BRIDGE_HOME
Environment=PATH=$BRIDGE_HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=$ENV_FILE
WorkingDirectory=$WORKSPACE
ExecStart=/usr/bin/python3 $SRC_DIR/run/opencode_bridge.py \\
  --host 127.0.0.1 --port $PORT \\
  --cwd $WORKSPACE \\
  --model $MODEL \\
  --max-concurrency 2 --timeout 300
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=$WORKSPACE $BRIDGE_HOME

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable opencode-bridge >/dev/null 2>&1
systemctl restart opencode-bridge

log "8/8 health check"
for i in $(seq 1 30); do
  if curl -fsS -m 3 -H "Authorization: Bearer $(cut -d= -f2- "$ENV_FILE")" \
      "http://127.0.0.1:$PORT/health" >/tmp/health.json 2>/dev/null; then
    cat /tmp/health.json; echo
    break
  fi
  sleep 2
done

echo
echo "MARKER=$MARKER"
systemctl is-active opencode-bridge
