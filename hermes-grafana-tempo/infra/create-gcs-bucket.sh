#!/usr/bin/env bash
# Create a dedicated GCS bucket for one environment and give Kubernetes service accounts
# least-privilege access to it through Workload Identity Federation for GKE (no keys). Idempotent.
#
#   BUCKET=tempo-traces-prod KSAS="observability/tempo" infra/create-gcs-bucket.sh
#   BUCKET=thanos-metrics-prod KSAS="monitoring/prometheus-kube-prometheus-prometheus monitoring/thanos-store monitoring/thanos-compact" \
#     infra/create-gcs-bucket.sh
#
# Bucket: uniform bucket-level access, public access prevention, versioning OFF, lifecycle rule
# deleting objects after LIFECYCLE_DAYS (default 33) as a backstop behind the application's own
# retention (Tempo block_retention 720h, Thanos compactor 30d).
# Roles (ROLES, space-separated): default roles/storage.objectUser (objects: create/get/list/update/delete;
# no bucket admin). Tempo also needs roles/storage.bucketViewer (storage.buckets.get: it reads the bucket
# attributes at start); infra/create-tempo-bucket.sh adds it. Every role gets the same scope below.
#
# ACCESS_MODE (least privilege first):
#   bucket       (default) role bound ON THE BUCKET to each KSA principal
#                principal://.../subject/ns/<ns>/sa/<sa>. Needs storage.buckets.getIamPolicy+setIamPolicy.
#   conditional  role bound at PROJECT level to each KSA principal with an IAM condition limiting it to
#                this bucket and its objects. Needs resourcemanager.projects.get/setIamPolicy.
#   gsa          a DEDICATED Google service account (GSA_NAME, created here, never a default compute
#                account) gets the role with the same bucket condition; each KSA may impersonate it
#                (roles/iam.workloadIdentityUser). Prints the GSA email to annotate the KSAs with.
#                scripts/deploy.sh wires this for Tempo only (it annotates observability/tempo); the Thanos
#                bucket must use bucket or conditional (deploy.sh refuses gsa there).
# Never uses JSON keys.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
BUCKET="${BUCKET:?set BUCKET (one dedicated bucket per environment)}"
KSAS="${KSAS:?set KSAS to space-separated <namespace>/<serviceaccount> pairs}"
LIFECYCLE_DAYS="${LIFECYCLE_DAYS:-33}"
ACCESS_MODE="${ACCESS_MODE:-bucket}"
ROLES="${ROLES:-roles/storage.objectUser}"
[ -n "$PROJECT_ID" ] || { echo "PROJECT_ID is not set" >&2; exit 1; }
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
POOL="$PROJECT_ID.svc.id.goog"
principal() { echo "principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/subject/ns/${1%%/*}/sa/${1##*/}"; }
# IAM condition: this bucket and the objects in it only.
COND="expression=resource.name == 'projects/_/buckets/$BUCKET' || resource.name.startsWith('projects/_/buckets/$BUCKET/objects/'),title=only-$BUCKET"

if ! gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://$BUCKET" --project="$PROJECT_ID" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
lc="$(mktemp)"; trap 'rm -f "$lc"' EXIT
printf '{"rule":[{"action":{"type":"Delete"},"condition":{"age":%s}}]}\n' "$LIFECYCLE_DAYS" > "$lc"
gcloud storage buckets update "gs://$BUCKET" --lifecycle-file="$lc" --no-versioning >/dev/null

gsa=""
case "$ACCESS_MODE" in
  bucket)
    for k in $KSAS; do for r in $ROLES; do
      gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="$(principal "$k")" --role="$r" >/dev/null
    done; done ;;
  conditional)
    for k in $KSAS; do for r in $ROLES; do
      gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$(principal "$k")" --role="$r" \
        --condition="$COND" >/dev/null
    done; done ;;
  gsa)
    GSA_NAME="${GSA_NAME:?ACCESS_MODE=gsa needs GSA_NAME (dedicated, e.g. tempo-gcs)}"
    gsa="$GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
    gcloud iam service-accounts describe "$gsa" >/dev/null 2>&1 \
      || gcloud iam service-accounts create "$GSA_NAME" --project="$PROJECT_ID" --display-name="GCS access for $BUCKET"
    for r in $ROLES; do
      gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$gsa" --role="$r" \
        --condition="$COND" >/dev/null
    done
    for k in $KSAS; do
      gcloud iam service-accounts add-iam-policy-binding "$gsa" --role=roles/iam.workloadIdentityUser \
        --member="serviceAccount:${POOL}[${k%%/*}/${k##*/}]" >/dev/null
    done ;;
  *) echo "ACCESS_MODE must be bucket, conditional or gsa" >&2; exit 2 ;;
esac

echo "gs://$BUCKET ready: $ROLES for [$KSAS] via $ACCESS_MODE, lifecycle ${LIFECYCLE_DAYS}d, versioning off" >&2
echo "$BUCKET"
echo "$gsa"
