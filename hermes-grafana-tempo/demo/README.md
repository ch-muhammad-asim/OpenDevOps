# 🎬 Demo: ask Hermes what is going on

A short, copy-paste demo for a YouTube walkthrough: an AI agent answers production questions about this cluster in
plain English, with real numbers, trace IDs and Grafana links.

## 🎬 What this demo shows

Three small apps (Next.js → Node.js → Python) carry real, deliberate bugs. They send OpenTelemetry traces and span
metrics through the OpenTelemetry Collector into Grafana Tempo and Prometheus/Thanos. Hermes Agent runs in the same
cluster, and its read-only observability skill can query Tempo (TraceQL), the metrics API (PromQL) and Grafana.

You then ask Hermes a normal question — *"which service is failing?"*, *"why is this route slow?"* — and it runs the
queries itself, ranks what it finds, and points at the file to change.

Why it matters: in production Hermes is connected to Slack, so an engineer types the question in a channel and gets
the diagnosis there, without opening four dashboards first.

## 🧭 Architecture in short

- **Sources:** the three sample apps and the Hermes gateway itself, over OTLP/HTTP.
- **Pipeline:** OpenTelemetry Collector → Tempo (traces) and → Prometheus/Thanos (metrics, service graph, alerts).
- **Answers:** Grafana for humans, Hermes for questions; Hermes reads only Tempo `:3200`, the Thanos querier
  `:10902` and Grafana `:3000` with a Viewer token (no writes, no Prometheus `:9090`).

No diagram on this page: the full set lives in [`../docs/diagrams/`](../docs/diagrams/) (start with the
[learning map](../docs/diagrams/learning-map.md)); the component and telemetry-flow diagrams are in the
[top-level README](../README.md).

## ✅ Before you start

> ⚠️ **Set `DOMAIN` first:** `export DOMAIN=<your-domain>`. `scripts/load.sh` defaults to `example.com` and fails with
> `not healthy: https://tempo-nextjs.example.com/healthz` if you forget it. The full command is
> `cd hermes-grafana-tempo && DOMAIN=<your-domain> scripts/load.sh public`.

- [ ] The GKE cluster is up: `kubectl get nodes` shows 3 `Ready`.
- [ ] Every hostname answers: `https://grafana-tempo.<domain>` → `200`/`302`,
      `https://hermes-gke.<domain>` → `302` to the Hermes login, the three `tempo-*` app hosts → `200`.
- [ ] The platform checks pass (0 failures):
      `PROFILE=lab DOMAIN=<domain> scripts/verify.sh`
- [ ] The Hermes checks pass (0 failures): `DOMAIN=<domain> hermes/verify.sh`
- [ ] There is fresh traffic — run `DOMAIN=<your-domain> scripts/load.sh public`, wait about 30 s for ingest, then open
      Grafana → Explore → Tempo to confirm traces exist.
- [ ] The dashboards answer: `scripts/verify-dashboards.sh` prints `ERROR 0` and `NO_DATA 0` (start it before recording;
      it reads the admin password from the Secret and never prints it).

> ⏱️ **Span metrics and the service graph go stale.** The Tempo metrics-generator writes
> `traces_service_graph_*` and `traces_spanmetrics_*` while spans arrive; a few minutes after `load.sh` stops, the
> latest sample is older than a 15-minute window and *Tempo Service Graph* says "No data found in response". Run
> `DOMAIN=<your-domain> scripts/load.sh public` just before you open the service-graph or span-metric panels, or widen
> the time range (the Service Graph dashboard now opens on *Last 1 hour*, which covers a short gap).

`<domain>` is the domain you deployed with (`example.com` in the manifests). Everything below runs from
`hermes-grafana-tempo/`.

## 🔐 How to log in to Hermes

The login is generated at deploy time and lives only in a Kubernetes Secret. Read the username and password into your
terminal — never paste the values into a recording, a slide or a commit:

```bash
kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.password}' | base64 -d; echo
```

Open `https://hermes-gke.<domain>`, log in with provider **Username & Password**, then open **Chat**. Type (or paste)
one prompt at a time and wait for the answer.

## 💬 Copy-paste prompts

Each block is one prompt. Paste one, wait for the answer, then paste the next: the free model tier rate-limits, and
each turn can run several tool calls. The questions are grouped; on camera the health → diagnose → one drill-down
path is enough.

### 🩺 Health

"You have 30 seconds before the incident call — is the agent itself healthy, and what is already paging?"

```text
Is the Hermes gateway healthy, and which alerts are firing right now?
```

- **What Hermes should do:** run the observability skill twice — `obs.py hermes` for gateway health, then
  `obs.py alerts` for firing and pending alerts — and summarise.
- **What to look for:** `gateway_up=1`, state `running`, platform `api_server` up, then a list of alert names with
  their severity. Blur or hide the Grafana/Alertmanager URLs if you record it.

**🔎 Verify in Grafana**
- 📊 Dashboard: Dashboards → Hermes → **Hermes Agent gateway** → panels *Gateway* and *State* (time range: Last 15 minutes)
- 🧮 Query (Explore → Prometheus): `max(hermes_gateway_up)` and `ALERTS{alertstate="firing"}`
- ✅ Hermes is correct if: *Gateway* = 1 and *State* = `running`, and every alert name + service in the answer appears in the `ALERTS` result — nothing missing, nothing extra.

```text
Can you see the application traces? Show me recent traces for each app.
```

- **What Hermes should do:** run the observability skill once per service — `obs.py traceql` with
  `{ resource.service.name = "nextjs-web" }`, then `nodejs-orders`, then `python-inventory` — and quote a few recent
  traces per service with their trace IDs and links.
- **What to look for:** three groups, each with a trace ID, a service and a route, and a link that opens the trace — not
  one flat list and never "no traces".

**🔎 Verify in Grafana**
- 📊 Dashboard: Explore → **Tempo** → Search, *Service Name* `nextjs-web` (time range: Last 15 minutes)
- 🧮 Query (Explore → Tempo): `{ resource.service.name = "nextjs-web" }`, then the same with `nodejs-orders` and
  `python-inventory`
- ✅ Hermes is correct if: every trace ID it quotes opens with a root span in the service it named, and the three queries
  show roughly the traffic `load.sh` sent. The trace table lists the **root** span, so a `python-inventory` query shows
  rows whose Service column says `nextjs-web` — see [Troubleshooting](#-troubleshooting) for why.

### 🔥 Incidents

"This is the question an on-call engineer actually asks at 02:00."

```text
Diagnose the platform and suggest the top issues, with Grafana links.
```

- **What Hermes should do:** run `obs.py diagnose` once: firing alerts, failing rules, Hermes health, every planted
  issue with a matching trace, RED anomalies against a baseline and failing service-graph edges; then rank by user
  impact.
- **What to look for:** a short ranked list, each item with a number (p95, error ratio), a **trace ID**, the file to
  look at, a suggested fix and a Grafana link.

**🔎 Verify in Grafana**
- 📊 Dashboard: Dashboards → Tempo → **Tempo Service Graph** → panel *Service Topology*, plus Alerting → **Alert rules**
  (time range: Last 15 minutes)
- 🧮 Query (Explore → Prometheus): `sum by (service) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m])) / sum by (service) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))`
- ✅ Hermes is correct if: each service it ranks has that error ratio in Prometheus (within a few points), the failing
  edge it names is the red one in *Service Topology*, and every trace ID it quotes opens with an error span at the
  service it blames.

```text
Which service has the highest error rate in the last 15 minutes, and why?
```

- **What Hermes should do:** query the span metrics (`traces_spanmetrics_calls_total` by `service` and by
  `span_name`), pick the worst service, then explain the failing route from a trace.
- **What to look for:** one service named with an error ratio in percent, the route that drives it, the exception and
  the file to change.

**🔎 Verify in Grafana**
- 📊 Dashboard: Explore → **Prometheus**, split by `service` and then by `span_name` (time range: Last 15 minutes)
- 🧮 Query (Explore → Prometheus): `sum by (span_name) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m]))`
- ✅ Hermes is correct if: `nextjs-web` is the top series of the per-service ratio (~35% in a loaded lab, against ~19%
  and ~18% for nodejs and python), and the per-route errors load onto the routes it names (`POST /api/checkout`, then
  `GET /api/stock/[id]`).

```text
Show me the errors in nodejs-orders in the last 15 minutes with example trace IDs.
```

- **What Hermes should do:** `obs.py errors nodejs --since 15m`, group the errors by route and quote example trace
  IDs.
- **What to look for:** several trace IDs you can paste into Grafana → Explore → Tempo, grouped by cause instead of
  one flat list.

**🔎 Verify in Grafana**
- 📊 Dashboard: Explore → **Tempo** → paste one of the trace IDs from the answer (time range: Last 15 minutes)
- 🧮 Query (Explore → Tempo): `{ resource.service.name = "nodejs-orders" && status = error }`
- ✅ Hermes is correct if: the query returns about as many error traces as it claims (10 in 15 minutes in the recorded
  run) in the three groups it names — `POST /orders` TypeError, `GET /orders/:id` 502 from SKU-999,
  `GET /orders/:id/stock` 2 s timeout — and the quoted trace IDs open with a red span.

### 🐢 Latency

"Slow is harder than broken. This is where the traces earn their keep."

```text
Find the slowest traces for the nextjs app in the last 30 minutes and explain the root cause.
```

- **What Hermes should do:** `obs.py slowest nextjs --since 30m --limit 5`, then `obs.py trace <id>` on the slowest
  one and read the span tree.
- **What to look for:** a table of trace IDs with durations, then the span where the time actually goes — usually one
  hop below the app the question named — with a Grafana link.

**🔎 Verify in Grafana**
- 📊 Dashboard: Explore → **Tempo** → the slowest trace ID from the answer, waterfall view (time range: Last 30 minutes)
- 🧮 Query (Explore → Tempo): `{ resource.service.name = "nextjs-web" && duration > 2s }`
- ✅ Hermes is correct if: the query lists the same slow requests with the same trace IDs and ~2.2-2.3 s durations,
  and in the slowest trace the time sits in the nodejs `orders.build_report` span, not in the nextjs span above it.

```text
Show me the request path from nextjs-web to python-inventory and where time is spent.
```

- **What Hermes should do:** combine the service graph with `obs.py trace <id>` on a slow cross-service request and
  print the span tree with each hop's duration.
- **What to look for:** the full chain Next.js → Node.js → Python with milliseconds per hop, the failing hop and the
  timeout that cuts it short.

**🔎 Verify in Grafana**
- 📊 Dashboard: Dashboards → Tempo → **Tempo Service Graph** → panel *Service Topology*; the trace itself in
  Explore → **Tempo** (time range: Last 15 minutes)
- 🧮 Query (Explore → Tempo): `{ resource.service.name = "python-inventory" && name = "legacy_supplier_sync" }`
- ✅ Hermes is correct if: *Service Topology* shows `nextjs-web → nodejs-orders → python-inventory`, and in the trace
  the `legacy_supplier_sync` span is ~3 s while nodejs gives up at 2 s — so the upper hops are errors and python's own
  span is not.

```text
Which endpoint is slowest in python-inventory, and which file should I change to fix it?
```

- **What Hermes should do:** `obs.py slowest python --since 30m`, then `obs.py issue python` for the known pattern.
- **What to look for:** one endpoint, about 3 s per request, the span inside it (for example a synchronous supplier
  sync) and the file to change.

**🔎 Verify in Grafana**
- 📊 Dashboard: Explore → **Tempo** → the trace ID from the answer, span tree (time range: Last 30 minutes)
- 🧮 Query (Explore → Tempo): `{ resource.service.name = "python-inventory" && name = "GET /inventory/slow" }`
- ✅ Hermes is correct if: the spans come back at ~3.0 s, the child `legacy_supplier_sync` holds almost all of that
  time, and the file it names is `apps/python/main.py` with a `PLANTED ISSUE:` comment on that sync.

```text
Show me p99 and p95 latency and the error rate per service and route for the last 15 minutes, and explain the cause.
```

- **What Hermes should do:** run `obs.py prom` for the percentiles and `obs.py red` for the error ratio — both grouped by
  `service` and `span_name` — rank the routes, then open a trace of the worst one.
- **What to look for:** p95 and p99 side by side with an error ratio per route, then one named cause with a trace ID,
  and the judgement whether the slowness is the whole route or only its tail.

**🔎 Verify in Grafana**
- 📊 Dashboard: Explore → **Prometheus**, two queries, *Table* view (time range: Last 15 minutes)
- 🧮 Query (Explore → Prometheus): `histogram_quantile(0.99, sum by (le, service, span_name) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER"}[5m])))`
  and `sum by (service, span_name) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m])) / sum by (service, span_name) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))`
- ✅ Hermes is correct if: its p95 and p99 match those queries per route, and it reads p99 ≈ p95 on `GET /inventory/slow`
  (~3 s) and `GET /api/stock/[id]` (~2 s) as *every request on this route is slow*, not a few outliers — that is the
  baseline-vs-tail distinction from [📚 Concepts to know](#-concepts-to-know-15-minute-video).

### 🕸️ Service graph

"One picture, built from spans: who calls whom, and where the failures start."

```text
What does the service graph look like, and which edge is failing?
```

- **What Hermes should do:** `obs.py graph`, i.e. `traces_service_graph_request_total` and
  `..._failed_total` by client and server.
- **What to look for:** the request chain and one named edge with failed-per-second and a percentage, plus the
  judgement that the deepest failing hop is the origin, not a symptom.

The dashboard draws the topology from span metrics (one node per service, one edge per `client → server` pair, layered
layout). For a single request's path there is a built-in alternative: Explore → Tempo → query type **Service Graph**,
which builds the same picture from the spans of the traces in the time range.

**🔎 Verify in Grafana**
- 📊 Dashboard: Dashboards → Tempo → **Tempo Service Graph** → panel *Service Topology* (time range: Last 15 minutes)
- 🧮 Query (Explore → Prometheus): `sum by (client, server) (rate(traces_service_graph_request_failed_total[5m]))`
- ✅ Hermes is correct if: `nodejs-orders → python-inventory` is the edge with the largest failed/s (≈0.27 of
  ≈1.55 req/s, ~17% in a loaded lab), the user-facing edges fail at a similar or lower rate, and the graph names
  python-inventory as the origin rather than a downstream symptom.

### 📈 Trends

"Yesterday's p95, this hour's memory: the questions that need 30 days of metrics."

```text
Is anything throttled or running out of memory? Check CPU and memory trends.
```

- **What Hermes should do:** `obs.py trends`, then PromQL for CPU throttling, container memory against limits,
  restarts and OOM kills.
- **What to look for:** a plain answer — throttling total or not — and a memory curve with numbers, the limit, and an
  estimate of how long until it is reached.

**🔎 Verify in Grafana**
- 📊 Dashboard: Dashboards → Kubernetes / Compute Resources / **Namespace (Pods)**, namespace `tempo-apps`,
  panels *Memory Usage (w/o cache)* and *Memory Quota* (time range: Last 6 hours)
- 🧮 Query (Explore → Prometheus): `sum by (namespace, pod) (container_memory_working_set_bytes{namespace="tempo-apps", container!=""})`
- ✅ Hermes is correct if: the nodejs pod is the only rising line (~165 MB against a 256 MB limit, ~62% and climbing),
  nextjs and python stay flat, and `sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="tempo-apps"}[5m])) / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{namespace="tempo-apps"}[5m]))`
  stays near zero.

```text
Compare today's latency with yesterday for each service.
```

- **What Hermes should do:** `obs.py trends --range 1d` and report which comparison it could actually make.
- **What to look for:** per-service p95 numbers, and an honest note when the history is too short for day-over-day
  (a fresh lab has hours, not days) with the closest window instead.

**🔎 Verify in Grafana**
- 📊 Dashboard: Explore → **Prometheus**, range *Last 24 hours* (time range: Last 24 hours)
- 🧮 Query (Explore → Prometheus): `histogram_quantile(0.95, sum by (le, service) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER"}[1h])))`
- ✅ Hermes is correct if: it says it cannot compare day-over-day because the backend holds hours, not days, and the
  p95 values it does report match the same query over the last hour against the hour before; a confident
  "yesterday was X%" with no yesterday data is the wrong answer.

### 🛠️ Fixes

"End the demo on the code, not on the dashboard."

```text
Summarise the planted issues you can find and how to fix each one.
```

- **What Hermes should do:** `obs.py diagnose` plus `obs.py issue <app>` per app, then group the findings by service.
- **What to look for:** one short section per app, each bug with evidence, root cause, file and fix, and a suggested
  order of work.

**🔎 Verify in Grafana**
- 📊 Dashboard: Explore → **Tempo** → the trace IDs in the answer, plus the file on disk (time range: Last 15 minutes)
- 🧮 Query (Explore → Tempo): `{ status = error }`
- ✅ Hermes is correct if: every bug it lists has a matching `PLANTED ISSUE:` comment in the file it names, and the
  query shows the error or slow span it describes — 14 bugs across the three apps is the full set in this repo.

## 🧑‍✈️ Verify like a lead DevOps engineer (not vibe testing)

Hermes's answer is a lead, not proof. Every number, trace ID, file and alert it names is a claim you confirm against
the telemetry **before** you act on it.

**Trust, then verify:** ask → read the evidence Hermes cites → open the same thing in Grafana → confirm the numbers →
confirm the cause in code → decide.

**🗺️ Where to look in Grafana:**

| Where (folder → title) | What it shows in one line | Verifies |
|---|---|---|
| Hermes → **Hermes Agent gateway** | Gateway up/state, platform, cron and Hermes spans in one place | 🩺 health |
| Tempo → **Tempo Service Graph** | The `client → server` topology built from span metrics | 🔥 diagnose, 🐢 path, 🕸️ graph, 🛠️ fixes |
| Tempo → **Tempo / Writes**, **Tempo / Reads** | Tempo's own ingest and query path, when a trace never arrives | 🩺 health, 📈 trends |
| Explore → **Prometheus** | Any PromQL: RED per service and route, service-graph edges, container CPU/memory | 🔥, 🐢, 📈, 🕸️ |
| Explore → **Tempo** | TraceQL and trace-ID search: span trees, error spans, slow spans | 🐢 latency, 🛠️ fixes, errors |
| Alerting → **Alert rules** | What is firing or pending, for how long, on which service | 🩺 health, 🔥 diagnose |
| Alertmanager / **Overview** | Active alert groups and notifications sent | 🩺 health |
| Grafana Overview | Firing alerts plus Grafana's own request and latency stats | 🩺 health |
| Kubernetes / Compute Resources / **Namespace (Pods)**, namespace `tempo-apps` | CPU and memory against limits, throttling and restarts per pod | 📈 trends |

No app RED/span-metrics dashboard is installed in this stack (the Grafana dashboard list has the Tempo mixin set, the
Hermes and Kubernetes dashboards, and nothing per-app): those span metrics are one PromQL query away in Explore →
Prometheus, and every block below gives that query.

| Prompt group | What to open | What to confirm | Red flags |
|---|---|---|---|
| 🩺 Health | Grafana → Dashboards → **Hermes** → **Hermes Agent gateway** (*Gateway UP* and *State* panels); Alerting → firing alerts | Gateway UP = 1 and state `running`; the firing list matches what Hermes said, name for name; `max(hermes_gateway_up)` = 1 | an alert Hermes "sees" that Alertmanager does not show, or the reverse |
| 🔥 Incidents | the trace ID in the answer: Explore → Tempo → paste it; then `sum by (service) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m])) / sum by (service) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))` over the same window | the error span is in that trace with `status = error`, the exception event and the service Hermes named; the error ratio is the one in the answer | a trace ID that does not exist; a service that is not in this repo; an error ratio you cannot reproduce |
| 🐢 Latency | the slowest trace in the answer (Explore → Tempo waterfall); `histogram_quantile(0.95, sum by (le, service) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER"}[5m])))` | the span Hermes names is the one holding the time — usually one hop below the app in the question — and p95 matches | a "slow" span that takes a few ms; a p95 that does not match the dashboard |
| 🕸️ Service graph | **Tempo Service Graph** dashboard, and Explore → Tempo → **Service Graph**; `sum by (client, server) (rate(traces_service_graph_request_failed_total[5m]))` | the failing edge Hermes named is the one with errors, and it is the deepest failing hop, not a symptom | an edge that is not in the graph; a "root cause" that is really the caller |
| 📈 Trends | the same query over 24 h and 7 d; long windows are answered by the Thanos querier (Prometheus keeps 2 days locally, Thanos 30 days) | the direction and the size of the change; a day-over-day claim needs days of history — a fresh lab has hours | a window you did not ask for; a large percentage computed from two data points |
| 🛠️ Fixes | the file Hermes names, for example `apps/nodejs/server.js` | the `PLANTED ISSUE:` comment at that line, and that the root cause in the answer matches the code, before you change anything | a file or line that does not exist; a root cause the code does not support |

**Red flags — stop and re-check:** no trace ID or link in the answer; numbers that do not match the dashboard; a
service, file or metric that does not exist in this repo; a window different from the one you asked for; "no data"
straight after `load.sh` (wait ~30 s); a confident root cause with no evidence.

**Before you act:**

- [ ] The evidence is confirmed in Grafana, in the window you asked about.
- [ ] The blast radius is known: which services and users are affected, and what the change touches.
- [ ] The fix is reviewed in the code, not just described in the chat answer.
- [ ] The change goes through a PR and review — never applied straight from a chat answer.
- [ ] In production Hermes stays read-only (Viewer token, read-only skill) and a human approves every change.

In Slack the same rules apply: paste the Grafana link in the thread so everyone can verify the claim themselves.

## 📚 Concepts to know (15-minute video)

Every prompt above is one observability idea in practice. These are the ideas, two or three lines each, with the place
in this lab where you can see them. The deeper glossary (terms, tools, links) is
[`../docs/technologies/README.md`](../docs/technologies/README.md).

**📊 p50 / p95 / p99 — why the average lies.** A percentile is the value that share of requests stay under: p99 is the
slowest 1%. The average hides the tail, because one 3 s request among a hundred 100 ms requests barely moves it. *In
this lab:* `GET /inventory/slow` takes ~3.0 s for every request, so its p50, p95 and p99 sit on top of each other — the
whole route is slow. When p99 jumps far above p95 instead, only a few requests are slow (a timeout, a lock, a cold
start). *See:* Explore → Prometheus,
`histogram_quantile(0.99, sum by (le, service) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER"}[5m])))`
and the alert `TempoAppsHighLatencyP95` in Alerting → Alert rules.

**⚖️ Latency, throughput and error rate.** Three independent numbers: how long one request takes, how many arrive per
second, and what share fail. High throughput with rising latency is overload; steady throughput with a high error rate
is a broken dependency. *In this lab:* `load.sh public` sends 10 rounds; nextjs answers at the same rate while ~35% of
the responses are 5xx, so the problem is a dependency, not capacity. *See:* the RED queries below in Explore →
Prometheus.

**🔴 RED method.** Rate, Errors, Duration — one row per service or route, the three numbers that describe a
request-driven system. *In this lab:* rate is
`sum by (service) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))`, errors are the same
counter with `status_code="STATUS_CODE_ERROR"`, duration is the percentile query above. *See:* Explore → Prometheus (no
per-app dashboard is installed in this stack, so every block in this page gives the query).

**🟡 USE method.** Utilization, Saturation, Errors — one row per resource (CPU, memory, disk, network). RED says what
the users feel, USE says what the machine is doing. *In this lab:* the namespace dashboard shows memory against the
limit (utilization), CPU throttling (saturation) and restarts (errors) for `tempo-apps`. *See:* Dashboards →
Kubernetes / Compute Resources / **Namespace (Pods)**, namespace `tempo-apps`;
`container_memory_working_set_bytes`, `kube_pod_container_resource_limits`,
`container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total`.

**🎯 SLI, SLO, error budget, burn rate.** The SLI is the measured number (the share of server requests that did not
fail), the SLO is the target (99% over 30 days), and the error budget is the 1% you are allowed to spend. Burn rate is
how fast you spend it: 1x uses the budget in exactly 30 days, 14.4x uses 2% of it in one hour. *In this lab:*
`TempoAppsErrorBudgetFastBurn` fires above 14.4x over 1 h and 5 m, `TempoAppsErrorBudgetSlowBurn` above 6x over 6 h
and 30 m, both computed from `service:spanmetrics_server_error_ratio:rate1h` and `:rate6h`. *See:* Alerting → Alert
rules, group `tempo-apps.alerts`; the rules are in
[`apps/monitoring/prometheusrule.yaml`](../apps/monitoring/prometheusrule.yaml).

**🧵 Trace, span, root span, context propagation.** One request is one **trace**; each unit of work inside it (a query,
an HTTP call) is a **span**, with a start, a duration and a parent. The **root span** is the first one — the inbound
request — and `traceparent` is the header that carries the trace ID between services, which is why nextjs, nodejs and
python appear in one trace. *In this lab:* `{ resource.service.name = "python-inventory" }` returns the traces that
*contain* a python span, but the trace table shows the root span, so rows read `nextjs-web GET /api/stock/[id]`; open
the trace to see the python span in the waterfall, or set Search Options → *Table Format* to `Spans`. *See:* Explore →
Tempo.

**🕸️ Span metrics and the service graph.** The Collector's spanmetrics connector turns spans into counters and
histograms (`traces_spanmetrics_calls_total`, `traces_spanmetrics_latency_bucket`) so you can alert on them without
opening a trace; the Tempo metrics-generator writes the `client → server` pairs
`traces_service_graph_request_total` / `..._failed_total`. *In this lab:* that is what draws
`nextjs-web → nodejs-orders → python-inventory → sqlite`. *See:* Dashboards → Tempo → **Tempo Service Graph**.

**💎 Exemplars — from a metric to the trace.** An exemplar is a metric sample that carries a trace ID, so a spike on a
chart has a link to the request behind it. *In this lab:* the Prometheus data source points exemplars at Tempo
(`trace_id` → *View trace*), so a p99 spike opens the slow trace in one click. *See:* Explore → Prometheus with
*Exemplars* enabled.

**💧 Memory leak.** Working-set memory climbs request after request and never returns to its baseline, until the
container hits its limit, is OOMKilled and restarts — and the restart hides the leak for a while. *In this lab:*
`GET /orders` in nodejs copies a 1 MiB buffer per request (the planted leak), and `/stress/memory?mb=32&hold_s=5`
makes it visible in seconds. *See:* Dashboards → Kubernetes / Compute Resources / **Namespace (Pods)** → *Memory Usage
(w/o cache)* against *Memory Quota*; `container_memory_working_set_bytes`, and
`kube_pod_container_status_restarts_total` for the restart.

**🔥 CPU throttling.** When a container uses its whole CPU limit inside a 100 ms period, the kernel pauses it for the
rest of the period, so latency rises while CPU usage looks flat at the limit. *In this lab:* `GET /orders/report` runs
`pbkdf2Sync` on the event loop (the planted CPU hog) and `/stress/cpu?ms=500` does the same on demand. *See:* the same
dashboard, *CPU Utilisation (from limits)*;
`rate(container_cpu_cfs_throttled_periods_total[5m]) / rate(container_cpu_cfs_periods_total[5m])`.

**⏳ Timeouts and cascading failure.** A caller that gives up before its dependency answers turns a slow call into an
error one hop up, and the user sees the last hop's status. *In this lab:* python's `legacy_supplier_sync` takes 3 s,
nodejs aborts `/inventory/slow` after 2 s, and nextjs `/api/stock/[id]` passes that `504` to the user. *See:* Explore →
Tempo, `{ resource.service.name = "nextjs-web" && name = "GET /api/stock/[id]" }`.

**🪜 N+1 calls.** One request triggers one call per item instead of one batched call: the trace shows a staircase of
similar child spans, and the route gets slower as the list grows. *In this lab:* `GET /api/dashboard` makes 11
sequential `fetch` calls (1 list + 10 details, `app.orders.requests=11`). *See:* Explore → Tempo,
`{ resource.service.name = "nextjs-web" && kind = server } >> { resource.service.name = "nextjs-web" && kind = client } | count() > 10`.

**🔁 Retries.** Repeating a failed call hides the symptom and multiplies load: the failing dependency sees more
requests than the callers above it, and every retry waits out the same timeout again. *In this lab:* there is no retry
today, which is why one slow call is one `504`; add one and the 3 s supplier sync is hit three times per user request.
*See:* **Tempo Service Graph**, compare `traces_service_graph_request_total` on the failing edge with the user-facing
edge.

**🔢 Cardinality.** Every distinct label combination is a separate time series, so a label with unbounded values (a
trace ID, a user, a URL with an ID) multiplies series and memory in Prometheus and Grafana. *In this lab:* span metrics
stay bounded because the route template `/api/stock/[id]` is recorded instead of each concrete URL. *See:* Explore →
Prometheus, `count by (__name__) ({__name__=~"traces_spanmetrics.*"})` and the `span_name` values.

**🎲 Sampling.** Keeping a fraction of traces (head sampling at the start, tail sampling after the whole trace is
visible) cuts cost and storage, and can hide rare failures. *In this lab:* every span is kept and retention is what
bounds the volume; the tail-sampling pipeline is an opt-in example under [`helm/otel-collector/`](../helm/otel-collector/).

**🗄️ Retention.** How long data survives: Prometheus keeps 2 days locally, Thanos keeps 30 days on GCS, Tempo keeps
30 days (720 h) of blocks. A day-over-day question needs the Thanos window, not the local one — which is why prompt 7
in the tested run answered honestly that the lab had only hours of history. *See:* Explore → Prometheus over *Last 7
days*, and `retention: 720h` in [`helm/tempo/values.yaml`](../helm/tempo/values.yaml).

## 🎥 Suggested 15-minute video outline

| Time | Segment | What to show |
|---|---|---|
| 0:00–2:00 | Intro and architecture | The problem (four dashboards, no answer), the three apps, Collector → Tempo + Prometheus/Thanos, Hermes in the cluster, the diagram from [`../docs/diagrams/`](../docs/diagrams/) |
| 2:00–4:00 | Load the traffic | `DOMAIN=<your-domain> scripts/load.sh public`; expected mix of `200`, `500`, `502` and `504`; wait ~30 s; one Tempo search to prove traces arrive |
| 4:00–9:00 | The prompts | 🩺 health, 🩺 recent traces, 🔥 highest error rate, 🐢 slowest nextjs trace, 🕸️ failing edge — one per minute, read the answer aloud, no editing |
| 9:00–13:00 | Verify in Grafana | **Tempo Service Graph** (the chain), **Namespace (Pods)** with `tempo-apps` (memory and throttling), one trace waterfall, Alert rules; then `scripts/verify-dashboards.sh` printing `ERROR 0` |
| 13:00–15:00 | Concepts recap and Slack | p95 vs p99, RED vs USE, trace vs span, span metrics and the graph, error budget and burn rate; close on [💼 Slack in production](#-slack-in-production) |

Tips for the recording: run one prompt at a time (the free model tier rate-limits), keep the Service Graph on *Last
1 hour* or re-run `load.sh` just before the graph segment, and blur alertmanager/Grafana URLs if you show the Slack
thread.

## 💼 Slack in production

Nothing above is Grafana-specific: Hermes is the same agent, and Slack is one of its gateway platforms. Connect the
gateway to a Slack workspace, invite the bot to a channel, and engineers ask in the channel exactly the prompts
above — "is anything throttled?", "diagnose the platform" — and get the same answers with trace links inline.
Alerts can be routed into the same channel, so the question and the evidence live in one thread.

- Hermes documentation (platforms, gateway, skills): <https://hermes-agent.nousresearch.com/docs>
- The skill used here: [`hermes/base/skills/grafana-tempo-observability/`](../hermes/base/skills/grafana-tempo-observability/README.md)
- Nothing to add for the demo: no Slack token, no extra secret, nothing in this repo changes.

## 🧪 Tested results

Run on 2026-11-11 against a freshly loaded lab, one prompt at a time through the in-pod OpenAI-compatible API server
(same method as [`../hermes/chat-proof.sh`](../hermes/chat-proof.sh)), model `opencode/deepseek-v4.1-flash-free`.
"Used skill" means the answer shows the skill's `obs.py` command in its tool trace; "real data" means numbers, trace
IDs or Grafana links taken from the live cluster, not invented.

| # | Prompt | Answered | Used skill | Real data | Time |
|---|---|---|---|---|---|
| 1 | Hermes gateway health + firing alerts | ✅ | ✅ `hermes`, `alerts` | ✅ alert names, `gateway_up=1`, severity | 26 s |
| 2 | Diagnose the platform, top issues + links | ✅ | ✅ `diagnose` | ✅ p95/error ratios, 7 trace IDs, Grafana links | 37 s |
| 3 | Highest error rate in the last 15 minutes | ✅ | ✅ `diagnose`, PromQL | ✅ 34.6% / 19.3% / 18.1%, routes, trace ID | 27 s |
| 4 | Slowest nextjs traces + root cause | ✅ | ✅ `slowest`, `trace`, `issue` | ✅ 5 trace IDs with ms, span tree | 27 s |
| 5 | Request path nextjs-web → python-inventory | ✅ | ✅ `trace`, `graph`, `issue` | ✅ per-hop ms, service-graph rate | 42 s |
| 6 | Throttling and memory trends | ✅ | ✅ `trends`, `diagnose`, PromQL | ✅ throttled ratios, MB vs limit, growth rate | 45 s |
| 7 | Today's latency vs yesterday | ⚠️ | ✅ `trends --range 1d`, `prom`, `traceql` | ⚠️ real p95 numbers, but only ~1.5 h of history: no yesterday data to compare, and it says so | 35 s |
| 8 | Service graph and the failing edge | ✅ | ✅ `graph` | ✅ req/s and failed/s per edge, percentages | 20 s |
| 9 | Planted issues and how to fix each | ✅ | ✅ `diagnose`, `issue` | ✅ 14 bugs across 3 apps, trace IDs, files | 40 s |
| 10 | Slowest python endpoint + file to change | ✅ | ✅ `slowest`, `issue` | ✅ ~3.0 s endpoint, span name, file | 34 s |
| 11 | nodejs-orders errors with trace IDs | ✅ | ✅ `errors`, `issue` | ✅ 3 error groups, 9 trace IDs | 52 s |

Honest notes:

- **11 of 11 answered**, all with live data, none rate-limited on this run. A free tier can still answer 429 or
  "Free usage limit reached" at any time; that is expected, not a bug in the demo.
- **#7 is the only partial one:** the lab had about 1.5 hours of metrics history, so day-over-day was impossible.
  Hermes said that and compared the last 45 minutes with the 45 before, which is the honest answer. On a cluster with
  24 h+ of data the same prompt is a real comparison.
- **#8 is short** on purpose: one question, one edge. It is the fastest prompt in the set and a good 20-second clip.
- Times are one run on a shared free tier, not a benchmark; expect 20–60 s per answer because each turn runs one to
  several tool calls.

## 🛟 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Free usage limit reached`, or HTTP 429 in the answer | The free model tier is shared and rate-limited | Wait for the limit to reset, or pick another free model in the Hermes model picker. Do not switch the demo to a paid model |
| "No traces" / empty answers for the apps | No traffic yet, or ingest has not flushed | `DOMAIN=<your-domain> scripts/load.sh public`, wait ~30 s, ask again |
| Hermes seems down (login or chat fails) | Gateway, dashboard or bridge not ready | `DOMAIN=<domain> hermes/verify.sh`, then `kubectl -n hermes get pods` |
| Skill answers "endpoint not reachable" | The Thanos querier or Tempo is down, or a NetworkPolicy changed | `kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-query`, and see [`../hermes/README.md`](../hermes/README.md#-operations-and-troubleshooting) |
| Skill calls return 401 from Grafana | Grafana restarted without a database, so the Viewer token is gone | Re-run `hermes/deploy.sh`, which re-creates the account and token |
| Answers are slow but correct | Several tool calls per turn on a free model | Normal; ask one question at a time |
| A TraceQL query returns *nothing*, but the apps clearly sent traffic | `=` is an exact match on the whole value | Use the exact service name from the table below, `=~ "python.*"` for a prefix, or the Search tab's **Service Name** dropdown |
| The trace table shows nextjs rows for a python query | The table lists one row per trace and shows the **root** span | Open the trace for the waterfall, or set *Table Format* to `Spans` (below) |

### 🔤 Exact service names — `=` matches the whole value

The `service.name` values are exact strings, and TraceQL `=` is an exact match, not a substring match:

| Component in the waterfall | `service.name` to query |
|---|---|
| Next.js frontend | `nextjs-web` |
| Node.js orders API | `nodejs-orders` |
| Python inventory API | `python-inventory` |
| Hermes gateway's own spans | `hermes-gateway` |

`{ resource.service.name = "python" }` returns **nothing**: no service reports that name (the Kubernetes Service is
called `python`, but the SDK sets `service.name` to `python-inventory` from `OTEL_SERVICE_NAME`). Use one of:

- `{ resource.service.name = "python-inventory" }` — the exact name
- `{ resource.service.name =~ "python.*" }` — a regex, when you only remember part of the name
- Explore → **Tempo** → Search → *Service Name* dropdown — it lists the values that exist, so a typo cannot happen

### 🧵 A service query returns traces, and the table shows the root span

`{ resource.service.name = "python-inventory" }` returns every trace that **contains** a python-inventory span — not
only the spans python produced. The Search table has one row per trace and its Service and Name columns describe the
**root** span, so the row reads `nextjs-web | GET /api/stock/[id] | 3.01 s`: the user's request, which travelled
nextjs-web → nodejs-orders → python-inventory. Open the trace and the python span is there in the waterfall.

To list python's own spans instead, open Search → *Search options* (the Options tab) and set *Table Format* to
`Spans`. Each row is then a single span with its own service, name and duration — the fastest way to see that
`legacy_supplier_sync` alone holds ~3 s of that 3.01 s.

### 🎯 One query per app, and what you click into

| App | Query | Root rows you will see | Planted issue to open |
|---|---|---|---|
| `nextjs-web` | `{ resource.service.name = "nextjs-web" }` | `GET /api/dashboard`, `GET /api/stock/[id]`, `POST /api/checkout` — nextjs is the entry point, so these traces start in nextjs | `GET /api/dashboard`: 11 sequential `fetch` spans under `dashboard.load_orders` (N+1); `POST /api/checkout` with an empty body: 500 and a `TypeError` exception event |
| `nodejs-orders` | `{ resource.service.name = "nodejs-orders" }` | Its own roots (`GET /orders`, `GET /orders/7`, `GET /orders/report`, `POST /orders`, sent by `load.sh`), plus the `nextjs-web` traces it serves as `GET /api/dashboard` and `GET /api/stock/[id]` | `GET /orders` (1 MiB copied per request, the memory leak), `GET /orders/7` (502 from `SKU-999`), `GET /orders/report` (~1.3 s CPU hog) |
| `python-inventory` | `{ resource.service.name = "python-inventory" }` | Its own roots (`GET /inventory/items`, `GET /inventory/report`, `GET /inventory/fib`), plus the `nextjs-web` roots `GET /api/dashboard` and `GET /api/stock/[id]`, plus the `nodejs-orders` root `GET /orders/7` | `GET /api/stock/[id]` or `GET /orders/7/stock` → the `legacy_supplier_sync` span (~3 s) beside nodejs's 2 s timeout; `GET /inventory/items/SKU-999` → `KeyError`; `GET /inventory/report` → 21 `SELECT` spans |

More: [`../README.md`](../README.md#-operations-and-troubleshooting) and
[`../hermes/README.md`](../hermes/README.md#-operations-and-troubleshooting).
