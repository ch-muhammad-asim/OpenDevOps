#!/usr/bin/env bash
# Run the OpenShell CLI against the GKE gateway from this machine:
#   sandbox/k8s/gke/openshell-cli.sh sandbox list
#   sandbox/k8s/gke/openshell-cli.sh logs hermes -n 200 --source sandbox
#   sandbox/k8s/gke/openshell-cli.sh sandbox exec -n hermes --no-tty -- id </dev/null
#
# How: a kubectl port-forward to svc/openshell (ClusterIP only, never exposed),
# the chart's client certificate (Secret openshell-client-tls) copied into a
# private temp dir for this run only, and the CLI from the hermes-tunnel image.
# Needs kubectl (context = the cluster), docker, and the image in Artifact Registry.
set -euo pipefail
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
REGISTRY="${REGISTRY:-us-central1-docker.pkg.dev/$PROJECT/hermes}"
PORT="${OPENSHELL_LOCAL_PORT:-18080}"
D="$(mktemp -d)"; chmod 700 "$D"
PF=""
cleanup() { [ -n "$PF" ] && kill "$PF" 2>/dev/null; rm -rf "$D"; }
trap cleanup EXIT
mkdir -p "$D/openshell/gateways/gke/mtls"
for f in ca.crt tls.crt tls.key; do
  kubectl -n openshell get secret openshell-client-tls -o "jsonpath={.data['${f//./\\.}']}" \
    | base64 -d > "$D/openshell/gateways/gke/mtls/$f"
done
chmod -R go-rwx "$D"
kubectl -n openshell port-forward svc/openshell "$PORT:8080" >/dev/null 2>&1 &
PF=$!
for _ in $(seq 1 30); do (echo > /dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && break; sleep 1; done
docker run --rm -i --network host --user "$(id -u):$(id -g)" \
  -e XDG_CONFIG_HOME=/cfg -e HOME=/tmp -e OPENSHELL_GATEWAY=gke \
  -e OPENSHELL_GATEWAY_ENDPOINT="https://127.0.0.1:$PORT" \
  -v "$D:/cfg" --entrypoint openshell "$REGISTRY/hermes-tunnel:0.1.6" "$@"
