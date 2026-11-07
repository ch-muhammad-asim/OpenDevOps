#!/usr/bin/env bash
# Deploy Hermes in NVIDIA OpenShell on the GKE cluster created by
# gcp/gcp-infra.sh (see ../README.md, "GKE deployment"). Idempotent where the
# tools allow it; every step prints what it does. Run from any directory with
# kubectl pointing at the cluster.
#
#   sandbox/k8s/gke/deploy.sh                # all steps
#   STEPS="openshell sandbox" sandbox/k8s/gke/deploy.sh   # selected steps
#
# Secrets are read from files and piped on stdin; nothing secret is printed or
# put on a command line:
#   NVIDIA key      ~/Desktop/sandbox/creds/nvidia/api   (line "API: nvapi-...")
#   Cloudflare DNS  ~/Desktop/sandbox/creds/cloudflare/dns/api  (cfat_... token)
#   Hermes env      ~/.config/hermes-sandbox/gke/hermes.env      (dashboard hash, API key)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANDBOX_DIR="$(cd "$HERE/../.." && pwd)"
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
REGISTRY="${REGISTRY:-us-central1-docker.pkg.dev/$PROJECT/hermes}"
HOST="${HOST:-hermes-gke.saqlainmushtaq.com}"
NVIDIA_KEY_FILE="${NVIDIA_KEY_FILE:-$HOME/Desktop/sandbox/creds/nvidia/api}"
CF_TOKEN_FILE="${CF_TOKEN_FILE:-$HOME/Desktop/sandbox/creds/cloudflare/dns/api}"
GKE_SECRETS="${GKE_SECRETS:-$HOME/.config/hermes-sandbox/gke}"
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v1.0.3}"
OPENSHELL_CHART_VERSION="${OPENSHELL_CHART_VERSION:-0.1.6}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-42.0.0}"
HERMES_CPU="${HERMES_CPU:-900m}"   # an e2-standard-2 node has ~950m CPU left after the GKE system pods
HERMES_MEMORY="${HERMES_MEMORY:-3Gi}"
HERMES_TAG="${HERMES_TAG:-v0.23.0-herdr0.9.5}"   # Hermes Agent release (+ herdr layer from gke/herdr/; plain "v0.23.0" = no herdr)
HERMES_CMD="${HERMES_CMD:-start-hermes-herdr}"   # sandbox entrypoint; use "start-hermes" with the plain image
STEPS="${STEPS:-base certmanager traefik netpol bridge openshell provider sandbox tunnel edge dns}"
# Helm's OCI client trips over a Docker credsStore it cannot run; use an empty config.
HELM_REG="$(mktemp -d)"; echo '{}' > "$HELM_REG/config.json"; trap 'rm -rf "$HELM_REG"' EXIT

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
want() { case " $STEPS " in *" $1 "*) return 0 ;; esac; return 1; }

# The OpenShell CLI runs from the hermes-tunnel image on this machine, through a
# kubectl port-forward to the gateway, with the chart's client certificate.
CLI_DIR=""
cli_start() {
  [ -n "$CLI_DIR" ] && return 0
  CLI_DIR="$(mktemp -d)"; chmod 700 "$CLI_DIR"
  mkdir -p "$CLI_DIR/openshell/gateways/gke/mtls"
  for f in ca.crt tls.crt tls.key; do
    kubectl -n openshell get secret openshell-client-tls -o "jsonpath={.data['${f//./\\.}']}" | base64 -d > "$CLI_DIR/openshell/gateways/gke/mtls/$f"
  done
  chmod -R go-rwx "$CLI_DIR"
  kubectl -n openshell port-forward svc/openshell 18080:8080 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null; rm -rf "$CLI_DIR" "$HELM_REG"' EXIT
  for _ in $(seq 1 30); do (echo > /dev/tcp/127.0.0.1/18080) 2>/dev/null && break; sleep 1; done
}
os() {  # openshell CLI; extra docker args before "--"
  cli_start
  local dargs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do dargs+=("$1"); shift; done; [ "${1:-}" = "--" ] && shift
  docker run --rm -i --network host --user "$(id -u):$(id -g)" \
    -e XDG_CONFIG_HOME=/cfg -e HOME=/tmp -e OPENSHELL_GATEWAY=gke \
    -e OPENSHELL_GATEWAY_ENDPOINT=https://127.0.0.1:18080 \
    -v "$CLI_DIR:/cfg" -v "$SANDBOX_DIR:/repo:ro" "${dargs[@]}" \
    --entrypoint openshell "$REGISTRY/hermes-tunnel:0.1.6" "$@"
}

# Rolling to a new image: STEPS="recreate-sandbox sandbox restore-data tunnel-restart". OpenShell deletes the
# workspace PVC with the sandbox, so /sandbox/hermes (chats, settings, memory) is saved to a private, timestamped
# file first and restored into the new sandbox (config.yaml is re-seeded from the image). Fails closed: if the
# backup is missing, empty or unreadable, nothing is deleted. Test: sandbox/k8s/gke/test-recreate-backup.sh
HERMES_BACKUP_DIR="${HERMES_BACKUP_DIR:-$GKE_SECRETS}"
backup_hermes_data() {   # prints the backup path; exits 1 (before any delete) on failure
  local f rc=0 n
  f="$HERMES_BACKUP_DIR/hermes-data-backup-$(date -u +%Y%m%dT%H%M%SZ).tgz"
  ( umask 077
    # Hermes keeps running: tar exits 1 for "file changed as we read it" (accepted), >1 is an error.
    os -- sandbox exec -n hermes --no-tty -- tar -C /sandbox --warning=no-file-changed --exclude='*.sock' \
      -czf - hermes > "$f.tmp" ) || rc=$?
  if [ "$rc" -gt 1 ]; then echo "backup failed: sandbox exec/tar exited $rc; nothing deleted" >&2; rm -f "$f.tmp"; exit 1; fi
  n="$(tar -tzf "$f.tmp" 2>/dev/null | grep -c '^hermes/' || true)"
  if [ "${n:-0}" -lt 1 ] || ! tar -tzf "$f.tmp" hermes/config.yaml >/dev/null 2>&1; then
    echo "backup failed: archive empty, unreadable or without hermes/config.yaml; nothing deleted" >&2; rm -f "$f.tmp"; exit 1
  fi
  mv "$f.tmp" "$f"
  echo "backup ok: $f ($n entries, $(du -h "$f" | cut -f1))" >&2
  printf '%s\n' "$f"
}
if want base; then
  log "Namespaces, LimitRange, Agent Sandbox controller $AGENT_SANDBOX_VERSION"
  kubectl apply -f "$HERE/namespaces.yaml"
  kubectl apply -f "$HERE/limitrange.yaml"
  kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$AGENT_SANDBOX_VERSION/sandbox.yaml"
  kubectl -n agent-sandbox-system rollout status deploy --timeout=180s
fi

if want certmanager; then
  log "cert-manager $CERT_MANAGER_VERSION, Cloudflare DNS-01 token, ClusterIssuers"
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  helm repo update jetstack traefik >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_VERSION" \
    -n cert-manager -f "$HERE/cert-manager-values.yaml" --wait --timeout 6m
  kubectl -n cert-manager get secret cloudflare-api-token >/dev/null 2>&1 || \
    grep -o -m1 'cfat_[A-Za-z0-9_-]*' "$CF_TOKEN_FILE" | tr -d '\n' \
      | kubectl -n cert-manager create secret generic cloudflare-api-token --from-file=api-token=/dev/stdin
  kubectl apply -f "$HERE/cluster-issuer.yaml"
fi

if want traefik; then
  log "Traefik chart $TRAEFIK_CHART_VERSION"
  helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_CHART_VERSION" \
    -n traefik -f "$HERE/traefik-values.yaml" --wait --timeout 6m
  kubectl -n traefik get svc traefik
fi

if want netpol; then
  log "NetworkPolicies (hermes-edge, traefik)"
  kubectl apply -f "$HERE/networkpolicies.yaml"
fi

if want bridge; then
  log "OpenCode bridge (in-cluster stand-in for the VM's host service)"
  kubectl apply -f "$HERE/opencode-bridge.yaml"
  kubectl -n hermes-edge rollout status deploy/opencode-bridge --timeout=300s
fi

if want openshell; then
  BRIDGE_IP="$(kubectl -n hermes-edge get svc opencode-bridge -o jsonpath='{.spec.clusterIP}')"
  log "OpenShell chart $OPENSHELL_CHART_VERSION (host.openshell.internal -> bridge $BRIDGE_IP)"
  DOCKER_CONFIG="$HELM_REG" helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --version "$OPENSHELL_CHART_VERSION" --registry-config "$HELM_REG/config.json" \
    -n openshell -f "$HERE/openshell-values.yaml" --set server.hostGatewayIP="$BRIDGE_IP" --wait --timeout 8m
  kubectl -n openshell get pods
fi

if want provider; then
  log "NVIDIA key: Kubernetes Secret (source of truth) and the OpenShell provider 'nvidia'"
  kubectl -n openshell get secret nvidia-api-key >/dev/null 2>&1 || \
    grep -o -m1 'nvapi-[A-Za-z0-9_-]*' "$NVIDIA_KEY_FILE" | tr -d '\n' \
      | kubectl -n openshell create secret generic nvidia-api-key --from-file=api-key=/dev/stdin
  os -- profile import -f /repo/providers/hermes-nvidia.yaml 2>/dev/null || true
  if ! os -- provider get nvidia >/dev/null 2>&1; then
    # The key goes from the Secret into this one CLI process's environment only.
    NVIDIA_API_KEY="$(kubectl -n openshell get secret nvidia-api-key -o jsonpath='{.data.api-key}' | base64 -d)"
    export NVIDIA_API_KEY   # docker -e NAME passes it without putting the value on a command line
    os -e NVIDIA_API_KEY -- provider create --name nvidia --type hermes-nvidia --from-existing
    unset NVIDIA_API_KEY
  fi
  os -- provider list
fi

if want recreate-sandbox; then   # not in the default STEPS
  log "Back up /sandbox/hermes to $HERMES_BACKUP_DIR (fails closed), then delete sandbox hermes"
  HERMES_BACKUP="$(backup_hermes_data)" || exit 1
  [ -s "$HERMES_BACKUP" ] || { echo "no backup file; nothing deleted" >&2; exit 1; }
  os -- sandbox delete hermes || true
  for _ in $(seq 1 30); do kubectl -n openshell get pod default--hermes >/dev/null 2>&1 || break; sleep 5; done
fi

if want delete-sandbox; then   # not in the default STEPS: re-create or tear down the sandbox
  log "Delete sandbox hermes (and its workspace PVC)"
  os -- sandbox delete hermes || true
  for _ in $(seq 1 30); do kubectl -n openshell get pod default--hermes >/dev/null 2>&1 || break; sleep 5; done
  kubectl -n openshell delete pvc workspace-default--hermes --ignore-not-found --wait=true
fi

if want sandbox; then
  log "Hermes sandbox ($HERMES_CPU CPU / $HERMES_MEMORY)"
  if os -- sandbox get hermes >/dev/null 2>&1; then
    echo "sandbox hermes already exists"
  else
    # By digest: the node caches images (IfNotPresent), so a rebuilt image under the same tag would not be pulled.
    HERMES_DIGEST="$(gcloud artifacts docker images describe "$REGISTRY/hermes-openshell:$HERMES_TAG" --format='value(image_summary.digest)')"
    echo "image $REGISTRY/hermes-openshell:$HERMES_TAG = $HERMES_DIGEST"
    env_args=(); env_from=()
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      export "${line%%=*}=${line#*=}"   # read literally: scrypt hashes contain $
      env_args+=(-e "${line%%=*}"); env_from+=(--env-from "${line%%=*}")
    done < "$GKE_SECRETS/hermes.env"
    os "${env_args[@]}" -- sandbox create --name hermes \
      --from "$REGISTRY/hermes-openshell@$HERMES_DIGEST" \
      --policy /repo/hermes/policy.yaml \
      --env HERMES_DASHBOARD_PORT=9119 --env API_SERVER_ENABLED=true \
      --env API_SERVER_HOST=0.0.0.0 --env API_SERVER_PORT=8642 \
      --env HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=43200 \
      --env OPENCODE_BRIDGE_API_KEY=not-needed \
      "${env_from[@]}" --no-credential-warnings \
      --provider nvidia --no-auto-providers \
      --cpu "$HERMES_CPU" --memory "$HERMES_MEMORY" \
      --detach --restart-policy on-failure -- "$HERMES_CMD" \
      || { os -- sandbox get hermes >/dev/null 2>&1 || exit 1   # the create call's stream can drop after the
           echo "sandbox create: stream closed early, but sandbox hermes exists; waiting for Ready"; }   # sandbox exists
  fi
  ready=0
  for _ in $(seq 1 60); do  # capture first: grep -q under pipefail would break the pipe
    out="$(os -- sandbox get hermes 2>/dev/null || true)"; case "$out" in *"Phase: Ready"*) ready=1; break ;; esac; sleep 10
  done
  printf '%s\n' "$out" | sed -n 1,20p
  [ "$ready" = 1 ] || { echo "sandbox hermes not Ready after 10 min" >&2; exit 1; }
fi

if want restore-data; then   # not in the default STEPS: see recreate-sandbox
  # The backup from this run, or HERMES_BACKUP=<file>, or the newest one in HERMES_BACKUP_DIR.
  HERMES_BACKUP="${HERMES_BACKUP:-$(ls -1t "$HERMES_BACKUP_DIR"/hermes-data-backup-*.tgz 2>/dev/null | head -1)}"
  [ -s "$HERMES_BACKUP" ] || { echo "restore-data: no backup found in $HERMES_BACKUP_DIR" >&2; exit 1; }
  log "Restore /sandbox/hermes from $HERMES_BACKUP (except config.yaml), restart the sandbox"
  # `sandbox exec` limits piped stdin to 4 MiB: send the archive in 3 MiB chunks to /tmp (writable, cleared on
  # restart), check its SHA-256, then extract.
  chunks="$(mktemp -d)"; split -b 3M "$HERMES_BACKUP" "$chunks/part."
  os -- sandbox exec -n hermes --no-tty -- rm -f /tmp/hermes-data.tgz
  for c in "$chunks"/part.*; do os -- sandbox exec -n hermes -- sh -c 'cat >> /tmp/hermes-data.tgz' < "$c"; done
  rm -rf "$chunks"
  sum="$(sha256sum "$HERMES_BACKUP" | cut -d' ' -f1)"
  os -- sandbox exec -n hermes --no-tty -- sh -c "echo '$sum  /tmp/hermes-data.tgz' | sha256sum -c - >/dev/null \
    && tar -C /sandbox -xzf /tmp/hermes-data.tgz --exclude=hermes/config.yaml; rc=\$?; rm -f /tmp/hermes-data.tgz; exit \$rc"
  os -- sandbox stop hermes && os -- sandbox start hermes   # stop/start keeps the workspace
fi

if want tunnel-restart; then   # not in the default STEPS: the tunnel re-forwards to a re-created sandbox
  kubectl -n hermes-edge rollout restart deploy/hermes-tunnel
  kubectl -n hermes-edge rollout status deploy/hermes-tunnel --timeout=300s
fi

if want tunnel; then
  log "hermes-tunnel (client certificate copied into hermes-edge, never printed)"
  kubectl -n hermes-edge get secret openshell-client-tls >/dev/null 2>&1 || \
    kubectl -n openshell get secret openshell-client-tls -o json \
      | jq '{apiVersion:"v1",kind:"Secret",type:.type,metadata:{name:"openshell-client-tls",namespace:"hermes-edge"},data:{"ca.crt":.data["ca.crt"],"tls.crt":.data["tls.crt"],"tls.key":.data["tls.key"]}}' \
      | kubectl create -f -
  # The manifest holds ${REGISTRY}; render it for this project (no other variables are substituted).
  sed "s#\${REGISTRY}#$REGISTRY#g" "$HERE/hermes-tunnel.yaml" | kubectl apply -f -
  kubectl -n hermes-edge rollout status deploy/hermes-tunnel --timeout=300s
fi

if want edge; then
  log "Origin certificate, routes"
  kubectl apply -f "$HERE/certificate.yaml"
  kubectl apply -f "$HERE/traefik-routes.yaml"
fi

if want dns; then
  LB_IP="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  log "Cloudflare A $HOST -> $LB_IP (proxied)"
  HERMES_HOST="$HOST" HERMES_ORIGIN_IP="$LB_IP" CLOUDFLARE_API_TOKEN_FILE="$CF_TOKEN_FILE" \
    "$SANDBOX_DIR/scripts/update_dns.sh"
fi
