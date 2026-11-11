# 📊 Grafana dashboards, explained

Every dashboard in this project's Grafana (<https://grafana-tempo.example.com>), in plain language: what it is
for, who looks at it and when, what each key panel measures, where the number comes from, the query behind it, what
good and bad look like, and a "try it" step with the demo apps.

## 📏 How metrics are measured

### Three kinds of metric

| Type | What it is | Example here | How you query it |
|---|---|---|---|
| **Counter** | A number that only goes up (resets to 0 on restart) | `traces_spanmetrics_calls_total` (requests seen), `container_cpu_usage_seconds_total` | Never plot it raw; use `rate()` or `increase()` |
| **Gauge** | A value that goes up and down, read as is | `hermes_gateway_up`, `container_memory_working_set_bytes`, `k6_vus` | Plot directly; `max`/`avg`/`sum` across series |
| **Histogram** | Counters per latency bucket (`_bucket{le="0.5"}` = requests that took ≤ 0.5 s), plus `_sum` and `_count` | `traces_spanmetrics_latency_bucket`, `k6_http_req_duration_milliseconds_bucket` | `histogram_quantile()` over `rate()` of the buckets |

([Prometheus metric types](https://prometheus.io/docs/concepts/metric_types/))

### `rate()` and `increase()`

`rate(x[5m])` is the per-second speed at which counter `x` grew over the last 5 minutes (it handles restarts).
`increase(x[5m])` is the same thing as a total over the window. Dashboards use `$__rate_interval`, a window Grafana
picks so that there are always enough samples. Rule of thumb: the time range must be at least 3 × the window, or the
panel shows "No data". ([Querying functions](https://prometheus.io/docs/prometheus/latest/querying/functions/#rate),
[Grafana `$__rate_interval`](https://grafana.com/docs/grafana/latest/datasources/prometheus/template-variables/#use-__rate_interval))

### Percentiles from histograms

p95 = the latency 95 % of requests were faster than. It is estimated from the buckets:

```promql
histogram_quantile(0.95, sum by (le, service) (rate(traces_spanmetrics_latency_bucket[5m])))
```

Keep `le` in the `sum by`, or the result is `NaN`. p50 is the typical request, p95/p99 the slow tail users notice;
averages hide the slow tail. The value is an estimate inside a bucket, so it moves in steps.
([Histograms and summaries](https://prometheus.io/docs/practices/histograms/))

### RED and USE

| Method | For | Signals | Where in these dashboards |
|---|---|---|---|
| **RED** | Services (requests) | **R**ate (requests/s), **E**rrors (failed/s or %), **D**uration (p95) | Stress tests, Tempo Reads/Writes, span metrics |
| **USE** | Resources (CPU, memory, disk, network) | **U**tilisation (% busy), **S**aturation (queued work, throttling, page faults), **E**rrors | Node Exporter / USE Method, Kubernetes / Compute Resources, Stress tests pod row |

### Span metrics (traces turned into numbers)

Tempo's [metrics-generator](https://grafana.com/docs/tempo/latest/metrics-generator/) reads every span the apps send
and writes RED metrics to Prometheus (remote write), so you get request rates and percentiles without adding metrics
code to the apps:

| Metric | Meaning | Labels |
|---|---|---|
| `traces_spanmetrics_calls_total` | Counter: spans seen | `service`, `span_name`, `span_kind`, `status_code` (`STATUS_CODE_ERROR` = failed) |
| `traces_spanmetrics_latency_bucket` | Histogram: span duration | same, plus `le` |
| `traces_service_graph_request_total` / `_failed_total` | Counters: calls from one service to another | `client`, `server` |

Use `service=` (not `service_name=`); look at one series' labels first if a query says "No data":
`{__name__=~"traces_spanmetrics.*"}`. Server spans (`span_kind="SPAN_KIND_SERVER"`) are the requests a service
answered. ([OpenTelemetry traces](https://opentelemetry.io/docs/concepts/signals/traces/),
[span kind](https://opentelemetry.io/docs/specs/otel/trace/api/#spankind))

### Where the numbers come from

| Source | What it measures | Metric prefix |
|---|---|---|
| Tempo metrics-generator | Span metrics and the service graph, from OpenTelemetry traces | `traces_spanmetrics_*`, `traces_service_graph_*` |
| cAdvisor (in the kubelet) | Container CPU, memory, throttling, network, disk | `container_*` |
| kube-state-metrics | Kubernetes objects: requests/limits, restarts, termination reasons, replicas | `kube_*` |
| node-exporter | Node CPU, memory, load, disk, network | `node_*`, `instance:node_*` (recording rules) |
| Hermes OTLP export | Hermes gateway health (via the OTel Collector `:8889`) | `hermes_*` |
| k6 OpenTelemetry output | Load-test requests, latency, virtual users (via the Collector) | `k6_*` |
| Tempo `/metrics` | Tempo's own ingest, query, storage and compaction health | `tempo_*`, `tempodb_*` |
| Kubernetes, Grafana, Alertmanager, Prometheus `/metrics` | Each component's own health | `apiserver_*`, `kubelet_*`, `grafana_*`, `alertmanager_*`, `prometheus_*` |

## 🗂️ Inventory

"Prometheus" is the Grafana data source with uid `prometheus`; it queries Thanos (Prometheus's last 2 days
plus 30 days from object storage). "Tempo" is uid `tempo`. The General dashboards are created by the
kube-prometheus-stack chart (`grafana.forceDeployDashboards`) as ConfigMaps in namespace `monitoring`: there is no
source file for them in this repository; change them through the chart version or its values
([`helm/kube-prometheus-stack/`](../../helm/kube-prometheus-stack/README.md)).

| Folder | Dashboard | uid | Source | Datasource | Data in the lab |
|---|---|---|---|---|---|
| Hermes | [Hermes Agent gateway](#hermes-agent-gateway) | `hermes-gateway` | [`hermes/base/hermes-gateway-dashboard.json`](../../hermes/base/hermes-gateway-dashboard.json) | Prometheus, Tempo | ✅ |
| Tests | [Stress tests](#stress-tests) | `stress-tests` | [`tests/dashboards/stress-tests.yaml`](../../tests/dashboards/stress-tests.yaml) | Prometheus, Tempo | ✅ k6 panels during/after a run |
| Tempo | [Tempo - Backend Work](#tempo---backend-work) | `eeht753h7e5tse` | [`tempo-mixin-backendwork.yaml`](../../helm/grafana/dashboards/tempo-mixin-backendwork.yaml) | Prometheus (+ unused Loki variable) | Blocklist, compaction, jobs; redaction and KEDA rows usually empty |
| Tempo | [Tempo / Livestore](#tempo--livestore) | `tempo-livestore` | [`tempo-mixin-livestore.yaml`](../../helm/grafana/dashboards/tempo-mixin-livestore.yaml) | Prometheus | Live traces, resources; lag, zones, KEDA production only |
| Tempo | [Tempo / Reads](#tempo--reads) | `tempo-reads` | [`tempo-mixin-reads.yaml`](../../helm/grafana/dashboards/tempo-mixin-reads.yaml) | Prometheus | Gateway, frontend, querier rows; partition, Memcached, external rows production only |
| Tempo | [Tempo / Resources](#tempo--resources) | `tempo-resources` | [`tempo-mixin-resources.yaml`](../../helm/grafana/dashboards/tempo-mixin-resources.yaml) | Prometheus | ✅ (every row shows the one `tempo-0` pod) |
| Tempo | [Tempo / Tenants](#tempo--tenants) | `tempo-tenants` | [`tempo-mixin-tenants.yaml`](../../helm/grafana/dashboards/tempo-mixin-tenants.yaml) | Prometheus | ✅ (`single-tenant`) |
| Tempo | [Tempo / Writes](#tempo--writes) | `tempo-writes` | [`tempo-mixin-writes.yaml`](../../helm/grafana/dashboards/tempo-mixin-writes.yaml) | Prometheus | Gateway, distributor rows; Envoy, Kafka, Memcached rows production only |
| Tempo | [Tempo Operational](#tempo-operational) | `a6175b9cc7ec20591890117c39580030` | [`tempo-mixin-operational.yaml`](../../helm/grafana/dashboards/tempo-mixin-operational.yaml) | Prometheus (+ unused Loki variable) | General, Maintenance, Read, Write, Backend, Compactor rows; empty by design: bad words (promtail/Loki), Ring/Memberlist, Memcached, Vulture |
| Tempo | [Tempo Service Graph](#tempo-service-graph) | `tempo-service-graph` | [`tempo-mixin-service-graph.yaml`](../../helm/grafana/dashboards/tempo-mixin-service-graph.yaml) | Prometheus | ✅ |
| General | [Alertmanager / Overview](#alertmanager--overview) | `alertmanager-overview` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Grafana Overview](#grafana-overview) | `6be0s85Mk` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / API server](#kubernetes-mixin-dashboards) | `09ec8aa1e996d6ffcd6817bbaff4db1b` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Compute Resources / Cluster](#kubernetes-mixin-dashboards) | `efa86fd1d0c121a26444b636a3f509a8` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Compute Resources / Multi-Cluster](#kubernetes-mixin-dashboards) | `b59e6c9f2fcbe2e16d77fc492374cc4f` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Compute Resources / Namespace (Pods)](#kubernetes-mixin-dashboards) | `85a562078cdf77779eaa1add43ccec1e` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Compute Resources / Namespace (Workloads)](#kubernetes-mixin-dashboards) | `a87fb0d919ec0ea5f6543124e16c42a5` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Compute Resources / Node (Pods)](#kubernetes-mixin-dashboards) | `200ac8fdbfbb74b39aff88118e4d1c2c` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Compute Resources / Nodes Overview](#kubernetes-mixin-dashboards) | `058020e04168bfdea0c52269cb699df2` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Compute Resources / Pod](#kubernetes-mixin-dashboards) | `6581e46e4e5c7ba40a07646395ef7b23` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Compute Resources / Workload](#kubernetes-mixin-dashboards) | `a164a7f0339f99e89cea5cb47e9be617` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Kubelet](#kubernetes-mixin-dashboards) | `3138fa155d5915769fbded898ac09fd9` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Networking / Cluster](#kubernetes-mixin-dashboards) | `ff635a025bcfea7bc3dd4f508990a3e9` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Networking / Namespace (Pods)](#kubernetes-mixin-dashboards) | `8b7a8b326d7a6f1f04244066368c67af` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Networking / Namespace (Workload)](#kubernetes-mixin-dashboards) | `bbb2a765a623ae38130206c7d94a160f` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Networking / Pod](#kubernetes-mixin-dashboards) | `7a18067ce943a40ae25454675c19ff5c` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Networking / Workload](#kubernetes-mixin-dashboards) | `728bf77cc1166d2f3133bf25846876cc` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Kubernetes / Persistent Volumes](#kubernetes-mixin-dashboards) | `919b92a8e8041bd567af9edab12c840c` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Node Exporter / AIX](#node-exporter-dashboards) | `7e0a61e486f727d763fb1d86fdd629c2` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | Empty (Linux nodes) |
| General | [Node Exporter / MacOS](#node-exporter-dashboards) | `629701ea43bf69291922ea45f4a87d37` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | Empty (Linux nodes) |
| General | [Node Exporter / Nodes](#node-exporter-dashboards) | `7d57716318ee0dddbac5a7f451fb7753` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Node Exporter / USE Method / Cluster](#node-exporter-dashboards) | `3e97d1d02672cdd0861f4c97c64f89b2` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Node Exporter / USE Method / Node](#node-exporter-dashboards) | `fac67cfbe174d3ef53eb473d73d9212f` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |
| General | [Prometheus / Overview](#prometheus--overview) | `9fa0d141-d019-4ad7-8bc5-42196ee308bd` | kube-prometheus-stack chart ConfigMap (`monitoring`) | Prometheus | ✅ |

There is no CoreDNS dashboard: GKE runs kube-dns, and its metrics are not scraped in this stack.

## 🧪 Check every panel at once

[`scripts/verify-dashboards.sh`](../../scripts/verify-dashboards.sh) answers "is any panel broken?" without clicking
through 30 dashboards. It reads every dashboard through the Grafana API, expands collapsed rows, fills each template
variable (the first value, or `All`), and runs each panel's Prometheus targets as instant queries over 15 minutes —
then again over 1 hour when a query returns nothing, because a 1-minute `rate()` on a sparse counter is `NaN`.
It is read-only and safe to re-run:

```bash
scripts/verify-dashboards.sh                                   # port-forward svc/grafana, admin Secret read in-cluster
GRAFANA_URL=https://grafana-tempo.<your-domain> scripts/verify-dashboards.sh
scripts/verify-dashboards.sh --dashboard tempo-service-graph   # one dashboard, repeatable
```

One line is printed per panel, then a summary, and the exit code is the number of `ERROR` panels, so CI can use it
directly. On this lab, after `load.sh public 10`:

```text
summary: 414 panels - OK 321, EXPECTED(empty by design) 42, NO_DATA 0, SKIP 50, ERROR 0
```

| Result | Meaning | What to do |
|---|---|---|
| `OK` | The query returned at least one row | — |
| `EXPECTED` | Empty by design, and the printed reason says why: a component this stack does not run, a counter Tempo 3.1 does not export, or a panel that filters `> 0` when there is nothing to show | Add a rule with its reason if you add another intentionally empty panel |
| `NO_DATA` | Empty without a rule | A real bug: fix the query, the selector or the dashboard variable |
| `SKIP` | Row, text, annotation and list panels: no data source behind them | — |
| `ERROR` | The data source returned an error: a stale data source uid, invalid PromQL, or a `nodeGraph` panel with duplicate node ids | A real bug; the summary must end with `ERROR 0` |

Run `DOMAIN=<your-domain> scripts/load.sh public` first: most application panels read span metrics and the service
graph, which exist only while spans arrive. **The Tempo metrics-generator writes those counters as spans arrive**, so
a few minutes after traffic stops the newest sample is older than a 15-minute window and the service-graph and
span-metric panels go empty — which is why *Tempo Service Graph* now opens on *Last 1 hour*, and why a demo re-runs
`load.sh` just before showing it.

The rules live in `EXPECTED_EMPTY` in the script, keyed on `<dashboard> / <panel> / <query>` and printed with their
reason, so an empty panel is never confused with a broken one. The per-dashboard version of the same list is in
[`helm/grafana/README.md`](../../helm/grafana/README.md).

---

## 🤖 Hermes folder

### Hermes Agent gateway

**What it is for:** shows whether the Hermes Agent gateway is up and healthy, and links to its spans in Tempo.
**Who and when:** whoever runs Hermes, when chat stops answering or an alert such as `HermesGatewayDown` fires.
**Source:** Hermes's built-in OTLP export (content-free: no prompts or replies) → OTel Collector → Prometheus;
spans → Tempo. Every query uses `max(...)` over the `$instance` variable so a restarted pod's old series do not
double-count. Details: [`hermes/`](../../hermes/README.md).

| Panel | Measures | Query | Good / bad |
|---|---|---|---|
| Gateway | Gauge: 1 while the gateway reports itself up | `max(hermes_gateway_up)` | Green **UP** (1) / red **DOWN** (0) or no data (pod or export gone) |
| State | The current state label | `max by (hermes_gateway_state) (hermes_gateway_state) == 1` | `running` / `starting`, `draining` for minutes |
| Active agents, Busy | Agent runs in progress; busy flag | `max(hermes_gateway_active_agents)`, `max(hermes_gateway_busy)` | Rises during a chat, back to 0 after |
| Restart requested | A restart is pending | `max(hermes_gateway_restart_requested)` | 0 / 1 for > 10 min (alert) |
| Platform up / degraded | Per platform (here `api_server`) | `max by (hermes_platform) (hermes_platform_up)` | UP and OK / DOWN or DEGRADED |
| Cron: jobs enabled, running, overdue, store writable, heartbeat age | Scheduler health | `max(hermes_cron_jobs_overdue)`, `max(hermes_cron_store_writable)` | overdue 0, writable 1 / overdue > 0 for 15 min, writable 0 (disk full) |
| Gateway up and active agents | History of the above | same queries over time | Flat line at 1 |
| Hermes gateway spans | Trace table from Tempo | TraceQL `{ resource.service.name = "hermes-gateway" }` | A `gateway.health_snapshot` span every ~15 s, a `gateway.lifecycle` span per start |

**Try it:** log in at <https://hermes-gke.example.com>, open **Chat** and ask a question; watch *Active
agents* and *Busy* go to 1 and back. Click a trace ID in the table to see a health span's attributes.

## 🧪 Tests folder

### Stress tests

**What it is for:** one screen for load tests: what k6 sent, how the apps answered, and what it did to their pods.
**Who and when:** whoever sizes the apps or checks a release, during and after a run of `tests/run.sh`
([`tests/`](../../tests/README.md)). Pick the run with the `testid` variable.
**Source:** k6's OpenTelemetry output (via the Collector), Tempo span metrics, cAdvisor and kube-state-metrics.

| Panel | Source | Query | Good / bad |
|---|---|---|---|
| k6 requests per second | k6 | `sum by (testid) (rate(k6_http_reqs_total[$__rate_interval]))` | Follows the scenario's ramp / flattens while VUs keep rising = saturated |
| k6 p95 latency | k6 | `histogram_quantile(0.95, sum by (le, testid) (rate(k6_http_req_duration_milliseconds_bucket[$__rate_interval])))` | load/soak < 500 ms, stress/spike < 2 s (the k6 thresholds) |
| k6 error rate (non-2xx) | k6 | non-2xx `rate(k6_http_reqs_total{status!~"2.."})` ÷ all | load/soak < 1 %, stress/spike < 5 % |
| k6 virtual users | k6 | `sum by (testid) (k6_vus)` | The scenario's shape (e.g. 20 → 150 VUs for `stress`) |
| App server p95 latency | Span metrics | `histogram_quantile(0.95, sum by (le, service) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER"}[$__rate_interval])))` | The server-side view of the same latency; < 1 s (alert threshold) |
| CPU used vs limit | cAdvisor + kube-state-metrics | `rate(container_cpu_usage_seconds_total[...])` vs `kube_pod_container_resource_limits{resource="cpu"}` | Below the limit line / at the limit = CPU-bound |
| CPU throttling | cAdvisor | throttled CFS periods ÷ all periods | ~0 % / > 25 % means the limit slows requests |
| Working-set memory vs limit | cAdvisor + kube-state-metrics | `container_memory_working_set_bytes` vs memory limit | Flat, well under the limit / climbing towards it (OOM risk; alert at 85 %) |
| Restarts, OOMKilled | kube-state-metrics | `increase(kube_pod_container_status_restarts_total[5m])`, termination reason `OOMKilled` | 0 / any restart or OOM kill |
| Service graph: failed calls per second | Span metrics | `sum by (client, server) (rate(traces_service_graph_request_failed_total[$__rate_interval]))` | 0 / a `nextjs-web → nodejs-orders` line while a dependency is down |
| Stress spans, Error traces | Tempo | `{ name =~ "stress.*" }`, `{ resource.service.namespace = "tempo-apps" && status = error }` | Click through to the exact slow or failed request |

**Try it:** `tests/run.sh nextjs stress` (90 s, in-cluster). Watch k6 p95 bend upwards while VUs ramp, CPU hit the
limit line and throttling rise: that bend is the breaking point. `tests/run.sh nodejs dependency` makes the failed-calls
panel show `nextjs-web → nodejs-orders`.

## 🔭 Tempo folder

These are the official [Tempo mixin](https://grafana.com/docs/tempo/latest/operations/monitor/) dashboards. They read
Tempo's own `/metrics` (`tempo_*`, `tempodb_*`) plus cAdvisor. They are written for **distributed** Tempo (production
profile); in the lab's single-binary Tempo every component is the one `tempo-0` pod, and rows for parts the lab does
not run stay empty by design: Kafka, Memcached, Envoy, Vulture (Tempo's synthetic checker), KEDA, zone-aware
live-stores, memberlist (the ring gossip of distributed Tempo) and Loki/promtail (log panels and their data-source
variable; this stack has no log backend). Use them when traces are missing or slow to appear, or when Tempo itself
alerts.

### Tempo Service Graph

**What it is for:** a live map of which service calls which, drawn from traces. **Who and when:** anyone new to the
system, or during an incident to see which hop fails.

| Panel | Measures | Query |
|---|---|---|
| Service Topology (node graph) | Every `client → server` pair seen in the time range | `traces_service_graph_request_total` grouped by `client`, `server` |

**How to read it:** you should see `nextjs-web → nodejs-orders → python-inventory`. A missing edge means one service
stopped sending spans or stopped propagating `traceparent`. For call rates and failures per edge, use Explore → Tempo →
**Service Graph**, which colours failing edges red.

The panel draws one node per service and one edge per `client → server` pair, with the layered layout (a call chain that
does not move) — a service that is both client and server appears once. If you only need the path of one request, Explore
→ Tempo → query type **Service Graph** is the built-in alternative: it builds the graph from the spans of the traces in
the range you already filtered.

**Stale series:** the metrics-generator writes `traces_service_graph_*` and `traces_spanmetrics_*` only while spans
arrive, so a few minutes after `load.sh` stops the latest sample falls outside a 15-minute window and the graph says
"No data found in response". The dashboard therefore opens on **Last 1 hour**; re-run `load.sh` before a demo, or pick
a wider range. **Try it:** open <https://tempo-nextjs.example.com/api/dashboard> a few times and refresh the dashboard
after ~1 minute.

### Tempo Operational

**What it is for:** Tempo's overall health on one page: Go runtime, maintenance, reads, writes, storage, compaction.
**Who and when:** the platform team, first stop for any Tempo problem.
**Empty by design in this stack:** the *bad words* panel (a promtail/Loki log metric), the Ring/Memberlist row
(memberlist gossip, distributed Tempo only), the Memcached row and the Vulture row; the `logsds` Loki variable has no
data source.

| Row: panel | Measures | Query (simplified) | Good / bad |
|---|---|---|---|
| General: go heap, goroutines, cpu, working set | Tempo process resources | `go_memstats_heap_inuse_bytes`, `rate(container_cpu_usage_seconds_total{pod=~"tempo-.*"})` | Stable saw-tooth / steady growth (leak) or at the limit |
| General: data volume free | Free space on Tempo's PVC | `kubelet_volume_stats_available_bytes` | Plenty free / falling towards 0 (lab: 10Gi, 24h retention) |
| Maintenance: blocklist length, retention | Blocks Tempo tracks; blocks deleted by retention | `tempodb_blocklist_length`, `increase(tempodb_retention_deleted_total)` | Flat once retention runs / ever-growing (retention not deleting) |
| Maintenance: maintenance errors, restarts | Compaction errors; pod restarts | `increase(tempodb_compaction_errors_total)`, `increase(kube_pod_container_status_restarts_total[5m])` | 0 / any |
| Read: queries/s and p99 latency (trace ID and search) | Query load and speed per stage | `rate(tempo_request_duration_seconds_count{route=~".*traces_traceid\|.*api_search.*"})`, p99 of `_bucket` | p99 under a few seconds / tens of seconds, 5xx codes |
| Write: spans received, distributor queue, push failures | Ingest volume and backlog | `rate(tempo_distributor_spans_received_total)`, `tempo_distributor_queue_length` | Follows app traffic, queue ~0 / growing queue, push failures > 0 |
| Write: generator spans/s | Spans feeding span metrics | `rate(tempo_metrics_generator_spans_received_total)` | ≈ spans received / 0 means no span metrics |
| Backend: requests and latency by operation | Object storage calls (local disk in the lab, GCS in production) | `rate(tempodb_backend_request_duration_seconds_count)` | Low latency, 2xx / errors, rising latency |
| Compactor: objects/bytes written, blocks compacted | Compaction progress | `rate(tempodb_compaction_objects_written_total)`, `increase(tempodb_compaction_blocks_total[5m])` | Steady activity / none while blocks pile up |

**Try it:** run `DOMAIN=<your-domain> scripts/load.sh public 20` and watch *Spans Received* and *Generator Spans/second* rise together.

### Tempo / Writes

**What it is for:** the write path: is every span the Collector sends accepted and stored?
**Who and when:** when traces are missing, or the Collector logs export errors.

| Row: panel | Measures | Query (simplified) | Good / bad |
|---|---|---|---|
| Gateway: QPS, latency | OTLP push requests and their p99 | `rate(tempo_request_duration_seconds_count{route=~"...traceservice_export\|otlp_v1_traces"})` by status | 2xx only, p99 low / 4xx-5xx, rising latency |
| Distributor: spans/s, bytes/s, latency | Accepted spans and push p99 | `rate(tempo_receiver_accepted_spans)`, `histogram_quantile(0.99, ... tempo_distributor_push_duration_seconds_bucket)` | Matches app traffic / drops to 0 |
| Discarded spans | Spans rejected, by reason | `rate(tempo_discarded_spans_total) by (reason)` | No data or 0 / any (limits hit, traces too large) |
| Kafka produced records, Kafka writes | Distributor → Kafka (production only) | `rate(tempo_distributor_produce_records_total)`, `..._produce_failures_total` | Empty in the lab; production: failures 0 |
| Envoy, Memcached, Backend - Compactor | Proxy, cache and storage writes | `envoy_*`, `tempo_memcache_*`, `tempodb_backend_*{operation=~"PUT\|POST"}` | Envoy/Memcached empty in this stack |

**Try it:** open <https://tempo-python.example.com/inventory/report> a few times; the distributor
spans/s line steps up (each request creates one SQL span per row).

### Tempo / Reads

**What it is for:** the query path, from Grafana's request down to storage. **Who and when:** when Explore → Tempo is
slow or a trace "is not found".

| Row: panel | Measures | Query (simplified) | Good / bad |
|---|---|---|---|
| Gateway / Query Frontend / Querier: QPS, latency | Queries by status and their p99 per stage | `rate(tempo_request_duration_seconds_count{route=~"api_.*"})` by status, p99 × 1000 (ms) | 2xx, p99 ≲ 1–3 s / 5xx, p99 tens of seconds |
| Livestore: QPS, latency, pending queue, completed blocks | Recent-trace lookups and block completion | `tempo_live_store_complete_queue_length`, `rate(tempo_live_store_blocks_completed_total)` | Queue near 0 / growing |
| Livestore partitions: lag | Kafka consumer lag (production only) | `tempo_ingest_group_partition_lag_seconds` | Empty in the lab; production: seconds, not minutes |
| Memcached, Backend, External requests | Cache, storage GETs, external endpoints | `tempo_memcache_*`, `tempodb_backend_*{operation="GET"}` | Backend 2xx; others empty in this stack |

**Try it:** search `{ status = error }` in Explore → Tempo, then watch the Query Frontend QPS and latency move.

### Tempo / Livestore

**What it is for:** the part of Tempo that holds the most recent traces in memory before they become blocks.
**Who and when:** production on-call when new traces appear late or live-stores push back.
In the lab only *Live traces*, *Live trace memory* and the resource row have data.

| Row: panel | Measures | Good / bad |
|---|---|---|
| Triage cockpit: read p99, read QPS, max ingest lag, backpressure, complete queue | One-glance health per zone | Lag in seconds, backpressure 0 / lag growing, backpressure > 0 |
| Consistency: ingest lag, worst partition, records/bytes processed | How far live-stores trail Kafka (`tempo_ingest_group_partition_lag_seconds`) | Flat and low / rising for one partition |
| Backpressure and readiness: seconds/s by reason, readiness, catch-up | Whether live-stores refuse work | 0 backpressure, all ready / any sustained backpressure |
| WAL completion: duration, blocks completed/failed, block size | Turning live data into blocks | Completions steady, failures 0 |
| Live traces and tenant pressure | `tempo_live_store_live_traces`, `tempo_live_store_live_trace_bytes`, top tenants | Follows traffic / runaway growth (memory risk) |
| Resource pressure, Autoscaling/KEDA | CPU, memory, restarts, desired replicas | Below limits; KEDA rows empty unless KEDA is installed |

**Try it:** run `DOMAIN=<your-domain> scripts/load.sh public 20`; *Live traces* rises with traffic and falls back after the run.

### Tempo / Resources

**What it is for:** CPU, working-set memory and Go heap per Tempo component. **Who and when:** capacity planning,
and when a component is OOM-killed or throttled. In the lab every row shows the same single `tempo-0` pod.

| Panel (per component) | Query | Good / bad |
|---|---|---|
| CPU | `sum by (pod) (rate(container_cpu_usage_seconds_total{container="tempo"}[$__rate_interval]))` | Below the request most of the time / at the limit |
| Memory (working set) | `container_memory_working_set_bytes{container="tempo"}` | Below the limit (lab: 2Gi) / approaching it |
| Memory (Go heap in use) | `go_memstats_heap_inuse_bytes` | Saw-tooth / only rising |

**Try it:** compare the Tempo CPU line before and during `DOMAIN=<your-domain> scripts/load.sh public 50`.

### Tempo / Tenants

**What it is for:** per-tenant limits and usage. This stack has one tenant, `single-tenant`.
**Who and when:** production, when one team's traces hit a limit.

| Row: panel | Query | Good / bad |
|---|---|---|
| Tenant info: limits | `tempo_limits_overrides` or `tempo_limits_defaults` | Reference values |
| Ingestion: bytes/s, spans/s, live traces | `rate(tempo_distributor_bytes_received_total{tenant=...})` | Well below the limits / near them (spans get discarded) |
| Reads: queries/s (ID lookup, search) | `rate(tempo_query_frontend_queries_total) by (status)` | Successes only |
| Storage: blocklist length, outstanding compactions | `tempodb_blocklist_length`, `tempodb_compaction_outstanding_blocks` | Flat / growing backlog |
| Metrics generator: bytes/s, active series | `tempo_metrics_generator_registry_active_series` | Stable / exploding series (high-cardinality span names) |

**Try it:** check *Active series* after `DOMAIN=<your-domain> scripts/load.sh`; low-cardinality span names keep it stable.

### Tempo - Backend Work

**What it is for:** background jobs that keep storage tidy: blocklist polling, retention, compaction, redaction.
**Who and when:** production, when storage grows or old traces are not deleted.

| Row: panel | Query (simplified) | Good / bad |
|---|---|---|
| Blocklist maintenance: length, poll duration, retention | `tempodb_blocklist_length`, p99 of `tempodb_blocklist_poll_duration_seconds_bucket`, `increase(tempodb_retention_deleted_total)` | Retention deleting regularly / blocklist only growing |
| Jobs: active, completed, failed, retry, dropped, duration | `tempo_backend_scheduler_jobs_*` | Failed and dropped 0 |
| Redaction | `tempo_backend_scheduler_jobs_*{job_type="JOB_TYPE_REDACTION"}` | Usually empty: only used when traces are redacted |
| Compactions: outstanding blocks, objects/bytes written | `tempodb_compaction_outstanding_blocks` | Low and stable / growing backlog |
| Resources: backend-scheduler, backend-worker (+ KEDA autoscaling) | cAdvisor CPU/memory | Below limits; KEDA panels empty without KEDA |

**Try it:** leave the stack running for an hour and watch *Outstanding blocks* stay low while compactions run.

## 🧰 General folder

### Alertmanager / Overview

**What it is for:** are alerts arriving and are notifications delivered? **Who and when:** whoever owns alert routing,
when a page was expected but did not come.

| Panel | Query | Good / bad |
|---|---|---|
| Alerts | `sum(alertmanager_alerts) by (instance)` | A few (the always-on `Watchdog`) / a sudden jump |
| Alerts receive rate | `rate(alertmanager_alerts_received_total)`, `rate(alertmanager_alerts_invalid_total)` | Invalid 0 |
| Notifications send rate / duration (per integration) | `rate(alertmanager_notifications_total)`, `..._failed_total`, p99 of `alertmanager_notification_latency_seconds_bucket` | Failed 0, seconds / any failed (bad receiver secret or URL) |

**Try it:** `DOMAIN=<your-domain> scripts/load.sh public 50` drives the apps' error ratio up (the planted 500/502/504s);
`TempoAppsErrorBudgetFastBurn` goes pending in Prometheus (Alerting) and, if the load lasts long enough, fires and
reaches Alertmanager (receive rate rises).

### Grafana Overview

**What it is for:** Grafana's own health. **Who and when:** when dashboards load slowly or show errors.

| Panel | Query | Good / bad |
|---|---|---|
| Firing alerts, dashboards, build info | `grafana_alerting_result_total{state="alerting"}`, `grafana_stat_totals_dashboard`, `grafana_build_info` | Version and dashboard count as expected |
| RPS by status | `sum by (status_code) (irate(grafana_http_request_duration_seconds_count[1m]))` | Mostly 200 / many 5xx |
| Request latency p50/p99 | `histogram_quantile(0.99, ... grafana_http_request_duration_seconds_bucket)` | Sub-second / seconds |

**Try it:** open a few heavy dashboards (Tempo Operational) and watch RPS and p99 move.

### Prometheus / Overview

**What it is for:** is Prometheus scraping everything and keeping up? **Who and when:** when panels show "No data" or
gaps.

| Panel | Measures | Good / bad |
|---|---|---|
| Targets, Target sync, Scrape failures | Number of scrape targets, sync time, failed scrapes | Failures 0 / any (a target down or blocked by a NetworkPolicy) |
| Average scrape interval duration | Actual time between scrapes | ≈ the configured interval / much longer |
| Appended samples, Head series, Head chunks | Ingest volume and in-memory series (`prometheus_tsdb_head_series`) | Stable / sudden growth (a new high-cardinality label) |
| Query rate, Stage duration | Query load and how long evaluation takes | Low latency / slow queries |

**Try it:** Status → Targets in the Prometheus UI should match the *Targets* panel; all `up`.

### Kubernetes mixin dashboards

From the [kubernetes-mixin](https://github.com/kubernetes-monitoring/kubernetes-mixin) shipped by kube-prometheus-stack.
Sources: cAdvisor (`container_*`), kube-state-metrics (`kube_*`), the kubelet and the API server. Pick the cluster,
namespace, workload or pod with the variables at the top. USE view: *Utilisation* = usage ÷ capacity, *Requests /
Limits Commitment* = sum of requests or limits ÷ allocatable (over 100 % limits commitment is normal; over 100 %
requests commitment means pods cannot all be scheduled).

| Dashboard | One line |
|---|---|
| Compute Resources / Cluster | Cluster-wide CPU and memory use vs requests and limits, by namespace; network and storage I/O |
| Compute Resources / Multi-Cluster | The same across clusters (one cluster here) |
| Compute Resources / Namespace (Pods) | CPU and memory per pod in one namespace, vs requests/limits (e.g. `tempo-apps`) |
| Compute Resources / Namespace (Workloads) | The same grouped by Deployment/StatefulSet |
| Compute Resources / Node (Pods) | Which pods use a node's CPU and memory |
| Compute Resources / Nodes Overview | CPU and memory per node |
| Compute Resources / Pod | One pod's containers: CPU, throttling, memory, network |
| Compute Resources / Workload | One Deployment/StatefulSet across its pods |
| Kubelet | Kubelet health: running pods and containers, operation rates and latencies, volume and PLEG timings |
| API server | Kubernetes API availability, request rate, errors and latency (managed control plane metrics on GKE) |
| Networking / Cluster | Bytes and packets received/transmitted and dropped, by namespace |
| Networking / Namespace (Pods) | Network per pod in a namespace |
| Networking / Namespace (Workload) | Network per workload in a namespace |
| Networking / Pod | One pod's network |
| Networking / Workload | One workload's network |
| Persistent Volumes | PVC space and inode use (`kubelet_volume_stats_*`); alert before 100 % |

**Try it:** open *Compute Resources / Namespace (Pods)* for `tempo-apps`, then open
<https://tempo-nodejs.example.com/orders/report> a few times: the `nodejs` pod's CPU spikes (the report is a
planted CPU hog).

### Node Exporter dashboards

From the [node-mixin](https://github.com/prometheus/node_exporter/tree/master/docs/node-mixin), source node-exporter.

| Dashboard | One line |
|---|---|
| Nodes | One node: CPU, load, memory, disk I/O and space, network |
| USE Method / Cluster | Utilisation and saturation of CPU, memory, network and disk across all nodes |
| USE Method / Node | The same for one node |
| AIX | For AIX hosts: empty here (Linux nodes) |
| MacOS | For macOS hosts: empty here (Linux nodes) |

**How to read the USE panels:** CPU utilisation under ~70 % with load-per-CPU under 1 is comfortable; memory major
page faults should stay near 0; any network drops or disk I/O saturation near 1 means the node is the bottleneck.
**Try it:** during `tests/run.sh nextjs stress`, *USE Method / Cluster* shows CPU utilisation climbing on the node that
runs the `nextjs` pod.

## 🧪 Try it: a 5-minute tour

1. Open <https://tempo-nextjs.example.com> and click **Report** 5–10 times (a CPU-bound report in
   `nodejs-orders`).
2. After ~1 minute, Explore → Prometheus:
   `histogram_quantile(0.95, sum by (le, service) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER"}[5m])))`;
   the `nextjs-web` and `nodejs-orders` p95 rise.
3. Click **Stock check** a few times (a 2 s upstream timeout → 504); error ratio:
   `service:spanmetrics_server_error_ratio:rate5m` goes up for `nextjs-web`.
4. Explore → Tempo: `{ resource.service.name = "nextjs-web" && status = error }`, open a trace and see where it failed.
5. Open **Tempo Service Graph** and **Kubernetes / Compute Resources / Namespace (Pods)** (`tempo-apps`) to see the
   same requests as a map and as CPU.

## 🔗 References

- Grafana: [dashboards](https://grafana.com/docs/grafana/latest/dashboards/), [Explore](https://grafana.com/docs/grafana/latest/explore/), [provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards)
- Tempo: [metrics-generator](https://grafana.com/docs/tempo/latest/metrics-generator/), [service graphs](https://grafana.com/docs/tempo/latest/metrics-generator/service_graphs/), [TraceQL](https://grafana.com/docs/tempo/latest/traceql/), [monitoring Tempo](https://grafana.com/docs/tempo/latest/operations/monitor/)
- Prometheus: [metric types](https://prometheus.io/docs/concepts/metric_types/), [querying basics](https://prometheus.io/docs/prometheus/latest/querying/basics/), [functions](https://prometheus.io/docs/prometheus/latest/querying/functions/), [histograms](https://prometheus.io/docs/practices/histograms/)
- OpenTelemetry: [traces](https://opentelemetry.io/docs/concepts/signals/traces/), [metrics](https://opentelemetry.io/docs/concepts/signals/metrics/), [Collector](https://opentelemetry.io/docs/collector/)
- k6: [OpenTelemetry output](https://grafana.com/docs/k6/latest/results-output/real-time/opentelemetry/)
- Methods: [The RED method](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/), [USE method](https://www.brendangregg.com/usemethod.html)
