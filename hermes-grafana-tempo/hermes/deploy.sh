#!/usr/bin/env bash
# Deploy Hermes Agent (gateway with OTLP monitoring export + web dashboard) into namespace "hermes".
#   hermes/deploy.sh                      production profile (hermes/base/)
#   HERMES_PROFILE=lab hermes/deploy.sh   lab profile (hermes/lab/: no PVC, smaller requests)
#   hermes/deploy.sh                                                                  model: OpenCode free models via the bridge (default)
#   MODEL_PROVIDER=cloudflare CLOUDFLARE_AI_CREDS_FILE=~/keys/cloudflare-ai hermes/deploy.sh   model: Cloudflare Workers AI
#   MODEL_PROVIDER=opencode OPENCODE_API_KEY_FILE=~/keys/opencode hermes/deploy.sh    model: OpenCode Zen/Go
# Needs: kubectl pointed at the cluster, kube-prometheus-stack (PrometheusRule CRD), Traefik (IngressRoute
# CRD) and the OpenTelemetry Collector running in namespace "observability".
# Secrets are generated once (model credentials are read from local files, see step 3), stored only in Kubernetes
# Secrets, and never printed or written to Git.
# To use Secret Manager instead, sync Secrets with the same names and keys before running this.
set -euo pipefail
cd "$(dirname "$0")"

case "${HERMES_PROFILE:-production}" in
  production) dir=base ;;
  lab) dir=lab ;;
  *) echo "HERMES_PROFILE must be production or lab" >&2; exit 1 ;;
esac

for crd in prometheusrules.monitoring.coreos.com ingressroutes.traefik.io middlewares.traefik.io; do
  kubectl get crd "$crd" >/dev/null || { echo "CRD $crd missing: install kube-prometheus-stack and Traefik first" >&2; exit 1; }
done

kubectl apply -f base/namespace.yaml
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
umask 077

# Public hostname. The manifests keep the reusable example.com placeholder, so a private copy is rendered with
# DOMAIN (or the older ZONE) and applied instead of the tracked files.
DOMAIN="${DOMAIN:-${ZONE:-example.com}}"
if [ "$DOMAIN" != example.com ]; then
  mkdir -p "$tmp/rendered"
  cp -a "$dir" "$tmp/rendered/$dir"
  grep -rlZ 'example\.com' "$tmp/rendered/$dir" 2>/dev/null | xargs -0 -r sed -i "s/example\.com/${DOMAIN}/g"
  dir="$tmp/rendered/$dir"
fi
rand() { head -c "$1" /dev/urandom | base64 | tr -d '\n/+='; }

# 1. Gateway API server key (the API server listens on localhost only).
if ! kubectl -n hermes get secret hermes-api-server >/dev/null 2>&1; then
  rand 48 > "$tmp/API_SERVER_KEY"
  kubectl -n hermes create secret generic hermes-api-server --from-file=API_SERVER_KEY="$tmp/API_SERVER_KEY"
fi

# 2. Hermes dashboard login, Secret hermes-dashboard-auth:
#   username, password_hash (scrypt), session_secret -> env of the dashboard container
#   password                                          -> for the operator only (README, 'Log in'); not in the pod
if ! kubectl -n hermes get secret hermes-dashboard-auth >/dev/null 2>&1; then
  printf 'admin' > "$tmp/username"
  rand 24 > "$tmp/password"
  rand 48 > "$tmp/session_secret"
  # Same format as Hermes's plugins.dashboard_auth.basic.hash_password (scrypt n=2^14, r=8, p=1).
  # shellcheck disable=SC2016  # the $ signs are literal parts of the hash format
  python3 -I -c 'import base64, hashlib, secrets, sys
pw = open(sys.argv[1]).read().strip().encode(); salt = secrets.token_bytes(16)
dk = hashlib.scrypt(pw, salt=salt, n=16384, r=8, p=1, dklen=32, maxmem=0)
open(sys.argv[2], "w").write("scrypt$16384$8$1$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(dk).decode())' \
    "$tmp/password" "$tmp/password_hash"
  kubectl -n hermes create secret generic hermes-dashboard-auth \
    --from-file=username="$tmp/username" --from-file=password="$tmp/password" \
    --from-file=password_hash="$tmp/password_hash" \
    --from-file=session_secret="$tmp/session_secret"
fi

# 3. OpenCode bridge (default model provider: OpenCode's free models, no key, no cost). Reuses the bridge script from
#    this repository (../../opencode/kubernetes/bridge/opencode_bridge.py) as ConfigMap opencode-bridge-script, and a
#    random shared key (Secret hermes-opencode-bridge) that Hermes sends to it.
REPO_ROOT="$(cd ../.. && pwd)"   # this script cd's into hermes/, so the repository root is two levels up
BRIDGE_SRC="${OPENCODE_BRIDGE_SRC:-$REPO_ROOT/opencode/kubernetes/bridge/opencode_bridge.py}"
[[ -r "$BRIDGE_SRC" ]] || { echo "error: OpenCode bridge script not found at $BRIDGE_SRC" >&2
  echo "       clone the full repository or set OPENCODE_BRIDGE_SRC to its opencode/kubernetes/bridge/opencode_bridge.py" >&2
  exit 1; }
if kubectl -n hermes create configmap opencode-bridge-script --from-file=opencode_bridge.py="$BRIDGE_SRC" \
     --dry-run=client -o yaml | kubectl apply -f - | grep -q configured; then
  bridge_changed=1
fi
if ! kubectl -n hermes get secret hermes-opencode-bridge >/dev/null 2>&1; then
  rand 48 > "$tmp/OPENCODE_BRIDGE_API_KEY"
  kubectl -n hermes create secret generic hermes-opencode-bridge --from-file=OPENCODE_BRIDGE_API_KEY="$tmp/OPENCODE_BRIDGE_API_KEY"
fi

# 4. Model provider -> Secret hermes-model-key (HERMES_MODEL, HERMES_MODEL_BASE_URL, HERMES_MODEL_API_KEY).
#    Credentials come from local files outside the repo and are never printed. Re-run to switch providers, then
#    restart the pod. Without a credentials file the existing Secret is kept (or the gateway runs telemetry-only).
#    MODEL_PROVIDER=opencode-bridge (default)  the in-cluster bridge above; model opencode/deepseek-v4.1-flash-free
#                               (override: HERMES_MODEL, any free model the bridge lists at /v1/models)
#    MODEL_PROVIDER=cloudflare  CLOUDFLARE_AI_CREDS_FILE=<file with lines "Account ID: <id>" and "API: <token>">
#                               model @cf/openai/gpt-oss-120b (override: HERMES_MODEL)
#    MODEL_PROVIDER=opencode    OPENCODE_API_KEY_FILE=<file with the key>   (OpenCode Zen pay-as-you-go or Go;
#                               its free models are not available outside the OpenCode app)
#                               model glm-5.3-flash (override: HERMES_MODEL; OPENCODE_BASE_URL for Go)
field() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]]+).*/\\1/p" "$2" | head -n1 | tr -d '\r\n'; }
model_secret() {  # $1 model id, $2 base URL, key in $tmp/HERMES_MODEL_API_KEY
  [[ -s "$tmp/HERMES_MODEL_API_KEY" ]] || { echo "model API key is empty" >&2; exit 1; }
  printf '%s' "$1" >"$tmp/HERMES_MODEL"; printf '%s' "$2" >"$tmp/HERMES_MODEL_BASE_URL"
  kubectl -n hermes create secret generic hermes-model-key --from-file=HERMES_MODEL="$tmp/HERMES_MODEL" \
    --from-file=HERMES_MODEL_BASE_URL="$tmp/HERMES_MODEL_BASE_URL" --from-file=HERMES_MODEL_API_KEY="$tmp/HERMES_MODEL_API_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "Secret hermes-model-key: provider ${MODEL_PROVIDER:-opencode-bridge}, model $1 (restart the pod to load it)"
}
case "${MODEL_PROVIDER:-opencode-bridge}" in
  opencode-bridge)
    kubectl -n hermes get secret hermes-opencode-bridge -o jsonpath='{.data.OPENCODE_BRIDGE_API_KEY}' | base64 -d >"$tmp/HERMES_MODEL_API_KEY"
    model_secret "${HERMES_MODEL:-opencode/deepseek-v4.1-flash-free}" "http://opencode-bridge.hermes:18282/v1" ;;
  cloudflare)
    if [[ -n "${CLOUDFLARE_AI_CREDS_FILE:-}" ]]; then
      [[ -r "$CLOUDFLARE_AI_CREDS_FILE" ]] || { echo "CLOUDFLARE_AI_CREDS_FILE not readable" >&2; exit 1; }
      acct="$(field 'Account ID' "$CLOUDFLARE_AI_CREDS_FILE")"
      field 'API' "$CLOUDFLARE_AI_CREDS_FILE" >"$tmp/HERMES_MODEL_API_KEY"
      [[ -n "$acct" ]] || { echo "CLOUDFLARE_AI_CREDS_FILE needs an 'Account ID:' line" >&2; exit 1; }
      model_secret "${HERMES_MODEL:-@cf/openai/gpt-oss-120b}" "https://api.cloudflare.com/client/v4/accounts/$acct/ai/v1"
      unset acct
    fi ;;
  opencode)
    if [[ -n "${OPENCODE_API_KEY_FILE:-}" ]]; then
      [[ -r "$OPENCODE_API_KEY_FILE" ]] || { echo "OPENCODE_API_KEY_FILE not readable" >&2; exit 1; }
      # Accept a bare key or a labelled line ("API: <key>").
      { field 'API' "$OPENCODE_API_KEY_FILE"; } >"$tmp/HERMES_MODEL_API_KEY"
      [[ -s "$tmp/HERMES_MODEL_API_KEY" ]] || tr -d '[:space:]' <"$OPENCODE_API_KEY_FILE" >"$tmp/HERMES_MODEL_API_KEY"
      model_secret "${HERMES_MODEL:-glm-5.3-flash}" "${OPENCODE_BASE_URL:-https://opencode.ai/inference/openai/v1}"
    fi ;;
  *) echo "MODEL_PROVIDER must be opencode-bridge, cloudflare or opencode" >&2; exit 1 ;;
esac
if ! kubectl -n hermes get secret hermes-model-key >/dev/null 2>&1; then
  echo "No model configured: see 'Model provider' in hermes/README.md (telemetry works without it)" >&2
fi

# 5. Grafana Viewer service account for the observability skill (read-only: dashboards, panels, /api/ds/query).
#    Created once in Grafana (namespace observability, admin login from Secret grafana-admin); the token is stored
#    only in Secret hermes-grafana-token (key GRAFANA_TOKEN) and never printed. Delete that Secret to rotate; tokens
#    expire after GRAFANA_TOKEN_TTL_DAYS (default 90) and are re-minted by the next deploy.sh run.
#    Re-minted when Grafana rejects the stored token (e.g. Grafana without a persistent database was restarted).
if kubectl -n observability get secret grafana-admin >/dev/null 2>&1; then
  gport="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  kubectl -n observability port-forward svc/grafana "$gport:80" >/dev/null 2>&1 & gpf=$!
  for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:$gport/api/health" >/dev/null 2>&1 && break; sleep 1; done
  printf 'user = "%s:%s"\n' "$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d | tr -d '\n')" \
    "$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d | tr -d '\n')" >"$tmp/gadmin"
  gapi() { curl -fsS -K "$tmp/gadmin" -H 'Content-Type: application/json' "$@"; }
  said="$(gapi "http://127.0.0.1:$gport/api/serviceaccounts/search?query=hermes-readonly" \
          | python3 -I -c 'import json, sys; a = [x for x in json.load(sys.stdin)["serviceAccounts"] if x["name"] == "hermes-readonly"]; print(a[0]["id"] if a else "")')"
  # An existing account must still be a Viewer (someone may have raised its role): reset it on every run.
  if [[ -n "$said" ]]; then
    role="$(gapi "http://127.0.0.1:$gport/api/serviceaccounts/$said" | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("role", ""))')"
    if [[ "$role" != Viewer ]]; then
      echo "Grafana service account hermes-readonly had role '$role': resetting to Viewer"
      gapi -X PATCH --data '{"role":"Viewer"}' "http://127.0.0.1:$gport/api/serviceaccounts/$said" >/dev/null
    fi
  fi
  if kubectl -n hermes get secret hermes-grafana-token >/dev/null 2>&1; then
    printf 'header = "Authorization: Bearer %s"\n' "$(kubectl -n hermes get secret hermes-grafana-token -o jsonpath='{.data.GRAFANA_TOKEN}' | base64 -d)" >"$tmp/gtok"
    if ! curl -fs -K "$tmp/gtok" -o /dev/null "http://127.0.0.1:$gport/api/search?limit=1"; then
      echo "Grafana rejects the stored token: re-creating it"
      kubectl -n hermes delete secret hermes-grafana-token >/dev/null
      regrafana=1
    fi
  fi
  if ! kubectl -n hermes get secret hermes-grafana-token >/dev/null 2>&1; then
    [[ -n "$said" ]] || said="$(gapi -X POST --data '{"name":"hermes-readonly","role":"Viewer","isDisabled":false}' \
            "http://127.0.0.1:$gport/api/serviceaccounts" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
    # Tokens expire after GRAFANA_TOKEN_TTL_DAYS (default 90); an expired token is rejected and re-minted by this step.
    ttl=$(( ${GRAFANA_TOKEN_TTL_DAYS:-90} * 86400 ))
    gapi -X POST --data "{\"name\":\"hermes-$(date +%Y%m%d%H%M%S)\",\"secondsToLive\":$ttl}" "http://127.0.0.1:$gport/api/serviceaccounts/$said/tokens" \
      | python3 -I -c 'import json, sys; d = json.load(sys.stdin); open(sys.argv[1], "w").write(str(d["id"])); sys.stdout.write(d["key"])' "$tmp/tokid" >"$tmp/GRAFANA_TOKEN"
    # Revoke every older token of the account, so only the new one (in the Secret) is valid.
    gapi "http://127.0.0.1:$gport/api/serviceaccounts/$said/tokens" \
      | python3 -I -c 'import json, sys; [print(t["id"]) for t in json.load(sys.stdin) if str(t["id"]) != sys.argv[1]]' "$(cat "$tmp/tokid")" \
      | while read -r old; do gapi -X DELETE "http://127.0.0.1:$gport/api/serviceaccounts/$said/tokens/$old" >/dev/null; done
    [[ -s "$tmp/GRAFANA_TOKEN" ]] || { echo "Grafana token creation failed" >&2; exit 1; }
    kubectl -n hermes create secret generic hermes-grafana-token --from-file=GRAFANA_TOKEN="$tmp/GRAFANA_TOKEN"
  fi
  kill "$gpf" 2>/dev/null
else
  echo "Secret observability/grafana-admin not found: skipping the Grafana token (skill works without Grafana links)" >&2
fi

kubectl apply -k "$dir"
[[ -n "${regrafana:-}" ]] && kubectl -n hermes rollout restart deploy/hermes-gateway deploy/opencode-bridge >/dev/null   # reload GRAFANA_TOKEN
[[ -n "${bridge_changed:-}" ]] && kubectl -n hermes rollout restart deploy/opencode-bridge >/dev/null      # new bridge script
kubectl -n hermes rollout status deploy/opencode-bridge --timeout=300s
kubectl -n hermes rollout status deploy/hermes-gateway --timeout=300s
echo "Dashboard: https://hermes-gke.$DOMAIN  (user and password: see hermes/README.md, 'Log in')"
