#!/usr/bin/env bash
# Deploy the hermes-grafana-tempo platform onto the current kubectl context (idempotent).
#
#   scripts/deploy.sh                 # everything below, in order
#   scripts/deploy.sh <step> [...]    # only some steps: namespaces objectstore prometheus certmanager
#                                     #   traefik tempo collector grafana dashboards edge dns
#
# Env: PROFILE=prod|lab (default prod), TLS_MODE=cloudflare|letsencrypt (default cloudflare),
#      OBJECT_STORE=gcs|seaweedfs (default gcs), TEMPO_STORAGE=gcs|s3|local (follows OBJECT_STORE),
#      TEMPO_BUCKET / THANOS_BUCKET (default tempo-traces-<project>, thanos-metrics-<project>),
#      ACCESS_MODE=bucket|conditional|gsa (infra/create-gcs-bucket.sh), KAFKA_BOOTSTRAP (prod Tempo).
# Inputs (files, never values on the command line):
#   CF_TOKEN_FILE   Cloudflare API token file, Zone:DNS:Edit on the zone (chmod 600). Required by the
#                   `dns` step (and `certmanager` with TLS_MODE=letsencrypt); no default.
# The Grafana admin password is generated once into Secret observability/grafana-admin.
set -euo pipefail
# chart <repo>/<name> <version>: use a pre-downloaded chart from CHART_CACHE when present (helm pull
# into that directory first if the chart host is slow or unreachable), otherwise the repo reference.
chart() { local f="${CHART_CACHE:-}/${1#*/}-$2.tgz"; if [ -n "${CHART_CACHE:-}" ] && [ -f "$f" ]; then echo "$f"; else echo "$1"; fi; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S="$ROOT/k8s"; HELM="$ROOT/helm"; GRAFANA_HELM="$HELM/grafana"
CF_TOKEN_FILE="${CF_TOKEN_FILE:-}"
# Public domain for the five hostnames. Manifests and values keep the reusable example.com placeholders, so a
# private copy is rendered with DOMAIN before it is applied: a deploy never edits tracked files. ZONE is accepted
# as the older name for the same value.
DOMAIN="${DOMAIN:-${ZONE:-example.com}}"
if [ "$DOMAIN" != example.com ]; then
  RENDER="$(mktemp -d)"; trap 'rm -rf "$RENDER"' EXIT
  render() { local src="$1" dst="$2"; cp -a "$src" "$dst"
    grep -rlZ 'example\.com' "$dst" 2>/dev/null | xargs -0 -r sed -i "s/example\.com/${DOMAIN}/g"; }
  render "$ROOT/k8s" "$RENDER/k8s"
  render "$HELM/grafana" "$RENDER/grafana"
  K8S="$RENDER/k8s"; GRAFANA_HELM="$RENDER/grafana"
  echo "rendered manifests for $DOMAIN in $RENDER"
fi
# PROFILE=prod (default): production values (each chart's values.yaml); Tempo = tempo-distributed
#   (needs KAFKA_BOOTSTRAP, a Kafka-compatible queue) on GCS via Workload Identity scoped to the bucket.
# PROFILE=lab: values.yaml + values-lab.yaml overlays sized for 3 x e2-standard-2; Tempo = single binary.
PROFILE="${PROFILE:-prod}"
case "$PROFILE" in prod|lab) ;; *) echo "PROFILE must be prod or lab" >&2; exit 2 ;; esac
# (TEMPO_STORAGE: gcs = bucket via Workload Identity (default), s3 = SeaweedFS, local = PVC only.)
# Object storage for Tempo blocks and Thanos (30-day retention). All software is free/OSS.
#   gcs:       default (lab and prod), dedicated GCS buckets, roles/storage.objectUser via Workload Identity (infra/).
#   seaweedfs: optional fallback, in-cluster SeaweedFS S3 on a PVC (helm/seaweedfs), for clusters without
#              cloud object storage.
OBJECT_STORE="${OBJECT_STORE:-gcs}"
case "$OBJECT_STORE" in gcs|seaweedfs) ;; *) echo "OBJECT_STORE must be gcs or seaweedfs" >&2; exit 2 ;; esac
# Tempo trace storage follows the object store (s3 = SeaweedFS); local = PVC only (no object store).
if [ "$OBJECT_STORE" = gcs ]; then TEMPO_STORAGE="${TEMPO_STORAGE:-gcs}"; else TEMPO_STORAGE="${TEMPO_STORAGE:-s3}"; fi
export LIFECYCLE_DAYS="${LIFECYCLE_DAYS:-33}"   # GCS backstop after the 30-day (720h) Tempo/Thanos retention
# TLS_MODE=cloudflare (default): HTTPS ends at the Cloudflare proxy; Traefik serves its default
#   certificate to Cloudflare (zone SSL mode "Full"). No cert-manager.
# TLS_MODE=letsencrypt: cert-manager + Let's Encrypt DNS-01 certificates on Traefik ("Full (strict)").
TLS_MODE="${TLS_MODE:-cloudflare}"
PROJECT_ID_FOR_BUCKETS="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"   # bucket names: tempo-traces-<project>, thanos-metrics-<project>
HOSTS=(grafana-tempo tempo-nextjs tempo-python tempo-nodejs hermes-gke)   # hermes-gke: Hermes dashboard route (hermes/)

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
  local names=(traefik prometheus-community grafana-community open-telemetry)
  if [ "$TLS_MODE" = letsencrypt ]; then
    helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
    names+=(jetstack)
  fi
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
  # Unrelated user repositories (or optional cert-manager in Cloudflare mode) must
  # not block deployment when their chart hosts are unreachable.
  helm repo update "${names[@]}" >/dev/null
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
  helm upgrade --install cert-manager "$(chart jetstack/cert-manager "$CERT_MANAGER_VERSION")" --version "$CERT_MANAGER_VERSION" \
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
  helm upgrade --install traefik "$(chart traefik/traefik "$TRAEFIK_VERSION")" --version "$TRAEFIK_VERSION" \
    -n traefik "${TRAEFIK_VALS[@]}" --wait --timeout 10m
}

# Optional fallback object store (OBJECT_STORE=seaweedfs): SeaweedFS S3 with one identity per bucket. Credentials are generated once into
# Secrets (never printed, never in git) and reused on re-runs; all three Secrets are written together.
step_objectstore() {
  [ "$OBJECT_STORE" = seaweedfs ] || { log "object store: GCS (buckets created by the tempo/prometheus steps)"; return 0; }
  log "SeaweedFS namespace + S3 credentials (the server is applied in the prometheus step, after the CRDs)"
  kubectl apply -f "$HELM/seaweedfs/namespace.yaml"   # PSS restricted
  if ! kubectl -n object-storage get secret seaweedfs-s3-config >/dev/null 2>&1 \
     || ! kubectl -n observability get secret tempo-s3 >/dev/null 2>&1 \
     || ! kubectl -n monitoring get secret thanos-objstore >/dev/null 2>&1; then
    local d; d="$(mktemp -d)"; chmod 700 "$d"
    key() { openssl rand -hex "$1"; }
    printf '%s' "$(key 10)" > "$d/tempo_ak"; printf '%s' "$(key 20)" > "$d/tempo_sk"
    printf '%s' "$(key 10)" > "$d/thanos_ak"; printf '%s' "$(key 20)" > "$d/thanos_sk"
    python3 -I - "$d" <<'PY'
import json, sys, os
d = sys.argv[1]
r = lambda n: open(os.path.join(d, n)).read()
ident = lambda name, bucket: {"name": name,
    "credentials": [{"accessKey": r(name + "_ak"), "secretKey": r(name + "_sk")}],
    "actions": [f"Read:{bucket}", f"Write:{bucket}", f"List:{bucket}"]}
json.dump({"identities": [ident("tempo", "tempo-traces"), ident("thanos", "thanos-metrics")]},
          open(os.path.join(d, "s3.json"), "w"))
open(os.path.join(d, "objstore.yml"), "w").write(
    "type: S3\nconfig:\n  bucket: thanos-metrics\n  endpoint: seaweedfs.object-storage:8333\n"
    f"  insecure: true\n  access_key: {r('thanos_ak')}\n  secret_key: {r('thanos_sk')}\n")
PY
    kubectl -n object-storage create secret generic seaweedfs-s3-config --from-file=s3.json="$d/s3.json" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n observability create secret generic tempo-s3 --from-file=AWS_ACCESS_KEY_ID="$d/tempo_ak" \
      --from-file=AWS_SECRET_ACCESS_KEY="$d/tempo_sk" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n monitoring create secret generic thanos-objstore --from-file=objstore.yml="$d/objstore.yml" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    rm -rf "$d"
    echo "S3 credentials generated (Secrets seaweedfs-s3-config, tempo-s3, thanos-objstore; not printed)"
    # s3.json is read only at start: pick up new keys (no-op on a fresh install).
    kubectl -n object-storage rollout restart statefulset/seaweedfs >/dev/null 2>&1 || true
  fi
}

# SeaweedFS server + bucket bootstrap Job (needs the ServiceMonitor/PrometheusRule CRDs).
apply_seaweedfs() {
  log "SeaweedFS server and buckets (helm/seaweedfs)"
  kubectl -n object-storage delete job seaweedfs-bootstrap --ignore-not-found >/dev/null   # Job spec is immutable
  kubectl apply -k "$HELM/seaweedfs"
  kubectl -n object-storage rollout status statefulset/seaweedfs --timeout 10m
  kubectl -n object-storage wait --for=condition=complete job/seaweedfs-bootstrap --timeout 10m
}

step_prometheus() {
  local V; mapfile -t V < <(vals "$HELM/kube-prometheus-stack")
  log "kube-prometheus-stack $KPS_VERSION"
  if [ "$OBJECT_STORE" = gcs ]; then
    # 30-day metrics in GCS via Thanos (helm/thanos/README.md): dedicated bucket, roles/storage.objectUser
    # for the sidecar (Prometheus SA), store and compactor KSAs via Workload Identity. The Secret must exist
    # before Prometheus starts (the sidecar mounts it). 35-day lifecycle: 30d retention + 48h delete-delay.
    local out bucket d old
    # ACCESS_MODE=gsa is wired for Tempo only (one KSA annotation); Thanos needs bucket or conditional.
    [ "${ACCESS_MODE:-bucket}" != gsa ] || { echo "error: ACCESS_MODE=gsa is Tempo-only; use bucket or conditional for Thanos" >&2; exit 2; }
    out="$(BUCKET="${THANOS_BUCKET:-thanos-metrics-$PROJECT_ID_FOR_BUCKETS}" LIFECYCLE_DAYS=35 \
      KSAS="monitoring/prometheus-kube-prometheus-prometheus monitoring/thanos-store monitoring/thanos-compact" \
      "$ROOT/infra/create-gcs-bucket.sh")"
    bucket="$(printf '%s\n' "$out" | head -n1)"   # contract: line 1 = bucket, line 2 = GSA
    [ "${#bucket}" -ge 3 ] || { echo "error: could not parse the Thanos bucket from infra/create-gcs-bucket.sh (got '$bucket')" >&2; exit 2; }
    d="$(mktemp -d)"; chmod 700 "$d"
    printf 'type: GCS\nconfig:\n  bucket: %s\n' "$bucket" > "$d/objstore.yml"   # no key: Workload Identity
    old="$(kubectl -n monitoring get secret thanos-objstore -o jsonpath='{.data.objstore\.yml}' 2>/dev/null || true)"
    kubectl -n monitoring create secret generic thanos-objstore --from-file=objstore.yml="$d/objstore.yml" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    # The sidecar, store and compactor read objstore.yml only at start: restart them when it changed.
    [ -z "$old" ] || [ "$old" = "$(base64 -w0 < "$d/objstore.yml")" ] || OBJSTORE_CHANGED=1
    rm -rf "$d"
  fi
  helm upgrade --install prometheus "$(chart prometheus-community/kube-prometheus-stack "$KPS_VERSION")" --version "$KPS_VERSION" \
    -n monitoring "${V[@]}" --wait --timeout 15m
  [ "$OBJECT_STORE" = seaweedfs ] && apply_seaweedfs
  # Thanos query, store-gateway, compactor: prod base or the lab overlay (1 replica); objstore from the Secret.
  if [ "$PROFILE" = prod ]; then log "Thanos (helm/thanos)"; kubectl apply -k "$HELM/thanos"
  else log "Thanos (helm/thanos/overlays/lab)"; kubectl apply -k "$HELM/thanos/overlays/lab"; fi
  kubectl -n monitoring rollout status deploy/thanos-query --timeout 10m
  if [ "${OBJSTORE_CHANGED:-0}" = 1 ]; then
    log "object store changed: restarting the Thanos sidecar (Prometheus), store and compactor"
    # The operator owns the Prometheus StatefulSet (it would revert a restart annotation): delete the pod.
    kubectl -n monitoring delete pod prometheus-prometheus-kube-prometheus-prometheus-0
    for s in thanos-store thanos-compact; do kubectl -n monitoring rollout restart "statefulset/$s"; done
    for s in prometheus-prometheus-kube-prometheus-prometheus thanos-store thanos-compact; do
      kubectl -n monitoring rollout status "statefulset/$s" --timeout 10m
    done
  fi
}

step_tempo() {
  local extra=() wi=() bucket gsa out
  if [ "$TEMPO_STORAGE" = gcs ]; then
    # Dedicated bucket + roles/storage.objectUser on it for observability/tempo via Workload Identity
    # (ACCESS_MODE=bucket|conditional|gsa, see infra/create-gcs-bucket.sh). No keys, no broad roles.
    out="$("$ROOT/infra/create-tempo-bucket.sh")"   # contract: line 1 = bucket, line 2 = GSA (may be empty)
    bucket="$(printf '%s\n' "$out" | head -n1)"; gsa="$(printf '%s\n' "$out" | sed -n 2p)"
    [ "${#bucket}" -ge 3 ] || { echo "error: could not parse the Tempo bucket from infra/create-tempo-bucket.sh (got '$bucket')" >&2; exit 2; }
    # Only ACCESS_MODE=gsa returns a (dedicated) Google service account to impersonate.
    [ -n "$gsa" ] && wi=(--set-string "serviceAccount.annotations.iam\.gke\.io/gcp-service-account=$gsa")
  fi
  if [ "$PROFILE" = prod ]; then
    log "tempo-distributed $TEMPO_DISTRIBUTED_VERSION (storage: $TEMPO_STORAGE)"
    [ -n "${KAFKA_BOOTSTRAP:-}" ] || { echo "error: PROFILE=prod needs KAFKA_BOOTSTRAP (Kafka-compatible queue, see helm/tempo-distributed/README.md)" >&2; exit 2; }
    [ "$TEMPO_STORAGE" = gcs ] && extra=(--set "storage.trace.gcs.bucket_name=$bucket")
    helm upgrade --install tempo "$(chart grafana-community/tempo-distributed "$TEMPO_DISTRIBUTED_VERSION")" --version "$TEMPO_DISTRIBUTED_VERSION" \
      -n observability -f "$HELM/tempo-distributed/values.yaml" "${extra[@]}" "${wi[@]}" \
      --set "ingest.kafka.address=$KAFKA_BOOTSTRAP" --wait --timeout 15m
    kubectl apply -f "$HELM/tempo-distributed/prometheusrule-rollout-operator.yaml"
  else
    log "tempo $TEMPO_VERSION single binary (storage: $TEMPO_STORAGE)"
    [ "$TEMPO_STORAGE" = gcs ] && extra=(-f "$HELM/tempo/values-gcs.yaml" --set "tempo.storage.trace.gcs.bucket_name=$bucket")
    [ "$TEMPO_STORAGE" = s3 ] && extra=(-f "$HELM/tempo/values-s3.yaml")   # SeaweedFS, Secret tempo-s3
    helm upgrade --install tempo "$(chart grafana-community/tempo "$TEMPO_VERSION")" --version "$TEMPO_VERSION" \
      -n observability -f "$HELM/tempo/values.yaml" "${extra[@]}" "${wi[@]}" --wait --timeout 10m
  fi
}

step_collector() {
  local V; mapfile -t V < <(vals "$HELM/otel-collector")
  log "opentelemetry-collector $OTEL_COLLECTOR_VERSION"
  helm upgrade --install otel-collector "$(chart open-telemetry/opentelemetry-collector "$OTEL_COLLECTOR_VERSION")" --version "$OTEL_COLLECTOR_VERSION" \
    -n observability "${V[@]}" --wait --timeout 10m
}

step_grafana() {
  local V; mapfile -t V < <(vals "$GRAFANA_HELM")
  log "grafana $GRAFANA_VERSION"
  if ! kubectl -n observability get secret grafana-admin >/dev/null 2>&1; then
    # Values come from files in a private temp dir (never on a command line).
    local d; d="$(mktemp -d)"; chmod 700 "$d"
    printf 'admin' > "$d/admin-user"
    python3 -I -c 'import secrets,sys; sys.stdout.write(secrets.token_urlsafe(24))' > "$d/admin-password"
    kubectl -n observability create secret generic grafana-admin \
      --from-file=admin-user="$d/admin-user" --from-file=admin-password="$d/admin-password" >/dev/null
    rm -rf "$d"
    echo "secret observability/grafana-admin created (read it with kubectl, it is not printed)"
  fi
  helm upgrade --install grafana "$(chart grafana-community/grafana "$GRAFANA_VERSION")" --version "$GRAFANA_VERSION" \
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
    CF_TOKEN_FILE="$CF_TOKEN_FILE" CF_ZONE="$DOMAIN" "$ROOT/scripts/update-dns.sh" "$h.$DOMAIN" "$ip"
  done
}

# kube-prometheus-stack first: it owns the ServiceMonitor/PrometheusRule CRDs the other charts use.
# k8s/ chart values: <name>-values.yaml plus <name>-values-lab.yaml in the lab profile.
CM_VALS=(-f "$K8S/cert-manager-values.yaml"); TRAEFIK_VALS=(-f "$K8S/traefik-values.yaml")
if [ "$PROFILE" = lab ]; then
  [ -f "$K8S/cert-manager-values-lab.yaml" ] && CM_VALS+=(-f "$K8S/cert-manager-values-lab.yaml")
  [ -f "$K8S/traefik-values-lab.yaml" ] && TRAEFIK_VALS+=(-f "$K8S/traefik-values-lab.yaml")
fi

ALL=(namespaces objectstore prometheus certmanager traefik tempo collector grafana dashboards edge dns)
STEPS=("$@"); [ ${#STEPS[@]} -gt 0 ] || STEPS=("${ALL[@]}")
if ! command -v helm >/dev/null || ! command -v kubectl >/dev/null; then echo "need helm and kubectl" >&2; exit 2; fi
echo "context: $(kubectl config current-context)  profile: $PROFILE  tls: $TLS_MODE  object store: $OBJECT_STORE  tempo storage: $TEMPO_STORAGE"
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
