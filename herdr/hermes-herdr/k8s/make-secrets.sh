#!/usr/bin/env bash
# Create the POC's Secrets in namespace hermes-herdr (idempotent: existing Secrets are kept; ROTATE=1 replaces the
# SSH keys). Keys are generated in a private temp dir, loaded with --from-file, then deleted; nothing is printed.
#   NVIDIA key file: ~/Desktop/sandbox/creds/nvidia/api (line "API: nvapi-..."), or NVIDIA_KEY_FILE=...
#
# Secret (only the pod that needs it mounts it)  Contents
#   nvidia-api-key          herdr-hermes        api-key (read-only file /run/secrets/nvidia_api_key)
#   herdr-hermes-keys       herdr-hermes        Hermes's ssh key (terminal backend) + the workbench host key it pins
#   hermes-workbench-keys   hermes-workbench    host key, key for herdr-broker, authorized_keys for Hermes and the
#                                               work panes, the broker host key it pins
#   hermes-herdr-work-keys  hermes-herdr-work   host key, pane key, authorized_keys for the workbench's broker key,
#                                               the workbench host key it pins
set -euo pipefail
NS=hermes-herdr
NVIDIA_KEY_FILE="${NVIDIA_KEY_FILE:-$HOME/Desktop/sandbox/creds/nvidia/api}"
have() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

if ! have nvidia-api-key; then
  grep -o -m1 'nvapi-[A-Za-z0-9_-]*' "$NVIDIA_KEY_FILE" | tr -d '\n' \
    | kubectl -n "$NS" create secret generic nvidia-api-key --from-file=api-key=/dev/stdin >/dev/null
  echo "created nvidia-api-key"
fi

if [ "${ROTATE:-0}" != 1 ] && have herdr-hermes-keys && have hermes-workbench-keys && have hermes-herdr-work-keys; then
  echo "ssh key Secrets exist (ROTATE=1 to replace)"; exit 0
fi
D="$(mktemp -d)"; chmod 700 "$D"; trap 'rm -rf "$D"' EXIT
k() { ssh-keygen -q -t ed25519 -N '' -C "$2" -f "$D/$1"; }
k hermes hermes-herdr                 # Hermes's terminal backend -> workbench (restrict)
k wb_host hermes-workbench-host       # workbench sshd host key
k wb_ctl hermes-workbench-ctl         # workbench -> herdr-broker (restrict)
k work_host hermes-herdr-work-host    # herdr-broker sshd host key
k pane hermes-herdr-pane              # work pane shells -> workbench (restrict,pty)
pub() { cut -d' ' -f1,2 "$D/$1.pub"; }
printf '[hermes-workbench]:2222 %s\n' "$(pub wb_host)" >"$D/workbench_known_hosts"
printf '[hermes-herdr-work]:2222 %s\n' "$(pub work_host)" >"$D/broker_known_hosts"

apply() { kubectl -n "$NS" create secret generic "$1" "${@:2}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; echo "applied $1"; }
apply herdr-hermes-keys \
  --from-file=id_ed25519="$D/hermes" --from-file=id_ed25519.pub="$D/hermes.pub" \
  --from-file=workbench_known_hosts="$D/workbench_known_hosts"
printf 'restrict %s\n' "$(cat "$D/hermes.pub")" >"$D/keys_authorized_keys"
printf 'restrict,pty %s\n' "$(cat "$D/pane.pub")" >"$D/panekeys_authorized_keys"
apply hermes-workbench-keys \
  --from-file=ssh_host_ed25519_key="$D/wb_host" --from-file=ssh_host_ed25519_key.pub="$D/wb_host.pub" \
  --from-file=ctl_ed25519="$D/wb_ctl" --from-file=ctl_ed25519.pub="$D/wb_ctl.pub" \
  --from-file=keys_authorized_keys="$D/keys_authorized_keys" \
  --from-file=panekeys_authorized_keys="$D/panekeys_authorized_keys" \
  --from-file=broker_known_hosts="$D/broker_known_hosts"
printf 'restrict %s\n' "$(cat "$D/wb_ctl.pub")" >"$D/ctlkeys_authorized_keys"
apply hermes-herdr-work-keys \
  --from-file=ssh_host_ed25519_key="$D/work_host" --from-file=ssh_host_ed25519_key.pub="$D/work_host.pub" \
  --from-file=pane_ed25519="$D/pane" --from-file=pane_ed25519.pub="$D/pane.pub" \
  --from-file=ctlkeys_authorized_keys="$D/ctlkeys_authorized_keys" \
  --from-file=workbench_known_hosts="$D/workbench_known_hosts"
