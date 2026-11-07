#!/usr/bin/env bash
# Bring up the OpenShell gateway and run Hermes Agent inside a sandbox.
# Idempotent: re-running skips steps that are already done.
#
#   HERMES_ENV_FILE=~/.config/hermes-sandbox/hermes.env sandbox/scripts/up.sh
#
# The `nvidia` provider (sandbox/scripts/set_nvidia_key.sh) is attached
# automatically when it exists. Optional: HERMES_PROVIDERS="nvidia other" to
# choose explicitly the LLM providers that
# you created with `openshell provider create` (see ../README.md).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSHELL="${OPENSHELL:-openshell}"
GATEWAY_NAME="${GATEWAY_NAME:-hermes-gw}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:v0.23.0}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-hermes-openshell:v0.23.0}"
DATA_VOLUME="${DATA_VOLUME:-hermes-data}"
HERMES_ENV_FILE="${HERMES_ENV_FILE:-$HOME/.config/hermes-sandbox/hermes.env}"
DASHBOARD_PORT="${DASHBOARD_PORT:-9119}"
API_PORT="${API_PORT:-8642}"
# /tmp inside the sandbox is a size-capped tmpfs (counted in the memory limit),
# so filling it can never fill the host disk.
TMP_SIZE_BYTES="${TMP_SIZE_BYTES:-536870912}"

log() { printf '\n==> %s\n' "$*"; }

[ -r "$HERMES_ENV_FILE" ] || { echo "missing $HERMES_ENV_FILE (copy hermes/hermes.env.example)" >&2; exit 1; }

log "Starting OpenShell gateway"
docker compose -f "$HERE/openshell/docker-compose.yml" up -d
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null http://127.0.0.1:8081/ 2>/dev/null && break
  sleep 1
done

if ! "$OPENSHELL" gateway list 2>/dev/null | grep -q "$GATEWAY_NAME"; then
  "$OPENSHELL" gateway add http://127.0.0.1:8080 --local --name "$GATEWAY_NAME"
fi
"$OPENSHELL" gateway select "$GATEWAY_NAME" >/dev/null 2>&1 || true
"$OPENSHELL" status

log "Building $SANDBOX_IMAGE from $HERMES_IMAGE"
docker build -q --build-arg "HERMES_IMAGE=$HERMES_IMAGE" -t "$SANDBOX_IMAGE" "$HERE/hermes"
# Each build of the 4 GB Hermes image leaves ~4.5 GB of build cache behind;
# drop it right away so re-runs never fill the disk.
docker builder prune -af >/dev/null 2>&1 || true

log "Ensuring persistent volume $DATA_VOLUME"
docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1 || docker volume create \
  --label openshell.ai/sandbox-attachable=true \
  --label openshell.ai/sandbox-attachable-workspace=default \
  "$DATA_VOLUME" >/dev/null

if "$OPENSHELL" sandbox get "$SANDBOX_NAME" >/dev/null 2>&1; then
  log "Sandbox $SANDBOX_NAME already exists"
else
  log "Creating sandbox $SANDBOX_NAME"
  # Read the env file literally: scrypt hashes contain `$`, so never source it.
  env_from=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    export "$key=${line#*=}"
    env_from+=(--env-from "$key")
  done < "$HERMES_ENV_FILE"

  providers=()
  default_providers=""
  "$OPENSHELL" provider get nvidia >/dev/null 2>&1 && default_providers="nvidia"
  for p in ${HERMES_PROVIDERS:-$default_providers}; do providers+=(--provider "$p"); done

  "$OPENSHELL" sandbox create \
    --name "$SANDBOX_NAME" \
    --from "$SANDBOX_IMAGE" \
    --policy "$HERE/hermes/policy.yaml" \
    --driver-config-json "{\"docker\":{\"mounts\":[{\"type\":\"volume\",\"source\":\"$DATA_VOLUME\",\"target\":\"/sandbox/hermes\",\"read_only\":false},{\"type\":\"tmpfs\",\"target\":\"/tmp\",\"size_bytes\":$TMP_SIZE_BYTES}]}}" \
    --env HERMES_DASHBOARD_PORT="$DASHBOARD_PORT" \
    --env API_SERVER_ENABLED=true \
    --env API_SERVER_HOST=0.0.0.0 \
    --env API_SERVER_PORT="$API_PORT" \
    --env HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=43200 \
    --env OPENCODE_BRIDGE_API_KEY=not-needed \
    "${env_from[@]}" \
    --no-credential-warnings \
    "${providers[@]}" \
    --no-auto-providers \
    --cpu 2 --memory 4Gi \
    --detach --restart-policy on-failure \
    -- start-hermes
fi

log "Forwarding dashboard and API to host loopback"
for port in "$DASHBOARD_PORT" "$API_PORT"; do
  "$OPENSHELL" forward list 2>/dev/null | grep -qE "\b$port\b.*$SANDBOX_NAME|$SANDBOX_NAME.*\b$port\b" \
    || "$OPENSHELL" forward start "127.0.0.1:$port" "$SANDBOX_NAME" -d </dev/null >/dev/null 2>&1
done
"$OPENSHELL" forward list

cat <<EOF

Hermes is running in OpenShell sandbox "$SANDBOX_NAME".
  On the server: dashboard http://127.0.0.1:$DASHBOARD_PORT, API http://127.0.0.1:$API_PORT/health
  Public HTTPS:  run sandbox/scripts/https_up.sh (Traefik behind Cloudflare)
  Logs:          $OPENSHELL logs $SANDBOX_NAME
EOF
