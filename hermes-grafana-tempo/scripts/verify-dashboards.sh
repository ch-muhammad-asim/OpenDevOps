#!/usr/bin/env bash
# Check every Grafana dashboard panel headlessly through the Grafana API.
#
# For each dashboard (folder + title) and each panel (including the panels of collapsed rows) this
# runs the panel's Prometheus targets as instant queries over the last 15 minutes (again over 1 hour
# when a query has no data) and classifies the result:
#
#   OK          the query returned at least one row
#   NO_DATA     no rows; "EXPECTED" when the panel is empty by design in this single-binary stack
#   ERROR       the data source returned an error, or a nodeGraph panel has duplicate node ids
#   SKIP        row, text and other panels that do not query a data source
#
# Read-only and idempotent. Exit code = number of ERROR panels.
#
# Usage:
#   scripts/verify-dashboards.sh                 # port-forward svc/grafana on a free local port
#   GRAFANA_URL=https://grafana-tempo.<domain> scripts/verify-dashboards.sh
#   scripts/verify-dashboards.sh --dashboard tempo-service-graph   # one dashboard (repeatable)
#
# Environment:
#   GRAFANA_URL        Grafana base URL. When empty, port-forward svc/grafana (namespace
#                      GRAFANA_NAMESPACE, default observability) on a free local port.
#   GRAFANA_USER       Admin user. Default: key admin-user of Secret observability/grafana-admin.
#   GRAFANA_PASSWORD   Admin password. Default: key admin-password of the same Secret. Never printed.
#   GRAFANA_NAMESPACE  Namespace of the Grafana service and Secret (default observability).
set -euo pipefail

GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-observability}"
DASHBOARDS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dashboard) DASHBOARDS+=("${2:?--dashboard needs a uid}"); shift 2 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

if [[ -z "${GRAFANA_URL:-}" ]]; then
  command -v kubectl >/dev/null || { echo "kubectl not found and GRAFANA_URL is empty" >&2; exit 1; }
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  kubectl -n "$GRAFANA_NAMESPACE" port-forward svc/grafana "$PORT:80" >/dev/null 2>&1 &
  PF_PID=$!
  GRAFANA_URL="http://127.0.0.1:$PORT"
  for _ in $(seq 1 30); do
    curl -sf -o /dev/null "$GRAFANA_URL/api/health" && break
    sleep 1
  done
  curl -sf -o /dev/null "$GRAFANA_URL/api/health" || { echo "cannot reach Grafana through the port-forward" >&2; exit 1; }
fi

if [[ -z "${GRAFANA_USER:-}" || -z "${GRAFANA_PASSWORD:-}" ]]; then
  command -v kubectl >/dev/null || { echo "set GRAFANA_USER and GRAFANA_PASSWORD when kubectl is not available" >&2; exit 1; }
  GRAFANA_USER="${GRAFANA_USER:-$(kubectl -n "$GRAFANA_NAMESPACE" get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d)}"
  GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-$(kubectl -n "$GRAFANA_NAMESPACE" get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)}"
  [[ -n "$GRAFANA_USER" && -n "$GRAFANA_PASSWORD" ]] || { echo "could not read the Grafana admin credentials" >&2; exit 1; }
fi

GRAFANA_URL="$GRAFANA_URL" GRAFANA_USER="$GRAFANA_USER" GRAFANA_PASSWORD="$GRAFANA_PASSWORD" \
DASHBOARDS="${DASHBOARDS[*]:-}" python3 - <<'PY'
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request

URL = os.environ["GRAFANA_URL"].rstrip("/")
AUTH = "Basic " + base64.b64encode(
    f'{os.environ["GRAFANA_USER"]}:{os.environ["GRAFANA_PASSWORD"]}'.encode()).decode()
ONLY = [u for u in os.environ.get("DASHBOARDS", "").split() if u]
# A panel is retried over a wider range and a wider rate window: some counters (blocklist poll,
# retention, job duration) only move every few minutes, and a 1m rate over such a series is NaN.
WINDOWS = [("15m", 15, "1m"), ("1h", 60, "5m"), ("6h", 360, "15m")]

# Panels that are empty by design in this stack. Each rule matches "<dashboard> / <panel> / <query>"
# (the panel's own query is the reliable key: several dashboards reuse a panel title) and carries the
# reason that is printed next to the panel.
EXPECTED_EMPTY = [
    (r"loki|promtail", "log panels need Loki, which this stack does not run"),
    (r"envoy|kafka|memcached|vulture|keda|autoscal|partition|block.builder|backend worker",
     "panel needs a component this single-binary stack does not run"),
    (r"grafana_alerting_result_total", "Grafana's own metrics are not scraped here"),
    (r"kubelet_node_config_error|storage_operation_errors_total",
     "this kubelet does not export the metric"),
    (r"node_memory_(total|available|internal|purgeable|wired|compressed)_bytes",
     "AIX and macOS collectors; this cluster has Linux nodes only"),
    (r"instance:node_network_(receive|transmit)_drop_.*:rate5m",
     "the panel filters drops != 0 and there are none"),
    (r"kube_pod_container_status_restarts_total",
     "the panel filters restarts > 0 and there are none"),
    (r"tempo_memberlist_|gauge_memberlist_", "single-binary Tempo: no memberlist ring"),
    (r"tempo_distributor_metrics_generator_pushes_failures_total",
     "the metrics-generator runs in-process, there are no gRPC pushes to fail"),
    (r'route=~"\(opentelemetry_proto_collector_trace_v1_traceservice_export\|otlp_v1_traces\)"'
     r'|route=~"/tempopb\.MetricsGenerator/PushSpans"',
     "no gateway and no remote metrics-generator: OTLP ingest is measured on Tempo / Writes"),
    (r"tempodb_compaction_objects_(written|combined)_total",
     "Tempo 3.1 does not export these counters; read Blocks Compacted and Bytes Written / s"),
    (r"tempo_backend_scheduler_jobs_(failed|retry|dropped)_total",
     "Tempo 3.1 does not export these scheduler counters"),
    (r'job_type="JOB_TYPE_REDACTION"|tempo_backend_scheduler_redaction',
     "no redaction job is configured in this stack"),
    (r"tempodb_retention_duration_seconds_bucket",
     "the retention loop runs about once an hour; the panel is empty between runs"),
    (r"tempo_memcache_request_duration", "no memcached in this stack"),
]
SKIP_TYPES = {"row", "text", "dashlist", "news", "alertlist", "annolist", "welcome", "gettingstarted"}


def api(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(URL + path, data=data, headers={
        "Authorization": AUTH, "Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            return json.loads(body)
        except ValueError:
            return {"error": f"HTTP {e.code}: {body[:200]}"}


def query_value(v, var):
    """First value of a query variable, the way Grafana fills it: label_values(<metric>{<selector>},
    <label>) becomes count by (<label>) over the metric. Other query forms (query_result, promql)
    fall back to All."""
    q = v.get("query")
    if isinstance(q, dict):
        q = q.get("query")
    m = re.fullmatch(r"\s*label_values\(\s*([A-Za-z_:][A-Za-z0-9_:]*)\s*(\{[^{}]*\})?\s*,\s*"
                     r"([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*", q or "")
    if not m:
        return ".*"
    metric, selector, label = m.group(1), m.group(2) or "", m.group(3)
    selector, _ = substitute(selector, var, "1h", "1m")
    res = api("/api/ds/query", {"from": "now-1h", "to": "now", "queries": [{
        "refId": "var", "datasource": {"type": "prometheus", "uid": "prometheus"},
        "expr": f"count by ({label}) ({metric}{selector})",
        "format": "table", "instant": True, "range": False,
        "intervalMs": 60000, "maxDataPoints": 1000}]})
    values = set()
    for frame in frames_of((res.get("results") or {}).get("var") or {}):
        values |= {m2.get(label) for m2 in [label_map(frame)] if m2.get(label)}
    return sorted(values)[0] if values else ".*"


def variables(dash, dsmap, first=False):
    """Resolve every template variable: data source variables to the real uid (this stack's default
    is the "Prometheus"/"Tempo" data source, whose uid is not its display name), query variables to
    All when the dashboard offers All and to their first value otherwise (first=True forces the
    first value for every query variable too), custom variables to their value."""
    out = {}
    for v in dash.get("templating", {}).get("list", []):
        name = v.get("name")
        if not name:
            continue
        cur = (v.get("current") or {}).get("value")
        if v.get("type") == "datasource":
            out[name] = "" if cur in (None, "", "default") else dsmap.get(str(cur), "")
        elif v.get("type") == "custom":
            first_opt = next((o.get("value") for o in v.get("options") or [] if o.get("value") != "$__all"), "")
            out[name] = str(cur) if cur not in (None, "", "$__all") else str(first_opt)
        elif v.get("type") == "query":
            if not first or v.get("includeAll"):
                out[name] = v.get("allValue") or ".*"
            else:
                out[name] = query_value(v, out)
        else:
            out[name] = str(cur) if cur is not None else ""
    return out


def panels(dash):
    out = []

    def walk(items):
        for p in items or []:
            out.append(p)
            walk(p.get("panels"))

    walk(dash.get("panels"))
    return out


def substitute(expr, var, window, step):
    for name, value in var.items():
        if value in (".*", ".+"):
            # "All" in Grafana: an exact matcher on the variable becomes a regex matcher.
            expr = re.sub(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"\$\{?' + re.escape(name) + r'\}?"',
                          r'\1=~"' + value + '"', expr)
        expr = expr.replace("${%s}" % name, value).replace("$" + name, value)
    expr = (expr.replace("$__range", window).replace("$__rate_interval", step)
                .replace("$__interval", step).replace("$__auto_interval", step)
                .replace("$__interval_ms", "60000").replace("$__rate_interval_ms", "60000"))
    leftover = re.findall(r"\$[A-Za-z_][A-Za-z0-9_]*", expr)
    return expr, sorted(set(leftover))


def frames_of(result):
    return result.get("frames") or []


def rows_of(frame):
    values = frame.get("data", {}).get("values") or []
    if not values:
        return 0
    return max((len(v) for v in values if isinstance(v, list)), default=0)


def label_map(frame):
    out = {}
    for f in frame.get("schema", {}).get("fields", []):
        out.update(f.get("labels") or {})
    return out


def ds_uid(ds, var, panel_type):
    """Resolve a data source uid: literal, "$var" / "${var}", or a per-type default (this stack has
    one Prometheus uid "prometheus" and one Tempo uid "tempo")."""
    uid = ""
    if isinstance(ds, dict):
        uid = str(ds.get("uid") or "")
    m = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", uid)
    if m:
        uid = var.get(m.group(1), "")
    if uid and uid != "-- Mixed --":
        return uid
    return {"prometheus": "prometheus", "tempo": "tempo"}.get(panel_type, "")


def run(panel, var, window, step, minutes):
    targets = [t for t in panel.get("targets", []) if (t.get("expr") or "").strip()]
    if not targets:
        return "SKIP", "no data source query"
    queries, notes = [], []
    for t in targets:
        expr, leftover = substitute(t["expr"], var, window, step)
        if leftover:
            notes.append("unresolved variable " + ",".join(leftover))
        ds = t.get("datasource") or panel.get("datasource") or {}
        dtype = (ds.get("type") if isinstance(ds, dict) else "") or "prometheus"
        uid = ds_uid(ds, var, dtype)
        if not uid:
            return "ERROR", "no data source for this target"
        queries.append({"refId": t.get("refId") or f"q{len(queries)}",
                        "datasource": {"type": dtype, "uid": uid},
                        "expr": expr, "format": "table", "instant": True, "range": False,
                        "intervalMs": 60000, "maxDataPoints": 1000})
    res = api("/api/ds/query", {"from": f"now-{minutes}m", "to": "now", "queries": queries})
    if "error" in res:
        return "ERROR", str(res["error"])[:160]
    if "results" not in res:
        return "ERROR", str(res.get("message") or "no results in the response")[:160]
    results = res.get("results", {})
    total, errors = 0, []
    for q in queries:
        r = results.get(q["refId"], {})
        if not r:
            errors.append(f"{q['refId']}: no result")
            continue
        if r.get("error"):
            errors.append(str(r["error"])[:160])
            continue
        total += sum(rows_of(f) for f in frames_of(r))
    if errors:
        return "ERROR", "; ".join(errors)
    if panel.get("type") == "nodeGraph":
        ids = [m.get("id") for q in queries
               for f in frames_of(results.get(q["refId"], {})) for m in [label_map(f)] if m.get("id")]
        if ids and len(ids) != len(set(ids)):
            dup = sorted({i for i in ids if ids.count(i) > 1})
            return "ERROR", "duplicate node ids: " + ", ".join(dup)
        if ids:
            return "OK", f"{len(set(ids))} nodes, {total} rows"
    if total:
        return "OK", f"{total} rows"
    return "NO_DATA", (notes[0] if notes else "empty in the last %s" % window)


def exprs_of(panel):
    return " ".join(t.get("expr") or "" for t in panel.get("targets") or [])


def probe(panel, var):
    """Run a panel over each window until it has data (or reports an error)."""
    status, detail = "NO_DATA", ""
    for window, minutes, step in WINDOWS:
        status, detail = run(panel, var, window, step, minutes)
        if status in ("OK", "ERROR"):
            break
    return status, detail


def main():
    search = api("/api/search?type=dash-db")
    if not isinstance(search, list):
        print("cannot list dashboards:", search, file=sys.stderr)
        return 1
    dsmap = {}
    for src in api("/api/datasources") or []:
        if isinstance(src, dict) and src.get("uid"):
            dsmap[src["name"]] = src["uid"]
            dsmap[src["uid"]] = src["uid"]
    if ONLY:
        search = [d for d in search if d.get("uid") in ONLY]
    rows, errors, no_data, expected, skipped = [], 0, 0, 0, 0
    print(f"Grafana {URL} - {len(search)} dashboards\n")
    for d in search:
        meta = api("/api/dashboards/uid/" + d["uid"])
        dash = meta.get("dashboard") or {}
        var = variables(dash, dsmap)
        var_first = None
        for p in panels(dash):
            title = p.get("title") or "(untitled)"
            ptype = p.get("type", "")
            if ptype in SKIP_TYPES:
                skipped += 1
                rows.append((d, title, "SKIP", ptype))
                continue
            if not p.get("targets"):
                skipped += 1
                rows.append((d, title, "SKIP", ptype + " without queries"))
                continue
            status, detail = probe(p, var)
            if status == "NO_DATA":
                # Some panels divide two topk(1, ...) subqueries that only line up when the variable
                # holds one concrete value; retry with the first value of every query variable.
                if var_first is None:
                    var_first = variables(dash, dsmap, first=True)
                status, detail = probe(p, var_first)
            if status == "NO_DATA":
                key = f"{dash.get('title', '')} / {title} / {exprs_of(p)}"
                reason = next((why for pattern, why in EXPECTED_EMPTY if re.search(pattern, key, re.I)), "")
                if reason:
                    status, detail = "EXPECTED", reason
                    expected += 1
                else:
                    no_data += 1
            elif status == "ERROR":
                errors += 1
            rows.append((d, title, status, detail))
    for d, title, status, detail in rows:
        folder = d.get("folderTitle") or "-"
        print(f"{status:<8} | {folder:<12} | {d.get('title',''):<34} | {title[:52]:<52} | {detail}")
    ok = sum(1 for r in rows if r[2] == "OK")
    print(f"\nsummary: {len(rows)} panels - OK {ok}, EXPECTED(empty by design) {expected}, "
          f"NO_DATA {no_data}, SKIP {skipped}, ERROR {errors}")
    if no_data:
        print("unexpected NO_DATA: fix the query or add the panel to the expected-empty list")
    return errors


if __name__ == "__main__":
    sys.exit(main())
PY
