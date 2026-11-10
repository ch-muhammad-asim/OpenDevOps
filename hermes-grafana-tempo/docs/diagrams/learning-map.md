# Visual learning map — Hermes + Grafana Tempo on GKE

A beginner-friendly companion to the [detailed architecture](architecture.mmd), [telemetry flow](telemetry-flow.mmd), and [lab vs production diagram](lab-vs-production.mmd). This explains **what each component does, how a request becomes a trace, and how to study the repository**. The diagrams are conceptual: refer to the linked component READMEs for exact ports, replicas, and deployment commands.

## 1. Start here: system learning map

Read **left to right**. Each group answers a different engineering question.

```mermaid
flowchart LR
  ROOT["Hermes + Grafana Tempo<br/>on Google Kubernetes Engine"]
  ROOT --> EDGE["1 · Platform & entry"]
  ROOT --> APP["2 · Sample services"]
  ROOT --> PIPE["3 · Observability"]
  ROOT --> AI["4 · AI-assisted SRE"]
  ROOT --> OPS["5 · Security & delivery"]

  EDGE --> GKE["GKE<br/>Runs and schedules pods"]
  EDGE --> CF["Cloudflare + Traefik<br/>Public HTTPS and ingress"]
  EDGE --> GCS["GCS + Workload Identity<br/>Keyless trace/metric storage"]

  APP --> NX["Next.js · nextjs-web<br/>Web entry point"]
  APP --> ND["Node.js · nodejs-orders<br/>Downstream orders"]
  APP --> PY["Python · python-inventory<br/>Inventory/data calls"]

  PIPE --> OTel["OpenTelemetry SDKs<br/>Create spans + trace context"]
  PIPE --> COL["OTel Collector<br/>Receive, enrich and export"]
  PIPE --> TEM["Tempo<br/>Store/query distributed traces"]
  PIPE --> PROM["Prometheus<br/>Metrics, rules and alerts"]
  PIPE --> THAN["Thanos<br/>30-day metrics via GCS"]
  PIPE --> GRAF["Grafana<br/>Traces, metrics and dashboards"]

  AI --> HG["Hermes gateway + dashboard<br/>Read-only SRE investigations"]
  AI --> LLM["Model provider<br/>OpenCode bridge or alternative"]
  AI --> SKILL["Observability skill<br/>Queries Tempo, Thanos, Grafana"]

  OPS --> SEC["NetworkPolicies + restricted pods<br/>Isolation and least privilege"]
  OPS --> TEST["k6 + seeded failures<br/>Observe latency, errors, OOM"]
  OPS --> DEP["Helm/Kustomize + scripts<br/>Deploy and verify"]

  classDef topic fill:#dbeafe,stroke:#2563eb,color:#1e3a8a
  classDef leaf fill:#dcfce7,stroke:#16a34a,color:#14532d
  class ROOT,EDGE,APP,PIPE,AI,OPS topic
  class GKE,CF,GCS,NX,ND,PY,OTel,COL,TEM,PROM,THAN,GRAF,HG,LLM,SKILL,SEC,TEST,DEP leaf
```

**Five questions to remember:** Where does traffic enter? Which app handles it? Where does telemetry go? How does an engineer investigate? What protects and tests the system?

## 2. Follow one request — do not confuse application traffic with telemetry

```mermaid
flowchart TB
  USER["Browser / student"] -->|"HTTPS"| CF["Cloudflare"]
  CF -->|"Origin HTTPS"| TR["Traefik ingress · GKE"]
  TR --> NX["Next.js · nextjs-web"]
  NX -->|"HTTP + traceparent"| ND["Node.js · nodejs-orders"]
  ND -->|"HTTP + traceparent"| PY["Python · python-inventory"]

  NX -.->|"OTLP traces"| COL["OpenTelemetry Collector"]
  ND -.->|"OTLP traces"| COL
  PY -.->|"OTLP traces"| COL
  COL -->|"Export traces"| TEM["Tempo"]
  TEM -->|"Trace blocks"| TGCS[("GCS: tempo-traces")]
  TEM -->|"Span metrics + service graph<br/>remote write"| PROM["Prometheus"]
  COL -->|"Metrics scrape endpoint"| PROM
  KM["Node + Kubernetes exporters"] -->|"Prometheus scrapes"| PROM
  PROM -->|"TSDB blocks via Thanos sidecar"| MGCS[("GCS: thanos-metrics")]
  MGCS -->|"Historical blocks"| STORE["Thanos Store Gateway"]
  PROM -->|"Recent data via Thanos sidecar"| QUERY["Thanos Query"]
  STORE --> QUERY
  PROM -->|"Alert rules"| ALERT["Alertmanager"]
  GRAF["Grafana"] -->|"TraceQL"| TEM
  GRAF -->|"PromQL"| QUERY
  HER["Hermes read-only skill"] -.->|"Diagnostic queries"| TEM
  HER -.->|"PromQL"| QUERY
  HER -.->|"Grafana Viewer queries"| GRAF

  classDef entry fill:#dbeafe,stroke:#2563eb,color:#1e40af
  classDef observe fill:#dcfce7,stroke:#16a34a,color:#14532d
  classDef storage fill:#ffedd5,stroke:#ea580c,color:#7c2d12
  class USER,CF,TR,NX,ND,PY entry
  class COL,TEM,PROM,STORE,QUERY,ALERT,GRAF,HER,KM observe
  class TGCS,MGCS storage
```

**How to read it:**

1. **Solid blue-path arrows are application requests.** A Next.js call can create downstream Node.js and Python calls. W3C `traceparent` associates their spans with one distributed trace.
2. **Dotted arrows from apps to the Collector are observability data, not application requests.** The OpenTelemetry SDKs export traces over OTLP.
3. **Tempo stores traces; Prometheus stores time-series metrics.** Tempo's metrics-generator produces metrics from spans and remote-writes them to Prometheus. Prometheus also scrapes the Collector and Kubernetes exporters.
4. **Thanos extends metrics retention.** The sidecar uploads Prometheus blocks to a dedicated GCS bucket; Thanos Query reads recent data through the sidecar and historical data through the Store Gateway. Compactor maintains retention and downsampling.
5. **Grafana visualizes, Hermes investigates.** Grafana queries Tempo and Thanos. Hermes's observability skill uses read-only queries; its separate LLM provider is for chat/analysis, **not** the source of traces.
6. **The log pipeline is limited.** The Collector's logs pipeline uses a debug exporter, not a searchable logs backend such as Loki. Do not promise full central log search.

The **Hermes gateway also exports content-free health spans/metrics and diagnostic logs** to the Collector. This does *not* send conversations or prompts through the telemetry pipeline. The default OpenCode free-model bridge depends on an external model service with availability/quota limits.

## 3. Lab profile versus proposed production profile

| Area | Lab example | Production configuration |
|---|---|---|
| GKE | Zonal, 3 × `e2-standard-2` | Regional, larger node pools and higher availability |
| Tempo | Single-binary deployment, PVC, GCS trace blocks | Distributed components; external Kafka-compatible queue required |
| OpenTelemetry Collector | One replica | Autoscaling Collector replicas |
| Prometheus | One replica, ~2 days local retention | High-availability replicas |
| Thanos | Sidecar + Query + Store + Compactor | HA-oriented deployment of metrics components |
| Storage | Separate GCS trace and metrics buckets, ~30-day application retention | Same separation, least-privilege bucket IAM |
| TLS edge | Cloudflare Full; Traefik default origin certificate | Prefer validated origin TLS: Cloudflare Full (strict) |

**Security nuance:** The lab's Cloudflare **Full** mode encrypts traffic to the origin but does **not authenticate the origin certificate**. Full (strict) with a valid origin certificate is preferable for production.

## 4. Understand planted failures through SRE signals

| Example | What to look for | Where |
|---|---|---|
| N+1 calls | Repeated child spans; total request time | Grafana Explore → Tempo |
| Unhandled exception | Error spans and HTTP 5xx | Tempo + Prometheus |
| Downstream timeout | Long wait on a dependency span | Trace waterfall |
| CPU saturation | CPU throttling, rising p95 latency | Prometheus / Stress tests dashboard |
| Memory pressure or OOM | Working set, memory limit and pod termination | Prometheus / Kubernetes |
| Dependency outage | Increased error rate and failed cross-service calls | Tempo service graph + metrics |

The repository's k6 scenarios deliberately create failures and sometimes change Kubernetes workloads. **Run disruption tests only in a disposable lab or staging cluster**, never unannounced on production.

## 5. Learning path and the authoritative README files

| Lesson | Read first | What you should be able to explain |
|---|---|---|
| Infrastructure and storage | [infra](../../infra/README.md) | GKE cluster, nodes, GCS and Workload Identity |
| Edge and isolation | [k8s](../../k8s/README.md) | Cloudflare, Traefik, TLS and NetworkPolicies |
| Request chain | [apps](../../apps/README.md) | Next.js → Node.js → Python and seeded issues |
| Telemetry pipeline | [OTel Collector](../../helm/otel-collector/README.md) | OTLP receivers, processors and exporters |
| Distributed tracing | [Tempo](../../helm/tempo/README.md) | Spans, TraceQL and span-derived metrics |
| Metrics and history | [Prometheus](../../helm/kube-prometheus-stack/README.md) + [Thanos](../../helm/thanos/README.md) | Scraping, rules, object-store history and querying |
| Explore and alert | [Grafana](../../helm/grafana/README.md) | Tempo/Thanos data sources and dashboards |
| AI-assisted diagnosis | [Hermes](../../hermes/README.md) | Gateway telemetry, model bridge and read-only skill |
| Deployment and evidence | [scripts](../../scripts/README.md) + [tests](../../tests/README.md) | Deploy, verify, load tests and what passed |

For deeper explanations and the pinned software versions, see [Every technology explained](../technologies/README.md). For detailed infrastructure flows, use [architecture.mmd](architecture.mmd), [telemetry-flow.mmd](telemetry-flow.mmd), and [lab-vs-production.mmd](lab-vs-production.mmd).

## 6. A simple way to teach the architecture

> "Our demo services intentionally contain slow requests and errors. OpenTelemetry traces requests across Next.js, Node.js and Python. The Collector forwards spans to Tempo, and Tempo turns those spans into useful metrics. Prometheus records metrics, Thanos stores their history, Grafana helps engineers explore the evidence, and Hermes can query that evidence with read-only access. All of this runs on GKE, with Cloudflare/Traefik at the edge and GCS for durable storage."

**Note:** A valid trace explains *where* time was spent and *where* errors appeared. It does not, on its own, prove the root cause. Confirm hypotheses with code, metrics and controlled tests.
