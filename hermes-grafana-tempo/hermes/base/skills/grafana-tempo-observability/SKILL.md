---
name: grafana-tempo-observability
description: "Read-only Grafana, Tempo and Prometheus for this cluster: diagnose the platform, suggest issues with evidence, query traces/metrics, explain the OpenTelemetry setup."
version: 1.0.0
author: hermes-grafana-tempo
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Observability, Grafana, Tempo, Prometheus, OpenTelemetry, TraceQL, PromQL, SRE, Diagnose]
---

# Grafana Tempo observability (read-only)

Use this skill whenever the user asks about health, errors, latency, slow requests, traces, metrics, alerts,
dashboards, "what is wrong", "diagnose", "suggest issues", or how the OpenTelemetry / Tempo / Prometheus / Grafana
setup works. You CAN access these systems through the script below. Never guess numbers: run the script and quote
its output (numbers, trace IDs, links).

Script (Python stdlib only, prints compact JSON):

```
python3 /opt/skills/observability/grafana-tempo-observability/scripts/obs.py <command>
```

It is **read-only**: GET requests to the Prometheus and Tempo query APIs and Grafana's search/dashboard APIs, plus
Grafana's `/api/ds/query` (a query, Viewer role). It cannot change anything. Do not try other write APIs.

## Start here

| User asks | Run |
|---|---|
| "diagnose", "what's wrong", "suggest issues", "health of the platform" | `obs.py diagnose` |
| "trends", "last 30 days", "week over week", "getting worse?", "capacity", "error budget" | `obs.py trends` (add `--range 7d` for a shorter range) |
| Hermes itself: "is the gateway up", "which alerts fire" | `obs.py hermes` (and `obs.py alerts`) |
| "slowest traces for <app>" | `obs.py slowest <nextjs\|nodejs\|python> --since 15m --limit 5`, then `obs.py trace <id>` for the slowest |
| "errors in <app>" | `obs.py errors <app> --since 15m` |
| "planted issues / known bugs of <app>" | `obs.py issue <nextjs\|nodejs\|python>` |
| rate / errors / latency | `obs.py red <app>` (rate, error ratio, p95, p99, 6 h baseline per server span) |
| which service calls fail | `obs.py graph` (service graph: req/s and failed/s per edge) |
| any PromQL / TraceQL | `obs.py prom '<PromQL>'` (add `--range 1h`), `obs.py traceql '<TraceQL>' --since 30m` |
| dashboards / panels | `obs.py dashboards [search]`, `obs.py panels <uid>` |
| a link for the user | `obs.py link tempo '<TraceQL or trace ID>'`, `obs.py link prometheus '<PromQL>'` |
| scrape health | `obs.py targets` |

## How to answer (efficient)

1. Run ONE command that fits (usually `diagnose`), read its JSON, answer. Do not dump raw JSON to the user.
2. Drill down only where needed: `trace <id>` returns a compact span tree (max 60 spans) — never fetch more.
3. Keep time ranges small (`--since 15m`..`60m`) unless the user asks for more.
4. For each problem give: what (service, route), evidence (numbers + one trace ID), probable root cause, the file to
   look at, a suggested fix, and the Grafana link from the output (`links.trace`). Rank by severity:
   errors users see > latency > resource leaks.
5. If a command returns `"error"`, say which system failed (Prometheus/Tempo/Grafana) and show the message.

## Trends (30 days)

`obs.py trends` compares the current window with the previous one: week-over-week when 14+ days of history exist,
day-over-day with 2+ days, otherwise "last window vs the one before" (it says which in `comparison`; always tell
the user how much history there was, `history_available_h`). It ranks: error-ratio rises, p95 latency growth per
service and per route (top regressions), error-budget burn against the 99% SLO (`budget_used_pct`), TraceQL
p95 trends from Tempo, CPU/memory growth and container restarts. A latency trend on a service whose traffic also
jumped is flagged as likely load-driven. Long ranges use steps of 1 h-6 h. All metrics (PromQL, alerts, rules,
targets) come from the Thanos querier (`thanos-query.monitoring:10902`, 30 days); if `endpoint_note` is set, say
the metrics endpoint was unreachable.

## The services

| App (`obs.py` name) | OTel `service.name` | Calls | Code |
|---|---|---|---|
| nextjs | `nextjs-web` (Next.js BFF) | -> nodejs-orders | `apps/nextjs/app/api/*/route.ts` |
| nodejs | `nodejs-orders` (Express 5) | -> python-inventory | `apps/nodejs/server.js` |
| python | `python-inventory` (FastAPI, sqlite) | - | `apps/python/main.py` |
| hermes | `hermes-gateway` (this agent's gateway) | -> OTel Collector | `hermes/base/` |

The three apps have deliberate ("planted") bugs; `obs.py issue <app>` and `diagnose` know each one with its
TraceQL, root cause, file and fix: N+1 calls/queries, unhandled exceptions (TypeError, KeyError), a cascading
2 s timeout over a 3 s python endpoint, CPU hogs on the event loop, an unbounded memory cache, a hidden downstream
failure behind a 200.

## How the telemetry works (to explain the setup)

- **Instrumentation:** each app uses the OpenTelemetry SDK for its language (Next.js: `@vercel/otel`; Node.js:
  `@opentelemetry/sdk-node` + auto-instrumentations; Python: `opentelemetry-instrument` for FastAPI/sqlite) plus a
  few manual spans, attributes and events. Spans go over OTLP/HTTP to `otel-collector.observability:4318`.
- **Hermes** exports its own gateway health (metrics `hermes_*`, spans `hermes.gateway_health`, diagnostic logs)
  with its built-in monitoring exporter to the same Collector. No prompts or messages are exported.
- **OpenTelemetry Collector:** receives OTLP, sends traces to Tempo (OTLP gRPC) and exposes metrics on `:8889`,
  which Prometheus scrapes (`job="otel-collector"`; Hermes's job is in `exported_job`).
- **Tempo** stores traces (TraceQL search). Its **metrics-generator** turns spans into Prometheus metrics and remote-
  writes them: span metrics `traces_spanmetrics_calls_total`, `traces_spanmetrics_latency_bucket` (labels `service`,
  `span_name`, `span_kind`, `status_code`) and the service graph `traces_service_graph_request_total` /
  `..._failed_total` (labels `client`, `server`).
- **Prometheus** (kube-prometheus-stack) stores metrics and evaluates alert rules (`HermesGatewayDown`, ...).
- **Grafana** (public: https://grafana-tempo.saqlainmushtaq.com) has the `prometheus` and `tempo` data sources,
  Explore with TraceQL, and dashboards (e.g. "Hermes Agent gateway", uid `hermes-gateway`).

## Useful queries

- p95 latency per route: `histogram_quantile(0.95, sum by (service, span_name, le) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER"}[5m])))`
- error ratio: `sum by (service) (rate(traces_spanmetrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m])) / sum by (service) (rate(traces_spanmetrics_calls_total[5m]))`
- failing edges: `sum by (client, server) (rate(traces_service_graph_request_failed_total[5m])) > 0`
- Hermes: `max(hermes_gateway_up)`, `max by (hermes_platform) (hermes_platform_up)`
- TraceQL errors: `{ status = error }`; slow: `{ kind = server && span:duration > 1s }`; one app: `{ resource.service.name = "python-inventory" }`
