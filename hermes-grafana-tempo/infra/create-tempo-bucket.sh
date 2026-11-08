#!/usr/bin/env bash
# Tempo trace bucket: a dedicated bucket per environment for Tempo blocks, with
# roles/storage.objectUser for the Kubernetes service account observability/tempo through
# Workload Identity (no keys). Thin wrapper around create-gcs-bucket.sh (see it for ACCESS_MODE).
#   infra/create-tempo-bucket.sh        # last two lines: bucket name, dedicated GSA email ("" unless ACCESS_MODE=gsa)
# Lifecycle backstop 33 days, after Tempo's block_retention of 720h (30 days).
set -euo pipefail
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
export PROJECT_ID
export BUCKET="${TEMPO_BUCKET:-tempo-traces-$PROJECT_ID}"
export KSAS="${TEMPO_KSAS:-observability/tempo}"
export LIFECYCLE_DAYS="${LIFECYCLE_DAYS:-33}"
export ACCESS_MODE="${ACCESS_MODE:-bucket}"
[ "$ACCESS_MODE" = gsa ] && export GSA_NAME="${GSA_NAME:-tempo-gcs}"
exec "$(dirname "${BASH_SOURCE[0]}")/create-gcs-bucket.sh"
