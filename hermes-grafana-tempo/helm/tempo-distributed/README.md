# 🏭 Grafana Tempo (distributed, production profile)

Tempo 3.x in microservices mode with the `grafana-community/tempo-distributed` chart: every component runs as its own
Deployment or StatefulSet, trace blocks live in Google Cloud Storage, and a Kafka-compatible queue sits between the
distributor and the components that consume spans. **Why:** independent scaling of the write and read paths,
zone-redundant recent-data queries and isolated failure domains. This is the **production profile**
(`scripts/deploy.sh` with `PROFILE=prod`); the lab uses the single-binary chart in [`../tempo/`](../tempo/) with a
local PV. There is no `values-lab.yaml` here: this profile does not fit a small lab cluster (see Sizing).

**Status:** 🚧 renders with `helm template`, passes `helm lint` and `kubeconform -strict` (Kubernetes 1.36 schemas;
the `ZoneAwarePodDisruptionBudget` custom resource has no public schema and is skipped) on chart 3.27.0 / Tempo 3.1.1
(2026-11-08); [`prometheusrule-rollout-operator.yaml`](prometheusrule-rollout-operator.yaml) passes `promtool check
rules`. Not installed on a cluster; runtime behaviour is to be verified on deploy.

## 📨 Kafka: required in Tempo 3.x microservices mode

| Question | Answer | Source |
|---|---|---|
| Does distributed mode need a queue? | **Yes.** Distributor → Kafka-compatible queue → live-store, block-builder, metrics-generator | [Deployment modes](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/plan/deployment-modes/) ("Kafka required: Yes") |
| Does the chart bundle Kafka? | **No.** The chart only configures the client and refuses to render without `ingest.kafka.address` | [Configure Kafka](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/configure-kafka/), [chart UPGRADE.md](https://github.com/grafana-community/helm-charts/blob/main/charts/tempo-distributed/UPGRADE.md) |
| Does single-binary avoid it? | **Yes.** `-target=all` pushes spans in-process to the live-store and metrics-generator | [Architecture](https://grafana.com/docs/tempo/latest/introduction/architecture/), [CHANGELOG #6729](https://github.com/grafana/tempo/blob/v3.1.1/CHANGELOG.md) |
| Which backends work? | Apache Kafka, Redpanda, WarpStream or a managed Kafka API | [Kafka component](https://grafana.com/docs/tempo/latest/reference-tempo-architecture/components/kafka/) |

Production uses an **external, managed or operator-run** Kafka-compatible service (TLS + SASL SCRAM-SHA-512, topic
pre-created). For a test run, [`kafka-test.yaml`](kafka-test.yaml) + [`values-kafka-test.yaml`](values-kafka-test.yaml)
start a single plaintext Apache Kafka broker in the namespace (no replication, not for production).
Google Cloud Managed Service for Apache Kafka recommends keyless OAUTHBEARER via Application Default Credentials;
Tempo reads OAUTHBEARER tokens only from a Secret, file or Unix socket, so that option needs a token-refresh sidecar
(not included here).

Topic settings from the official guide: one topic `tempo-traces`, partitions ≥ live-store replicas, replication
factor 3, `min.insync.replicas=2`, `cleanup.policy=delete`, retention 24h (never below 40m),
`max.message.bytes=16000000`.

## 🧩 Components

| Name | What it does (one line) | Where defined | Security role |
|---|---|---|---|
| Deployment `tempo-distributor` (3, HPA 3–9) | Receives OTLP gRPC 4317 / HTTP 4318 and writes spans to Kafka | `distributor`, `traces.otlp` | Only ingest entry point; ClusterIP |
| External Kafka topic `tempo-traces` | Durable write-ahead log between the distributor and all consumers | `ingest.kafka` | TLS + SCRAM, creds from Secret `tempo-kafka` |
| StatefulSets `tempo-live-store-zone-a/-b` (3 + 3, PVC 20Gi) | One live-store per partition per zone; serves recent data | `liveStore` | Non-root, read-only root FS |
| StatefulSet `tempo-block-builder` (3) | One per partition; builds Parquet blocks and writes them to GCS | `blockBuilder` | GCS write via Workload Identity |
| Deployment `tempo-metrics-generator` (2) | Consumes Kafka; service-graphs + span-metrics remote-written to Prometheus | `metricsGenerator`, `overrides` | Pushes only to in-cluster Prometheus |
| Deployment `tempo-query-frontend` (2) | Grafana entry point; shards queries to the queriers | `queryFrontend` | ClusterIP only |
| Deployment `tempo-querier` (3, HPA 3–9) | Runs query jobs against live-stores and GCS | `querier` | GCS read via Workload Identity |
| StatefulSet `tempo-backend-scheduler` (1) | Schedules compaction and 720h (30-day) retention jobs (singleton by design) | `backendScheduler` | GCS via Workload Identity |
| StatefulSet `tempo-backend-worker` (2) | Executes compaction and retention jobs | `backendWorker` | Deletes expired blocks |
| StatefulSet `tempo-memcached` (2) + exporter | Bloom, Parquet-footer and search cache | `memcached`, `memcachedExporter` | Cluster-internal, no auth |
| Deployment `tempo-rollout-operator` (1) | Zone-by-zone live-store rollouts, per-partition eviction guard | `rollout_operator` | Cluster-scoped webhooks + 2 CRDs |
| PrometheusRule `tempo-rollout-operator` | Alerts when the rollout-operator is down or its webhooks fail | [`prometheusrule-rollout-operator.yaml`](prometheusrule-rollout-operator.yaml) | — |
| Per-tenant limits | Ingest rate/burst, live traces, trace size, generator series, tag-value size | `overrides.defaults` | Bounds a noisy sender and Prometheus cardinality |
| ServiceMonitors (9) | Prometheus scrapes every component and memcached | `metaMonitoring.serviceMonitor` | — |
| GCS bucket `tempo-traces-<project>` | Trace blocks, retention enforced by Tempo; lifecycle delete after 33 days as backstop | `storage.trace.gcs`, [`../../infra/create-tempo-bucket.sh`](../../infra/create-tempo-bucket.sh) | `roles/storage.objectUser` + `roles/storage.bucketViewer` on the bucket for the WIF principal `observability/tempo`, no keys |

## 🗓️ Retention and cost

| Item | Value | Source |
|---|---|---|
| Trace retention | `block_retention: 720h` (30 days); `compacted_block_retention: 1h` | [`values.yaml`](values.yaml) `backendScheduler.config.provider.compaction` |
| Bucket lifecycle | `Delete` after 33 days (backstop, never before Tempo's own deletion) | [`../../infra/create-tempo-bucket.sh`](../../infra/create-tempo-bucket.sh) |
| Measured ingest (lab, 2026-11-08) | 38.8 KB/s received, 131.5 spans/s; blocks ~0.31 of received bytes | Single-binary lab, synthetic load plus Hermes |
| Bucket size at 30 days | ~31 GB | 38.8 KB/s × 2,592,000 s × 0.31 |
| Storage cost | ~$0.62/month plus operations | GCS Standard, us-central1, $0.020 per GB-month list price |

Production ingest will differ; re-measure with `sum(rate(tempo_distributor_bytes_received_total[1h]))` and
`gcloud storage du -s gs://$TEMPO_BUCKET`.

## 🔌 Endpoints

| Consumer | Setting | Value |
|---|---|---|
| OpenTelemetry Collector | `exporters.otlp_grpc/tempo.endpoint` | `tempo-distributor.observability:4317` (or HTTP `http://tempo-distributor.observability:4318`) |
| Grafana Tempo data source | `url` | `http://tempo-query-frontend.observability:3200` |

No nginx gateway: both consumers are in-cluster and the Services are ClusterIP, so a gateway would add a hop and no
control. Enable `gateway` only if an external client must reach Tempo.

## 📏 Sizing

Starting point for up to ~10 MB/s ingest (3 Kafka partitions); scale per the
[official sizing guide](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/plan/size/).

| Component | Replicas | Requests (each) | Limits (each) | Official guide |
|---|---|---|---|---|
| distributor | 3 (HPA 3–9) | 500m / 1Gi | 2 / 2Gi | 1 per 10 MB/s, 2 CPU / 2 GB |
| live-store | 3 per zone × 2 | 1 / 4Gi | 2 / 6Gi | 1 per 6–10 MB/s, 1 CPU / 4–20 GB |
| block-builder | 3 | 500m / 4Gi | 1 / 8Gi | 1 per partition, 0.5 CPU / 5–10 GB |
| querier | 3 (HPA 3–9) | 500m / 2Gi | 2 / 4Gi | 1 per 1–2 MB/s, 4–20 GB |
| query-frontend | 2 | 250m / 1Gi | 1 / 2Gi | 2 for HA |
| metrics-generator | 2 | 500m / 1Gi | 1 / 2Gi | — |
| backend-scheduler | 1 | 500m / 1Gi | 1 / 2Gi | 1, 0.5 CPU / 1–2 GB |
| backend-worker | 2 | 500m / 1Gi | 1 / 2Gi | 0.5 CPU / 1–2 GB |
| memcached + exporter | 2 | 300m / 1344Mi | 600m / 1408Mi | — |
| rollout-operator | 1 | 100m / 100Mi | 200m / 200Mi | — |
| **Total (HPA minimum)** | 25 pods | **14.2 vCPU / 54.7 GiB** | 35.4 vCPU / 95 GiB | Kafka not included |
| Test Kafka (`kafka-test.yaml`) | 1 | 500m / 1.5Gi | 1 / 1.5Gi | Test only |

Cluster: regional GKE, at least 2 zones (live-store zones use `topology.kubernetes.io/zone` anti-affinity) and
enough nodes for hostname spread. This profile does **not** fit a 3 × e2-standard-2 lab (5.8 vCPU / ~17.6 GiB
allocatable); use [`../tempo/`](../tempo/) there.

## 🚀 Install

| Step | Command | Why |
|---|---|---|
| 1 | `infra/create-tempo-bucket.sh` | Creates bucket `tempo-traces-<project>` (uniform access, public access prevention, versioning off) with a 33-day `Delete` lifecycle backstop (above Tempo's 720h retention) and grants `roles/storage.objectUser` + `roles/storage.bucketViewer` on this bucket to the WIF principal of KSA `observability/tempo` (`ACCESS_MODE=bucket`); prints the bucket name. `bucketViewer`: Tempo reads the bucket attributes at start (`storage.buckets.get`), which `objectUser` lacks |
| 2 | Check the binding: `gcloud storage buckets get-iam-policy gs://$TEMPO_BUCKET` | A `principal://…/subject/ns/observability/sa/tempo` member with `roles/storage.objectUser` and `roles/storage.bucketViewer`; no Google service account involved |
| 3 | Create topic `tempo-traces` with the settings above on the Kafka service | Production keeps auto-creation off |
| 4 | `kubectl -n observability create secret generic tempo-kafka --from-literal=username="$KAFKA_USER" --from-file=password=/path/to/kafka-password` | SASL credentials; never in Git or Helm values |
| 5 | `helm upgrade --install tempo grafana-community/tempo-distributed --version 3.27.0 -n observability --create-namespace -f helm/tempo-distributed/values.yaml --set storage.trace.gcs.bucket_name="$TEMPO_BUCKET" --set ingest.kafka.address="$KAFKA_BOOTSTRAP"` | Deploy (after kube-prometheus-stack, which provides the ServiceMonitor CRD) |
| 5b | `kubectl apply -f helm/tempo-distributed/prometheusrule-rollout-operator.yaml` | Alerts for the rollout-operator (see [Rollout-operator](#-rollout-operator)) |
| 6 | Collector: production [`../otel-collector/values.yaml`](../otel-collector/values.yaml) already exports to `tempo-distributor`; Grafana: use the production data source URL above | The single-binary Service `tempo` does not exist in this profile |

`scripts/deploy.sh` (`PROFILE=prod`, `KAFKA_BOOTSTRAP` set) runs steps 1 and 5 (lifecycle default 33 days). Alternatives:
`ACCESS_MODE=conditional` (project-level binding with an IAM condition limited to
this bucket and its objects) or `ACCESS_MODE=gsa` (a dedicated Google service account, never a default compute
account, impersonated via `roles/iam.workloadIdentityUser`; deploy.sh annotates the KSA); see
[`../../infra/`](../../infra/README.md#-gcs-buckets-both-profiles).

Test path (no managed Kafka): `kubectl apply -f helm/tempo-distributed/kafka-test.yaml`, then step 5 with
`-f helm/tempo-distributed/values-kafka-test.yaml` added and without `--set ingest.kafka.address`.

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| Pods | `kubectl -n observability get pods -l app.kubernetes.io/instance=tempo` | All `Running`, live-stores in both zones |
| Ready | `kubectl -n observability port-forward svc/tempo-query-frontend 3200` then `curl -s localhost:3200/ready` | `ready` |
| Kafka produce | PromQL `sum(rate(tempo_distributor_kafka_write_bytes_total[5m]))` | > 0 with traffic |
| Consumer lag | PromQL `max by (group, partition) (tempo_ingest_group_partition_lag_seconds)` | Seconds, not growing |
| Blocks in GCS | `gcloud storage ls gs://$TEMPO_BUCKET/single-tenant/` | Block directories after the first flush |
| Generator | PromQL `traces_spanmetrics_calls_total`, `traces_service_graph_request_total` | Series per service |
| Scraped | PromQL query 1 below | `1` per pod |
| Limits loaded | `curl -s localhost:3200/status/overrides` (query-frontend port-forward above) | The values from `overrides.defaults` |
| Rollout-operator alerts | `kubectl -n observability get prometheusrule tempo-rollout-operator` | Present; alerts inactive |

Query 1 (scrape targets, one regex over the component jobs):

```promql
up{job=~"observability/(distributor|live-store|block-builder|metrics-generator|querier|query-frontend|backend-scheduler|backend-worker|memcached)"}
```

## 🚦 Limits

Per-tenant limits in `overrides.defaults` (Tempo 3.1 format; one tenant, `single-tenant`), sized for the ~10 MB/s design
point above. Keys and defaults are from the [Tempo configuration reference](https://grafana.com/docs/tempo/latest/configuration/#overrides).

| Setting | Value | Tempo default | Enforced by | When exceeded |
|---|---|---|---|---|
| `ingestion.rate_strategy` | `global` | `local` | distributor | Rate limit is shared by the healthy distributors, so HPA scale-out does not multiply it |
| `ingestion.rate_limit_bytes` | 15 MB/s (1.5 x design point) | 30 MB/s per distributor | distributor | `RATE_LIMITED` to the sender |
| `ingestion.burst_size_bytes` | 20 MB (always per distributor) | 30 MB | distributor | `RATE_LIMITED`; keep above the largest single OTLP push |
| `ingestion.max_traces_per_user` | 20000 per live-store | 10000 | live-store | `LIVE_TRACES_EXCEEDED`, spans discarded |
| `global.max_bytes_per_trace` | 5 MB | 5 MB | live-store, block-builder, querier | `TRACE_TOO_LARGE`, spans discarded |
| `metrics_generator.max_active_series` | 100000 per generator instance | 0 (unlimited) | metrics-generator | New series dropped; 2 instances = at most 200k series on each Prometheus replica |
| `read.max_bytes_per_tag_values_query` | 5 MB | 1 MB | querier | Tag-value autocomplete truncated |

Watch `sum by (reason) (rate(tempo_discarded_spans_total[5m]))` and
`rate(tempo_metrics_generator_registry_series_limited_total[5m])`; raise a limit only when real traffic hits it, and
grow Prometheus memory (about 4 KiB per active series) before raising `max_active_series`.

## 🔄 Rollout-operator

The rollout-operator's webhooks (`pod-eviction`, `prepare-downscale`, `no-downscale`, `zpdb-validation`) use
`failurePolicy: Fail` for namespace `observability`. While it is down, the kube-apiserver rejects every eviction, node
drain and live-store scale-down there. The subchart (0.53.1) hard-codes `replicas: 1` and has no PDB value, so it cannot
run two replicas from these values; a PDB on one replica would only block drains. The safety net is
[`prometheusrule-rollout-operator.yaml`](prometheusrule-rollout-operator.yaml), applied after the chart (install step 5b).

| Alert | Fires when | Severity |
|---|---|---|
| `TempoRolloutOperatorDown` | `kube_deployment_status_replicas_available` of `tempo-rollout-operator` < 1 for 5m | critical |
| `TempoRolloutOperatorWebhookErrors` | `apiserver_admission_webhook_rejection_count` with `error_type="calling_webhook_error"` for a `*-observability.grafana.com` webhook rises for 10m | warning |

#### TempoRolloutOperatorDown
Critical. `kubectl -n observability get deploy,pods -l app.kubernetes.io/name=rollout-operator` and its logs. Common
causes: node drain evicted it (it is rescheduled; wait for `Ready`), image pull, or its webhook certificate Secret
`certificate` missing (it re-creates it on start). Also check `kubectl -n observability get netpol
tempo-rollout-operator-webhook` (port 8443 from the kube-apiserver). Emergency only, when drains must proceed and the
operator cannot start: set `rollout_operator.webhooks.failurePolicy: Ignore` with `helm upgrade`, finish the
maintenance, then revert, because without the webhooks live-store zones are not protected against parallel evictions.

## 🛡️ Security

| Threat | Control | How it's enforced |
|---|---|---|
| Leaked storage keys | No keys: `roles/storage.objectUser` + `roles/storage.bucketViewer` on the bucket for the WIF principal of KSA `observability/tempo` | `serviceAccount`, install step 1 |
| Container escape / privilege | PSS restricted: non-root UID/GID 10001 (the image's user; pod, container and `fsGroup` agree), seccomp `RuntimeDefault`, drop ALL, read-only root FS, no privilege escalation | `tempo.podSecurityContext`, `tempo.securityContext`, `rollout_operator.*` |
| Image tampering | Every image pinned by tag **and** multi-arch index digest | `*.image.tag` |
| Kafka credential exposure | Secret `tempo-kafka` injected as env, not written to the ConfigMap; TLS on. **Partly protected:** the chart expands the env vars into container args (`-ingest.sasl-password=$(TEMPO_KAFKA_SASL_PASSWORD)`, upstream behaviour), so the password is in the process command line, readable by anyone who can exec into a Kafka-client pod or read the node's process table | `ingest.kafka.sasl.existingSecret`, `ingest.kafka.tls`; restrict `pods/exec` in `observability` with RBAC |
| Unauthenticated OTLP writes in-cluster | **Not protected** (`multitenancy_enabled: false`) | Restrict senders with a NetworkPolicy on the distributor |
| Webhook outage blocks drains | Rollout-operator webhooks use `failurePolicy: Fail` (namespace `observability` only) | Alerts in `prometheusrule-rollout-operator.yaml`; runbook [TempoRolloutOperatorDown](#temporolloutoperatordown) |

## 📋 Production checklist

| Area | Item |
|---|---|
| HA sizing | Regional cluster, ≥ 2 zones (live-store zones use `topology.kubernetes.io/zone`), enough nodes per zone for the hostname spread; requests above (≈ 14.2 vCPU / 55 GiB) + 30% headroom |
| HA sizing | Kafka partitions = `liveStore.replicas` = `blockBuilder.replicas`; scale live-stores only with the [safe scale-down procedure](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/configure-kafka/#scale-safely), never an HPA; distributor/querier HPAs need metrics-server |
| Kafka | External Kafka-compatible service: RF 3, `min.insync.replicas=2`, TLS + SCRAM-SHA-512, topic `tempo-traces` pre-created (settings above), auto-creation off; Secret `tempo-kafka` from a secret manager; the test broker in `kafka-test.yaml` is never production |
| Storage access | `roles/storage.objectUser` + `roles/storage.bucketViewer` on the bucket only for the WIF principal `ns/observability/sa/tempo` (`ACCESS_MODE=bucket`); no keys, no default compute account, no unconditioned project-wide roles |
| Backups | The bucket is the system of record for traces. Versioning is off by design (compaction rewrites blocks constantly); GCS soft delete (default 7 days) covers accidental deletes; Bucket Lock or a retention policy only if compliance requires it. Live-store PVCs and Kafka are rebuilt from Kafka/GCS, no backup |
| Access logs and cost | Cloud Audit Logs Data Access (`DATA_READ`, `DATA_WRITE`) for Cloud Storage; a budget alert covering the bucket |
| Retention | Tempo deletes blocks after 30 days (`block_retention: 720h`, backend-scheduler); bucket lifecycle `Delete` at 33 days as a backstop (`LIFECYCLE_DAYS=31`, the default) |
| Upgrades | Pin chart, image tag and digest; read the chart [UPGRADE.md](https://github.com/grafana-community/helm-charts/blob/main/charts/tempo-distributed/UPGRADE.md) and [Tempo release notes](https://github.com/grafana/tempo/releases); `helm diff` before apply; the rollout-operator moves one live-store zone at a time; roll back with `helm rollback tempo` after checking the release notes for block-format changes |
| Cost | Requests ≈ 14.2 vCPU / 55 GiB plus Kafka; GCS Standard: ~31 GB per 30 days at the measured lab ingest ≈ $0.62/month storage + operations (polling, compaction), see [Retention and cost](#-retention-and-cost); cross-zone Kafka traffic (Tempo 3.1 `client_rack` reduces it); cut volume with Collector tail sampling ([`../otel-collector/`](../otel-collector/README.md#-tail-sampling-documented-not-enabled)) |
| SLO: ingest | Proposed: 99.9% of OTLP pushes succeed over 30 days (`tempo_request_duration_seconds_count{job="observability/distributor"}`, non-5xx / all); Kafka consumer lag < 60s |
| SLO: query | Proposed: 99% of trace-by-ID lookups < 5s, 95% of searches over 1h < 10s (`tempo_request_duration_seconds_bucket{job="observability/query-frontend"}` by `route`); alert on error-budget burn rate |
| Alerts | Load the full [Tempo mixin](https://github.com/grafana/tempo/tree/v3.1.1/operations/tempo-mixin) (all components); [`../tempo/prometheusrule-tempo-mixin.yaml`](../tempo/prometheusrule-tempo-mixin.yaml) keeps only the monolithic subset |
| Runbooks | Every mixin alert maps to the [official runbook](https://github.com/grafana/tempo/blob/v3.1.1/operations/tempo-mixin/runbook.md); add Kafka lag, GCS `403` and live-store zone outage to the on-call runbook (Troubleshooting below) |
| Network | NetworkPolicies: only the Collector → distributor 4317/4318, only Grafana → query-frontend 3200, Tempo → Kafka and GCS egress, Prometheus → all metrics ports |
| Limits | Per-tenant limits in [Limits](#-limits); review them against `tempo_discarded_spans_total` and the generator's series count after the first week |
| Rollout-operator | Single replica (subchart limit); apply [`prometheusrule-rollout-operator.yaml`](prometheusrule-rollout-operator.yaml) and route its critical alert to on-call |
| Endpoints | Collector `values.yaml` exports to `tempo-distributor.observability:4317`; Grafana's production data source URL is `http://tempo-query-frontend.observability:3200` |

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `helm template` fails: `ingest.kafka.address is required` | Kafka address missing | `--set ingest.kafka.address=...` or the test overlay |
| Live-store pods `Pending` | Fewer than 2 zones (zonal cluster) | Use a regional cluster, or set `liveStore.zoneAwareReplication.topologyKey: kubernetes.io/hostname` |
| `MESSAGE_TOO_LARGE` from distributor | Topic/broker limit below 16 MB | `max.message.bytes=16000000` |
| Kafka auth/TLS errors | Wrong SASL mechanism, Secret keys or CA | Secret `tempo-kafka` keys `username`/`password`; set `ingest.kafka.tls.caPath` for a private CA |
| GCS `403` on objects | `roles/storage.objectUser` binding missing for the WIF principal | Re-run install step 1; check project number, namespace and KSA name `tempo` |
| Tempo crash-loops, `403` `storage.buckets.get` | `roles/storage.bucketViewer` missing (the GCS backend reads the bucket attributes at start) | Re-run install step 1 (`infra/create-tempo-bucket.sh` grants both roles) |
| Consumer lag keeps growing | Under-sized block-builders/live-stores or GCS throttling | Add partitions + replicas together (checklist) |
| Senders get `RATE_LIMITED` | Ingest above `rate_limit_bytes` / `burst_size_bytes` | Check the sender burst; raise the limit in [Limits](#-limits) if the traffic is legitimate |
| `LIVE_TRACES_EXCEEDED` / `TRACE_TOO_LARGE` in `tempo_discarded_spans_total` | Too many concurrent traces per live-store, or a runaway trace | Add partitions + live-stores, or fix the instrumentation; raise the limit last |
| Node drain hangs, `failed calling webhook "pod-eviction-observability.grafana.com"` | Rollout-operator down | Runbook [TempoRolloutOperatorDown](#temporolloutoperatordown) |

## 📌 Pinned versions

| Item | Version | Digest (multi-arch index) |
|---|---|---|
| Chart `grafana-community/tempo-distributed` | 3.27.0 (latest, 2026-11-08) | — |
| `grafana/tempo` | 3.1.1 (latest release) | `sha256:64e2fbd56d9c2b3412a4b430a58ea59e91a670b1e75f920a0c702213ad145044` |
| `memcached` | 1.6.45-alpine | `sha256:bfc2ee42c4edb65f436dafc6a61cbc6938c30118e11ddea2f968e1a2c90bb12a` |
| `prom/memcached-exporter` | v0.18.0 | `sha256:1458b31d4cae1a6618e85c8d31ecc49c4ebdcee3c8530be8d80d93e8792c4a58` |
| `grafana/rollout-operator` (subchart 0.53.1) | v0.41.1 | `sha256:49e0d230669d261cec44e7b33188c72dde02fa29bfa9ec1e14274a9965bda740` |
| `apache/kafka` (test only) | 4.4.0 | `sha256:833b867a9585a141da455dc2b57431c65cbccb27f11c91f694444cca9f777e0f` |

## 🧹 Teardown

`kubectl delete --ignore-not-found -f helm/tempo-distributed/prometheusrule-rollout-operator.yaml`,
`helm uninstall tempo -n observability`, then `kubectl -n observability delete pvc -l app.kubernetes.io/instance=tempo`
(live-store data) and, for the test path, `kubectl delete -f helm/tempo-distributed/kafka-test.yaml` plus its PVC
`data-tempo-kafka-0`. The bucket and IAM binding stay until removed with `gcloud`.

## 🔗 References

- [Tempo deployment modes](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/plan/deployment-modes/)
- [Tempo architecture](https://grafana.com/docs/tempo/latest/introduction/architecture/)
- [Configure a Kafka-compatible backend](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/configure-kafka/)
- [Size the cluster](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/plan/size/)
- [Tempo GCS backend](https://grafana.com/docs/tempo/latest/configuration/hosted-storage/gcs/)
- [Monitor Tempo](https://grafana.com/docs/tempo/latest/operations/monitor/)
- [Tempo runbook](https://github.com/grafana/tempo/blob/v3.1.1/operations/tempo-mixin/runbook.md)
- [Tempo CHANGELOG v3.1.1](https://github.com/grafana/tempo/blob/v3.1.1/CHANGELOG.md)
- [tempo-distributed chart](https://github.com/grafana-community/helm-charts/tree/main/charts/tempo-distributed)
- [GKE Workload Identity Federation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
