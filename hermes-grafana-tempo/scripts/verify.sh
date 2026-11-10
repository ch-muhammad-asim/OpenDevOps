#!/usr/bin/env bash
# Verify the platform end to end. Prints PASS/FAIL per check; exit code = number of failures.
#   scripts/verify.sh                 # PROFILE=prod (default) or PROFILE=lab, same as deploy.sh
#   scripts/verify.sh --read-only     # no probe pods: skips the test span and the NetworkPolicy check
# Checks: nodes, Helm releases, pods Ready, certificates (letsencrypt mode), Tempo/Grafana/Prometheus
# health, Grafana datasources (Prometheus, Tempo, Alertmanager), project PrometheusRules loaded,
# an OTLP test span through the Collector into Tempo, Prometheus scraping the Collector,
# NetworkPolicy enforcement, and the public HTTPS endpoint through Cloudflare.
# Side effects (default mode only): two short-lived curl pods, `otlp-probe` in tempo-apps and
# `netpol-probe` in default, deleted on exit; one test span with service.name=verify-probe.
set -uo pipefail

PROFILE="${PROFILE:-prod}"
READ_ONLY=0; [ "${1:-}" = --read-only ] && READ_ONLY=1
TLS_MODE="${TLS_MODE:-cloudflare}"   # same default as deploy.sh; letsencrypt adds the cert-manager checks
CM_RELEASE=""; CM_NS=""
[ "$TLS_MODE" = letsencrypt ] && { CM_RELEASE="cert-manager:cert-manager"; CM_NS="cert-manager"; }
# Tempo query API: single binary "tempo" (lab) or the query-frontend (prod, tempo-distributed).
if [ "$PROFILE" = lab ]; then TEMPO_QUERY_SVC="${TEMPO_QUERY_SVC:-tempo}"; else TEMPO_QUERY_SVC="${TEMPO_QUERY_SVC:-tempo-query-frontend}"; fi
DOMAIN="${DOMAIN:-${ZONE:-example.com}}"
GRAFANA_HOST="${GRAFANA_HOST:-grafana-tempo.$DOMAIN}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93}"
# Probe pods must pass Pod Security "restricted" (observability, tempo-apps, hermes enforce it).
# Usage: probe_overrides <pod-name> <curl args...>  -> full pod spec override (image, args, securityContext).
probe_overrides() { python3 -I -c 'import json,sys
n,img,*a=sys.argv[1:]
print(json.dumps({"spec":{"securityContext":{"runAsNonRoot":True,"runAsUser":100,"runAsGroup":101,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":n,"image":img,"args":a,"securityContext":{"allowPrivilegeEscalation":False,"readOnlyRootFilesystem":True,"capabilities":{"drop":["ALL"]}}}]}}))' "$1" "$CURL_IMAGE" "${@:2}"; }
fails=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

pf_pids=()
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { for p in "${pf_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  kubectl -n default delete pod netpol-probe --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n tempo-apps delete pod otlp-probe --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT
# Port-forward svc $2 (ns $1, port $3) to a free local port; sets PORT. Waits until it answers.
pf() {
  PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
  kubectl -n "$1" port-forward "svc/$2" "$PORT:$3" >/dev/null 2>&1 & pf_pids+=($!)
  for _ in $(seq 1 20); do curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/" && return 0; sleep 1; done
}

echo "context: $(kubectl config current-context)  profile: $PROFILE  tls: $TLS_MODE"

# 1. Nodes
ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)"
if [ "$ready" -ge 3 ]; then pass "nodes Ready: $ready"; else fail "nodes Ready: $ready (want 3)"; fi

# 2. Helm releases deployed
for r in $CM_RELEASE traefik:traefik prometheus:monitoring tempo:observability \
         otel-collector:observability grafana:observability; do
  st="$(helm status "${r%%:*}" -n "${r##*:}" -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null)"
  if [ "$st" = deployed ]; then pass "helm ${r%%:*} deployed"; else fail "helm ${r%%:*} status=${st:-missing}"; fi
done

# 3. Pods Ready (Completed job pods ignored)
OS_NS=""; kubectl get ns object-storage >/dev/null 2>&1 && OS_NS="object-storage"   # optional SeaweedFS fallback (OBJECT_STORE=seaweedfs)
for ns in $CM_NS $OS_NS traefik monitoring observability tempo-apps; do
  bad="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3!="Completed"{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print $1}')"
  if [ -z "$bad" ]; then pass "pods Ready in $ns"; else fail "pods not Ready in $ns: ${bad//$'\n'/ }"; fi
done

# 4. Certificates (TLS_MODE=letsencrypt only)
if [ "$TLS_MODE" = letsencrypt ]; then
for c in observability/grafana-tempo-tls tempo-apps/tempo-nextjs-tls tempo-apps/tempo-python-tls tempo-apps/tempo-nodejs-tls; do
  st="$(kubectl -n "${c%%/*}" get certificate "${c##*/}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  if [ "$st" = True ]; then pass "certificate $c Ready"; else fail "certificate $c Ready=${st:-missing}"; fi
done
fi

# 5. Component health (port-forward, in-cluster APIs)
pf observability "$TEMPO_QUERY_SVC" 3200; TEMPO_PORT=$PORT
check "tempo /ready" curl -fsS -m 10 "http://127.0.0.1:$TEMPO_PORT/ready"
pf observability grafana 80; GRAFANA_PORT=$PORT
check "grafana /api/health" curl -fsS -m 10 "http://127.0.0.1:$GRAFANA_PORT/api/health"
pf monitoring prometheus-kube-prometheus-prometheus 9090; PROM_PORT=$PORT
check "prometheus /-/ready" curl -fsS -m 10 "http://127.0.0.1:$PROM_PORT/-/ready"

# Thanos (30-day metrics): querier ready and connected to the sidecar and the store-gateway.
if kubectl -n monitoring get svc thanos-query >/dev/null 2>&1; then
  pf monitoring thanos-query 10902; THANOS_PORT=$PORT
  check "thanos-query /-/ready" curl -fsS -m 10 "http://127.0.0.1:$THANOS_PORT/-/ready"
  check "thanos-query sees sidecar + store-gateway" sh -c \
    "curl -fsS -m 10 'http://127.0.0.1:$THANOS_PORT/api/v1/stores' | python3 -c 'import json,sys;d=json.load(sys.stdin)[\"data\"];sys.exit(0 if d.get(\"sidecar\") and d.get(\"store\") else 1)'"
fi

# Grafana datasources (admin creds read into variables from the Secret, never printed)
gu="$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d | tr -d '\n')"
gp="$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d | tr -d '\n')"
netrc="$(mktemp)"; chmod 600 "$netrc"; printf 'machine 127.0.0.1 login %s password %s\n' "$gu" "$gp" > "$netrc"; unset gu gp
for uid in prometheus tempo; do
  check "grafana datasource $uid healthy" sh -c "curl -fsS -m 20 --netrc-file '$netrc' http://127.0.0.1:$GRAFANA_PORT/api/datasources/uid/$uid/health | grep -q '\"OK\"'"
done
# The Alertmanager datasource has no backend health endpoint in Grafana 13 (/health returns
# plugin.unavailable by design); check it through the datasource proxy instead.
check "grafana datasource alertmanager reachable (proxy /api/v2/status)" sh -c \
  "curl -fsS -m 20 --netrc-file '$netrc' http://127.0.0.1:$GRAFANA_PORT/api/datasources/proxy/uid/alertmanager/api/v2/status | grep -q '\"cluster\"'"

# 6. Test span: tempo-apps pod -> Collector (OTLP/HTTP) -> Tempo, then find it by trace ID
if [ "$READ_ONLY" = 1 ]; then echo "SKIP  test span (--read-only)"; else
tid="$(openssl rand -hex 16)"; sid="$(openssl rand -hex 8)"; now="$(date +%s)000000000"
span="{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"verify-probe\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$tid\",\"spanId\":\"$sid\",\"name\":\"verify\",\"kind\":1,\"startTimeUnixNano\":\"$now\",\"endTimeUnixNano\":\"$now\"}]}]}]}"
if kubectl -n tempo-apps run otlp-probe --rm -i --restart=Never --image="$CURL_IMAGE" --quiet \
     --overrides="$(probe_overrides otlp-probe -fsS -m 10 -H 'Content-Type: application/json' -d "$span" \
       http://otel-collector.observability:4318/v1/traces)" >/dev/null 2>&1; then
  pass "OTLP span accepted by collector (from tempo-apps)"
else
  fail "OTLP span accepted by collector (from tempo-apps)"
fi
found=""
for _ in $(seq 1 12); do
  curl -fsS -m 10 "http://127.0.0.1:$TEMPO_PORT/api/v2/traces/$tid" 2>/dev/null | grep -q verify-probe && { found=1; break; }
  sleep 5
done
if [ -n "$found" ]; then pass "test trace found in Tempo"; else fail "test trace not found in Tempo"; fi
[ -n "$found" ] && check "test trace visible through Grafana" sh -c \
  "curl -fsS -m 20 --netrc-file '$netrc' http://127.0.0.1:$GRAFANA_PORT/api/datasources/proxy/uid/tempo/api/v2/traces/$tid | grep -q verify-probe"
fi
rm -f "$netrc"

# 7. Prometheus scrapes the Collector and receives Tempo span metrics
check "prometheus scrapes otel-collector" sh -c \
  "curl -fsS -m 10 'http://127.0.0.1:$PROM_PORT/api/v1/query?query=up%7Bservice%3D%22otel-collector%22%7D' | grep -q '\"1\"\\]'"
check "tempo metrics-generator remote write active" sh -c \
  "curl -fsS -m 10 'http://127.0.0.1:$PROM_PORT/api/v1/query?query=count(traces_spanmetrics_calls_total)' | grep -q '\"result\":\\[{'"

# 7b. Project PrometheusRules loaded (Prometheus rule groups by rule-file name)
for r in monitoring/otel-collector monitoring/traefik monitoring/grafana monitoring/cert-manager observability/tempo-mixin; do
  check "PrometheusRule $r loaded" sh -c \
    "curl -fsS -m 10 'http://127.0.0.1:$PROM_PORT/api/v1/rules' | grep -q '${r%%/*}-${r##*/}-'"
done

# 8. NetworkPolicy enforced: a pod in 'default' must NOT reach Tempo
if [ "$READ_ONLY" = 1 ]; then echo "SKIP  NetworkPolicy probe (--read-only)"; else
# Blocked = curl timeout (exit 28: packets dropped by the policy). Any other failure is not proof.
kubectl -n default run netpol-probe --rm -i --restart=Never --image="$CURL_IMAGE" --quiet \
  --overrides="$(probe_overrides netpol-probe -sS -o /dev/null -m 5 "http://$TEMPO_QUERY_SVC.observability:3200/ready")" \
  >/dev/null 2>&1
rc=$?
if [ "$rc" = 28 ]; then pass "networkpolicy: default -> $TEMPO_QUERY_SVC:3200 blocked (timeout)"
else fail "networkpolicy: default -> $TEMPO_QUERY_SVC:3200 not proven blocked (exit $rc, want 28)"; fi
fi

# 9. Public endpoint through Cloudflare
code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 "https://$GRAFANA_HOST/api/health" 2>/dev/null)"
if [ "$code" = 200 ]; then pass "https://$GRAFANA_HOST/api/health 200"; else fail "https://$GRAFANA_HOST/api/health code=$code"; fi
code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 "https://$GRAFANA_HOST/" 2>/dev/null)"
if [ "$code" = 302 ]; then pass "grafana root redirects to login (302)"; else fail "grafana root code=$code (want 302 login redirect)"; fi

echo; echo "failures: $fails"
exit "$fails"
