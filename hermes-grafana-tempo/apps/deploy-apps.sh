#!/usr/bin/env bash
# Apply the three sample apps to namespace tempo-apps, pinned by image DIGEST from Artifact Registry.
# Usage: apps/deploy-apps.sh [production|lab]   (default production; after apps/build-push.sh;
#        namespace tempo-apps must exist). lab = 1 replica per app for a 3 x e2-standard-2 cluster.
# Env:   PROJECT_ID, REGION, AR_REPO, TAG - same defaults as build-push.sh
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${1:-production}"
case "$PROFILE" in
  production) KUSTOMIZE_DIR=. ;;
  lab) KUSTOMIZE_DIR=lab ;;
  *) echo "usage: $0 [production|lab]" >&2; exit 2 ;;
esac

command -v gcloud >/dev/null || { echo "gcloud CLI not found" >&2; exit 1; }
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-us-central1}"
AR_REPO="${AR_REPO:-tempo-apps}"
TAG="${TAG:-1.0.3}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}"
APPS=(python nodejs nextjs)

[[ -n "$PROJECT_ID" ]] || { echo "PROJECT_ID is not set and gcloud has no default project" >&2; exit 1; }

# Resolve each tag to its digest, so pods run exactly the pushed image.
SED_ARGS=()
for app in "${APPS[@]}"; do
  digest=$(gcloud artifacts docker images describe "${REGISTRY}/${app}:${TAG}" \
    --format='value(image_summary.digest)' 2>/dev/null) || true
  [[ "$digest" == sha256:* ]] || { echo "image ${app}:${TAG} not found in ${AR_REPO}; run apps/build-push.sh" >&2; exit 1; }
  echo "${app}:${TAG} -> ${digest}"
  SED_ARGS+=(-e "s#image: tempo-apps/${app}:[^[:space:]]*#image: ${REGISTRY}/${app}@${digest}#")
done

echo "profile: ${PROFILE}"
kubectl kustomize "$KUSTOMIZE_DIR" | sed "${SED_ARGS[@]}" | kubectl apply -f -
for app in "${APPS[@]}"; do
  kubectl -n tempo-apps rollout status "deployment/${app}" --timeout=180s
done
kubectl -n tempo-apps get pods -l app.kubernetes.io/part-of=tempo-apps -o wide
