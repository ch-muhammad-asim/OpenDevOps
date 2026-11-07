#!/usr/bin/env bash
# Deploy the herdr + Hermes POC to the current kubectl context (namespace hermes-herdr).
#   herdr/hermes-herdr/k8s/deploy.sh             # build + push images, apply, create Secrets, wait
#   BUILD=0 herdr/hermes-herdr/k8s/deploy.sh     # reuse the images already in the registry
#   CLUSTER_NAME / ZONE (as in gcp-infra.sh) or POD_CIDR: the pod range tinyproxy allows (read from the cluster)
# Images: the compose images, built from herdr/hermes-herdr, pushed to Artifact Registry and pinned by digest.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; POC="$(cd "$HERE/.." && pwd)"
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
REGISTRY="${REGISTRY:-us-central1-docker.pkg.dev/$PROJECT/hermes}"
HERMES_VERSION="${HERMES_VERSION:-v0.23.0}"
declare -A IMG=(
  [herdr-hermes]="herdr-hermes:herdr0.9.5-hermes${HERMES_VERSION}|$POC|--build-arg HERMES_IMAGE=nousresearch/hermes-agent:${HERMES_VERSION}"
  [hermes-workbench]="hermes-workbench:alpine3.24.2|$POC/workbench|"
  [hermes-herdr-work]="hermes-herdr-work:herdr0.9.5-alpine3.24.2|$POC/work|"
  [hermes-herdr-egress]="hermes-herdr-egress:alpine3.24.2|$POC/egress|"
)
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if [ "${BUILD:-1}" = 1 ]; then
  log "Build and push images to $REGISTRY"
  DOCKER_CONFIG="$(mktemp -d)"; export DOCKER_CONFIG; trap 'rm -rf "$DOCKER_CONFIG"' EXIT
  echo '{"credHelpers":{"us-central1-docker.pkg.dev":"gcloud"}}' >"$DOCKER_CONFIG/config.json"
  [ -d "$HOME/.docker/cli-plugins" ] && ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG/"
  for n in "${!IMG[@]}"; do
    IFS='|' read -r tag ctx args <<<"${IMG[$n]}"
    # shellcheck disable=SC2086  # $args is a word list
    docker buildx build -q --load $args -t "$REGISTRY/$tag" "$ctx" >/dev/null
    docker push -q "$REGISTRY/$tag" >/dev/null
    echo "pushed $tag"
  done
fi

log "Pin images by digest"
WORK="$(mktemp -d)"; cp "$HERE"/*.yaml "$WORK/"
# tinyproxy's Allow = the cluster's pod range (it differs per cluster); the NetworkPolicy is the control that limits
# callers to herdr-hermes. Same CLUSTER_NAME/ZONE variables as gcp/gcp-infra.sh; POD_CIDR overrides the lookup.
CLUSTER_NAME="${CLUSTER_NAME:-hermes-gke}"
ZONE="${ZONE:-$(gcloud container clusters list --filter="name=$CLUSTER_NAME" --format='value(location)' | head -1)}"
POD_CIDR="${POD_CIDR:-$(gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" --format='value(clusterIpv4Cidr)')}"
[[ "$POD_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || { echo "no valid pod CIDR ('$POD_CIDR'): set POD_CIDR" >&2; exit 1; }
sed -i "s#@POD_CIDR@#$POD_CIDR#" "$WORK/egress.yaml"
echo "egress Allow = pod range $POD_CIDR"
for n in "${!IMG[@]}"; do
  IFS='|' read -r tag _ _ <<<"${IMG[$n]}"
  digest="$(gcloud artifacts docker images describe "$REGISTRY/$tag" --format='value(image_summary.digest)' 2>/dev/null)" \
    || { echo "$REGISTRY/$tag is not in the registry: run without BUILD=0 (BUILD=0 only reuses pushed images)" >&2; exit 1; }
  # kustomization.yaml lists each image name; add newName + digest under it.
  sed -i "s#^  - name: $n\$#  - name: $n\n    newName: $REGISTRY/${tag%%:*}\n    digest: $digest#" "$WORK/kustomization.yaml"
  echo "$n = ${tag%%:*}@$digest"
done

log "Apply (namespace, NetworkPolicies, Services, Deployments, PVCs)"
kubectl apply -f "$WORK/namespace.yaml"
"$HERE/make-secrets.sh"
kubectl apply -k "$WORK"
rm -rf "$WORK"

log "Wait for the four Deployments"
for n in hermes-herdr-egress hermes-workbench hermes-herdr-work herdr-hermes; do
  kubectl -n hermes-herdr rollout status "deploy/$n" --timeout=600s
done
kubectl -n hermes-herdr get pods -o wide
