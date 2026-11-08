#!/usr/bin/env bash
# Build the three sample app images (linux/amd64) and push them to Artifact Registry.
# Usage: apps/build-push.sh            (all apps)
#        apps/build-push.sh nodejs     (one app)
# Env:   PROJECT_ID (default: gcloud config), REGION (default us-central1),
#        AR_REPO (default tempo-apps), TAG (default 1.0.3)
set -euo pipefail
cd "$(dirname "$0")"

command -v gcloud >/dev/null || { echo "gcloud CLI not found" >&2; exit 1; }
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
AR_REPO="${AR_REPO:-tempo-apps}"
TAG="${TAG:-1.0.3}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}"
if [[ $# -gt 0 ]]; then APPS=("$@"); else APPS=(python nodejs nextjs); fi

[[ -n "$PROJECT_ID" ]] || { echo "PROJECT_ID is not set and gcloud has no default project" >&2; exit 1; }

if ! gcloud artifacts repositories describe "$AR_REPO" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Artifact Registry repo '$AR_REPO' not found. Create it first:" >&2
  echo "  gcloud artifacts repositories create $AR_REPO --repository-format=docker --location=$REGION" >&2
  exit 1
fi
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet >/dev/null

for app in "${APPS[@]}"; do
  [[ -f "$app/Dockerfile" ]] || { echo "unknown app: $app" >&2; exit 1; }
  echo "==> $app -> ${REGISTRY}/${app}:${TAG}"
  docker buildx build --platform linux/amd64 --provenance=false \
    -t "${REGISTRY}/${app}:${TAG}" --push "$app"
done
echo "Pushed: ${APPS[*]} (tag ${TAG}) to ${REGION}-docker.pkg.dev/<project>/${AR_REPO}"
