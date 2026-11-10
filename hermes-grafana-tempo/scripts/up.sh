#!/usr/bin/env bash
# One command to deploy the whole hermes-grafana-tempo lab and verify it.
#
#   PROJECT_ID=<project> DOMAIN=<your-domain> CF_TOKEN_FILE=<cloudflare-token-file> scripts/up.sh
#
# What it does, in order (each step is idempotent, re-run to converge):
#   1. GKE cluster (infra/create-cluster.sh, lab or prod profile)
#   2. platform: Prometheus, Traefik, Tempo, Collector, Grafana, dashboards, routes, namespaces
#   3. sample app images -> Artifact Registry, deployed by digest
#   4. Hermes gateway, dashboard and OpenCode bridge
#   5. Cloudflare DNS (proxied A records -> the Traefik load balancer)
#   6. sample traffic, then scripts/verify.sh and hermes/verify.sh; exit code = number of failed checks
#
# Env:
#   PROJECT_ID      GCP project (default: the active gcloud project)
#   DOMAIN          public domain for the five hostnames (default example.com; DNS is skipped for example.com)
#   CF_TOKEN_FILE   Cloudflare API token file, Zone:DNS:Edit + Zone:Zone:Read, chmod 600 (needed for DNS)
#   PROFILE         lab (default) or prod
#   GCP_ZONE        zone for the lab cluster (default us-central1-a)
#   REGION          region for a prod cluster (required with PROFILE=prod)
#   AR_REGION       Artifact Registry region (default us-central1)
#   TLS_MODE        cloudflare (default) or letsencrypt
#   ACCESS_MODE     GCS Workload Identity grant style: bucket (default), conditional, gsa
#   SKIP_CLUSTER=1  reuse the current kubectl context (no cluster create)
#   SKIP_PLATFORM=1 skip the platform deploy (e.g. only rebuild apps/Hermes)
#   SKIP_APPS=1     skip the sample app build/deploy
#   SKIP_HERMES=1   skip Hermes
#   SKIP_LOAD=1     skip the demo traffic
#   SKIP_VERIFY=1   skip the verify scripts
#   SKIP_E2E=1      skip the public end-to-end check (needs DOMAIN with DNS)
#   HERMES_ENV_FILE operator credential file to (re)write after Hermes, e.g. ~/creds/hermes-gke-dashboard.env
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${PROFILE:-lab}"
GCP_ZONE="${GCP_ZONE:-us-central1-a}"
REGION="${REGION:-}"
AR_REGION="${AR_REGION:-us-central1}"
DOMAIN="${DOMAIN:-example.com}"
TLS_MODE="${TLS_MODE:-cloudflare}"
ACCESS_MODE="${ACCESS_MODE:-bucket}"
CF_TOKEN_FILE="${CF_TOKEN_FILE:-}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
CLUSTER_NAME="${CLUSTER_NAME:-tempo-demo}"
AR_REPO="${AR_REPO:-tempo-apps}"

say() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

command -v gcloud >/dev/null || die "gcloud not found"
command -v kubectl >/dev/null || die "kubectl not found"
command -v helm >/dev/null || die "helm not found"
[ -n "$PROJECT_ID" ] || die "PROJECT_ID is not set and gcloud has no default project"
case "$PROFILE" in lab|prod) ;; *) die "PROFILE must be lab or prod (got: $PROFILE)" ;; esac
if [ "$PROFILE" = prod ] && [ -z "$REGION" ]; then die "PROFILE=prod needs REGION (e.g. REGION=us-central1)"; fi

# DNS is part of a real deployment; example.com is the reusable placeholder and is never touchable.
want_dns=1
if [ "$DOMAIN" = example.com ]; then want_dns=0; fi
if [ "$want_dns" = 1 ]; then
  [ -n "$CF_TOKEN_FILE" ] || die "DOMAIN=$DOMAIN needs CF_TOKEN_FILE (Cloudflare token file, chmod 600)"
  [ -r "$CF_TOKEN_FILE" ] || die "CF_TOKEN_FILE not readable: $CF_TOKEN_FILE"
  mode=$(stat -c %a "$CF_TOKEN_FILE" 2>/dev/null || stat -f %Lp "$CF_TOKEN_FILE" 2>/dev/null || echo unknown)
  case "$mode" in 600|400) ;; *) die "CF_TOKEN_FILE must be chmod 600 (it is $mode)" ;; esac
fi

gcloud config set project "$PROJECT_ID" >/dev/null
echo "project: $PROJECT_ID  profile: $PROFILE  domain: $DOMAIN  tls: $TLS_MODE"

# ---------------------------------------------------------------- 1. cluster
context=""
if [ "${SKIP_CLUSTER:-0}" != 1 ]; then
  say "1 GKE cluster $CLUSTER_NAME ($PROFILE)"
  if [ "$PROFILE" = prod ]; then
    PROFILE="$PROFILE" PROJECT_ID="$PROJECT_ID" REGION="$REGION" CLUSTER_NAME="$CLUSTER_NAME" infra/create-cluster.sh
  else
    PROFILE="$PROFILE" PROJECT_ID="$PROJECT_ID" ZONE="$GCP_ZONE" CLUSTER_NAME="$CLUSTER_NAME" infra/create-cluster.sh
  fi
fi
context="$(kubectl config current-context)"
[ -n "$context" ] || die "no kubectl context; have you run infra/create-cluster.sh?"
kubectl get nodes >/dev/null || die "cluster not reachable with context $context"

# --------------------------------------------------------------- 2. platform
if [ "${SKIP_PLATFORM:-0}" != 1 ]; then
  say "2 platform (Prometheus, Traefik, Tempo, Collector, Grafana, dashboards, routes, DNS)"
  PROFILE="$PROFILE" TLS_MODE="$TLS_MODE" ACCESS_MODE="$ACCESS_MODE" PROJECT_ID="$PROJECT_ID" \
  DOMAIN="$DOMAIN" CF_TOKEN_FILE="$CF_TOKEN_FILE" scripts/deploy.sh || die "platform deploy failed"
fi

# ------------------------------------------------------------- 3. sample apps
if [ "${SKIP_APPS:-0}" != 1 ]; then
  say "3 sample apps (Artifact Registry + digest-pinned deploy)"
  gcloud artifacts repositories describe "$AR_REPO" --location="$AR_REGION" --project="$PROJECT_ID" >/dev/null 2>&1 \
    || gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$AR_REGION" \
         --immutable-tags --project="$PROJECT_ID" || die "cannot create Artifact Registry repo $AR_REPO"
  PROJECT_ID="$PROJECT_ID" REGION="$AR_REGION" AR_REPO="$AR_REPO" apps/build-push.sh || die "sample app build/push failed"
  app_profile=production; [ "$PROFILE" = lab ] && app_profile=lab
  PROJECT_ID="$PROJECT_ID" REGION="$AR_REGION" AR_REPO="$AR_REPO" apps/deploy-apps.sh "$app_profile" \
    || die "sample app deploy failed"
fi

# ----------------------------------------------------------------- 4. Hermes
if [ "${SKIP_HERMES:-0}" != 1 ]; then
  say "4 Hermes gateway, dashboard, OpenCode bridge"
  DOMAIN="$DOMAIN" PROJECT_ID="$PROJECT_ID" hermes/deploy.sh || die "Hermes deploy failed"
  # Keep the operator's credential file current (mode 600, values never printed).
  if [ -n "${HERMES_ENV_FILE:-}" ]; then
    DOMAIN="$DOMAIN" hermes/dashboard-env.sh "$HERMES_ENV_FILE"
  fi
fi

# ------------------------------------------------------------------- 5. TLS
# TLS_MODE=cloudflare terminates at the Cloudflare proxy and Traefik serves its default (self-signed)
# certificate, so the zone must be "Full"; letsencrypt issues real origin certificates and wants
# "Full (strict)". Best effort: needs Zone Settings:Edit on the token, a warning is printed otherwise.
if [ "$want_dns" = 1 ]; then
  say "5 Cloudflare zone SSL mode"
  token=$(grep -o -m1 'cfat_[A-Za-z0-9_-]*' "$CF_TOKEN_FILE" 2>/dev/null || head -1 "$CF_TOKEN_FILE")
  zid=$(curl -fsS -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" 2>/dev/null \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("result") or [{}])[0].get("id",""))' 2>/dev/null || true)
  want=full; [ "$TLS_MODE" = letsencrypt ] && want=strict
  cur=$(curl -fsS -H "Authorization: Bearer $token" \
    "https://api.cloudflare.com/client/v4/zones/$zid/settings/ssl" 2>/dev/null \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("result") or {}).get("value",""))' 2>/dev/null || true)
  if [ "$cur" = "$want" ]; then
    echo "zone $DOMAIN SSL mode already '$want'"
  elif [ -n "$zid" ] && curl -fsS -X PATCH -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
       --data "{\"value\":\"$want\"}" "https://api.cloudflare.com/client/v4/zones/$zid/settings/ssl" >/dev/null 2>&1; then
    echo "zone $DOMAIN SSL mode set to '$want' (was '${cur:-unknown}')"
  else
    echo "warning: zone $DOMAIN SSL mode is '${cur:-unknown}', expected '$want'; set it in the Cloudflare dashboard" >&2
  fi
  unset token
fi

# ------------------------------------------------------------------ 6. traffic
if [ "${SKIP_LOAD:-0}" != 1 ]; then
  say "demo traffic"
  DOMAIN="$DOMAIN" scripts/load.sh public || echo "warning: load.sh reported a failure (non-fatal)"
fi

# ------------------------------------------------------------------- 7. verify
fails=0
if [ "${SKIP_VERIFY:-0}" != 1 ]; then
  say "verify"
  PROFILE="$PROFILE" DOMAIN="$DOMAIN" scripts/verify.sh || fails=$((fails + $?))
  DOMAIN="$DOMAIN" hermes/verify.sh || fails=$((fails + $?))
fi

if [ "$want_dns" = 1 ] && [ "${SKIP_E2E:-0}" != 1 ]; then
  say "end-to-end (DNS -> Cloudflare -> Traefik -> apps -> OTel -> Tempo/Prometheus -> Grafana)"
  DOMAIN="$DOMAIN" scripts/e2e.sh || fails=$((fails + $?))
fi

if [ "$want_dns" = 1 ]; then
  say "public endpoints"
  for h in grafana-tempo tempo-nextjs tempo-nodejs tempo-python hermes-gke; do
    code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "https://$h.$DOMAIN/" || echo 000)
    echo "https://$h.$DOMAIN -> $code"
  done
fi

if [ "$fails" -ne 0 ]; then
  printf '\nFAILED: %s failed checks (see the output above)\n' "$fails" >&2
  exit 1
fi
say "done - deployment complete and verified"
