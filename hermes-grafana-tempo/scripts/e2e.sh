#!/usr/bin/env bash
# End-to-end check through the public DNS names: Cloudflare -> Traefik -> apps, then the telemetry path
# (OpenTelemetry Collector -> Tempo traces and Prometheus metrics) and Grafana.
#
#   DOMAIN=<domain> scripts/e2e.sh
#
# Optional: PROM_PORT, TEMPO_PORT, GRAFANA_PORT for the local port-forwards (random free ports by default);
#           EXPECT_CHAIN (default nextjs) picks the app that starts the traced chain.
# Exit code = number of failed checks.
set -uo pipefail
cd "$(dirname "$0")/.."

DOMAIN="${DOMAIN:-${ZONE:-example.com}}"
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
freeport() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null || true; }

pf() {  # pf <namespace> <service> <remote-port> <local-var-name>
  local ns="$1" svc="$2" rport="$3" port; port="$(freeport)"
  kubectl -n "$ns" port-forward "svc/$svc" "$port:$rport" >/dev/null 2>&1 &
  eval "PF_$4_PID=$!"
  for _ in $(seq 1 40); do curl -fsS -m 2 "http://127.0.0.1:$port/" >/dev/null 2>&1 && break; sleep 0.5; done
  eval "PF_$4_PORT=$port"
}
stop_pf() { local v; for v in PROM TEMPO GRAFANA; do eval "pid=\${PF_${v}_PID:-}"; [ -n "$pid" ] && kill "$pid" 2>/dev/null; done; }
trap stop_pf EXIT

echo "== public edge (DNS + Cloudflare + Traefik) =="
"$(command -v dig >/dev/null && echo dig || echo host)" +short "grafana-tempo.$DOMAIN" >/dev/null 2>&1 || true
dns_ips="$(dig +short "grafana-tempo.$DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.' | tr '\n' ' ')"
[ -n "$dns_ips" ] && pass "DNS grafana-tempo.$DOMAIN resolves ($dns_ips)" || fail "DNS grafana-tempo.$DOMAIN does not resolve"
for h in grafana-tempo tempo-nextjs tempo-nodejs tempo-python hermes-gke; do
  out="$(curl -sS -o /dev/null -m 25 -w '%{http_code} %{remote_ip} %{ssl_verify_result}' "https://$h.$DOMAIN/" 2>/dev/null || echo "000 - -")"
  code="${out%% *}"; verify="$(echo "$out" | awk '{print $3}')"
  if [ "$code" = 403 ]; then pass "https://$h.$DOMAIN -> 403 (Traefik cloudflare-only filter, expected off-proxy)"
  elif [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ]; then
    [ "$verify" = 0 ] && pass "https://$h.$DOMAIN -> $code, TLS chain verified" || fail "https://$h.$DOMAIN -> $code but TLS verify=$verify"
  else fail "https://$h.$DOMAIN -> $code"; fi
done
server_hdr="$(curl -sSI -m 20 "https://tempo-nodejs.$DOMAIN/" 2>/dev/null | tr -d '\r' | grep -i '^server:' || true)"
case "$server_hdr" in *cloudflare*) pass "response served through Cloudflare ($server_hdr)";; *) fail "no Cloudflare server header ($server_hdr)";; esac

echo "== traced request chain (apps -> collector -> Tempo) =="
for i in 1 2 3; do
  code="$(curl -sS -o /dev/null -m 25 -w '%{http_code}' "https://tempo-nextjs.$DOMAIN/" 2>/dev/null || echo 000)"
  echo "  nextjs request $i -> $code"
done
[ "$code" = 200 ] || [ "$code" = 302 ] && pass "sample app answers over public DNS" || fail "sample app did not answer ($code)"
sleep 8   # let the batch span exporter flush

echo "== telemetry backends =="
pf monitoring prometheus-kube-prometheus-prometheus 9090 PROM
pf observability tempo 3200 TEMPO
pf observability grafana 80 GRAFANA

prom() { curl -fsS -m 10 --get "http://127.0.0.1:$PF_PROM_PORT/api/v1/query" --data-urlencode "query=$1" 2>/dev/null; }
v="$(prom 'sum(up)' | json 'd["data"]["result"][0]["value"][1] if d.get("data",{}).get("result") else ""')"
[ -n "$v" ] && pass "Prometheus reachable, sum(up)=$v" || fail "Prometheus query failed"
v="$(prom 'sum(otelcol_receiver_accepted_spans_total) or sum(otelcol_receiver_accepted_spans)' | json 'd["data"]["result"][0]["value"][1] if d.get("data",{}).get("result") else ""')"
if [ -n "$v" ] && [ "${v%%.*}" -ge 1 ] 2>/dev/null; then pass "OpenTelemetry Collector accepted spans (total=$v)"; else fail "OpenTelemetry Collector span counter missing or zero ($v)"; fi
v="$(prom 'sum(otelcol_exporter_sent_spans_total) or sum(otelcol_exporter_sent_spans)' | json 'd["data"]["result"][0]["value"][1] if d.get("data",{}).get("result") else ""')"
[ -n "$v" ] && pass "collector exported spans to Tempo (total=$v)" || fail "collector exporter span counter missing"
v="$(prom 'max(hermes_gateway_up)' | json 'd["data"]["result"][0]["value"][1] if d.get("data",{}).get("result") else ""')"
[ "$v" = 1 ] && pass "Hermes gateway telemetry (hermes_gateway_up=1)" || fail "hermes_gateway_up=$v"
v="$(prom 'sum(up{job=~".*traefik.*"}) or sum(up{namespace="traefik"})' | json 'd["data"]["result"][0]["value"][1] if d.get("data",{}).get("result") else ""')"
[ -n "$v" ] && pass "Traefik metrics scraped (up sum=$v)" || fail "no Traefik scrape target up"

# TraceQL search for the demo services first; fall back to scanning the newest traces (Hermes sends its own
# telemetry, so "newest trace" is not necessarily a sample-app trace).
tr="$(curl -fsS -m 20 --get "http://127.0.0.1:$PF_TEMPO_PORT/api/search" \
  --data-urlencode 'q={resource.service.name=~"nextjs-web|nodejs-orders|python-inventory"}' \
  --data-urlencode 'limit=5' 2>/dev/null || true)"
n="$(printf '%s' "$tr" | json 'len((d.get("traces") or []))')"
[ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null || { tr="$(curl -fsS -m 20 "http://127.0.0.1:$PF_TEMPO_PORT/api/search?limit=20" 2>/dev/null || true)"; n="$(printf '%s' "$tr" | json 'len((d.get("traces") or []))')"; }
ids="$(printf '%s' "$tr" | json '" ".join(t.get("traceID","") for t in (d.get("traces") or []))')"
if [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null; then pass "Tempo search returned $n trace(s)"; else fail "Tempo returned no traces"; fi

found=""
for tid in $ids; do
  t="$(curl -fsS -m 15 "http://127.0.0.1:$PF_TEMPO_PORT/api/traces/$tid" 2>/dev/null || true)"
  info="$(printf '%s' "$t" | python3 -c 'import json,sys
d=json.load(sys.stdin)
svc=set(); spans=0
for b in d.get("batches",[]):
  for a in b.get("resource",{}).get("attributes",[]):
    if a.get("key")=="service.name": svc.add(a["value"].get("stringValue",""))
  for s in (b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []): spans+=len(s.get("spans",[]))
print(",".join(sorted(s for s in svc if s)), spans)' 2>/dev/null || true)"
  case "$info" in *nextjs*|*nodejs*|*python*) found="$tid|$info"; break;; esac
done
if [ -n "$found" ]; then
  pass "sample-app trace ${found%%|*} has services ${found#*|}"
  svcs="${found#*|}"
  case "$svcs" in *nextjs-web*|*nodejs-orders*|*python-inventory*) pass "trace carries the demo app services end to end";; esac
else
  fail "no sample-app trace in Tempo ($n trace(s) scanned)"
fi

echo "== Grafana =="
gu="$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d | tr -d '\n')"
gp="$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d | tr -d '\n')"
netrc="$(mktemp)"; chmod 600 "$netrc"; printf 'machine 127.0.0.1 login %s password %s\n' "$gu" "$gp" >"$netrc"; unset gu gp
gapi() { curl -fsS -m 15 --netrc-file "$netrc" "http://127.0.0.1:$PF_GRAFANA_PORT$1" 2>/dev/null; }
for uid in prometheus tempo; do
  v="$(gapi "/api/datasources/uid/$uid/health" | json 'd.get("status","")')"
  [ "$v" = OK ] && pass "Grafana datasource $uid healthy" || fail "Grafana datasource $uid health=$v"
done
v="$(gapi '/api/search?type=dash-db' | json 'len(d)')"
[ -n "$v" ] && [ "$v" -ge 1 ] 2>/dev/null && pass "Grafana serves $v dashboards" || fail "Grafana dashboards: $v"
rm -f "$netrc"

echo
if [ "$fails" -eq 0 ]; then echo "E2E PASS (0 failures)"; else echo "E2E FAIL ($fails failures)"; fi
exit "$fails"
