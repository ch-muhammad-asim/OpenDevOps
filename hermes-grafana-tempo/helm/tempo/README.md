# 🔭 Grafana Tempo (single binary, lab profile)

Tempo in monolithic (single-binary) mode: one pod, trace blocks on a local PV. **Why:** stores every trace from the
sample apps and Hermes Agent for TraceQL search, and its metrics-generator turns spans into request/error/latency
metrics and a service graph in Prometheus, with one StatefulSet instead of a dozen components and a Kafka queue.

This is the **lab / small-cluster profile** (`scripts/deploy.sh` with `PROFILE=lab`). **Production** uses the
microservices chart in [`../tempo-distributed/`](../tempo-distributed/) (HA, GCS, Kafka). There is no
`values-lab.yaml` here: [`values.yaml`](values.yaml) itself is the lab profile. The lab keeps blocks on the local
PV; the GCS overlay [`values-gcs.yaml`](values-gcs.yaml) is optional and not used in the lab.

**Status:** ✅ running on the lab cluster (chart 3.2.1, Tempo 3.1.1, local PV). `values.yaml` renders the same
manifests as the running release except the image reference, which is now pinned by digest (the same digest the pod
already runs). Renders with `helm template`, passes `helm lint` and `kubeconform -strict` (Kubernetes 1.36), with and
without the GCS overlay (2026-11-08). The GCS overlay has not been run on a cluster.

## 🧩 Components

| Name | What it does (one line) | Where defined | Security role |
|---|---|---|---|
| StatefulSet `tempo` (1 replica) | Distributor, live-store, querier, backend scheduler/worker and metrics-generator in one process | [`values.yaml`](values.yaml) | PSS restricted: non-root 10001, seccomp, drop ALL, read-only root FS, no SA token |
| Service `tempo` | 3200 HTTP API/query, 4317 OTLP gRPC, 4318 OTLP HTTP | chart default | ClusterIP only |
| PVC `storage-tempo-0` (10Gi, `standard-rwo`) | Blocks, WAL and generator WAL under `/var/tempo` | `persistence` | Zonal disk, RWO |
| Metrics-generator | `service-graphs` + `span-metrics` → remote write to Prometheus | `tempo.metricsGenerator`, `tempo.overrides.defaults` | Pushes only to the in-cluster Prometheus |
| ServiceMonitor `tempo` | Prometheus scrapes Tempo's own metrics on 3200 (`job="tempo"`) | `serviceMonitor` | — |
| PrometheusRule `tempo-mixin` | Official Tempo recording rules + the alerts that apply to monolithic mode | [`prometheusrule-tempo-mixin.yaml`](prometheusrule-tempo-mixin.yaml) | Read-only rules |
| GCS bucket (optional overlay) | Trace blocks under `single-tenant/<block-id>/` | [`values-gcs.yaml`](values-gcs.yaml) | Workload Identity principal scoped to the bucket, no keys |

## ⚙️ Key settings

| Setting | Value | Why |
|---|---|---|
| `tempo.tag` | `3.1.1@sha256:64e2fbd5…5044` | Tag + multi-arch index digest; the digest wins at pull time |
| `tempo.resources` | requests 250m / 1Gi, limit memory 2Gi | Memory capped; no CPU limit on purpose (throttling slows ingest and compaction) |
| `tempo.retention` | `24h` | Short lab retention; fits the 10Gi PV |
| `persistence` | 10Gi `standard-rwo`, RWO | Survives pod restarts and reschedules within the zone |
| `tempo.receivers.otlp` | gRPC `0.0.0.0:4317`, HTTP `0.0.0.0:4318` | The Collector (lab overlay) exports OTLP gRPC to `tempo.observability:4317` |
| `tempo.streamOverHttpEnabled` | `true` | Grafana streaming search and TraceQL metrics over port 3200 |
| `metricsGenerator.remoteWriteUrl` | `http://prometheus-kube-prometheus-prometheus.monitoring:9090/api/v1/write` | Needs `enableRemoteWriteReceiver` in kube-prometheus-stack |
| `metricsGenerator.processor.span_metrics.dimensions` | `service.namespace`, `service.version` | Extra span-metric labels; each one multiplies series, so only low-cardinality resource attributes |
| `overrides.defaults.metrics_generator.processors` | `[service-graphs, span-metrics]` | RED metrics and the Grafana service map |
| `overrides.defaults.metrics_generator.trace_id_label_name` | `trace_id` | Exemplar label; matches the Grafana Prometheus data source (Tempo's default is `traceID`) |
| `securityContext` (pod) + `tempo.securityContext` | UID/GID 10001, `runAsNonRoot`, `RuntimeDefault`, no privilege escalation, drop ALL, read-only root FS | Pod Security Standards `restricted` |
| `serviceAccount.automountServiceAccountToken` | `false` | Tempo never calls the Kubernetes API |
| `tempo.reportingEnabled` | `false` | No usage reporting |

**`local-blocks`:** Tempo 3.0 removed the metrics-generator `local-blocks` processor. TraceQL metrics and Traces
Drilldown are served by the live-store in single-binary mode, so the processor is not listed.

**Jaeger receivers:** the chart's Service template reads the default Jaeger receiver keys, so they stay in the config
(ports 14250/14268/6831/6832, cluster-internal, unused).

## 🚀 Install

```bash
helm upgrade --install tempo grafana-community/tempo --version 3.2.1 \
  --namespace observability --create-namespace -f helm/tempo/values.yaml   # lab: local PV
kubectl apply -f helm/tempo/prometheusrule-tempo-mixin.yaml                # Tempo rules and alerts
```

Install after kube-prometheus-stack (ServiceMonitor and PrometheusRule CRDs). `scripts/deploy.sh` with `PROFILE=lab`
and `TEMPO_STORAGE=local` runs exactly this.

### ☁️ Optional: GCS backend (Workload Identity, scoped to the bucket)

Not used in the lab. The overlay switches `storage.trace.backend` to `gcs`; WAL, live-store data and generator WAL stay
on the PV.

| Step | Command | Why |
|---|---|---|
| 1 | `ACCESS_MODE=principal infra/create-tempo-bucket.sh` | Creates the bucket (uniform access, public access prevention, lifecycle rule) and grants `roles/storage.objectAdmin` on this bucket only to the Workload Identity principal of KSA `observability/tempo`; prints the bucket name |
| 2 | `helm upgrade --install tempo grafana-community/tempo --version 3.2.1 -n observability -f helm/tempo/values.yaml -f helm/tempo/values-gcs.yaml --set tempo.storage.trace.gcs.bucket_name="$TEMPO_BUCKET"` | Deploy with the GCS backend (`TEMPO_STORAGE=gcs` in `scripts/deploy.sh` does both steps) |

The principal binding needs no Google service account and no KSA annotation; the GKE metadata server issues the token.
`ACCESS_MODE=gsa` exists only for accounts that cannot edit bucket IAM: the KSA then impersonates an existing Google
service account. **Not recommended:** that account (by default the project's compute service account) usually has
project-wide access, far broader than one bucket.

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| Ready | `kubectl -n observability get pods -l app.kubernetes.io/name=tempo` | `tempo-0` `1/1 Running` |
| Image pinned | `kubectl -n observability get pod tempo-0 -o jsonpath='{.status.containerStatuses[0].imageID}'` | Ends in `sha256:64e2fbd5…5044` |
| API | `kubectl -n observability port-forward svc/tempo 3200` then `curl -s localhost:3200/ready` | `ready` |
| Traces stored | `curl -s 'localhost:3200/api/search?limit=5'` | JSON with `traces` once apps send traffic |
| Generator writing | PromQL `traces_spanmetrics_calls_total`, `traces_service_graph_request_total` | Series per service |
| Scraped | PromQL `up{job="tempo"}` | `1` |
| Rules loaded | `kubectl -n observability get prometheusrule tempo-mixin` | Present; Prometheus → Alerts lists `tempo_alerts` |
| GCS (overlay only) | `gcloud storage ls gs://$TEMPO_BUCKET/single-tenant/` | Block directories after the first flush |

## 🛡️ Security

| Threat | Control | How it's enforced |
|---|---|---|
| Public access to traces | ClusterIP only; Grafana is the only UI | No ingress/route in values |
| Unauthenticated OTLP writes in-cluster | **Not protected** by auth (`multitenancy_enabled: false`) | NetworkPolicies in `k8s/` limit senders to the Collector |
| Sensitive data in spans | Apps and Hermes send content-free spans | See `apps/` and `hermes/` |
| Container privilege | PSS restricted (see Key settings), no SA token | `securityContext`, `tempo.securityContext`, `serviceAccount` |
| Image tampering | Pinned by multi-arch index digest | `tempo.tag` |
| Leaked storage credentials (overlay) | No keys; IAM on one bucket for one KSA principal | `infra/create-tempo-bucket.sh`, deploy-time `--set` |

## 🩺 Operations

| Topic | Single binary |
|---|---|
| HA | None: one replica; a restart is a short ingest gap that the Collector's retry queue (up to 5 min) covers |
| Capacity | Watch PV usage (`kubelet_volume_stats_used_bytes{persistentvolumeclaim="storage-tempo-0"}`); lower `retention` or raise `persistence.size` |
| Backup | None for a 24h lab store; production keeps blocks in GCS ([`../tempo-distributed/`](../tempo-distributed/)) |
| Upgrade | Bump chart, tag and digest together, `helm diff`, apply, check `tempo-0` ready and `/api/search`; roll back with `helm rollback tempo` |

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No service graph / span metrics | Processors not active or remote write rejected | Check Tempo logs for `remote write`; confirm `enableRemoteWriteReceiver: true` |
| Exemplar "View trace" link missing | Label mismatch | `trace_id_label_name` here must equal `exemplarTraceIdDestinations[].name` in Grafana |
| Tempo refuses to start: legacy overrides | Flat overrides format | Keep overrides under `overrides.defaults` (scoped format, required in Tempo 3) |
| PV full | Retention vs. traffic | Lower `retention` or raise `persistence.size` |
| Wrong image after an upgrade | Tag bumped, digest not | Resolve the new multi-arch index digest; set `tag: "<tag>@sha256:<digest>"` |
| GCS `403` (overlay) | Principal binding missing | Re-run `infra/create-tempo-bucket.sh`; check the KSA is `observability/tempo` |
| GCS `bucket_name` empty, Tempo exits | Overlay used without `--set tempo.storage.trace.gcs.bucket_name` | Pass the bucket name |
| Too many span-metric series | High-cardinality dimension | Remove it from `span_metrics.dimensions` |

## 📌 Pinned versions

| Item | Version | Digest (multi-arch index) |
|---|---|---|
| Chart `grafana-community/tempo` | 3.2.1 | — |
| `grafana/tempo` | 3.1.1 | `sha256:64e2fbd56d9c2b3412a4b430a58ea59e91a670b1e75f920a0c702213ad145044` |

## 🧹 Teardown

`helm uninstall tempo -n observability`, then `kubectl -n observability delete pvc storage-tempo-0` (trace data) and
`kubectl delete -f helm/tempo/prometheusrule-tempo-mixin.yaml`.

## 🔗 References

- [Tempo documentation](https://grafana.com/docs/tempo/latest/)
- [Tempo deployment modes](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/plan/deployment-modes/)
- [Tempo configuration](https://grafana.com/docs/tempo/latest/configuration/)
- [Metrics-generator](https://grafana.com/docs/tempo/latest/metrics-from-traces/metrics-generator/)
- [Tempo GCS backend](https://grafana.com/docs/tempo/latest/configuration/hosted-storage/gcs/)
- [GKE Workload Identity Federation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [Tempo monitoring mixin](https://grafana.com/docs/tempo/latest/operations/monitor/)
- [Tempo releases / changelog](https://github.com/grafana/tempo/releases)
- [grafana-community/tempo chart](https://github.com/grafana-community/helm-charts/tree/main/charts/tempo)
