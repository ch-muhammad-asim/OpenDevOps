#!/usr/bin/env bash
# Create the GCS bucket for Tempo trace blocks and let the Kubernetes service account
# observability/tempo use it through Workload Identity (idempotent).
# No key files in either mode:
#   ACCESS_MODE=principal (default, production): objectAdmin on THIS bucket for the Kubernetes
#     service account itself (Workload Identity Federation principal). Needs bucket setIamPolicy.
#   ACCESS_MODE=gsa (restricted lab accounts that cannot edit bucket IAM): the Kubernetes service
#     account impersonates an existing Google service account (TEMPO_GSA, default: the project's
#     default compute service account) that already has storage access. Broader than "principal".
# Output (last two lines): the bucket name, then the Google service account to annotate ("" for principal).
#   infra/create-tempo-bucket.sh
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
TEMPO_BUCKET="${TEMPO_BUCKET:-tempo-traces-$PROJECT_ID}"
K8S_NAMESPACE="${K8S_NAMESPACE:-observability}"
K8S_SA="${K8S_SA:-tempo}"
LIFECYCLE_DAYS="${LIFECYCLE_DAYS:-16}"  # safety net, longer than Tempo retention (prod 14d); deploy.sh sets it per profile
ACCESS_MODE="${ACCESS_MODE:-principal}"   # principal (production) or gsa (restricted accounts, not recommended)

[ -n "$PROJECT_ID" ] || { echo "PROJECT_ID is not set" >&2; exit 1; }
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
MEMBER="principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/$K8S_NAMESPACE/sa/$K8S_SA"

if ! gcloud storage buckets describe "gs://$TEMPO_BUCKET" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$TEMPO_BUCKET" --project="$PROJECT_ID" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi

lc="$(mktemp)"; trap 'rm -f "$lc"' EXIT
printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":%s}}]}\n' "$LIFECYCLE_DAYS" > "$lc"
gcloud storage buckets update "gs://$TEMPO_BUCKET" --lifecycle-file="$lc" >/dev/null

gsa=""
if [ "$ACCESS_MODE" = principal ]; then
  # Tempo reads, writes and deletes (compaction, retention) objects in this bucket only.
  gcloud storage buckets add-iam-policy-binding "gs://$TEMPO_BUCKET" \
    --member="$MEMBER" --role=roles/storage.objectAdmin >/dev/null
else
  gsa="${TEMPO_GSA:-$PROJECT_NUMBER-compute@developer.gserviceaccount.com}"
  gcloud iam service-accounts add-iam-policy-binding "$gsa" --project="$PROJECT_ID" \
    --role=roles/iam.workloadIdentityUser \
    --member="serviceAccount:$PROJECT_ID.svc.id.goog[$K8S_NAMESPACE/$K8S_SA]" >/dev/null
fi

echo "bucket ready, Workload Identity access ($ACCESS_MODE) for $K8S_NAMESPACE/$K8S_SA" >&2
echo "$TEMPO_BUCKET"
echo "$gsa"
