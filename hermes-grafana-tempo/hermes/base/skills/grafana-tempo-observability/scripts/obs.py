#!/usr/bin/env python3
"""Read-only Prometheus, Tempo and Grafana queries for the grafana-tempo-observability skill (Python stdlib only).

Read-only by construction: HTTP GET to the Prometheus and Tempo query APIs and the Grafana search/dashboard APIs; the
one POST is Grafana's /api/ds/query (a datasource query, allowed for the Viewer role). Output is compact JSON with
bounded time ranges and result limits; whole traces are summarised, never dumped.

  obs.py diagnose [--window 15m] [--since 60m]   ranked suggested issues with evidence, root cause, file, fix, links
  obs.py hermes                          Hermes gateway health + firing alerts
  obs.py alerts | targets
  obs.py prom '<PromQL>' [--range 15m] [--step 60s]
  obs.py red <service> [--window 15m]    rate, error ratio, p95/p99 per server span (Tempo span metrics)
  obs.py graph [--window 15m]            service graph edges: requests/s, failed/s
  obs.py traceql '<TraceQL>' [--since 15m] [--limit 20]
  obs.py slowest <service> [--since 15m] [--limit 10]
  obs.py errors <service> [--since 15m] [--limit 10]
  obs.py issue <app> [--since 60m]       ready-made TraceQL per planted issue: nextjs | nodejs | python
  obs.py trace <traceID>                 compact span tree (max 60 spans)
  obs.py tags [<tag>]                    TraceQL tag names, or values of one tag
  obs.py dashboards [<search>]           Grafana dashboards (title, uid, public URL)
  obs.py panels <dashboard-uid>          panels of one dashboard: title, type, queries, panel deep link
  obs.py gquery prometheus|tempo '<query>' [--since 15m]   query through Grafana's /api/ds/query
  obs.py link prometheus|tempo '<query or traceID>' [--since 1h]   Grafana Explore deep link
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PROM = os.environ.get("OBS_PROMETHEUS_URL", "http://prometheus-kube-prometheus-prometheus.monitoring:9090")
TEMPO = os.environ.get("OBS_TEMPO_URL", "http://tempo.observability:3200")
GRAFANA = os.environ.get("OBS_GRAFANA_URL", "http://grafana.observability")
GRAFANA_PUBLIC = os.environ.get("OBS_GRAFANA_PUBLIC_URL", "https://grafana-tempo.saqlainmushtaq.com").rstrip("/")
GRAFANA_TOKEN = os.environ.get("GRAFANA_TOKEN", "")
DS = {"prometheus": {"type": "prometheus", "uid": "prometheus"}, "tempo": {"type": "tempo", "uid": "tempo"}}

SERVICES = {"nextjs": "nextjs-web", "nodejs": "nodejs-orders", "python": "python-inventory", "hermes": "hermes-gateway"}
APPS = ["nextjs-web", "nodejs-orders", "python-inventory"]

# Planted issues of the sample apps: TraceQL that finds each one (as in apps/*/README.md), probable root cause,
# file to look at and suggested fix. severity: error (users get failures) > latency > resource.
ISSUES = {
    "nextjs-web": [
        ("Unhandled exception in checkout", "error", "POST /api/checkout",
         '{ resource.service.name = "nextjs-web" && event.exception.type = "TypeError" }',
         "The cart body is never validated; an empty body throws TypeError and the route answers 500",
         "apps/nextjs/app/api/checkout/route.ts", "Validate the cart and answer 400"),
        ("Cascading timeout on stock lookup", "error", "GET /api/stock/:id",
         '{ resource.service.name = "nextjs-web" && kind = client && status = error && span:duration > 2s }',
         "nodejs aborts its call to python /inventory/slow (~3 s) at 2 s; the 504 cascades to the user",
         "apps/nextjs/app/api/stock/[id]/route.ts", "Own time budget (AbortSignal.timeout(500)) with a fallback value; fix the slow dependency"),
        ("Hidden downstream failure in dashboard", "error", "GET /api/dashboard",
         '{ resource.service.name = "nextjs-web" && event:name = "order.fetch_failed" }',
         "Order 7 fails downstream (502) but the page still answers 200; only the order.fetch_failed event shows it",
         "apps/nextjs/app/api/dashboard/route.ts", "Keep degrading gracefully, alert on the event rate and fix the failing dependency"),
        ("N+1 HTTP fan-out in dashboard", "latency", "GET /api/dashboard",
         '{ resource.service.name = "nextjs-web" && kind = server } >> { resource.service.name = "nextjs-web" && kind = client } | count() > 10',
         "One list call plus one call per order (11 sequential fetches) instead of one batch call",
         "apps/nextjs/app/api/dashboard/route.ts", "Use a batch endpoint (details in GET /orders) or Promise.all with a concurrency limit"),
        ("Slow upstream report", "latency", "GET /api/report",
         '{ resource.service.name = "nextjs-web" && kind = client && span:duration > 1s } >> { name = "orders.build_report" }',
         "Almost all time is the call to nodejs, whose orders.build_report burns CPU synchronously",
         "apps/nextjs/app/api/report/route.ts", "Fix in nodejs (async crypto or worker thread); cache the report here"),
    ],
    "nodejs-orders": [
        ("Cross-service error chain for order 7", "error", "GET /orders/7",
         '{ resource.service.name = "nodejs-orders" && kind = server && status = error } >> { resource.service.name = "python-inventory" && status = error }',
         "Order 7 references SKU-999, python answers 500 (KeyError), nodejs turns it into a 502",
         "apps/nodejs/server.js", "Fix the python handler/data; here, return the order without stock instead of failing"),
        ("Unhandled exception in create order", "error", "POST /orders",
         '{ resource.service.name = "nodejs-orders" && name = "POST /orders" && status = error }',
         "The body is never validated; destructuring an undefined body throws TypeError -> 500",
         "apps/nodejs/server.js", "Validate the body and answer 400"),
        ("External call timeout on stock", "error", "GET /orders/:id/stock",
         '{ resource.service.name = "nodejs-orders" && kind = client && status = error && span:duration >= 2s }',
         "python /inventory/slow takes ~3 s but the client aborts at 2 s",
         "apps/nodejs/server.js", "Call a fast/cached endpoint; set the timeout from the dependency's p99 and add a fallback"),
        ("CPU hog on the event loop", "latency", "GET /orders/report",
         '{ resource.service.name = "nodejs-orders" && name = "orders.build_report" && span:duration > 1s }',
         "pbkdf2Sync runs on the event loop (~1.3 s span with no children); every other request waits",
         "apps/nodejs/server.js", "Async crypto.pbkdf2 or a worker_thread, or precompute/cache the report"),
        ("Memory leak in audit cache", "resource", "GET /orders",
         '{ resource.service.name = "nodejs-orders" && span.app.cache.bytes > 0 }',
         "Each request keeps a full 1 MiB buffer copy in an unbounded cache; app.cache.bytes only grows",
         "apps/nodejs/server.js", "Do not keep per-request copies; if needed keep subarray(0, written) in a bounded LRU with TTL"),
    ],
    "python-inventory": [
        ("Unhandled KeyError for unknown SKU", "error", "GET /inventory/items/{sku}",
         '{ resource.service.name = "python-inventory" && event.exception.type = "KeyError" }',
         "CATALOG[sku] raises KeyError for SKU-999 -> HTTP 500",
         "apps/python/main.py", "Use CATALOG.get(sku) and return 404"),
        ("Slow endpoint (legacy supplier sync)", "latency", "GET /inventory/slow",
         '{ resource.service.name = "python-inventory" && name = "legacy_supplier_sync" && span:duration > 2s }',
         "A synchronous supplier sync holds each request ~3 s; callers with a 2 s timeout fail first",
         "apps/python/main.py", "Run the sync as a background job and serve cached data"),
        ("N+1 queries in report", "latency", "GET /inventory/report",
         '{ resource.service.name = "python-inventory" && kind = server } >> { span.db.system = "sqlite" } | count() > 10',
         "One SELECT per item inside the loop (21 queries for 20 items)",
         "apps/python/main.py", "One SELECT for all rows"),
        ("CPU hog (recursive fib)", "latency", "GET /inventory/fib",
         '{ resource.service.name = "python-inventory" && span.http.route = "/inventory/fib" && span:duration > 150ms }',
         "Exponential recursive fib runs on the event loop inside an async def; other requests wait",
         "apps/python/main.py", "Iterative fib; keep CPU work off the event loop"),
    ],
}
SEV = {"critical": 0, "error": 1, "latency": 2, "resource": 3, "warning": 4}


# --------------------------------------------------------------------------------------------------------- HTTP
def _req(url, body=None, headers=None):
    h = {"Accept": "application/json", **(headers or {})}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method="POST" if body is not None else "GET", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode(errors='replace')[:200]}"}
    except Exception as e:  # network/DNS/timeout
        return {"error": f"{type(e).__name__}: {e}"}


def get(base, path, params=None):
    return _req(base + path + ("?" + urllib.parse.urlencode(params) if params else ""))


def gget(path, params=None):
    if not GRAFANA_TOKEN:
        return {"error": "GRAFANA_TOKEN not set (Secret hermes-grafana-token missing)"}
    return _req(GRAFANA + path + ("?" + urllib.parse.urlencode(params) if params else ""),
                headers={"Authorization": f"Bearer {GRAFANA_TOKEN}"})


def dur(s):
    """'15m' / '2h' / '30s' / '90' -> seconds."""
    s = str(s).strip()
    mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}.get(s[-1:], 1)
    return int(float(s[:-1] if s[-1:] in "smhd" else s) * mult)


def ms(ns):
    return round(int(ns) / 1e6, 1)


def num(v, nd=3):
    try:
        f = float(v)
        return None if f != f else round(f, nd)  # NaN -> None
    except (TypeError, ValueError):
        return None


# --------------------------------------------------------------------------------------------- Grafana links
def link(kind, query, since="1h"):
    """Grafana Explore deep link with the query prefilled (public URL)."""
    q = {"refId": "A", "datasource": {"uid": DS[kind]["uid"]}}
    q.update({"queryType": "traceql", "query": query} if kind == "tempo" else {"expr": query})
    panes = {"a": {"datasource": DS[kind]["uid"], "queries": [q], "range": {"from": f"now-{since}", "to": "now"}}}
    return f"{GRAFANA_PUBLIC}/explore?schemaVersion=1&orgId=1&panes=" + urllib.parse.quote(json.dumps(panes, separators=(",", ":")))


def dashboards(search=""):
    d = gget("/api/search", {"type": "dash-db", "query": search, "limit": 50})
    if isinstance(d, dict) and "error" in d:
        return d
    return [{"title": x["title"], "uid": x["uid"], "folder": x.get("folderTitle", "General"),
             "url": GRAFANA_PUBLIC + x["url"]} for x in d]


def panels(uid):
    d = gget(f"/api/dashboards/uid/{urllib.parse.quote(uid)}")
    if "error" in d:
        return d
    db = d["dashboard"]
    out = []

    def walk(ps):
        for p in ps:
            if p.get("type") == "row" and p.get("panels"):
                walk(p["panels"])
                continue
            out.append({"id": p.get("id"), "title": p.get("title"), "type": p.get("type"),
                        "queries": [t.get("expr") or t.get("query") for t in p.get("targets", []) if t.get("expr") or t.get("query")][:3],
                        "url": f"{GRAFANA_PUBLIC}/d/{uid}?viewPanel={p.get('id')}"})
    walk(db.get("panels", []))
    return {"title": db.get("title"), "url": f"{GRAFANA_PUBLIC}/d/{uid}", "panels": out[:40]}


def gquery(kind, query, since="15m"):
    """Query a datasource through Grafana (/api/ds/query). Returns a compact summary of the frames."""
    if not GRAFANA_TOKEN:
        return {"error": "GRAFANA_TOKEN not set (Secret hermes-grafana-token missing)"}
    q = {"refId": "A", "datasource": DS[kind]}
    if kind == "tempo":
        q.update({"queryType": "traceql", "query": query, "limit": 20, "tableType": "traces"})
    else:
        q.update({"expr": query, "instant": True})
    d = _req(GRAFANA + "/api/ds/query", {"from": f"now-{since}", "to": "now", "queries": [q]},
             headers={"Authorization": f"Bearer {GRAFANA_TOKEN}"})
    if "error" in d:
        return d
    res = d.get("results", {}).get("A", {})
    frames = []
    for f in res.get("frames", [])[:10]:
        fields = [x.get("name") for x in f.get("schema", {}).get("fields", [])]
        vals = f.get("data", {}).get("values", [])
        rows = [dict(zip(fields, r)) for r in zip(*vals)][:10] if vals else []
        frames.append({"name": f.get("schema", {}).get("name"), "fields": fields, "rows": rows})
    return {"query": query, "error": res.get("error"), "frames": frames, "explore": link(kind, query, since)}


# ------------------------------------------------------------------------------------------ Prometheus / Tempo
def prom_query(q, rng=None, step="60s"):
    if rng:
        end = time.time()
        d = get(PROM, "/api/v1/query_range", {"query": q, "start": end - dur(rng), "end": end, "step": dur(step)})
    else:
        d = get(PROM, "/api/v1/query", {"query": q})
    if "error" in d:
        return {"query": q, "result": [], **d}
    out = []
    for r in d.get("data", {}).get("result", []):
        m = {k: v for k, v in r.get("metric", {}).items() if not k.startswith("__") or k == "__name__"}
        if "values" in r:
            vals = r["values"]
            out.append({"metric": m, "points": len(vals), "first": vals[0][1], "last": vals[-1][1],
                        "max": max(float(v[1]) for v in vals)})
        else:
            out.append({"metric": m, "value": r["value"][1]})
    return {"query": q, "series": len(out), "result": out[:50]}


def alerts():
    d = get(PROM, "/api/v1/alerts")
    if "error" in d:
        return d
    al = [{"alertname": a["labels"].get("alertname"), "state": a["state"], "severity": a["labels"].get("severity"),
           "namespace": a["labels"].get("namespace"), "summary": a.get("annotations", {}).get("summary", "")[:160]}
          for a in d["data"]["alerts"] if a["labels"].get("alertname") not in ("Watchdog", "InfoInhibitor")]
    return {"firing": [a for a in al if a["state"] == "firing"], "pending": [a for a in al if a["state"] == "pending"]}


def targets():
    d = get(PROM, "/api/v1/targets", {"state": "active"})
    if "error" in d:
        return d
    jobs = {}
    for t in d["data"]["activeTargets"]:
        j = jobs.setdefault(t["labels"].get("job", t["scrapePool"]), {"up": 0, "down": 0, "errors": []})
        j["up" if t["health"] == "up" else "down"] += 1
        if t["health"] != "up" and t.get("lastError"):
            j["errors"].append(t["lastError"][:160])
    return jobs


def hermes():
    q = {
        "gateway_up": "max(hermes_gateway_up)",
        "gateway_state": "max by (hermes_gateway_state) (hermes_gateway_state) == 1",
        "platforms_up": "max by (hermes_platform) (hermes_platform_up)",
        "active_agents": "max(hermes_gateway_active_agents)",
        "restart_requested": "max(hermes_gateway_restart_requested)",
        "cron_jobs_overdue": "max(hermes_cron_jobs_overdue)",
    }
    res = {k: [(r["metric"], r["value"]) for r in prom_query(v).get("result", [])] for k, v in q.items()}
    al = alerts()
    res["alerts_firing"] = al.get("firing", al)
    res["hermes_alerts_firing"] = [a for a in al.get("firing", []) if str(a["alertname"]).startswith("Hermes")]
    lc = traceql('{ resource.service.name = "hermes-gateway" && span.hermes.name = "gateway.lifecycle" }', "6h", 3)
    res["recent_lifecycle_traces"] = [{"traceID": t["traceID"], "start": t["start"]} for t in lc.get("traces", [])]
    res["dashboard"] = f"{GRAFANA_PUBLIC}/d/hermes-gateway"
    return res


def red(service, window="15m"):
    s = SERVICES.get(service, service)
    b = f'service="{s}", span_kind="SPAN_KIND_SERVER"'
    rate = {r["metric"].get("span_name"): num(r["value"]) for r in
            prom_query(f"sum by (span_name) (rate(traces_spanmetrics_calls_total{{{b}}}[{window}]))")["result"]}
    err = {r["metric"].get("span_name"): num(r["value"]) for r in
           prom_query(f'sum by (span_name) (rate(traces_spanmetrics_calls_total{{{b}, status_code="STATUS_CODE_ERROR"}}[{window}]))')["result"]}
    p95 = {r["metric"].get("span_name"): num(r["value"]) for r in
           prom_query(f"histogram_quantile(0.95, sum by (span_name, le) (rate(traces_spanmetrics_latency_bucket{{{b}}}[{window}])))")["result"]}
    p99 = {r["metric"].get("span_name"): num(r["value"]) for r in
           prom_query(f"histogram_quantile(0.99, sum by (span_name, le) (rate(traces_spanmetrics_latency_bucket{{{b}}}[{window}])))")["result"]}
    base = {r["metric"].get("span_name"): num(r["value"]) for r in
            prom_query(f"histogram_quantile(0.95, sum by (span_name, le) (rate(traces_spanmetrics_latency_bucket{{{b}}}[6h] offset {window})))")["result"]}
    rows = []
    for n in sorted(rate, key=lambda k: -(rate[k] or 0)):
        r = rate[n] or 0
        rows.append({"span": n, "req_per_s": round(r, 3), "error_ratio": round((err.get(n) or 0) / r, 3) if r else 0,
                     "p95_s": p95.get(n), "p99_s": p99.get(n), "p95_baseline_6h_s": base.get(n)})
    return {"service": s, "window": window, "spans": rows[:25]}


def graph(window="15m"):
    req = prom_query(f"sum by (client, server) (rate(traces_service_graph_request_total[{window}]))")["result"]
    fail = {(r["metric"].get("client"), r["metric"].get("server")): num(r["value"]) for r in
            prom_query(f"sum by (client, server) (rate(traces_service_graph_request_failed_total[{window}]))")["result"]}
    return {"window": window, "edges": [{"client": r["metric"].get("client"), "server": r["metric"].get("server"),
                                         "req_per_s": num(r["value"]), "failed_per_s": fail.get((r["metric"].get("client"), r["metric"].get("server")), 0)}
                                        for r in req]}


def traceql(q, since="15m", limit=20):
    end = int(time.time())
    d = get(TEMPO, "/api/search", {"q": q, "start": end - dur(since), "end": end, "limit": limit, "spss": 3})
    if "error" in d:
        return {"query": q, "count": 0, "traces": [], **d}
    out = []
    for t in d.get("traces", []):
        spans = [s for ss in t.get("spanSets", [t.get("spanSet") or {}]) for s in (ss or {}).get("spans", [])]
        out.append({"traceID": t["traceID"], "root": f'{t.get("rootServiceName")} {t.get("rootTraceName")}',
                    "duration_ms": t.get("durationMs"),
                    "start": time.strftime("%H:%M:%SZ", time.gmtime(int(t.get("startTimeUnixNano", 0)) / 1e9)),
                    "matched": [{"name": s.get("name"), "duration_ms": ms(s.get("durationNanos", 0)),
                                 "attrs": {a["key"]: list(a["value"].values())[0] for a in s.get("attributes", [])}}
                                for s in spans[:3]]})
    return {"query": q, "since": since, "count": len(out), "traces": out}


def slowest(service, since="15m", limit=10):
    s = SERVICES.get(service, service)
    r = traceql(f'{{ resource.service.name = "{s}" && kind = server && span:duration > 100ms }} '
                '| select(name, span.http.route, span.http.response.status_code)', since, 100)
    rows = []
    for t in r.get("traces", []):
        sp = max(t["matched"], key=lambda m: m["duration_ms"]) if t["matched"] else {}
        at = sp.get("attrs", {})
        rows.append({"traceID": t["traceID"], "span": sp.get("name") or at.get("name"), "span_ms": sp.get("duration_ms"),
                     "route": at.get("http.route"), "status": None if at.get("http.response.status_code") in (None, "nil") else at.get("http.response.status_code"),
                     "trace_ms": t["duration_ms"], "trace_root": t["root"], "start": t["start"]})
    rows.sort(key=lambda x: -(x["span_ms"] or 0))
    r["traces"] = [dict(x, trace_link=link("tempo", x["traceID"], since)) for x in rows[:limit]]
    r.update(count=len(r["traces"]), note=f"slowest {s} server spans first (span_ms); trace_ms is the whole trace",
             explore=link("tempo", f'{{ resource.service.name = "{s}" && kind = server && span:duration > 500ms }}', since))
    return r


def errors(service, since="15m", limit=10):
    s = SERVICES.get(service, service)
    r = traceql(f'{{ resource.service.name = "{s}" && status = error }}', since, limit)
    r["explore"] = link("tempo", r["query"], since)
    return r


def issue(app, since="60m"):
    s = SERVICES.get(app, app)
    if s not in ISSUES:
        return {"error": f"unknown app {app}; use nextjs, nodejs or python"}
    out = []
    for title, sev, route, q, cause, path, fix in ISSUES[s]:
        r = traceql(q, since, 5)
        ex = r.get("traces", [])
        out.append({"issue": title, "severity": sev, "route": route, "matches": r.get("count", 0), "error": r.get("error"),
                    "example_trace": ex[0]["traceID"] if ex else None,
                    "max_duration_ms": max((t["duration_ms"] or 0) for t in ex) if ex else None,
                    "root_cause": cause, "file": path, "fix": fix, "explore": link("tempo", q, since)})
    return {"service": s, "since": since, "issues": out}


def trace(tid):
    d = get(TEMPO, f"/api/v2/traces/{urllib.parse.quote(tid)}")
    if "error" in d:
        return d
    batches = d.get("trace", d).get("resourceSpans", d.get("batches", []))
    spans = []
    for b in batches:
        svc = next((list(a["value"].values())[0] for a in b.get("resource", {}).get("attributes", [])
                    if a["key"] == "service.name"), "?")
        for ss in b.get("scopeSpans", []):
            for s in ss.get("spans", []):
                st = s.get("status", {})
                ev = []
                for e in s.get("events", [])[:3]:
                    detail = next((list(a["value"].values())[0] for a in e.get("attributes", [])
                                   if a["key"] in ("exception.type", "exception.message")), "")
                    ev.append(e.get("name", "") + (": " + str(detail)[:120] if detail else ""))
                spans.append({"service": svc, "name": s.get("name"), "kind": s.get("kind", "").replace("SPAN_KIND_", ""),
                              "start_ns": int(s.get("startTimeUnixNano", 0)),
                              "duration_ms": ms(int(s.get("endTimeUnixNano", 0)) - int(s.get("startTimeUnixNano", 0))),
                              "status": st.get("code", "").replace("STATUS_CODE_", "") or "UNSET", "events": ev})
    spans.sort(key=lambda s: s["start_ns"])
    t0 = spans[0]["start_ns"] if spans else 0
    for s in spans:
        s["offset_ms"] = round((s.pop("start_ns") - t0) / 1e6, 1)
    return {"traceID": tid, "span_count": len(spans), "services": sorted({s["service"] for s in spans}),
            "errors": [s for s in spans if s["status"] == "ERROR"][:10], "spans": spans[:60],
            "truncated": len(spans) > 60, "trace_link": link("tempo", tid)}


def tags(tag=None):
    if tag:
        d = get(TEMPO, f"/api/v2/search/tag/{urllib.parse.quote(tag)}/values")
        return d if "error" in d else {"tag": tag, "values": [v.get("value") for v in d.get("tagValues", [])][:100]}
    d = get(TEMPO, "/api/v2/search/tags")
    return d if "error" in d else {s["name"]: s.get("tags", [])[:60] for s in d.get("scopes", [])}


# ------------------------------------------------------------------------------------------------- diagnose
def diagnose(window="15m", since="60m"):
    """Ranked suggested issues across the platform. Bounded: ~25 small queries, compact output."""
    t_start = time.time()
    found = []

    def add(sev, service, title, evidence, cause, path, fix, links):
        found.append({"severity": sev, "service": service, "title": title, "evidence": evidence,
                      "probable_root_cause": cause, "look_at": path, "suggested_fix": fix, "links": links})

    # 1. Firing alerts
    al = alerts()
    for a in al.get("firing", []):
        add("critical" if a.get("severity") == "critical" else "warning", a.get("namespace") or "-",
            f"Alert firing: {a['alertname']}", {"summary": a.get("summary")}, "See the alert's runbook_url",
            "Prometheus rules", "Follow the runbook", {"alerts": f"{GRAFANA_PUBLIC}/alerting/list"})
    # 1b. Alert/recording rules that fail to evaluate (they can never fire)
    rd = get(PROM, "/api/v1/rules")
    for g in rd.get("data", {}).get("groups", []):
        for r in g.get("rules", []):
            if r.get("health") not in (None, "ok"):
                add("warning", "monitoring", f"Rule fails to evaluate: {r.get('name')} (group {g.get('name')})",
                    {"lastError": (r.get("lastError") or "")[:160]},
                    "The rule expression errors, so the alert can never fire (e.g. rate() over a __name__ regex drops "
                    "the metric name and the series collide)", f"the PrometheusRule with group {g.get('name')}",
                    "Fix the expression (e.g. aggregate per metric with label_replace or one rule per metric)", {})
    # 2. Hermes health
    hu = prom_query("max(hermes_gateway_up)")["result"]
    hermes_up = num(hu[0]["value"]) if hu else None
    if hermes_up != 1:
        add("critical", "hermes-gateway", "Hermes gateway not up", {"hermes_gateway_up": hermes_up},
            "Gateway starting/draining/crashed, or telemetry export failing", "hermes/base/deployment.yaml",
            "kubectl -n hermes logs deploy/hermes-gateway; see runbook HermesGatewayDown",
            {"dashboard": f"{GRAFANA_PUBLIC}/d/hermes-gateway"})
    # 3. Planted-issue TraceQL per app (evidence = matching trace)
    for svc, items in ISSUES.items():
        for title, sev, route, q, cause, path, fix in items:
            r = traceql(q, since, 3)
            if r.get("count"):
                t = r["traces"][0]
                add(sev, svc, f"{title} ({route})",
                    {"matching_traces_sampled": r["count"], "example_trace": t["traceID"], "trace_ms": t["duration_ms"],
                     "span": t["matched"][0]["name"] if t["matched"] else None},
                    cause, path, fix, {"trace": link("tempo", t["traceID"], since), "traceql": q})
    # 4. RED from span metrics: error ratio and latency vs 6h baseline (catches problems not in the list above)
    known = {(f["service"], f["title"].split(" (")[-1].rstrip(")")) for f in found}
    red_summary = {}
    for svc in APPS:
        rr = red(svc, window)
        red_summary[svc] = [{k: s[k] for k in ("span", "req_per_s", "error_ratio", "p95_s")} for s in rr["spans"][:3]]
        for s in rr["spans"]:
            hot_err = s["error_ratio"] >= 0.05 and s["req_per_s"] > 0
            p95, b = s["p95_s"] or 0, s["p95_baseline_6h_s"] or 0
            hot_lat = p95 >= 1 or (b and p95 > 2 * b and p95 > 0.3)
            if (hot_err or hot_lat) and not any(svc == k[0] and s["span"] and s["span"].split(" ")[-1] in k[1] for k in known):
                add("error" if hot_err else "latency", svc, f"RED anomaly on {s['span']}",
                    {k: s[k] for k in ("req_per_s", "error_ratio", "p95_s", "p99_s", "p95_baseline_6h_s")},
                    "Error ratio >= 5% or p95 >= 1 s / > 2x the 6 h baseline", "the service's handler for this route",
                    "Open the slowest/error traces for this span",
                    {"promql": f'histogram_quantile(0.95, sum by (le) (rate(traces_spanmetrics_latency_bucket{{service="{svc}", span_name="{s["span"]}"}}[5m])))'})
    # 5. Service graph failed edges
    g = graph(window)
    for e in g.get("edges", []):
        if (e.get("failed_per_s") or 0) > 0:
            ratio = round(e["failed_per_s"] / e["req_per_s"], 3) if e.get("req_per_s") else None
            add("error", e["server"], f"Failing calls {e['client']} -> {e['server']}",
                {"req_per_s": e["req_per_s"], "failed_per_s": e["failed_per_s"], "failed_ratio": ratio},
                "Calls on this edge fail (server errors or client timeouts); see the matching planted issues",
                "both services' handlers for this call", "Fix the server side, add timeouts/fallbacks on the client",
                {"promql": f'sum(rate(traces_service_graph_request_failed_total{{client="{e["client"]}", server="{e["server"]}"}}[5m]))'})
    # rank: severity, then services, keep compact
    found.sort(key=lambda f: (SEV.get(f["severity"], 9), f["service"], f["title"]))
    for i, f in enumerate(found, 1):
        f["rank"] = i
    per_app = {s: sum(1 for f in found if f["service"] == s) for s in APPS}
    return {"window": window, "trace_search_since": since, "took_s": round(time.time() - t_start, 1),
            "summary": {"issues": len(found), "per_app": per_app, "hermes_gateway_up": hermes_up,
                        "alerts_firing": [a["alertname"] for a in al.get("firing", [])]},
            "issues": found[:30], "red_top_spans": red_summary,
            "dashboards": {"hermes": f"{GRAFANA_PUBLIC}/d/hermes-gateway", "all": f"{GRAFANA_PUBLIC}/dashboards"},
            "hint": "links.trace opens the trace in Grafana Explore; get a link for any query with: obs.py link tempo|prometheus '<query>'"}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("diagnose"); a.add_argument("--window", default="15m"); a.add_argument("--since", default="60m")
    a.add_argument("--summary", action="store_true", help="one line per issue (for logs/cron)")
    sub.add_parser("hermes"); sub.add_parser("alerts"); sub.add_parser("targets")
    a = sub.add_parser("prom"); a.add_argument("query"); a.add_argument("--range"); a.add_argument("--step", default="60s")
    a = sub.add_parser("red"); a.add_argument("service"); a.add_argument("--window", default="15m")
    a = sub.add_parser("graph"); a.add_argument("--window", default="15m")
    a = sub.add_parser("traceql"); a.add_argument("query"); a.add_argument("--since", default="15m"); a.add_argument("--limit", type=int, default=20)
    for n in ("slowest", "errors"):
        a = sub.add_parser(n); a.add_argument("service"); a.add_argument("--since", default="15m"); a.add_argument("--limit", type=int, default=10)
    a = sub.add_parser("issue"); a.add_argument("app"); a.add_argument("--since", default="60m")
    a = sub.add_parser("trace"); a.add_argument("trace_id")
    a = sub.add_parser("tags"); a.add_argument("tag", nargs="?")
    a = sub.add_parser("dashboards"); a.add_argument("search", nargs="?", default="")
    a = sub.add_parser("panels"); a.add_argument("uid")
    a = sub.add_parser("gquery"); a.add_argument("kind", choices=["prometheus", "tempo"]); a.add_argument("query"); a.add_argument("--since", default="15m")
    a = sub.add_parser("link"); a.add_argument("kind", choices=["prometheus", "tempo"]); a.add_argument("query"); a.add_argument("--since", default="1h")
    x = p.parse_args()
    if x.cmd == "diagnose" and x.summary:
        r = diagnose(x.window, x.since)
        print(f"diagnose: {r['summary']['issues']} issues, per app {r['summary']['per_app']}, hermes_up={r['summary']['hermes_gateway_up']}, "
              f"alerts={r['summary']['alerts_firing']}, took {r['took_s']}s")
        for f in r["issues"]:
            print(f"#{f['rank']} [{f['severity']}] {f['service']}: {f['title']} trace={f['evidence'].get('example_trace', '-')}")
        return
    r = {
        "diagnose": lambda: diagnose(x.window, x.since), "hermes": hermes, "alerts": alerts, "targets": targets,
        "prom": lambda: prom_query(x.query, x.range, x.step), "red": lambda: red(x.service, x.window),
        "graph": lambda: graph(x.window), "traceql": lambda: traceql(x.query, x.since, x.limit),
        "slowest": lambda: slowest(x.service, x.since, x.limit), "errors": lambda: errors(x.service, x.since, x.limit),
        "issue": lambda: issue(x.app, x.since), "trace": lambda: trace(x.trace_id), "tags": lambda: tags(x.tag),
        "dashboards": lambda: dashboards(x.search), "panels": lambda: panels(x.uid),
        "gquery": lambda: gquery(x.kind, x.query, x.since), "link": lambda: {"url": link(x.kind, x.query, x.since)},
    }[x.cmd]()
    json.dump(r, sys.stdout, separators=(",", ":"), default=str)
    print()


if __name__ == "__main__":
    main()
