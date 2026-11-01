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
#   Edge htpasswd   ~/.config/hermes-sandbox/gke/edge-htpasswd   (Traefik basic auth)
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
HERMES_CPU="${HERMES_CPU:-1}"
HERMES_MEMORY="${HERMES_MEMORY:-3Gi}"
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
    env_args=(); env_from=()
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      export "${line%%=*}=${line#*=}"   # read literally: scrypt hashes contain $
      env_args+=(-e "${line%%=*}"); env_from+=(--env-from "${line%%=*}")
    done < "$GKE_SECRETS/hermes.env"
    os "${env_args[@]}" -- sandbox create --name hermes \
      --from "$REGISTRY/hermes-openshell:v0.22.5" \
      --policy /repo/hermes/policy.yaml \
      --env HERMES_DASHBOARD_PORT=9119 --env API_SERVER_ENABLED=true \
      --env API_SERVER_HOST=0.0.0.0 --env API_SERVER_PORT=8642 \
      --env HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS=43200 \
      --env OPENCODE_BRIDGE_API_KEY=not-needed \
      "${env_from[@]}" --no-credential-warnings \
      --provider nvidia --no-auto-providers \
      --cpu "$HERMES_CPU" --memory "$HERMES_MEMORY" \
      --detach --restart-policy on-failure -- start-hermes
  fi
  for _ in $(seq 1 60); do  # capture first: grep -q under pipefail would break the pipe
    out="$(os -- sandbox get hermes 2>/dev/null || true)"; case "$out" in *"Phase: Ready"*) break ;; esac; sleep 10
  done
  printf '%s\n' "$out" | sed -n 1,20p
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
  log "Dashboard basic-auth Secret, origin certificate, routes"
  kubectl -n hermes-edge get secret hermes-dashboard-basic-auth >/dev/null 2>&1 || \
    kubectl -n hermes-edge create secret generic hermes-dashboard-basic-auth --from-file=users="$GKE_SECRETS/edge-htpasswd"
  kubectl apply -f "$HERE/certificate.yaml"
  kubectl apply -f "$HERE/traefik-routes.yaml"
fi

if want dns; then
  LB_IP="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
  log "Cloudflare A $HOST -> $LB_IP (proxied)"
  HERMES_HOST="$HOST" HERMES_ORIGIN_IP="$LB_IP" CLOUDFLARE_API_TOKEN_FILE="$CF_TOKEN_FILE" \
    "$SANDBOX_DIR/scripts/update_dns.sh"
fi
