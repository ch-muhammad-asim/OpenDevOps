#!/usr/bin/env bash
# Remove everything this project created (platform, apps, Hermes Agent). Safe to re-run.
#   scripts/teardown.sh            # uninstall releases + namespaces, keep the cluster
#   scripts/teardown.sh --cluster  # also delete the Tempo bucket and the GKE cluster (asks to confirm each)
# DNS records are left in place; delete them in Cloudflare if the hostnames are not reused.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER_NAME="${CLUSTER_NAME:-tempo-demo}"

echo "context: $(kubectl config current-context)"
for r in grafana:observability otel-collector:observability tempo:observability prometheus:monitoring \
         traefik:traefik cert-manager:cert-manager; do
  helm uninstall "${r%%:*}" -n "${r##*:}" --wait 2>/dev/null || true
done
# hermes: Hermes Agent (hermes/), deployed into this platform.
kubectl delete namespace hermes tempo-apps observability monitoring object-storage traefik cert-manager --ignore-not-found --wait=true
kubectl delete clusterissuer letsencrypt-staging letsencrypt-prod --ignore-not-found 2>/dev/null || true
# Cluster-scoped leftovers (CRDs are kept by Helm on uninstall). Safe to re-run: no match is not an error.
{ kubectl get crd -o name | grep -E 'monitoring.coreos.com|cert-manager.io|traefik.io|traefik.containo.us' || true; } \
  | xargs -r kubectl delete

if [ "${1:-}" = "--cluster" ]; then
  TEMPO_BUCKET="${TEMPO_BUCKET:-tempo-traces-$PROJECT_ID}"
  if gcloud storage buckets describe "gs://$TEMPO_BUCKET" >/dev/null 2>&1; then
    read -r -p "Also delete the Tempo trace bucket and all its objects? [y/N] " b
    [ "$b" = y ] && gcloud storage rm -r "gs://$TEMPO_BUCKET"
  fi
  read -r -p "Delete GKE cluster $CLUSTER_NAME in $ZONE? Type the name to confirm: " ans
  [ "$ans" = "$CLUSTER_NAME" ] || { echo "aborted"; exit 1; }
  gcloud container clusters delete "$CLUSTER_NAME" --project="$PROJECT_ID" --zone="$ZONE" --quiet
  echo "Persistent disks from PVCs are deleted with the namespaces above; check: gcloud compute disks list"
fi
