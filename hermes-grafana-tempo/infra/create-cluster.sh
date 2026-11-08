#!/usr/bin/env bash
# Create the GKE cluster for hermes-grafana-tempo (idempotent).
#   PROFILE=lab  (default) zonal, 3 x e2-standard-2 (6 vCPU / 24 GB total), 50 GB pd-standard per node.
#                Sized for a small lab quota; the lab cluster was created with exactly these flags.
#   PROFILE=prod regional (REGION required, 3 zones), node autoscaling per zone, e2-standard-8,
#                pd-balanced, private nodes + Cloud NAT, maintenance window, surge upgrades.
# Dataplane V2 enforces the NetworkPolicies in ../k8s (it can only be set at create time).
set -euo pipefail

PROFILE="${PROFILE:-lab}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
ZONE="${ZONE:-us-central1-a}"
# Lab: zonal (ZONE) to stay inside a small quota; setting REGION makes it regional (NUM_NODES per zone).
# Prod: REGION is required.
REGION="${REGION:-}"
CLUSTER_NAME="${CLUSTER_NAME:-tempo-demo}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-regular}"
# Control-plane access: your current public IP only, unless set explicitly.
AUTHORIZED_NETWORKS="${AUTHORIZED_NETWORKS:-$(curl -fsS https://ifconfig.me)/32}"

case "$PROFILE" in
  lab)
    MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-2}"
    NUM_NODES="${NUM_NODES:-3}"
    DISK_TYPE="${DISK_TYPE:-pd-standard}"
    DISK_SIZE="${DISK_SIZE:-50}"
    ;;
  prod)
    MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-8}"
    NUM_NODES="${NUM_NODES:-2}"          # initial nodes PER ZONE
    MIN_NODES="${MIN_NODES:-2}"          # autoscaler bounds PER ZONE (x3 zones)
    MAX_NODES="${MAX_NODES:-4}"
    DISK_TYPE="${DISK_TYPE:-pd-balanced}"
    DISK_SIZE="${DISK_SIZE:-100}"
    NETWORK="${NETWORK:-default}"
    # Private nodes have no public IP; image pulls (Docker Hub, quay.io, ghcr.io) and external
    # APIs (Cloudflare, Kafka, Let's Encrypt) then need Cloud NAT. CREATE_NAT=false if the VPC
    # already has a Cloud NAT in REGION.
    PRIVATE_NODES="${PRIVATE_NODES:-true}"
    CREATE_NAT="${CREATE_NAT:-$PRIVATE_NODES}"
    # Weekly window (UTC); GKE needs at least 48h of availability in any 32 days.
    MAINTENANCE_START="${MAINTENANCE_START:-2026-01-03T02:00:00Z}"
    MAINTENANCE_END="${MAINTENANCE_END:-2026-01-03T08:00:00Z}"
    MAINTENANCE_RECURRENCE="${MAINTENANCE_RECURRENCE:-FREQ=WEEKLY;BYDAY=SA,SU}"
    [ -n "$REGION" ] || { echo "PROFILE=prod needs REGION (for example REGION=us-central1)" >&2; exit 1; }
    ;;
  *) echo "PROFILE must be lab or prod (got: $PROFILE)" >&2; exit 1 ;;
esac

[ -n "$PROJECT_ID" ] || { echo "PROJECT_ID is not set" >&2; exit 1; }

echo "Enabling APIs..."
gcloud services enable container.googleapis.com compute.googleapis.com artifactregistry.googleapis.com \
  --project="$PROJECT_ID"

if [ -n "$REGION" ]; then LOC=(--region="$REGION"); else LOC=(--zone="$ZONE"); fi

# Flags shared by both profiles; the lab cluster was created with exactly these.
COMMON=(
  --project="$PROJECT_ID"
  "${LOC[@]}"
  --release-channel="$RELEASE_CHANNEL"
  --machine-type="$MACHINE_TYPE"
  --num-nodes="$NUM_NODES"
  --disk-type="$DISK_TYPE"
  --disk-size="$DISK_SIZE"
  --image-type=COS_CONTAINERD
  --enable-ip-alias
  --enable-dataplane-v2
  --workload-pool="${PROJECT_ID}.svc.id.goog"
  --workload-metadata=GKE_METADATA
  --enable-master-authorized-networks
  --master-authorized-networks="$AUTHORIZED_NETWORKS"
  --logging=SYSTEM
  --monitoring=SYSTEM
)

PROD=()
if [ "$PROFILE" = prod ]; then
  PROD=(
    --network="$NETWORK"
    --enable-autoscaling
    --min-nodes="$MIN_NODES"
    --max-nodes="$MAX_NODES"
    --max-surge-upgrade=1
    --max-unavailable-upgrade=0
    --shielded-secure-boot
    --shielded-integrity-monitoring
    --maintenance-window-start="$MAINTENANCE_START"
    --maintenance-window-end="$MAINTENANCE_END"
    --maintenance-window-recurrence="$MAINTENANCE_RECURRENCE"
  )
  if [ "$PRIVATE_NODES" = true ]; then PROD+=(--enable-private-nodes); fi

  if [ "$CREATE_NAT" = true ]; then
    ROUTER="${CLUSTER_NAME}-router"
    NAT="${CLUSTER_NAME}-nat"
    if ! gcloud compute routers describe "$ROUTER" --project="$PROJECT_ID" --region="$REGION" >/dev/null 2>&1; then
      echo "Creating Cloud Router $ROUTER..."
      gcloud compute routers create "$ROUTER" --project="$PROJECT_ID" --region="$REGION" --network="$NETWORK"
    fi
    if ! gcloud compute routers nats describe "$NAT" --router="$ROUTER" --project="$PROJECT_ID" \
        --region="$REGION" >/dev/null 2>&1; then
      echo "Creating Cloud NAT $NAT..."
      gcloud compute routers nats create "$NAT" --router="$ROUTER" --project="$PROJECT_ID" --region="$REGION" \
        --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
    fi
  fi
fi

if gcloud container clusters describe "$CLUSTER_NAME" --project="$PROJECT_ID" "${LOC[@]}" >/dev/null 2>&1; then
  echo "Cluster $CLUSTER_NAME already exists"
else
  gcloud container clusters create "$CLUSTER_NAME" "${COMMON[@]}" "${PROD[@]}"
fi

gcloud container clusters get-credentials "$CLUSTER_NAME" --project="$PROJECT_ID" "${LOC[@]}"
kubectl get nodes -o wide
