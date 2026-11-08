# 🛰️ OpenTelemetry Collector

The OpenTelemetry Collector (contrib distribution) as a Deployment. **Why:** one OTLP endpoint for the sample apps and
Hermes Agent; it adds Kubernetes metadata to every signal, batches it and routes traces to Tempo and metrics to
Prometheus, so no app talks to a backend directly.

**Status:** ✅ the lab profile runs on the lab cluster (chart 0.178.2, contrib 0.165.0, 1 replica). The production
profile renders with `helm template`, passes `helm lint` and `kubeconform -strict` (Kubernetes 1.36); the rendered
prod, lab and tail-sampling configs pass `otelcol-contrib validate` 0.165.0 (2026-11-08). The production profile has
not been run on a cluster.

## 🎚️ Profiles

| | Production ([`values.yaml`](values.yaml)) | Lab (`+` [`values-lab.yaml`](values-lab.yaml)) |
|---|---|---|
| Replicas | HPA 3–12 on CPU 70%, scale-down 1 pod/min after 5 min | 1, no HPA |
| PDB | `maxUnavailable: 1` | none (would block node drains) |
| Spread | Zone (hard) + hostname (soft), `matchLabelKeys: [pod-template-hash]` | none |
| Requests / limits | 500m / 1Gi, limit memory 2Gi | 100m / 256Mi, limit memory 512Mi |
| `memory_limiter` | check 1s, limit 80%, spike 20% | check 5s, limit 80%, spike 25% |
| `batch` | 2048 spans, max 4096, 1s | 1024, no max, 5s |
| Traces exporter | `tempo-distributor.observability:4317` | `tempo.observability:4317` |
| Sending queue | in memory, 250k spans (`sizer: items`), 10 consumers | Collector default: 1000 batches, 10 consumers |
| Graceful shutdown | 60s (queue drains) | 30s |

Shared by both: image tag + digest, PSS restricted security context, OTLP receivers, `k8s_attributes`, `resource`,
retry (5s → 30s, give up after 5 min), Prometheus exporter on 8889, ServiceMonitor, `health_check`.
No CPU limit in either profile on purpose: throttling adds export latency and backs up the queue; the CPU request
reserves capacity and drives the HPA, memory is the capped resource.

## 🧩 Components

| Name | What it does (one line) | Where defined | Security role |
|---|---|---|---|
| Receiver `otlp` | Accepts OTLP gRPC on `0.0.0.0:4317` and HTTP on `0.0.0.0:4318` | [`values.yaml`](values.yaml) `config.receivers` | ClusterIP only; the single telemetry entry point |
| Extension `health_check` | Liveness/readiness endpoint on the pod IP, port 13133 | `config.extensions` | Probe target only |
| Processor `memory_limiter` | Refuses data (retryable) before the pod reaches its memory limit | `config.processors` | Protects the node from overload |
| Processor `k8s_attributes` | Adds namespace, pod, deployment and node to each signal | `presets.kubernetesAttributes` | ClusterRole: read pods, namespaces, replicasets |
| Processor `resource` | Sets `k8s.cluster.name=hermes-grafana-tempo` | `config.processors` | — |
| Processor `batch` | Groups spans/points into export batches | `config.processors` | — |
| Exporter `otlp_grpc/tempo` | Traces to Tempo with retry and a bounded sending queue (plaintext, in-cluster) | `config.exporters` | No TLS inside the cluster |
| Exporter `prometheus` | OTLP metrics as a scrape endpoint on `0.0.0.0:8889` (port `prom-metrics`) | `config.exporters`, `ports.prom-metrics` | ClusterIP only |
| Exporter `debug` | Logs pipeline, `basic` verbosity (counts only, no bodies) | `config.exporters` | No log content written |
| HPA + PDB `otel-collector` (prod) | Scale on CPU; at most one pod down during voluntary disruptions | `autoscaling`, `podDisruptionBudget` | — |
| ServiceMonitor `otel-collector` | Scrapes self-metrics (`metrics`, 8888) and `prom-metrics` (8889) | `serviceMonitor` | — |

Pipelines: **traces** otlp → memory_limiter, k8s_attributes, resource, batch → Tempo; **metrics** same processors →
`prometheus` (pulled by Prometheus via the ServiceMonitor); **logs** same processors → `debug`. Span metrics are not
computed here: Tempo's metrics-generator does that. **One path for metrics:** the Collector does not remote-write.

Component names use the current spelling (`otlp_grpc`, `k8s_attributes`); the chart's old-name rewrite is a no-op.

## 📬 Sending queue

| Option | Decision | Why |
|---|---|---|
| In-memory queue, `sizer: items`, 250k spans | **Used (prod)** | Memory use is bounded in spans (≈ 250–500 MiB) inside the 2Gi limit; drains to Tempo on graceful shutdown (60s grace) |
| Persistent queue (`file_storage` on an `emptyDir`) | **Not used** | Starts fine with `readOnlyRootFilesystem` (checked with the 0.165.0 binary), but an `emptyDir` is deleted with the pod, and pod deletion is the common case here (rollouts, HPA scale-down, node drains). It only helps on container crashes, at the cost of disk I/O |
| Persistent queue on a PVC | Option for strict no-loss | `mode: statefulset` + `statefulset.volumeClaimTemplates` + `file_storage` extension; queued data then survives until the same pod returns |

Retry: 5s initial, 30s max interval; a batch is dropped after 5 min of Tempo being unavailable
(`otelcol_exporter_send_failed_spans_total` counts it). When the queue is full, new data is refused
(`otelcol_exporter_enqueue_failed_spans_total`).

## 🎯 Tail sampling (documented, not enabled)

[`tail-sampling-example.yaml`](tail-sampling-example.yaml) is a ready-to-use overlay: keep every trace with an
error status, every trace slower than 1s, and 10% of the rest (a trace is kept if any policy matches).

| Replicas receiving spans | How to use it |
|---|---|
| Exactly 1 (lab) | `-f values.yaml -f values-lab.yaml -f tail-sampling-example.yaml` |
| More than 1 (production) | Needs **trace-ID-aware load balancing**: otherwise the spans of one trace land on different pods and each pod decides on a partial trace. Run two tiers (below) |

Two-tier layout for production: tier 1 is this release with the `loadbalancing` exporter in place of
`otlp_grpc/tempo`; tier 2 is a second release (for example `otel-sampler`, with a headless Service) using this
overlay and exporting to Tempo. Tier-1 exporter (validated with `otelcol-contrib validate` 0.165.0):

```yaml
exporters:
  loadbalancing:
    routing_key: traceID          # all spans of a trace go to the same tier-2 pod
    protocol:
      otlp:
        tls: {insecure: true}
        sending_queue: {enabled: true}
    resolver:
      k8s:
        service: otel-sampler-headless.observability   # tier-2 headless Service
        ports: [4317]
```

The `k8s` resolver needs RBAC to list/watch EndpointSlices in `observability`. Trade-off: Tempo's metrics-generator
then sees only sampled traces, so span metrics and the service graph undercount; generate RED metrics in tier 1
(before sampling) if they must be exact.

## 🚀 Install

```bash
# Production
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector --version 0.178.2 \
  --namespace observability --create-namespace -f helm/otel-collector/values.yaml
# Lab
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector --version 0.178.2 \
  --namespace observability --create-namespace \
  -f helm/otel-collector/values.yaml -f helm/otel-collector/values-lab.yaml
```

Install after kube-prometheus-stack (ServiceMonitor CRD) and Tempo. `scripts/deploy.sh` selects the files with
`PROFILE=prod|lab`. The production HPA needs metrics-server (on by default on GKE).

| Sender | Endpoint |
|---|---|
| Apps (OTLP HTTP) | `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability:4318` |
| Apps (OTLP gRPC) | `http://otel-collector.observability:4317` |
| Hermes Agent gateway | `http://otel-collector.observability:4318/v1/traces` |

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| Ready | `kubectl -n observability get pods -l app.kubernetes.io/name=opentelemetry-collector` | All `1/1 Running` (prod: ≥ 3, across zones) |
| HPA (prod) | `kubectl -n observability get hpa otel-collector` | `TARGETS` shows a CPU %, `MINPODS 3` |
| Config accepted | `kubectl -n observability logs deploy/otel-collector \| grep -i "Everything is ready"` | One line |
| Traces flowing | PromQL `otelcol_exporter_sent_spans_total{exporter="otlp_grpc/tempo"}` | Increasing |
| Export errors | `otelcol_exporter_send_failed_spans_total`, `otelcol_exporter_enqueue_failed_spans_total` | `0` |
| Queue headroom | `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity` | Well below 1 |
| Refused data | `otelcol_receiver_refused_spans_total` | `0` (non-zero = `memory_limiter` active) |
| Scrape endpoint | `kubectl -n observability port-forward svc/otel-collector 8889` then `curl -s localhost:8889/metrics \| head` | Prometheus text format |

Offline config check: render with `helm template`, take the `relay` key of the ConfigMap and run
`MY_POD_IP=127.0.0.1 otelcol-contrib validate --config=<file>` (release binary 0.165.0).

## 🛡️ Security

| Threat | Control | How it's enforced |
|---|---|---|
| Public OTLP endpoint | ClusterIP only, no ingress | Values; NetworkPolicies in `k8s/` |
| Unauthenticated OTLP writes in-cluster | **Not protected** by auth | Restrict senders with NetworkPolicies in `k8s/` |
| Over-broad RBAC | Only the k8s_attributes preset ClusterRole (read pods, namespaces, replicasets) | `presets.kubernetesAttributes` |
| Container privilege | PSS restricted: non-root 10001, drop ALL, read-only root FS, `RuntimeDefault` seccomp, no privilege escalation | `podSecurityContext`, `securityContext` |
| Image tampering | Pinned by multi-arch index digest | `image.digest` |
| Overload / OOM | `memory_limiter` at 80% of the memory limit, GOMEMLIMIT, bounded queue, HPA | `config.processors`, `resources`, `autoscaling` |

## 📋 Production checklist

| Area | Item |
|---|---|
| HA sizing | ≥ 3 replicas across zones (HPA min 3, PDB `maxUnavailable: 1`); size the HPA max so `maxReplicas × requests` fits the node pool; metrics-server present |
| Data safety | Retry 5 min + 250k-span in-memory queue; for strict no-loss use a PVC-backed persistent queue (Sending queue) |
| Backups | None: stateless (config is in Git) |
| Upgrades | Bump chart, image tag and digest together; `otelcol-contrib validate` the rendered config with the new binary; `helm diff`; rolling update surges one pod and keeps all ready ones |
| Cost | Requests 1.5 vCPU / 3 GiB at the HPA minimum; tail sampling (two tiers) cuts Tempo storage and Kafka volume |
| SLOs | Proposed: 99.9% of received spans exported (`1 - send_failed / sent`), queue utilisation < 50%, zero `refused` over 30 days |
| Alerts + runbooks | Alert on `otelcol_exporter_send_failed_spans_total` rate > 0, queue > 80% full, `otelcol_receiver_refused_spans_total` rate > 0, fewer than 3 ready pods; each maps to a Troubleshooting row below |
| Network | NetworkPolicies: OTLP ingress only from app namespaces and `hermes`; egress only to Tempo, DNS and the Kubernetes API (`k8s_attributes`) |

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `CrashLoopBackOff`, "unknown type" or "invalid keys" in logs | Component/option not in this contrib version | Run `otelcol-contrib validate` against the rendered config before deploying |
| Traces missing in Tempo | Wrong profile endpoint or Tempo not ready | Prod: `tempo-distributor`; lab: `tempo`; check `otelcol_exporter_send_failed_spans_total` |
| `enqueue_failed` rising | Tempo slow/unavailable longer than the queue covers | Fix Tempo first; then raise `queue_size` together with the memory limit |
| Pods `Pending` (prod) | Zone spread is `DoNotSchedule` and a zone has no capacity | Add nodes in that zone, or relax to `ScheduleAnyway` |
| App metrics missing in Prometheus | ServiceMonitor not picked up | Check target `otel-collector` on Prometheus `/targets`; `prom-metrics` port on the Service |
| Pods missing `k8s.*` attributes | No pod association | Apps must reach the Collector directly (no proxy) or send `k8s.pod.ip` |
| Data refused | `memory_limiter` triggered | Let the HPA scale, raise the memory limit or reduce traffic |

## 📌 Pinned versions

| Item | Version | Digest (multi-arch index) |
|---|---|---|
| Chart `open-telemetry/opentelemetry-collector` | 0.178.2 | — |
| `otel/opentelemetry-collector-contrib` | 0.165.0 | `sha256:e40d61f10c9a617cca1ffd1be4d7e2b3a4b0f0001798ff07e58cabe82e618cea` |

## 🧹 Teardown

`helm uninstall otel-collector -n observability` (stateless; nothing else to delete).

## 🔗 References

- [OpenTelemetry Collector documentation](https://opentelemetry.io/docs/collector/)
- [Collector configuration](https://opentelemetry.io/docs/collector/configuration/)
- [Exporter helper: retry and sending queue](https://github.com/open-telemetry/opentelemetry-collector/blob/v0.165.0/exporter/exporterhelper/README.md)
- [Memory limiter processor](https://github.com/open-telemetry/opentelemetry-collector/tree/v0.165.0/processor/memorylimiterprocessor)
- [Tail sampling processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.165.0/processor/tailsamplingprocessor)
- [Load-balancing exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/v0.165.0/exporter/loadbalancingexporter)
- [Kubernetes attributes processor](https://opentelemetry.io/docs/platforms/kubernetes/collector/components/#kubernetes-attributes-processor)
- [opentelemetry-collector chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-collector)
- [Collector contrib releases](https://github.com/open-telemetry/opentelemetry-collector-contrib/releases)
