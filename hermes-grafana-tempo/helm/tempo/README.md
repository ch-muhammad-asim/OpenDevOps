# 🔭 Grafana Tempo (single binary, lab profile)

Tempo in monolithic (single-binary) mode: one pod, trace blocks in object storage (lab: GCS via Workload Identity), WAL
on a local PV. **Why:** stores every trace from the
sample apps and Hermes Agent for TraceQL search, and its metrics-generator turns spans into request/error/latency
metrics and a service graph in Prometheus, with one StatefulSet instead of a dozen components and a Kafka queue.

This is the **lab / small-cluster profile** (`scripts/deploy.sh` with `PROFILE=lab`). **Production** uses the
microservices chart in [`../tempo-distributed/`](../tempo-distributed/) (HA, GCS, Kafka). There is no
`values-lab.yaml` here: [`values.yaml`](values.yaml) itself is the lab profile. The lab adds the GCS overlay
[`values-gcs.yaml`](values-gcs.yaml) (`TEMPO_STORAGE=gcs`, the default with `OBJECT_STORE=gcs`); the S3 overlay
[`values-s3.yaml`](values-s3.yaml) is the optional SeaweedFS fallback for clusters without cloud object storage.

**Status:** ✅ lab live on GCS (2026-11-08): chart 3.2.1, Tempo 3.1.1, `block_retention: 720h`, blocks in bucket
`tempo-traces-<suffix>` through Workload Identity (`ACCESS_MODE=conditional`), WAL on the 50Gi PVC;
`PROFILE=lab scripts/verify.sh` VERIFY_COUNT PASS, 0 failures. Blocks in the earlier SeaweedFS bucket were not migrated.
Renders with `helm template`, passes `helm lint` and `kubeconform -strict` (Kubernetes 1.36) with each overlay
(2026-11-08).

## 🧩 Components

| Name | What it does (one line) | Where defined | Security role |
|---|---|---|---|
| StatefulSet `tempo` (1 replica) | Distributor, live-store, querier, backend scheduler/worker and metrics-generator in one process | [`values.yaml`](values.yaml) | PSS restricted: non-root 10001, seccomp, drop ALL, read-only root FS, no SA token |
| Service `tempo` | 3200 HTTP API/query, 4317 OTLP gRPC, 4318 OTLP HTTP | chart default | ClusterIP only |
| PVC `storage-tempo-0` (50Gi, `standard-rwo`) | WAL, live-store data and generator WAL under `/var/tempo` (blocks too with the `local` backend) | `persistence` | Zonal disk, RWO |
| Metrics-generator | `service-graphs` + `span-metrics` → remote write to Prometheus | `tempo.metricsGenerator`, `tempo.overrides.defaults` | Pushes only to the in-cluster Prometheus |
| ServiceMonitor `tempo` | Prometheus scrapes Tempo's own metrics on 3200 (`job="tempo"`) | `serviceMonitor` | — |
| PrometheusRule `tempo-mixin` | Official Tempo recording rules + the alerts that apply to monolithic mode | [`prometheusrule-tempo-mixin.yaml`](prometheusrule-tempo-mixin.yaml) | Read-only rules |
| GCS bucket `tempo-traces-<suffix>` (lab, live) | Trace blocks under `single-tenant/<block-id>/` | [`values-gcs.yaml`](values-gcs.yaml) | `roles/storage.objectUser` + `roles/storage.bucketViewer` limited to the bucket for the Workload Identity principal, no keys |
| SeaweedFS bucket `tempo-traces` (optional fallback) | Trace blocks in the in-cluster S3 store | [`values-s3.yaml`](values-s3.yaml) | Bucket-scoped S3 identity `tempo`; keys only as env vars from Secret `tempo-s3` |

## ⚙️ Key settings

| Setting | Value | Why |
|---|---|---|
| `tempo.tag` | `3.1.1@sha256:64e2fbd5…5044` | Tag + multi-arch index digest; the digest wins at pull time |
| `tempo.resources` | requests 250m / 1Gi, limit memory 2Gi | Memory capped; no CPU limit on purpose (throttling slows ingest and compaction) |
| `tempo.retention` | `720h` | 30 days of traces for trend analysis; `block_retention` for the backend scheduler and worker |
| `persistence` | 50Gi `standard-rwo`, RWO | Sized for ~31 GB of local blocks per 30 days; with an object-store overlay it holds mostly the WAL (a PVC cannot shrink); survives restarts within the zone |
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

## 📏 Retention and sizing

| Item | Value | Source |
|---|---|---|
| Retention | `720h` (30 days) | `tempo.retention` |
| Measured ingest (lab, 2026-11-08) | 38.8 KB/s received, 131.5 spans/s | Tempo distributor metrics, 1h rate, synthetic load plus Hermes |
| Block size | ~0.31 of received bytes | Blocks on the PV vs bytes received (measured with the local backend) |
| Blocks per 30 days | ~31 GB | 38.8 KB/s × 2,592,000 s × 0.31 |
| Where blocks live (lab) | GCS bucket `tempo-traces-<suffix>`, lifecycle backstop 33 days | [`values-gcs.yaml`](values-gcs.yaml), [`../../infra/`](../../infra/README.md#-gcs-buckets-both-profiles) |
| Bucket cost (estimate) | ~$0.62/month storage (~31 GB × $0.020/GB-month, GCS Standard) plus operations (not measured) | [`../thanos/`](../thanos/README.md#production-gcs) price list |
| PVC | 50Gi `standard-rwo`, now mostly WAL | Sized for local blocks before the switch to object storage; a PVC cannot shrink |

**How the lab PVC was expanded (10Gi → 50Gi, online):** `standard-rwo` allows volume expansion, but a StatefulSet's
`volumeClaimTemplates` cannot be changed in place. So the StatefulSet object is deleted without its pod
(`kubectl -n observability delete sts tempo --cascade=orphan`), then `helm upgrade` (same command as Install) recreates
it with the 50Gi template, and the PVC itself is patched to the new size:
`kubectl -n observability patch pvc storage-tempo-0 -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'`.
The pod keeps running; GKE grows the disk and the filesystem online. Check with `kubectl -n observability get pvc
storage-tempo-0` (`CAPACITY 50Gi`).

TraceQL metrics over 30 days (`/api/metrics/query_range`) work; use a step of 1h or more. For 30-day trends the span
metrics and service-graph series in Prometheus are cheaper to query.

## 🚀 Install

```bash
helm upgrade --install tempo grafana-community/tempo --version 3.2.1 \
  --namespace observability --create-namespace -f helm/tempo/values.yaml   # local PV backend (TEMPO_STORAGE=local)
kubectl apply -f helm/tempo/prometheusrule-tempo-mixin.yaml                # Tempo rules and alerts
```

Install after kube-prometheus-stack (ServiceMonitor and PrometheusRule CRDs). `scripts/deploy.sh` with `PROFILE=lab`
and `TEMPO_STORAGE=local` runs exactly this; the lab default (`TEMPO_STORAGE=gcs`) adds the GCS overlay below.

### ☁️ Lab: GCS backend (default, Workload Identity, scoped to the bucket)

Live in the lab. The overlay switches `storage.trace.backend` to `gcs`; WAL, live-store data and generator WAL stay on
the PV.

| Step | Command | Why |
|---|---|---|
| 1 | `ACCESS_MODE=conditional TEMPO_BUCKET=tempo-traces-<suffix> infra/create-tempo-bucket.sh` | Creates the bucket (uniform access, public access prevention, versioning off, lifecycle delete after 33 days) and grants `roles/storage.objectUser` + `roles/storage.bucketViewer` limited to it to the Workload Identity principal of KSA `observability/tempo`; prints the bucket name |
| 2 | `helm upgrade --install tempo grafana-community/tempo --version 3.2.1 -n observability -f helm/tempo/values.yaml -f helm/tempo/values-gcs.yaml --set tempo.storage.trace.gcs.bucket_name="$TEMPO_BUCKET"` | Deploy with the GCS backend (`TEMPO_STORAGE=gcs` in `scripts/deploy.sh` does both steps) |

Why two roles: `objectUser` covers the objects; Tempo's GCS backend also reads the bucket attributes at start
(`storage.buckets.get`), which only `bucketViewer` adds. Without it Tempo crash-loops with `403` `storage.buckets.get`.

The lab uses `ACCESS_MODE=conditional` (project-level binding with an IAM condition limited to this bucket and its
objects). The script default `ACCESS_MODE=bucket` binds on the bucket itself; neither needs a Google service account or
a KSA annotation (the GKE metadata server issues the token). `ACCESS_MODE=gsa` uses a dedicated Google service account
`tempo-gcs`, never a default compute account; the KSA impersonates it via `roles/iam.workloadIdentityUser`, and
`scripts/deploy.sh` adds the KSA annotation. See [`../../infra/`](../../infra/README.md#-gcs-buckets-both-profiles).

### 🪣 Optional fallback: SeaweedFS S3 backend (`OBJECT_STORE=seaweedfs`)

For clusters without cloud object storage; not deployed in the lab. The overlay [`values-s3.yaml`](values-s3.yaml)
switches `storage.trace.backend` to `s3`: trace blocks go to bucket `tempo-traces` in the in-cluster SeaweedFS store
([`../seaweedfs/`](../seaweedfs/README.md)); WAL, live-store data and generator WAL stay on the PV.

| Setting | Value | Why |
|---|---|---|
| `tempo.storage.trace.s3.endpoint` | `seaweedfs.object-storage:8333` | In-cluster S3 gateway |
| `bucket` | `tempo-traces` | Created by the SeaweedFS bootstrap Job |
| `insecure` / `forcepathstyle` | `true` / `true` | Plain HTTP in-cluster; path-style URLs (no per-bucket DNS) |
| `region` | `us-east-1` | Any value works for SeaweedFS; set so the client skips the bucket-location lookup |
| `tempo.extraEnvFrom` | Secret `tempo-s3` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) | Tempo's S3 client falls back to the AWS env pair when `access_key`/`secret_key` are unset, so no key is rendered into the ConfigMap |

| Step | Command | Why |
|---|---|---|
| 1 | `kubectl apply -k helm/seaweedfs` (after its Secret, see its README) and wait for Job `seaweedfs-bootstrap` | Bucket must exist before Tempo flushes |
| 2 | `kubectl -n observability create secret generic tempo-s3 --from-env-file=<file>` (file lines `AWS_ACCESS_KEY_ID=…`, `AWS_SECRET_ACCESS_KEY=…`; `scripts/deploy.sh` does this from generated values, keys never on the command line) | Key of SeaweedFS identity `tempo` (read/write/list on `tempo-traces` only) |
| 3 | `helm upgrade --install tempo grafana-community/tempo --version 3.2.1 -n observability -f helm/tempo/values.yaml -f helm/tempo/values-s3.yaml` | Deploy with the S3 backend |

Check: `kubectl -n observability logs tempo-0 | grep -i s3` shows no `AccessDenied`; PromQL
`sum by (code) (rate(SeaweedFS_s3_request_total{bucket="tempo-traces"}[5m]))` shows `200` once blocks are flushed.

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
| GCS (lab) | `gcloud storage ls gs://$TEMPO_BUCKET/single-tenant/` | Block directories after the first flush |
| S3 writes (SeaweedFS fallback) | PromQL `sum by (code) (rate(SeaweedFS_s3_request_total{bucket="tempo-traces"}[5m]))` | Only `2xx` codes once blocks are flushed |

## 🛡️ Security

| Threat | Control | How it's enforced |
|---|---|---|
| Public access to traces | ClusterIP only; Grafana is the only UI | No ingress/route in values |
| Unauthenticated OTLP writes in-cluster | **Not protected** by auth (`multitenancy_enabled: false`) | NetworkPolicies in `k8s/` limit senders to the Collector |
| Sensitive data in spans | Apps and Hermes send content-free spans | See `apps/` and `hermes/` |
| Container privilege | PSS restricted (see Key settings), no SA token | `securityContext`, `tempo.securityContext`, `serviceAccount` |
| Image tampering | Pinned by multi-arch index digest | `tempo.tag` |
| Leaked storage credentials (GCS) | No keys; `roles/storage.objectUser` + `roles/storage.bucketViewer` limited to one bucket for one KSA principal | `infra/create-tempo-bucket.sh`, deploy-time `--set` |
| Leaked S3 key (SeaweedFS fallback) | Identity `tempo` limited to bucket `tempo-traces`; key only in Secret `tempo-s3` as env vars, not in the ConfigMap | [`values-s3.yaml`](values-s3.yaml), `scripts/deploy.sh` |

## 🩺 Operations

| Topic | Single binary |
|---|---|
| HA | None: one replica; a restart is a short ingest gap that the Collector's retry queue (up to 5 min) covers |
| Capacity | Watch PV usage (`kubelet_volume_stats_used_bytes{persistentvolumeclaim="storage-tempo-0"}`) and the bucket size (`gcloud storage du -s gs://$TEMPO_BUCKET`); lower `retention` or grow the PVC online ([Retention and sizing](#-retention-and-sizing)) |
| Backup | Blocks live in GCS (survive losing the cluster); versioning off, GCS soft delete (7-day default) covers accidental deletes; traces are rebuildable demo data |
| Upgrade | Bump chart, tag and digest together, `helm diff`, apply, check `tempo-0` ready and `/api/search`; roll back with `helm rollback tempo` |

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No service graph / span metrics | Processors not active or remote write rejected | Check Tempo logs for `remote write`; confirm `enableRemoteWriteReceiver: true` |
| Exemplar "View trace" link missing | Label mismatch | `trace_id_label_name` here must equal `exemplarTraceIdDestinations[].name` in Grafana |
| Tempo refuses to start: legacy overrides | Flat overrides format | Keep overrides under `overrides.defaults` (scoped format, required in Tempo 3) |
| PV full | Retention vs. traffic | Lower `retention` or grow the PVC ([Retention and sizing](#-retention-and-sizing)) |
| `helm upgrade` fails: `spec: Forbidden: updates to statefulset spec ... volumeClaimTemplates` | `persistence.size` changed on an existing StatefulSet | `kubectl -n observability delete sts tempo --cascade=orphan`, re-run `helm upgrade`, patch the PVC size |
| Wrong image after an upgrade | Tag bumped, digest not | Resolve the new multi-arch index digest; set `tag: "<tag>@sha256:<digest>"` |
| Tempo crash-loops, `403` `storage.buckets.get` | `roles/storage.bucketViewer` missing (the GCS backend reads the bucket attributes at start; `objectUser` lacks it) | Re-run `infra/create-tempo-bucket.sh` with the same `ACCESS_MODE` (it grants both roles); restart `tempo-0` |
| GCS `403` on objects | `roles/storage.objectUser` binding missing | Re-run `infra/create-tempo-bucket.sh`; check the KSA is `observability/tempo` |
| S3 `AccessDenied` / `403` (SeaweedFS fallback) | Key in Secret `tempo-s3` differs from identity `tempo` in SeaweedFS `s3.json` | Fix the Secrets; restart `seaweedfs-0`, then `tempo-0` |
| GCS `bucket_name` empty, Tempo exits | Overlay used without `--set tempo.storage.trace.gcs.bucket_name` | Pass the bucket name |
| Too many span-metric series | High-cardinality dimension | Remove it from `span_metrics.dimensions` |

## 📌 Pinned versions

| Item | Version | Digest (multi-arch index) |
|---|---|---|
| Chart `grafana-community/tempo` | 3.2.1 | — |
| `grafana/tempo` | 3.1.1 | `sha256:64e2fbd56d9c2b3412a4b430a58ea59e91a670b1e75f920a0c702213ad145044` |

## 🧹 Teardown

`helm uninstall tempo -n observability`, then `kubectl -n observability delete pvc storage-tempo-0` (WAL and local data)
and `kubectl delete -f helm/tempo/prometheusrule-tempo-mixin.yaml`. Trace blocks stay in the GCS bucket until
`scripts/teardown.sh --cluster` (asks first) or `gcloud storage rm -r gs://$TEMPO_BUCKET` (irreversible).

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
