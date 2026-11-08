# 🧰 Every technology explained

A beginner's guide to every tool in [hermes-grafana-tempo](../../README.md): what it is, what problem it solves here,
why it was chosen, what else you could use, which version is pinned and where to find it in this repository. Start with
the story, keep the glossary open, then read the cards in any order.

## 🗺️ How it all fits together: one request's journey

Follow one click on the Next.js demo's **Report** link from the browser to an answer from the AI agent.

| # | Step | What happens | Technology |
|---|---|---|---|
| 1 | You click **Report** | The browser asks `tempo-nextjs.saqlainmushtaq.com` for `/api/report` | Browser |
| 2 | DNS and HTTPS | The name points to Cloudflare, which terminates HTTPS and forwards the request to the cluster's public IP | [Cloudflare](#cloudflare-dns--proxied-tls) |
| 3 | Into the cluster | Traefik accepts only Cloudflare's addresses and routes by hostname to the `nextjs` Service | [Traefik](#traefik), [GKE](#google-kubernetes-engine-gke) |
| 4 | The apps work | `nextjs-web` calls `nodejs-orders`, which calls `python-inventory`; each passes a `traceparent` header so all three join one trace | [Next.js](#nextjs), [Node.js](#nodejs--express), [Python](#python--fastapi), [OpenTelemetry](#opentelemetry) |
| 5 | Telemetry leaves the apps | Each app's OpenTelemetry SDK sends its spans over OTLP to the Collector | [OpenTelemetry](#opentelemetry) |
| 6 | One pipeline | The Collector batches the spans, adds Kubernetes labels and forwards them to Tempo | [OpenTelemetry Collector](#opentelemetry-collector) |
| 7 | Traces are stored | Tempo keeps the trace (30 days); its metrics-generator turns spans into request-rate, error and latency metrics | [Grafana Tempo](#grafana-tempo) |
| 8 | Metrics are stored | Prometheus stores those metrics plus CPU, memory and Kubernetes state, and checks alert rules | [Prometheus](#prometheus), [kube-prometheus-stack](#kube-prometheus-stack) |
| 9 | Long-term history | Thanos uploads Prometheus's data every 2 hours to a bucket and serves 30 days of it | [Thanos](#thanos), [Google Cloud Storage](#google-cloud-storage-gcs) |
| 10 | Keys without keys | Tempo and Thanos reach their buckets with Workload Identity: no key files anywhere | [Workload Identity](#workload-identity-federation-for-gke) |
| 11 | You look | Grafana shows the trace waterfall, the p95 latency rising and the service map | [Grafana](#grafana) |
| 12 | Something is wrong | A rule fires (for example p95 above 1 s); Alertmanager groups and routes it | [Alertmanager](#alertmanager) |
| 13 | Ask the agent | In Hermes's chat you ask "diagnose the platform"; its read-only skill queries Tempo, Thanos and Grafana and answers with numbers and trace IDs | [Hermes Agent](#hermes-agent), [OpenCode bridge](#opencode-bridge-and-opencode-free-models) |

Under all of this: Kubernetes NetworkPolicies decide which pod may talk to which, Pod Security Standards keep containers
unprivileged, and Helm and Kustomize install everything from versioned files.

## 📖 Glossary

| Term | Meaning |
|---|---|
| **Trace** | The full path of one request through all services, shown as a waterfall |
| **Span** | One timed step inside a trace (an HTTP call, a SQL query) with a name, start, duration, status and attributes |
| **Context propagation** | Passing the trace ID from service to service (the W3C `traceparent` header) so their spans join one trace |
| **Exemplar** | A trace ID attached to a metric sample, so a latency graph can link to an example slow trace |
| **RED** | Rate, Errors, Duration: the three signals that describe a service from the user's side |
| **USE** | Utilisation, Saturation, Errors: the three signals that describe a resource (CPU, memory, disk, network) |
| **SLO** | Service level objective: a target such as "99 % of requests succeed over 30 days" |
| **Error budget** | What the SLO allows to fail (1 % above); alerts fire when it is used up too fast ("burn rate") |
| **Cardinality** | How many different label combinations a metric has; too many (for example a user ID as a label) makes storage slow and expensive |
| **Retention** | How long data is kept before it is deleted (30 days here for traces and metrics) |
| **Downsampling** | Storing lower-resolution copies of old metrics (5-minute and 1-hour averages) so long time ranges load fast |
| **OTLP** | OpenTelemetry Protocol: the wire format apps use to send telemetry (gRPC port 4317, HTTP port 4318) |
| **Instrumentation** | Code that creates telemetry: automatic (a library patches frameworks) or manual (you call the SDK) |

---

## ☁️ Platform

### Google Kubernetes Engine (GKE)

| | |
|---|---|
| What it is | Google's managed Kubernetes: Google runs the control plane, you run your containers on node VMs |
| Problem it solves here | One place to run every component (apps, observability stack, Hermes) with self-healing and rolling updates |
| Why chosen | Managed control plane, built-in Workload Identity and Dataplane V2, simple to create and delete per lab |
| Benefits | Automatic upgrades (release channel), managed networking, integrates with GCS and Artifact Registry |
| Alternatives | Amazon EKS, Azure AKS, self-managed Kubernetes (kubeadm, k3s) |
| Version | Kubernetes 1.36, `regular` release channel; lab: 3 × `e2-standard-2` |
| In this repo | [`infra/create-cluster.sh`](../../infra/create-cluster.sh) |
| Official link | <https://cloud.google.com/kubernetes-engine/docs> |

### Dataplane V2 (Cilium)

| | |
|---|---|
| What it is | GKE's networking layer built on Cilium and eBPF (programs that run inside the Linux kernel) |
| Problem it solves here | Actually **enforces** NetworkPolicies; without it they are accepted but ignored |
| Why chosen | Built into GKE, chosen with one flag at cluster creation, no extra add-on to run |
| Benefits | Fast in-kernel packet filtering, policy logging, no kube-proxy iptables chains |
| Alternatives | Calico, upstream Cilium, Antrea |
| Version | Managed by GKE (enabled with `--enable-dataplane-v2`; can only be chosen at creation) |
| In this repo | [`infra/create-cluster.sh`](../../infra/create-cluster.sh) |
| Official link | <https://cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2> |

### Kubernetes NetworkPolicy

| | |
|---|---|
| What it is | Kubernetes firewall rules: which pods may connect to which pods and ports |
| Problem it solves here | Each namespace denies all traffic by default, then allows only the needed paths (for example Hermes → Thanos query `:10902`, but not Prometheus `:9090`) |
| Why chosen | Standard Kubernetes API, versioned in Git, enforced by Dataplane V2 |
| Benefits | Limits what an attacker can reach from a compromised pod; documents the real data flows |
| Alternatives | Cilium/Calico-specific policies (FQDN rules, layer 7), a service mesh (Istio, Linkerd) |
| Version | `networking.k8s.io/v1` |
| In this repo | [`k8s/networkpolicies.yaml`](../../k8s/networkpolicies.yaml), [`k8s/networkpolicies-egress.yaml`](../../k8s/networkpolicies-egress.yaml), [`hermes/base/networkpolicy.yaml`](../../hermes/base/networkpolicy.yaml) |
| Official link | <https://kubernetes.io/docs/concepts/services-networking/network-policies/> |

### Pod Security Standards (PSS)

| | |
|---|---|
| What it is | Built-in Kubernetes profiles (`privileged`, `baseline`, `restricted`) enforced per namespace by a label |
| Problem it solves here | Stops containers from running as root, gaining privileges or mounting the host |
| Why chosen | No extra software: the API server enforces it at admission |
| Benefits | A whole namespace is safe by default; violations are rejected before a pod starts |
| Alternatives | Kyverno, OPA Gatekeeper, GKE Policy Controller |
| Version | `pod-security.kubernetes.io/enforce: restricted` on most namespaces; `monitoring` is `privileged` (node-exporter needs host access) |
| In this repo | [`k8s/namespaces.yaml`](../../k8s/namespaces.yaml), [`hermes/base/namespace.yaml`](../../hermes/base/namespace.yaml) |
| Official link | <https://kubernetes.io/docs/concepts/security/pod-security-standards/> |

### Artifact Registry

| | |
|---|---|
| What it is | Google Cloud's private registry for container images |
| Problem it solves here | Stores the three sample-app images the cluster pulls |
| Why chosen | Same project as GKE, no pull secrets needed, immutable tags |
| Benefits | Immutable tags (a pushed tag can never be overwritten), deployments by `@sha256` digest |
| Alternatives | Docker Hub, GitHub Container Registry, Harbor |
| Version | Docker repository `tempo-apps`, created with `--immutable-tags` |
| In this repo | [`apps/build-push.sh`](../../apps/build-push.sh), [`apps/deploy-apps.sh`](../../apps/deploy-apps.sh) |
| Official link | <https://cloud.google.com/artifact-registry/docs> |

### Google Cloud Storage (GCS)

| | |
|---|---|
| What it is | Google's object storage: buckets of files reached over HTTPS |
| Problem it solves here | Holds 30 days of trace blocks (Tempo) and metric blocks (Thanos), far cheaper than disks |
| Why chosen | Durable, pay-per-use, lifecycle rules, works with Workload Identity |
| Benefits | No disk to size or fill up; data survives the cluster |
| Alternatives | Amazon S3, Azure Blob Storage, in-cluster S3 ([SeaweedFS](#seaweedfs-optional-fallback), MinIO) |
| Version | Two buckets per environment: `tempo-traces-<suffix>` and `thanos-metrics-<suffix>` |
| In this repo | [`infra/`](../../infra/README.md), [`helm/tempo/values-gcs.yaml`](../../helm/tempo/values-gcs.yaml), [`helm/thanos/`](../../helm/thanos/README.md) |
| Official link | <https://cloud.google.com/storage/docs> |

### Workload Identity Federation for GKE

| | |
|---|---|
| What it is | Lets a Kubernetes ServiceAccount act as a Google identity, so pods call Google APIs without key files |
| Problem it solves here | Tempo and Thanos write to their buckets with **no keys** stored anywhere |
| Why chosen | Keys can leak and must be rotated; Workload Identity has nothing to leak |
| Benefits | Access granted per ServiceAccount and limited to one bucket with IAM conditions (`ACCESS_MODE=conditional`) |
| Alternatives | Service-account JSON keys (not recommended), HMAC keys, a secrets manager |
| Version | GKE feature, enabled at cluster creation |
| In this repo | [`infra/`](../../infra/README.md), [`scripts/deploy.sh`](../../scripts/deploy.sh) |
| Official link | <https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity> |

## 🛠️ Install tooling

### Helm

| | |
|---|---|
| What it is | The Kubernetes package manager: a chart is a templated, versioned bundle of manifests |
| Problem it solves here | Installs the big third-party components (Prometheus stack, Tempo, Grafana, Collector, Traefik) with our values |
| Why chosen | Every upstream project publishes an official chart; upgrades and rollbacks are one command |
| Benefits | Pinned chart versions, one values file per profile, `helm diff`/`helm template` before applying |
| Alternatives | Kustomize only, Argo CD / Flux (GitOps on top of Helm), Jsonnet/Tanka |
| Version | Helm 3; charts pinned per release (see [Pinned versions](../../helm/README.md#-pinned-versions)) |
| In this repo | [`helm/`](../../helm/README.md) |
| Official link | <https://helm.sh/docs/> |

### Kustomize

| | |
|---|---|
| What it is | A template-free way to customise plain YAML: a base plus overlays that patch it |
| Problem it solves here | Our own manifests (Hermes, apps, Thanos, SeaweedFS) with a production base and a small lab overlay |
| Why chosen | Built into `kubectl` (`kubectl apply -k`), no templating language to learn |
| Benefits | The base stays valid YAML; ConfigMaps get content hashes so a change rolls the pods |
| Alternatives | Helm (templates), Jsonnet, cdk8s |
| Version | The Kustomize built into `kubectl` |
| In this repo | [`hermes/base/`](../../hermes/base/README.md), [`hermes/lab/`](../../hermes/lab/README.md), [`apps/`](../../apps/README.md), [`helm/thanos/`](../../helm/thanos/README.md) |
| Official link | <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/> |

## 🌐 Edge

### Cloudflare (DNS + proxied TLS)

| | |
|---|---|
| What it is | A DNS provider and reverse proxy in front of the cluster ("orange cloud" proxied records) |
| Problem it solves here | Public hostnames, the HTTPS certificate users see, DDoS protection, and hiding the origin |
| Why chosen | The zone already lives there; proxied records give free edge TLS |
| Benefits | Edge TLS with no certificate to manage in the lab (SSL mode **Full**); the origin accepts only Cloudflare's ranges |
| Alternatives | Google Cloud DNS + Cloud Load Balancing, AWS Route 53 + CloudFront |
| Version | SaaS; zone SSL mode Full (lab), Full (strict) recommended for production |
| In this repo | [`k8s/`](../../k8s/README.md), [`scripts/deploy.sh`](../../scripts/deploy.sh) (`dns` step) |
| Official link | <https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/> |

### Traefik

| | |
|---|---|
| What it is | An ingress controller: the reverse proxy that routes incoming HTTP(S) to Services by hostname |
| Problem it solves here | One LoadBalancer for every public host, plus middlewares (Cloudflare-only allow-list, security headers) |
| Why chosen | Small, Kubernetes-native CRDs (`IngressRoute`, `Middleware`), official Helm chart |
| Benefits | Per-route middlewares, TLS options, access logs, metrics for Prometheus |
| Alternatives | ingress-nginx, Envoy Gateway / Gateway API, GKE Ingress |
| Version | Traefik v3.7.17, chart `traefik/traefik` 42.3.1 |
| In this repo | [`k8s/traefik-values.yaml`](../../k8s/traefik-values.yaml), [`k8s/ingressroutes.yaml`](../../k8s/ingressroutes.yaml) |
| Official link | <https://doc.traefik.io/traefik/> |

### cert-manager (optional)

| | |
|---|---|
| What it is | Kubernetes add-on that requests and renews TLS certificates (for example from Let's Encrypt) |
| Problem it solves here | Origin certificates when Cloudflare runs in **Full (strict)** mode (`TLS_MODE=letsencrypt`); not installed in the lab |
| Why chosen | The standard for automated certificates in Kubernetes; DNS-01 works behind Cloudflare's proxy |
| Benefits | Automatic renewal, certificates as Kubernetes Secrets |
| Alternatives | Cloudflare Origin CA certificates, Google-managed certificates |
| Version | v1.21.3 (chart `jetstack/cert-manager`) |
| In this repo | [`k8s/cert-manager-values.yaml`](../../k8s/cert-manager-values.yaml), [`k8s/cluster-issuer.yaml`](../../k8s/cluster-issuer.yaml) |
| Official link | <https://cert-manager.io/docs/> |

## 📡 Telemetry

### OpenTelemetry

| | |
|---|---|
| What it is | The vendor-neutral standard for telemetry: APIs, SDKs and a protocol (OTLP) for **traces**, **metrics** and **logs** |
| Problem it solves here | The apps describe their work as spans once, in a standard format, and any backend can read it |
| Why chosen | Open standard backed by every observability vendor; one SDK per language |
| Benefits | No lock-in; **context propagation** joins services into one trace; **auto-instrumentation** covers HTTP and databases with no code changes, manual spans add business steps |
| Alternatives | Vendor agents (Datadog, New Relic), Jaeger/Zipkin client libraries (older), Prometheus client libraries (metrics only) |
| Version | JavaScript SDK 2.12.0 (`sdk-node` 0.301.0, `auto-instrumentations-node` 0.83.0), `@vercel/otel` 2.3.0 for Next.js, Python SDK 1.45.2 (instrumentation 0.66b2) |
| In this repo | [`apps/`](../../apps/README.md) (each app's `instrumentation` / `tracing` code) |
| Official link | <https://opentelemetry.io/docs/concepts/> |

Concepts at a glance: a **trace** is a request's path, made of **spans**; **metrics** are numbers over time; **logs**
are timestamped events. **SDKs** create them in the app, **exporters** send them over OTLP, and
**auto-instrumentation** patches common libraries so you get spans for free.

### OpenTelemetry Collector

| | |
|---|---|
| What it is | A standalone service that receives, processes and exports telemetry |
| Problem it solves here | The single OTLP entry point for apps, Hermes and k6: traces → Tempo, metrics → Prometheus |
| Why chosen | Apps stay simple (one endpoint); processing happens in one place |
| Benefits | `memory_limiter`, batching, retries and sending queues; Kubernetes labels via `k8s_attributes`; tail sampling possible |
| Alternatives | Grafana Alloy, Fluent Bit, Vector, sending straight to Tempo |
| Version | Image `otel/opentelemetry-collector-contrib` 0.165.0, chart `open-telemetry/opentelemetry-collector` 0.178.2 |
| In this repo | [`helm/otel-collector/`](../../helm/otel-collector/README.md) |
| Official link | <https://opentelemetry.io/docs/collector/> |

## 🔭 Traces

### Grafana Tempo

| | |
|---|---|
| What it is | Grafana's trace database: stores spans cheaply in object storage and finds them with **TraceQL** |
| Problem it solves here | Keeps 30 days of traces (720h) so you can find the slow or failing request behind any symptom |
| Why chosen | Needs only object storage (no index database); integrates with Grafana and Prometheus |
| Benefits | The **metrics-generator** turns spans into **span metrics** (RED per service and endpoint) and a **service graph** (who calls whom), with exemplars back to traces |
| Alternatives | Jaeger, Zipkin, Elastic APM, SigNoz |
| Version | Tempo 3.1.1; lab: chart `grafana-community/tempo` 3.2.1 (**single binary**: one pod does everything); production: chart `grafana-community/tempo-distributed` 3.27.0 (**microservices**: distributor, live-stores, block-builder, queriers… scaled separately, with Kafka) |
| In this repo | [`helm/tempo/`](../../helm/tempo/README.md), [`helm/tempo-distributed/`](../../helm/tempo-distributed/README.md) |
| Official link | <https://grafana.com/docs/tempo/latest/> |

TraceQL examples: `{ status = error }` (failed spans), `{ span:duration > 1s }` (slow spans),
`{ resource.service.name = "nextjs-web" } >> { resource.service.name = "python-inventory" }` (a call chain).

## 📈 Metrics and alerts

### Prometheus

| | |
|---|---|
| What it is | A time-series database that **pulls** (scrapes) metrics from targets and evaluates alert rules, queried with PromQL |
| Problem it solves here | Stores span metrics, Hermes health, CPU/memory and Kubernetes state; runs the SLO and alert rules |
| Why chosen | The de-facto standard for Kubernetes metrics; huge ecosystem of exporters and dashboards |
| Benefits | Simple model, powerful PromQL, remote-write receiver (Tempo pushes span metrics into it) |
| Alternatives | VictoriaMetrics, Grafana Mimir, Google Managed Service for Prometheus |
| Version | Prometheus v3.16.0; keeps 2 days locally (Thanos keeps 30) |
| In this repo | [`helm/kube-prometheus-stack/`](../../helm/kube-prometheus-stack/README.md) |
| Official link | <https://prometheus.io/docs/introduction/overview/> |

### kube-prometheus-stack

| | |
|---|---|
| What it is | The community Helm chart that installs Prometheus, Alertmanager, the Prometheus Operator, exporters, rules and dashboards together |
| Problem it solves here | A complete, working Kubernetes monitoring setup from one chart |
| Why chosen | Maintained by the Prometheus community; sensible default rules and dashboards (the "mixins") |
| Benefits | The **Prometheus Operator** turns **ServiceMonitor** (what to scrape) and **PrometheusRule** (alerts) objects into config; **node-exporter** (node CPU, memory, disk) and **kube-state-metrics** (pods, restarts, limits) included |
| Alternatives | Installing each piece by hand, Grafana Alloy + Mimir, a managed service |
| Version | Chart `prometheus-community/kube-prometheus-stack` 93.1.0; operator v0.95.1, kube-state-metrics v2.20.0, node-exporter v1.12.1 |
| In this repo | [`helm/kube-prometheus-stack/`](../../helm/kube-prometheus-stack/README.md) |
| Official link | <https://prometheus-operator.dev/> |

### Alertmanager

| | |
|---|---|
| What it is | Receives alerts from Prometheus, groups and de-duplicates them, and sends notifications |
| Problem it solves here | Routes `critical` alerts to paging and `warning` alerts to a chat channel (production) |
| Why chosen | Part of the Prometheus project and the chart |
| Benefits | Grouping, silences, inhibition (a critical alert mutes the matching warning) |
| Alternatives | Grafana Alerting, PagerDuty/Opsgenie rules directly |
| Version | Alertmanager v0.34.2 |
| In this repo | [`helm/kube-prometheus-stack/values.yaml`](../../helm/kube-prometheus-stack/values.yaml) (route tree) |
| Official link | <https://prometheus.io/docs/alerting/latest/alertmanager/> |

### Thanos

| | |
|---|---|
| What it is | Add-ons that give Prometheus long-term storage in object storage and one global query view |
| Problem it solves here | **30-day retention** without big disks: Prometheus keeps 2 days, Thanos keeps 30 in GCS |
| Why chosen | Works with plain Prometheus (a sidecar), stores data in cheap buckets, de-duplicates the HA Prometheus pair |
| Benefits | **Sidecar** uploads each 2-hour block; **store gateway** reads old blocks from the bucket; **querier** merges live and historical data behind one PromQL endpoint (Grafana uses it); **compactor** merges blocks, applies retention and **downsampling** (5 m, 1 h) so a 30-day graph loads fast |
| Alternatives | Grafana Mimir, VictoriaMetrics, Cortex, longer local Prometheus retention |
| Version | Thanos v0.42.5 |
| In this repo | [`helm/thanos/`](../../helm/thanos/README.md) |
| Official link | <https://thanos.io/tip/thanos/getting-started.md/> |

Why 30 days: long enough to compare this week with last month and to cover an SLO window, short enough to keep storage
costs low.

## 📊 Visualisation

### Grafana

| | |
|---|---|
| What it is | The web UI for dashboards, exploring traces and metrics, and alerting |
| Problem it solves here | One place to see traces (Tempo), metrics (Thanos/Prometheus) and alerts (Alertmanager) side by side |
| Why chosen | Native Tempo support (trace waterfall, service graph, TraceQL), the standard UI for Prometheus |
| Benefits | **Data sources** (`prometheus` → Thanos query, `tempo`, `alertmanager`) linked to each other (exemplars → traces, traces → metrics); **dashboards provisioned** from ConfigMaps, so they are code |
| Alternatives | Kibana, Jaeger UI (traces only), Datadog/New Relic UIs |
| Version | Grafana 13.3.0, chart `grafana-community/grafana` 14.4.0 |
| In this repo | [`helm/grafana/`](../../helm/grafana/README.md); every dashboard explained: [`docs/dashboards/`](../dashboards/README.md) |
| Official link | <https://grafana.com/docs/grafana/latest/> |

## 🪣 Optional storage

### SeaweedFS (optional fallback)

| | |
|---|---|
| What it is | A small open-source object store that speaks the S3 API, run inside the cluster |
| Problem it solves here | A fallback bucket store (`OBJECT_STORE=seaweedfs`) for clusters without cloud object storage; the lab and production use GCS |
| Why chosen | One small pod, S3-compatible, Apache-2.0 |
| Benefits | No cloud dependency; same Tempo/Thanos configuration style (S3) |
| Alternatives | MinIO, Ceph (Rook), cloud buckets |
| Version | SeaweedFS 4.52 |
| In this repo | [`helm/seaweedfs/`](../../helm/seaweedfs/README.md) |
| Official link | <https://github.com/seaweedfs/seaweedfs> |

## 🧪 Testing

### k6

| | |
|---|---|
| What it is | Grafana's load-testing tool: test scenarios written in JavaScript |
| Problem it solves here | Load, stress, spike, soak and failure tests of the sample apps, run inside the cluster |
| Why chosen | Scriptable, small, and its OpenTelemetry output sends results through the same Collector |
| Benefits | Results appear in the **Stress tests** dashboard next to pod CPU, memory and traces |
| Alternatives | Locust, JMeter, Gatling, Vegeta |
| Version | `grafana/k6` 2.3.0 |
| In this repo | [`tests/`](../../tests/README.md) |
| Official link | <https://grafana.com/docs/k6/latest/> |

## 🤖 AI agent

### Hermes Agent

| | |
|---|---|
| What it is | An open-source AI agent that runs as a server and talks to a language model |
| Problem it solves here | Lets you ask "what is wrong?" in plain language and get an answer based on real traces and metrics |
| Why chosen | Self-hosted, plugin and skill system, built-in content-free OpenTelemetry export of its own health |
| Benefits | **Gateway** (the agent server) with an in-pod OpenAI-compatible **API server**; web **dashboard** with chat behind a login; **skills** (here the read-only observability skill); native **OTLP exporter** for gateway health (no prompts or replies) |
| Alternatives | OpenWebUI, LibreChat, building on an agent framework (LangGraph, CrewAI) |
| Version | `nousresearch/hermes-agent` v0.23.0 (pinned by digest) |
| In this repo | [`hermes/`](../../hermes/README.md) |
| Official link | <https://hermes-agent.nousresearch.com/docs/> |

### OpenCode bridge and OpenCode free models

| | |
|---|---|
| What it is | OpenCode is an open-source coding agent with free models; the bridge wraps the OpenCode client in an OpenAI-compatible endpoint |
| Problem it solves here | Hermes's default model provider at no cost and with no OpenCode account key (`opencode-bridge` Deployment + Service in `hermes`) |
| Why chosen | Free models are only usable through the OpenCode client; the bridge lets Hermes use them like any API |
| Benefits | No key to manage; OpenCode's tools run in the bridge pod, not in the Hermes pod |
| Alternatives | [Cloudflare Workers AI](#cloudflare-workers-ai), paid OpenCode Zen/Go, any OpenAI-compatible API |
| Version | OpenCode CLI 1.19.5; default model `opencode/deepseek-v4.1-flash-free`; free-usage limits apply |
| In this repo | [`hermes/base/opencode-bridge.yaml`](../../hermes/base/opencode-bridge.yaml); bridge source [`opencode/kubernetes/bridge/`](../../../opencode/kubernetes/bridge/README.md) |
| Official link | <https://opencode.ai/docs/> |

### Cloudflare Workers AI

| | |
|---|---|
| What it is | Cloudflare's hosted language models, reached with an OpenAI-compatible API |
| Problem it solves here | The alternative model provider for Hermes (`MODEL_PROVIDER=cloudflare`), with a free daily allocation |
| Why chosen | Free tier, tool calling, simple token-based access |
| Benefits | No GPU to run; switch models by name |
| Alternatives | OpenCode free models, other hosted model APIs, a self-hosted model server (vLLM, Ollama) |
| Version | Default model `@cf/qwen/qwen3.8-27b` |
| In this repo | [`hermes/README.md`](../../hermes/README.md#-model-provider) |
| Official link | <https://developers.cloudflare.com/workers-ai/> |

## 🧑‍💻 The three sample apps

Each app has deliberate bugs (marked `PLANTED ISSUE:` in the code) that show up in Tempo. Details:
[`apps/`](../../apps/README.md).

### Next.js

| | |
|---|---|
| What it is | A React framework for web apps with server-side route handlers |
| Problem it solves here | `nextjs-web`: the front door of the traced chain (N+1 fan-out, timeout cascade, unhandled exception) |
| Why chosen | Popular full-stack framework with built-in OpenTelemetry support |
| Benefits | `@vercel/otel` sets up tracing in a few lines; Next.js itself emits spans for routes and rendering |
| Alternatives | Remix, Nuxt (Vue), SvelteKit |
| Version | Next.js 16.4.5, React 19.3.1, Node.js 26.13.0 |
| In this repo | [`apps/nextjs/`](../../apps/nextjs/README.md) |
| Official link | <https://nextjs.org/docs/app/guides/open-telemetry> |

### Node.js + Express

| | |
|---|---|
| What it is | Node.js runs JavaScript on the server; Express is its classic minimal web framework |
| Problem it solves here | `nodejs-orders`: the middle service (500 and 502 errors, timeout, CPU hog, memory leak) |
| Why chosen | The most common Node.js server stack; full OpenTelemetry auto-instrumentation |
| Benefits | `@opentelemetry/auto-instrumentations-node` traces HTTP and Express with no code changes |
| Alternatives | Fastify, NestJS, Koa |
| Version | Node.js 26.13.0, Express 5.3.0 |
| In this repo | [`apps/nodejs/`](../../apps/nodejs/README.md) |
| Official link | <https://opentelemetry.io/docs/languages/js/> |

### Python + FastAPI

| | |
|---|---|
| What it is | FastAPI is a modern Python web framework for APIs, served here by uvicorn |
| Problem it solves here | `python-inventory`: the last hop (N+1 SQL queries, slow endpoint, CPU hog, 500 error) |
| Why chosen | Popular, typed, async; first-class OpenTelemetry instrumentation |
| Benefits | `opentelemetry-instrumentation-fastapi` and `-dbapi` trace requests and each SQL query |
| Alternatives | Flask, Django, Litestar |
| Version | Python 3.14.10, FastAPI 0.162.2, uvicorn 0.54.0 |
| In this repo | [`apps/python/`](../../apps/python/README.md) |
| Official link | <https://opentelemetry.io/docs/languages/python/> |

## 🔗 Where to go next

- The whole project and quickstart: [top-level README](../../README.md)
- Every Grafana dashboard explained: [`docs/dashboards/`](../dashboards/README.md)
- Diagrams: [`docs/diagrams/`](../diagrams/README.md)
