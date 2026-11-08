#!/usr/bin/env bash
# Deploy the hermes-grafana-tempo platform onto the current kubectl context (idempotent).
#
#   scripts/deploy.sh                 # everything below, in order
#   scripts/deploy.sh <step> [...]    # only some steps: namespaces prometheus certmanager
#                                     #   traefik tempo collector grafana dashboards edge dns
#
# Env: PROFILE=prod|lab (default prod), TLS_MODE=cloudflare|letsencrypt (default cloudflare),
#      TEMPO_STORAGE=gcs|local (prod default gcs, lab default local), KAFKA_BOOTSTRAP (prod Tempo).
# Inputs (files, never values on the command line):
#   CF_TOKEN_FILE   Cloudflare API token file, Zone:DNS:Edit on the zone (chmod 600). Required by the
#                   `dns` step (and `certmanager` with TLS_MODE=letsencrypt); no default.
# The Grafana admin password is generated once into Secret observability/grafana-admin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S="$ROOT/k8s"; HELM="$ROOT/helm"
CF_TOKEN_FILE="${CF_TOKEN_FILE:-}"
ZONE="${ZONE:-saqlainmushtaq.com}"
# PROFILE=prod (default): production values (each chart's values.yaml); Tempo = tempo-distributed
#   (needs KAFKA_BOOTSTRAP, a Kafka-compatible queue) on GCS via Workload Identity scoped to the bucket.
# PROFILE=lab: values.yaml + values-lab.yaml overlays sized for 3 x e2-standard-2; Tempo = single binary.
PROFILE="${PROFILE:-prod}"
case "$PROFILE" in prod|lab) ;; *) echo "PROFILE must be prod or lab" >&2; exit 2 ;; esac
# Tempo trace storage: gcs (bucket, Workload Identity scoped to it) or local (PVC). Lab default: local.
if [ "$PROFILE" = lab ]; then TEMPO_STORAGE="${TEMPO_STORAGE:-local}"; else TEMPO_STORAGE="${TEMPO_STORAGE:-gcs}"; fi
# Bucket lifecycle safety net must outlive Tempo's retention: prod 14d -> 16d, lab 24h -> 7d.
if [ "$PROFILE" = prod ]; then export LIFECYCLE_DAYS="${LIFECYCLE_DAYS:-16}"; else export LIFECYCLE_DAYS="${LIFECYCLE_DAYS:-7}"; fi
# TLS_MODE=cloudflare (default): HTTPS ends at the Cloudflare proxy; Traefik serves its default
#   certificate to Cloudflare (zone SSL mode "Full"). No cert-manager.
# TLS_MODE=letsencrypt: cert-manager + Let's Encrypt DNS-01 certificates on Traefik ("Full (strict)").
TLS_MODE="${TLS_MODE:-cloudflare}"   # gcs (bucket via Workload Identity) or local (PV only)
HOSTS=(grafana-tempo tempo-nextjs tempo-python tempo-nodejs)

# Pinned chart versions (see helm/README.md and k8s/README.md).
CERT_MANAGER_VERSION=v1.21.3
TRAEFIK_VERSION=42.3.1
KPS_VERSION=93.1.0
TEMPO_VERSION=3.2.1               # grafana-community/tempo (lab, single binary)
TEMPO_DISTRIBUTED_VERSION=3.27.0  # grafana-community/tempo-distributed (prod)
OTEL_COLLECTOR_VERSION=0.178.2
GRAFANA_VERSION=14.4.0

log() { printf '\n== %s ==\n' "$*"; }

# -f flags for a values dir: values.yaml, plus values-lab.yaml when PROFILE=lab and it exists.
vals() { local d="$1"; printf '%s\n' -f "$d/values.yaml"
  if [ "$PROFILE" = lab ] && [ -f "$d/values-lab.yaml" ]; then printf '%s\n' -f "$d/values-lab.yaml"; fi; }

repos() {
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
}

step_namespaces() {
  log "namespaces"
  kubectl apply -f "$K8S/namespaces.yaml"
}

step_certmanager() {
  [ "$TLS_MODE" = letsencrypt ] || { log "cert-manager skipped (TLS_MODE=$TLS_MODE)"; return 0; }
  log "cert-manager $CERT_MANAGER_VERSION"
  [ -n "$CF_TOKEN_FILE" ] || { echo "error: TLS_MODE=letsencrypt needs CF_TOKEN_FILE" >&2; exit 2; }
  kubectl apply -f "$K8S/cert-manager.yaml"   # namespace (PSS restricted) + NetworkPolicies
  helm upgrade --install cert-manager jetstack/cert-manager --version "$CERT_MANAGER_VERSION" \
    -n cert-manager "${CM_VALS[@]}" --wait --timeout 10m
  [ -r "$CF_TOKEN_FILE" ] || { echo "error: CF_TOKEN_FILE not readable" >&2; exit 2; }
  # Token from the file only (first cfat_... or bare token line); never printed.
  local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
  { grep -o -m1 'cfat_[A-Za-z0-9_-]*' "$CF_TOKEN_FILE" || grep -m1 -E '^[A-Za-z0-9_-]{30,}$' "$CF_TOKEN_FILE"; } \
    | tr -d '\n' > "$tmp"
  [ -s "$tmp" ] || { rm -f "$tmp"; echo "error: no token found in CF_TOKEN_FILE" >&2; exit 2; }
  kubectl -n cert-manager create secret generic cloudflare-api-token --from-file=api-token="$tmp" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -f "$tmp"
  echo "secret cert-manager/cloudflare-api-token applied"
  kubectl apply -f "$K8S/cluster-issuer.yaml"
}

step_traefik() {
  log "traefik $TRAEFIK_VERSION"
  helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_VERSION" \
    -n traefik "${TRAEFIK_VALS[@]}" --wait --timeout 10m
}

step_prometheus() {
  local V; mapfile -t V < <(vals "$HELM/kube-prometheus-stack")
  log "kube-prometheus-stack $KPS_VERSION"
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version "$KPS_VERSION" \
    -n monitoring "${V[@]}" --wait --timeout 15m
}

step_tempo() {
  local extra=() bucket out
  if [ "$TEMPO_STORAGE" = gcs ]; then
    # Bucket + Workload Identity access scoped to it for observability/tempo (no keys, no broad roles).
    out="$("$ROOT/infra/create-tempo-bucket.sh")"; bucket="$(printf '%s\n' "$out" | tail -n2 | head -n1)"
  fi
  if [ "$PROFILE" = prod ]; then
    log "tempo-distributed $TEMPO_DISTRIBUTED_VERSION (storage: $TEMPO_STORAGE)"
    [ -n "${KAFKA_BOOTSTRAP:-}" ] || { echo "error: PROFILE=prod needs KAFKA_BOOTSTRAP (Kafka-compatible queue, see helm/tempo-distributed/README.md)" >&2; exit 2; }
    [ "$TEMPO_STORAGE" = gcs ] && extra=(--set "storage.trace.gcs.bucket_name=$bucket")
    helm upgrade --install tempo grafana-community/tempo-distributed --version "$TEMPO_DISTRIBUTED_VERSION" \
      -n observability -f "$HELM/tempo-distributed/values.yaml" "${extra[@]}" \
      --set "ingest.kafka.address=$KAFKA_BOOTSTRAP" --wait --timeout 15m
    kubectl apply -f "$HELM/tempo-distributed/prometheusrule-rollout-operator.yaml"
  else
    log "tempo $TEMPO_VERSION single binary (storage: $TEMPO_STORAGE)"
    [ "$TEMPO_STORAGE" = gcs ] && extra=(-f "$HELM/tempo/values-gcs.yaml" --set "tempo.storage.trace.gcs.bucket_name=$bucket")
    helm upgrade --install tempo grafana-community/tempo --version "$TEMPO_VERSION" \
      -n observability -f "$HELM/tempo/values.yaml" "${extra[@]}" --wait --timeout 10m
  fi
}

step_collector() {
  local V; mapfile -t V < <(vals "$HELM/otel-collector")
  log "opentelemetry-collector $OTEL_COLLECTOR_VERSION"
  helm upgrade --install otel-collector open-telemetry/opentelemetry-collector --version "$OTEL_COLLECTOR_VERSION" \
    -n observability "${V[@]}" --wait --timeout 10m
}

step_grafana() {
  local V; mapfile -t V < <(vals "$HELM/grafana")
  log "grafana $GRAFANA_VERSION"
  if ! kubectl -n observability get secret grafana-admin >/dev/null 2>&1; then
    # Values come from files in a private temp dir (never on a command line).
    local d; d="$(mktemp -d)"; chmod 700 "$d"
    printf 'admin' > "$d/admin-user"
    openssl rand -base64 30 | tr -d '/+=\n' | cut -c1-32 > "$d/admin-password"
    kubectl -n observability create secret generic grafana-admin \
      --from-file=admin-user="$d/admin-user" --from-file=admin-password="$d/admin-password" >/dev/null
    rm -rf "$d"
    echo "secret observability/grafana-admin created (read it with kubectl, it is not printed)"
  fi
  helm upgrade --install grafana grafana-community/grafana --version "$GRAFANA_VERSION" \
    -n observability "${V[@]}" --wait --timeout 10m
}

step_dashboards() {
  log "Alert rules (Tempo mixin + platform) and Grafana dashboards"
  kubectl apply -f "$HELM/tempo/prometheusrule-tempo-mixin.yaml"
  kubectl apply -f "$HELM/kube-prometheus-stack/rules/"   # Collector, Traefik, cert-manager, Grafana alerts
  kubectl apply -f "$HELM/grafana/dashboards/"
}

step_edge() {
  log "certificates, routes, network policies, limits"
  kubectl apply -f "$K8S/ingressroutes.yaml"
  if [ "$TLS_MODE" = letsencrypt ]; then
    kubectl apply -f "$K8S/certificates.yaml"
    # Serve each host's Let's Encrypt certificate instead of Traefik's default one.
    for r in observability/grafana-tempo tempo-apps/tempo-nextjs tempo-apps/tempo-python tempo-apps/tempo-nodejs; do
      kubectl -n "${r%%/*}" patch ingressroute "${r##*/}-websecure" --type merge \
        -p "{\"spec\":{\"tls\":{\"secretName\":\"${r##*/}-tls\"}}}" >/dev/null
    done
    echo "ingressroutes patched with Let's Encrypt certificate Secrets"
  fi
  kubectl apply -f "$K8S/networkpolicies.yaml"
  kubectl apply -f "$K8S/limitrange.yaml"
}

step_dns() {
  log "Cloudflare DNS (proxied A records -> Traefik load balancer)"
  local ip=""
  for _ in $(seq 1 60); do
    ip="$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -n "$ip" ] && break; sleep 5
  done
  [ -n "$ip" ] || { echo "error: Traefik has no load balancer address yet" >&2; exit 1; }
  [ -n "$CF_TOKEN_FILE" ] || { echo "error: the dns step needs CF_TOKEN_FILE" >&2; exit 2; }
  for h in "${HOSTS[@]}"; do
    CF_TOKEN_FILE="$CF_TOKEN_FILE" CF_ZONE="$ZONE" "$ROOT/scripts/update-dns.sh" "$h.$ZONE" "$ip"
  done
}

# kube-prometheus-stack first: it owns the ServiceMonitor/PrometheusRule CRDs the other charts use.
# k8s/ chart values: <name>-values.yaml plus <name>-values-lab.yaml in the lab profile.
CM_VALS=(-f "$K8S/cert-manager-values.yaml"); TRAEFIK_VALS=(-f "$K8S/traefik-values.yaml")
if [ "$PROFILE" = lab ]; then
  [ -f "$K8S/cert-manager-values-lab.yaml" ] && CM_VALS+=(-f "$K8S/cert-manager-values-lab.yaml")
  [ -f "$K8S/traefik-values-lab.yaml" ] && TRAEFIK_VALS+=(-f "$K8S/traefik-values-lab.yaml")
fi

ALL=(namespaces prometheus certmanager traefik tempo collector grafana dashboards edge dns)
STEPS=("$@"); [ ${#STEPS[@]} -gt 0 ] || STEPS=("${ALL[@]}")
if ! command -v helm >/dev/null || ! command -v kubectl >/dev/null; then echo "need helm and kubectl" >&2; exit 2; fi
echo "context: $(kubectl config current-context)  profile: $PROFILE  tls: $TLS_MODE  tempo storage: $TEMPO_STORAGE"
# Production needs Secrets created out of band (Secret Manager / External Secrets); never from git.
if [ "$PROFILE" = prod ]; then
  missing=""
  kubectl -n monitoring get secret alertmanager-receivers >/dev/null 2>&1 || missing+=" monitoring/alertmanager-receivers"
  kubectl -n observability get secret grafana-db >/dev/null 2>&1 || missing+=" observability/grafana-db"
  kubectl -n observability get secret tempo-kafka >/dev/null 2>&1 || missing+=" observability/tempo-kafka"
  if [ -n "$missing" ]; then
    echo "error: PROFILE=prod needs Secrets:$missing (see helm/kube-prometheus-stack, helm/grafana, helm/tempo-distributed READMEs)" >&2
    exit 2
  fi
  [ -n "${KAFKA_BOOTSTRAP:-}" ] || { echo "error: PROFILE=prod needs KAFKA_BOOTSTRAP (helm/tempo-distributed/README.md)" >&2; exit 2; }
  # Prod spreads replicas across zones (hard zone spread for Tempo live-stores): needs a regional
  # cluster (infra/create-cluster.sh PROFILE=prod REGION=...), i.e. nodes in at least 2 zones.
  zones="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' | sort -u | grep -c . || true)"
  [ "$zones" -ge 2 ] || { echo "error: PROFILE=prod needs nodes in >= 2 zones (found $zones); create a regional cluster" >&2; exit 2; }
fi
repos
for s in "${STEPS[@]}"; do
  declare -F "step_$s" >/dev/null || { echo "unknown step: $s (valid: ${ALL[*]})" >&2; exit 2; }
  "step_$s"
done
log "done - run scripts/verify.sh"
