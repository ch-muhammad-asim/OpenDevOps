#!/usr/bin/env bash
# Verify Hermes end to end: pod Ready -> Prometheus metrics + rules -> Tempo spans -> Grafana dashboard
# and data sources -> public URL (Cloudflare-only route, no proxy login) and the Hermes login -> model settings
# -> OpenCode bridge (Ready, /v1/models; no chat call)
# -> read-only observability skill (loaded, reads via Thanos/Tempo/Grafana, Prometheus :9090 blocked, Grafana write refused).
# Prints PASS/FAIL per check; exit code = number of failures. Prometheus, Tempo and Grafana are reached
# with kubectl port-forward on free local ports (the API server's service proxy is blocked by the
# default-deny ingress NetworkPolicies). Credentials are read from Secrets into variables and passed to
# curl via files, never on the command line or to the terminal. Override the public host with HERMES_URL.
# VERIFY_CHAT=1 sends ONE chat request through the gateway (a real model call).
# VERIFY_BRIDGE_CHAT_MODEL=<id> sends ONE direct real inference request to that bridge model. Both are
# opt-in because free-provider quotas and bridge capacity are shared; catalog checks do not prove inference.
set -uo pipefail
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
enc() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
json() { python3 -I -c "import json, sys; d = json.load(sys.stdin); print($1)"; }

URL="${HERMES_URL:-https://hermes-gke.example.com}"
tmp="$(mktemp -d)"
cleanup() { [[ -f "$tmp/pids" ]] && xargs kill <"$tmp/pids" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
# forward NS SVC PORT -> prints the local base URL; picks a port nothing else listens on.
forward() {
  local p
  p="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  kubectl -n "$1" port-forward "svc/$2" "$p:$3" >/dev/null 2>&1 &
  echo "$!" >>"$tmp/pids"
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$p/" && break; sleep 0.5; done
  echo "http://127.0.0.1:$p"
}
PROM="$(forward monitoring prometheus-kube-prometheus-prometheus 9090)"
TEMPO="$(forward observability tempo 3200)"
GRAFANA="$(forward observability grafana 80)"
get() { curl -fsS --max-time 20 "$1"; }
TRACEQL='{ name = "hermes.gateway_health" && span.hermes.name = "gateway.lifecycle" }'

# 1. Pod Ready, non-root
if kubectl -n hermes rollout status deploy/hermes-gateway --timeout=120s >/dev/null 2>&1; then
  pass "hermes-gateway rolled out ($(kubectl -n hermes get pods -l app.kubernetes.io/name=hermes-gateway \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready} restarts={.items[0].status.containerStatuses[0].restartCount}'))"
else
  fail "hermes-gateway not rolled out"
fi

# 2. Prometheus: gateway and platform up (max, so a replaced pod's still-fresh series don't count)
for q in 'max(hermes_gateway_up)' 'min(max by (hermes_platform) (hermes_platform_up))'; do
  v="$(get "$PROM/api/v1/query?query=$(enc "$q")" 2>/dev/null \
       | json 'd["data"]["result"][0]["value"][1] if d["data"]["result"] else "none"' 2>/dev/null || echo error)"
  if [[ "$v" == 1 ]]; then pass "Prometheus $q = 1"; else fail "Prometheus $q = $v"; fi
done
n="$(get "$PROM/api/v1/query?query=$(enc 'count({__name__=~"hermes_.*"}) by (__name__)')" 2>/dev/null \
     | json 'len(d["data"]["result"])' 2>/dev/null || echo 0)"
if [[ "$n" -ge 18 ]]; then pass "Prometheus has $n hermes_* metric names (expected 18)"; else fail "Prometheus has $n hermes_* metric names (expected 18)"; fi

# 3. Prometheus: alert rules loaded, none firing
rules="$(get "$PROM/api/v1/rules" 2>/dev/null \
  | json '",".join(sorted(r["name"] for g in d["data"]["groups"] if g["name"] == "hermes-gateway" for r in g["rules"]))' 2>/dev/null)"
if [[ "$rules" == *HermesGatewayDown* ]]; then pass "rules loaded: $rules"; else fail "hermes-gateway rules not loaded"; fi
firing="$(get "$PROM/api/v1/alerts" 2>/dev/null \
  | json '",".join(a["labels"]["alertname"] for a in d["data"]["alerts"] if a["labels"]["alertname"].startswith("Hermes") and a["state"] == "firing")' 2>/dev/null)"
if [[ -z "$firing" ]]; then pass "no Hermes alerts firing"; else fail "Hermes alerts firing: $firing"; fi

# 4. Tempo: TraceQL finds the gateway lifecycle span (last 6 hours)
now="$(date +%s)"
tn="$(get "$TEMPO/api/search?q=$(enc "$TRACEQL")&start=$((now - 21600))&end=$now&limit=20" 2>/dev/null \
      | json 'len(d.get("traces", []))' 2>/dev/null || echo 0)"
if [[ "$tn" -ge 1 ]]; then pass "Tempo TraceQL $TRACEQL -> $tn trace(s)"; else fail "Tempo TraceQL $TRACEQL -> $tn traces"; fi

# 5. Grafana: dashboard provisioned, and both data sources answer through Grafana
gu="$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d)"
gp="$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
gcurl() { printf 'user = "%s:%s"\n' "$gu" "$gp" | curl -fsS -K - -H 'Content-Type: application/json' "$@"; }
title="$(gcurl "$GRAFANA/api/dashboards/uid/hermes-gateway" 2>/dev/null | json 'd["dashboard"]["title"] + " / panels=" + str(len(d["dashboard"]["panels"]))' 2>/dev/null)"
if [[ -n "$title" ]]; then pass "Grafana dashboard: $title"; else fail "Grafana dashboard hermes-gateway not found"; fi
body='{"from":"now-15m","to":"now","queries":[{"refId":"A","datasource":{"uid":"prometheus"},"expr":"max(hermes_gateway_up)","instant":true}]}'
gv="$(gcurl -X POST --data "$body" "$GRAFANA/api/ds/query" 2>/dev/null \
      | json 'd["results"]["A"]["frames"][0]["data"]["values"][1][-1]' 2>/dev/null)"
if [[ "$gv" == 1 || "$gv" == 1.0 ]]; then pass "Grafana -> Prometheus max(hermes_gateway_up) = 1"; else fail "Grafana -> Prometheus returned '$gv'"; fi
tq="$(python3 -I -c 'import json, sys; print(json.dumps({"from": "now-6h", "to": "now", "queries": [{"refId": "A", "datasource": {"uid": "tempo"}, "queryType": "traceql", "query": sys.argv[1], "limit": 20, "tableType": "traces"}]}))' "$TRACEQL")"
gt="$(gcurl -X POST --data "$tq" "$GRAFANA/api/ds/query" 2>/dev/null \
      | json 'len(d["results"]["A"]["frames"][0]["data"]["values"][0]) if d["results"]["A"].get("frames") else 0' 2>/dev/null || echo 0)"
if [[ "$gt" -ge 1 ]]; then pass "Grafana -> Tempo TraceQL -> $gt trace(s)"; else fail "Grafana -> Tempo TraceQL -> $gt traces"; fi
unset gu gp

# 6. Public URL: Cloudflare -> Traefik (Cloudflare-only allow list) -> Hermes dashboard (its own password login)
code() { curl -s -o /dev/null --max-time 20 -w '%{http_code}' "$@"; }
hdr="$(curl -sI --max-time 20 "$URL/")"
if ! grep -qi '^www-authenticate:' <<<"$hdr"; then pass "public $URL/ sends no WWW-Authenticate challenge"; else fail "public $URL/ sends a WWW-Authenticate challenge"; fi
c="$(code "$URL/")"
if [[ "$c" == 302 || "$c" == 307 ]]; then pass "public / without a session -> $c to the Hermes login"; else fail "public / without a session -> $c (want 302)"; fi
c="$(code "http://${URL#https://}/")"
if [[ "$c" == 301 || "$c" == 308 ]]; then pass "public http:// -> $c redirect to https"; else fail "public http:// -> $c (want 301/308)"; fi
c="$(code "$URL/login")"
if [[ "$c" == 200 ]]; then pass "public /login (Hermes login page) -> 200"; else fail "public /login -> $c"; fi
c="$(code "$URL/api/config")"
if [[ "$c" == 401 ]]; then pass "public /api/config without a Hermes session -> 401"; else fail "public /api/config without a session -> $c (want 401)"; fi
bu="$(kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.username}' | base64 -d)"
bp="$(kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.password}' | base64 -d)"
prov="$(curl -fsS --max-time 20 "$URL/api/auth/providers" 2>/dev/null \
        | json 'next(p["name"] for p in d["providers"] if p.get("supports_password"))' 2>/dev/null || echo basic)"
# Credentials reach python through its environment, not argv (argv is visible in ps).
( umask 077; P="$prov" U="$bu" W="$bp" python3 -I -c 'import json, os; print(json.dumps({"provider": os.environ["P"], "username": os.environ["U"], "password": os.environ["W"], "next": "/"}))' \
  > "$tmp/login.json" )
c="$(code -c "$tmp/jar" -H 'Content-Type: application/json' --data-binary "@$tmp/login.json" "$URL/auth/password-login")"
if [[ "$c" == 200 ]]; then pass "Hermes password login (provider $prov) -> 200"; else fail "Hermes password login (provider $prov) -> $c"; fi
c="$(code -b "$tmp/jar" "$URL/api/config")"
if [[ "$c" == 200 ]]; then pass "public /api/config with a Hermes session -> 200"; else fail "public /api/config with a Hermes session -> $c"; fi
unset bu bp

# 7. Model: settings Secret present and loaded (no model call); optional single chat request (VERIFY_CHAT=1)
keys="$(kubectl -n hermes get secret hermes-model-key -o jsonpath='{.data}' 2>/dev/null \
        | json '",".join(sorted(k for k, v in d.items() if v))' 2>/dev/null)"
if [[ "$keys" == "HERMES_MODEL,HERMES_MODEL_API_KEY,HERMES_MODEL_BASE_URL" ]]; then pass "Secret hermes-model-key has model, base URL and key"; else fail "Secret hermes-model-key keys='$keys' (run deploy.sh with a model credentials file)"; fi
for c in gateway dashboard; do
  n="$(kubectl -n hermes exec deploy/hermes-gateway -c "$c" -- sh -c '[ -n "$HERMES_MODEL" ] && [ -n "$HERMES_MODEL_BASE_URL" ] && [ -n "$HERMES_MODEL_API_KEY" ] && echo 1' 2>/dev/null)"
  if [[ "$n" == 1 ]]; then pass "$c container has the model credentials in its environment"; else fail "$c container lacks the model credentials (restart after creating the Secret)"; fi
done
# Dashboard chat (/chat) attaches its terminal to the gateway; Hermes refuses a HERMES_HOME it does not own.
gb="$(kubectl -n hermes exec deploy/hermes-gateway -c dashboard -- sh -c 'cd /opt/hermes && PYTHONPATH=/opt/hermes HERMES_PYTHON_SRC_ROOT=/opt/hermes timeout 40 /opt/hermes/.venv/bin/python hermes_cli/tui_dist/scripts/gateway_bootstrap.py 2>&1' \
      | json '"ok" if d.get("url") else "no url"' 2>/dev/null || echo "inaccessible")"
if [[ "$gb" == ok ]]; then pass "dashboard chat can attach to the gateway (HERMES_HOME owned by the Hermes user)"; else fail "dashboard chat cannot attach to the gateway ($gb): check HERMES_HOME ownership"; fi
# 7b. OpenCode bridge (default model provider): pod Ready, /v1/models answers with the shared key (no chat call)
if kubectl -n hermes rollout status deploy/opencode-bridge --timeout=120s >/dev/null 2>&1; then
  pass "opencode-bridge rolled out (Ready)"
else
  fail "opencode-bridge not Ready"
fi
v="$(kubectl -n hermes exec deploy/hermes-gateway -c gateway -- python3 -c 'import json, os, urllib.request
r = urllib.request.Request("http://opencode-bridge.hermes:18282/v1/models", headers={"Authorization": "Bearer " + os.environ["HERMES_MODEL_API_KEY"]})
d = json.load(urllib.request.urlopen(r, timeout=20)); ids = [m["id"] for m in d["data"]]; non_default = [m for m in ids if m != os.environ.get("HERMES_MODEL")]; print(json.dumps({"count": len(ids), "non_default_count": len(non_default), "sample": non_default[:3]}))' 2>/dev/null)"
if [[ -n "$v" ]] && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["count"] >= 2 and d["non_default_count"] >= 1 else 1)' "$v"; then pass "Hermes -> bridge /v1/models exposes multiple free models including alternatives: $v"; else fail "Hermes -> bridge /v1/models lacks model alternatives: ${v:-no answer} (MODEL_PROVIDER=opencode-bridge?)"; fi
v="$(kubectl -n hermes exec deploy/hermes-gateway -c gateway -- python3 -c 'import json, os, urllib.request
req = urllib.request.Request("http://127.0.0.1:8642/api/model/options", headers={"Authorization": "Bearer " + os.environ["API_SERVER_KEY"]})
d = json.load(urllib.request.urlopen(req, timeout=20))
req = urllib.request.Request("http://opencode-bridge.hermes:18282/v1/models", headers={"Authorization": "Bearer " + os.environ["HERMES_MODEL_API_KEY"]})
expected = {m["id"] for m in json.load(urllib.request.urlopen(req, timeout=20))["data"]}
found = set()
def walk(x):
 if isinstance(x, dict):
  if isinstance(x.get("models"), list):
   for m in x["models"]:
    found.add(m if isinstance(m, str) else str(m.get("id", "")) if isinstance(m, dict) else "")
  for y in x.values(): walk(y)
 elif isinstance(x, list):
  for y in x: walk(y)
walk(d)
print(json.dumps({"count": len(found & expected), "expected_count": len(expected), "missing": sorted(expected - found)}))' 2>/dev/null)"
if [[ -n "$v" ]] && python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["expected_count"] > 0 and not d["missing"] else 1)' "$v"; then pass "Hermes model picker contains the complete live OpenCode free catalogue: $v"; else fail "Hermes model picker is missing OpenCode free models: ${v:-no answer} (see custom_providers in base/config.yaml)"; fi
if [[ -n "${VERIFY_BRIDGE_CHAT_MODEL:-}" ]]; then
  b="$(kubectl -n hermes exec deploy/hermes-gateway -c gateway -- python3 -c 'import json, os, sys, urllib.request
model = sys.argv[1]
data = json.dumps({"model": model, "messages": [{"role": "user", "content": "Reply with exactly BRIDGE-MODEL-OK"}]}).encode()
req = urllib.request.Request("http://opencode-bridge.hermes:18282/v1/chat/completions", data=data, headers={"Authorization": "Bearer " + os.environ["HERMES_MODEL_API_KEY"], "Content-Type": "application/json"})
try:
 d = json.load(urllib.request.urlopen(req, timeout=180)); print(d["choices"][0]["message"].get("content", ""))
except Exception as e: print(type(e).__name__ + ": " + str(e))' "$VERIFY_BRIDGE_CHAT_MODEL" 2>/dev/null)"
  if [[ "$b" == *BRIDGE-MODEL-OK* ]]; then pass "OpenCode bridge inference succeeded for $VERIFY_BRIDGE_CHAT_MODEL"; else fail "OpenCode bridge inference failed for $VERIFY_BRIDGE_CHAT_MODEL: ${b:0:160}"; fi
fi

# 8. Read-only observability skill: loaded, reads work through the NetworkPolicies, writes are refused
OBS=/opt/skills/observability/grafana-tempo-observability/scripts/obs.py
gx() { kubectl -n hermes exec deploy/hermes-gateway -c gateway -- "$@" 2>/dev/null; }
sk="$(gx env COLUMNS=200 hermes skills list)"
if grep -q 'grafana-tempo-observability' <<<"$sk"; then pass "skill grafana-tempo-observability loaded"; else fail "skill grafana-tempo-observability not listed by 'hermes skills list'"; fi
v="$(gx python3 "$OBS" prom 'max(hermes_gateway_up)' | json 'd["result"][0]["value"] if d.get("result") else d.get("error", "none")' 2>/dev/null)"
if [[ "$v" == 1 ]]; then pass "skill -> Thanos querier :10902 (max(hermes_gateway_up) = 1)"; else fail "skill -> Thanos querier: $v"; fi
v="$(gx python3 -c 'import socket
s = socket.socket(); s.settimeout(5)
try: s.connect(("prometheus-kube-prometheus-prometheus.monitoring", 9090)); print("open")
except Exception as e: print("blocked")')"
if [[ "$v" == blocked ]]; then pass "Hermes pod cannot reach Prometheus :9090 (remote-write/reload/quit not exposed to it)"; else fail "Hermes pod reaches Prometheus :9090 ($v)"; fi
v="$(gx python3 "$OBS" traceql '{ resource.service.name = "hermes-gateway" }' --since 30m --limit 3 | json 'd.get("error") or d["count"]' 2>/dev/null)"
if [[ "$v" =~ ^[1-9] ]]; then pass "skill -> Tempo :3200 ($v traces)"; else fail "skill -> Tempo: $v"; fi
v="$(gx python3 "$OBS" dashboards hermes | json 'd.get("error") if isinstance(d, dict) else len(d)' 2>/dev/null)"
if [[ "$v" =~ ^[1-9] ]]; then pass "skill -> Grafana :3000 with the Viewer token ($v dashboards)"; else fail "skill -> Grafana: $v"; fi
v="$(gx python3 -c 'import json, os, urllib.request, urllib.error
r = urllib.request.Request("http://grafana.observability/api/dashboards/db", method="POST", data=json.dumps({"dashboard": {"title": "write-test"}}).encode(),
    headers={"Authorization": "Bearer " + os.environ["GRAFANA_TOKEN"], "Content-Type": "application/json"})
try: urllib.request.urlopen(r, timeout=15); print("200")
except urllib.error.HTTPError as e: print(e.code)')"
if [[ "$v" == 403 ]]; then pass "Grafana write with the skill's token -> 403 (Viewer, read-only)"; else fail "Grafana write with the skill's token -> $v (want 403)"; fi
v="$(gx python3 "$OBS" diagnose --summary | head -n1)"
if [[ "$v" == diagnose:* ]]; then pass "skill diagnose runs: ${v#diagnose: }"; else fail "skill diagnose: ${v:0:120}"; fi

v="$(gx python3 "$OBS" trends | json '" | ".join([d.get("comparison", ""), "history " + str(d.get("history_available_h")) + " h", str(len(d.get("trends", []))) + " trends", str(d.get("took_s")) + " s"])' 2>/dev/null)"
if [[ "$v" == *window* ]]; then pass "skill trends runs: $v"; else fail "skill trends: ${v:0:120}"; fi

if [[ "${VERIFY_CHAT:-0}" == 1 ]]; then
  pod="$(kubectl -n hermes get pod -l app.kubernetes.io/name=hermes-gateway -o jsonpath='{.items[0].metadata.name}')"
  p="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  kubectl -n hermes port-forward "pod/$pod" "$p:8642" >/dev/null 2>&1 &
  echo "$!" >>"$tmp/pids"
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$p/health" && break; sleep 0.5; done
  ak="$(kubectl -n hermes get secret hermes-api-server -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d)"
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$ak" > "$tmp/api" ); unset ak
  reply="$(curl -s --max-time 240 -K "$tmp/api" -H 'Content-Type: application/json' \
    -d '{"model":"hermes-agent","messages":[{"role":"user","content":"Reply with exactly: HERMES-VERIFY-OK"}]}' \
    "http://127.0.0.1:$p/v1/chat/completions" | json 'd["choices"][0]["message"]["content"]' 2>/dev/null)"
  if [[ "$reply" == *HERMES-VERIFY-OK* ]]; then pass "chat via API server -> model reply"; else fail "chat via API server -> '${reply:0:120}'"; fi
fi

echo "failures: $fails"
exit "$fails"
