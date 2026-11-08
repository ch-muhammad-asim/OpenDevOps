# 📦 Helm values

Values files for the Helm releases that make up the observability stack. Every `values.yaml` holds the
**production** defaults; a `values-lab.yaml` next to it shrinks sizes for the small lab cluster. Every file starts
with a header that gives the chart, chart version, app version and the exact `helm upgrade --install` command.

**Status:** ✅ the lab profile runs on the lab cluster (2026-11-08, `PROFILE=lab scripts/verify.sh` 31 PASS,
0 failures), including Thanos, with Tempo and Thanos blocks on GCS via Workload Identity. Every profile below renders with
`helm template` and passes `helm lint` and `kubeconform -strict` (Kubernetes 1.36) against the pinned chart; the
production profiles have not been run on a cluster. Each folder's README is authoritative for its chart.

## 🧩 Releases

| Dir | Release / namespace | What it does (one line) |
|---|---|---|
| [`kube-prometheus-stack/`](kube-prometheus-stack/) | `prometheus` / `monitoring` | Prometheus (remote-write receiver + exemplars), Alertmanager, operator, exporters, CRDs; production adds the Thanos sidecar |
| [`thanos/`](thanos/) | manifests (`kubectl apply -k`) / `monitoring` | Thanos query, store gateway and compactor; 30 days of metrics in a GCS bucket (both profiles) |
| [`seaweedfs/`](seaweedfs/) | manifests (`kubectl apply -k`) / `object-storage` | Optional fallback for clusters without cloud object storage: in-cluster S3 (Apache-2.0); not deployed in the lab |
| [`tempo-distributed/`](tempo-distributed/) | `tempo` / `observability` | Production trace store: Tempo microservices, GCS blocks, external Kafka, HA |
| [`tempo/`](tempo/) | `tempo` / `observability` | Lab trace store: Tempo single binary, blocks in GCS, WAL on a PV; metrics-generator; Tempo rules/alerts |
| [`otel-collector/`](otel-collector/) | `otel-collector` / `observability` | Single OTLP entry point: traces to Tempo, metrics to Prometheus, logs to debug |
| [`grafana/`](grafana/) | `grafana` / `observability` | UI with Prometheus, Tempo and Alertmanager data sources; official Tempo dashboards as ConfigMaps |

## 🎚️ Profiles

`scripts/deploy.sh` picks the files with `PROFILE=prod|lab` (default `prod`): `values.yaml`, plus `values-lab.yaml`
when `PROFILE=lab` and the file exists. The object store is `OBJECT_STORE=gcs` for both profiles (`seaweedfs` is an
optional fallback for clusters without cloud object storage), and Tempo storage follows it (`TEMPO_STORAGE=gcs`, `s3`
or `local`).

| Chart | Production (`PROFILE=prod`) | Lab (`PROFILE=lab`) |
|---|---|---|
| Object store | GCS buckets (`infra/`, `ACCESS_MODE=bucket`), no manifests | Same GCS buckets (`ACCESS_MODE=conditional`), no manifests |
| kube-prometheus-stack | `kube-prometheus-stack/values.yaml` (2d local + Thanos sidecar) | `+ kube-prometheus-stack/values-lab.yaml` (2d / 8GiB local + Thanos sidecar to GCS) |
| Thanos | `thanos/` (`kubectl apply -k`, after Secret `thanos-objstore` and the bucket) | `thanos/overlays/lab/` (1 replica each, same Secret `type: GCS`) |
| Tempo | `tempo-distributed/values.yaml` + `--set storage.trace.gcs.bucket_name=…` + `--set ingest.kafka.address=$KAFKA_BOOTSTRAP` | `tempo/values.yaml` + `tempo/values-gcs.yaml` (single binary, blocks in GCS, `TEMPO_STORAGE=gcs`). Alternatives: `local` (PV only), `+ tempo/values-s3.yaml` with `TEMPO_STORAGE=s3` (SeaweedFS fallback) |
| OTel Collector | `otel-collector/values.yaml` (HPA 3–12, PDB, zone spread, exports to `tempo-distributor:4317`) | `+ otel-collector/values-lab.yaml` (1 replica, 100m / 256Mi, exports to `tempo:4317`) |
| Grafana | `grafana/values.yaml` (Prometheus data source → `thanos-query:10902`) | `+ grafana/values-lab.yaml` (same data source URL; SQLite on a 1Gi PVC) |

Tempo endpoints per profile:

| Profile | Collector exporter | Grafana Tempo data source |
|---|---|---|
| Production | `tempo-distributor.observability:4317` | `http://tempo-query-frontend.observability:3200` |
| Lab | `tempo.observability:4317` | `http://tempo.observability:3200` |

## 🗓️ Retention summary

| Signal | Lab (live) | Production (rendered, not run live) | Details |
|---|---|---|---|
| Traces | Tempo `720h`; blocks in GCS `tempo-traces-<suffix>`, lifecycle 33 days, WAL on a 50Gi PVC | Tempo `block_retention: 720h`; GCS `tempo-traces-<project>`, lifecycle 33 days | [`tempo/`](tempo/README.md#-retention-and-sizing), [`tempo-distributed/`](tempo-distributed/README.md#-retention-and-cost) |
| Metrics | Prometheus `2d` / `8GiB` on a 40Gi PVC + Thanos 30 days (raw, 5m, 1h); GCS `thanos-metrics-<suffix>`, lifecycle 35 days | Prometheus `2d` + Thanos 30 days (raw, 5m, 1h); GCS `thanos-metrics-<project>`, lifecycle 35 days | [`kube-prometheus-stack/`](kube-prometheus-stack/README.md#-retention), [`thanos/`](thanos/README.md) |

Bucket access (both profiles): `roles/storage.objectUser` on each bucket for the Workload Identity principal of each KSA,
plus `roles/storage.bucketViewer` for Tempo (it reads the bucket attributes at start), no keys
(`infra/create-gcs-bucket.sh`; production `ACCESS_MODE=bucket`, lab `conditional`; dedicated-`gsa` alternative in
[`../infra/`](../infra/README.md#-gcs-buckets-both-profiles)). All software is free and open source (Thanos,
Prometheus: Apache-2.0; Tempo, Grafana: AGPL-3.0). Only GCS storage/operations and persistent disks are billed.

## 🚀 Install order

Same order as `scripts/deploy.sh` (`namespaces objectstore prometheus certmanager traefik tempo collector grafana dashboards edge dns`);
the chart steps:

| Step | Command | Why |
|---|---|---|
| 1 | `helm repo add grafana-community https://grafana-community.github.io/helm-charts` | Tempo + Grafana charts (the old `grafana/helm-charts` ones are deprecated) |
| 2 | `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts` | kube-prometheus-stack |
| 3 | `helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts` | OTel Collector |
| 4 | `helm repo update` | Fetch the pinned chart versions |
| 5 | kube-prometheus-stack (command in its header); `deploy.sh` first creates the Thanos bucket and Secret `thanos-objstore` (with the SeaweedFS fallback it then applies `seaweedfs/` and waits for its bucket Job); then `thanos/` (lab: `thanos/overlays/lab/`) | **First:** creates the ServiceMonitor/PrometheusRule CRDs the other charts use |
| 6 | Tempo: prod `tempo-distributed` (after bucket + Kafka), lab `tempo` with `values-s3.yaml` | Must exist before the Collector sends traces |
| 7 | OTel Collector | Accepts OTLP from apps and Hermes Agent |
| 8 | Grafana (after Secret `grafana-admin` exists) | UI; reads the admin user from the Secret |
| 9 | `kubectl apply -f helm/tempo/prometheusrule-tempo-mixin.yaml -f helm/kube-prometheus-stack/rules/ -f helm/grafana/dashboards/` | Tempo rules/alerts, platform alerts ([`rules/`](kube-prometheus-stack/rules/README.md)) and the official Tempo dashboards ([`dashboards/`](grafana/dashboards/README.md)); `scripts/deploy.sh dashboards` |
| 10 | Production only: `kubectl apply -f helm/tempo-distributed/prometheusrule-rollout-operator.yaml` | Alerts for the single-replica rollout-operator ([details](tempo-distributed/README.md#-rollout-operator)) |

## 📌 Pinned versions

Images are pinned by tag **and** multi-arch index digest where the folder says so; the folder README lists every
digest.

| Chart | Chart version | Main image | Digest (multi-arch index) |
|---|---|---|---|
| prometheus-community/kube-prometheus-stack | 93.1.0 | prometheus-operator v0.95.1 | see [`kube-prometheus-stack/`](kube-prometheus-stack/) |
| grafana-community/tempo-distributed | 3.27.0 | `grafana/tempo:3.1.1` | `sha256:64e2fbd56d9c2b3412a4b430a58ea59e91a670b1e75f920a0c702213ad145044` (+ memcached, exporter, rollout-operator in [`tempo-distributed/`](tempo-distributed/README.md#-pinned-versions)) |
| grafana-community/tempo | 3.2.1 | `grafana/tempo:3.1.1` | `sha256:64e2fbd56d9c2b3412a4b430a58ea59e91a670b1e75f920a0c702213ad145044` |
| — (manifests in `thanos/`) | — | `quay.io/thanos/thanos:v0.42.5` | `sha256:0a546b98a8dd47735456ab389983675ee363d68127e334937a9fceeea10da5e7` |
| — (manifests in `seaweedfs/`, optional fallback) | — | `chrislusf/seaweedfs:4.52` | `sha256:57877e32bb90073b37dc109b438ba66e84fd5ed9ced5f5c04f56444ef243ce59` |
| open-telemetry/opentelemetry-collector | 0.178.2 | `otel/opentelemetry-collector-contrib:0.165.0` | `sha256:e40d61f10c9a617cca1ffd1be4d7e2b3a4b0f0001798ff07e58cabe82e618cea` |
| grafana-community/grafana | 14.4.0 | `grafana/grafana:13.3.0` | see [`grafana/`](grafana/) |

## 📏 Sizing (requests)

| Release | Production | Lab |
|---|---|---|
| Tempo | ≈ 14.2 vCPU / 54.7 GiB at HPA minimum, plus Kafka ([details](tempo-distributed/README.md#-sizing)) | 250m / 1Gi (limit 2Gi), 50Gi PVC `standard-rwo` (WAL; blocks in GCS), 720h retention |
| Thanos | ≈ 1.35 vCPU / 5.5 GiB incl. sidecars; PVCs 2 × 10Gi + 50Gi ([details](thanos/README.md#-sizing-and-cost)) | 110m / 608Mi incl. sidecar; PVCs 5Gi + 20Gi |
| SeaweedFS (optional fallback) | Not used (GCS) | Not used (GCS); when enabled 100m / 256Mi (limit 1Gi), 100Gi PVC `standard-rwo` |
| OTel Collector | 3 × 500m / 1Gi (limit 2Gi), HPA up to 12 | 100m / 256Mi (limit 512Mi) |
| kube-prometheus-stack, Grafana | see their folders | see their folders |

## 📋 Production checklist

Summary; each linked checklist has the details.

| Area | What to check | Details |
|---|---|---|
| HA sizing | Regional cluster ≥ 2 zones; Tempo live-stores zone-aware, Kafka partitions = live-store = block-builder replicas; Collector ≥ 3 replicas with PDB and zone spread | [Tempo](tempo-distributed/README.md#-production-checklist), [Collector](otel-collector/README.md#-production-checklist) |
| Kafka | External Kafka-compatible service, RF 3, TLS + SCRAM, topic pre-created | [Tempo](tempo-distributed/README.md#-kafka-required-in-tempo-3x-microservices-mode) |
| Backups | GCS is the system of record (traces and metrics history); versioning off by design, soft delete 7 days; lifecycle 33 days (traces) and 35 days (metrics) above the 30-day retention; Collector stateless | [Tempo](tempo-distributed/README.md#-production-checklist), [Thanos](thanos/README.md) |
| Upgrades | Bump chart + tag + digest together, `helm diff`, validate the Collector config with the new binary | [Tempo](tempo-distributed/README.md#-production-checklist), [Collector](otel-collector/README.md#-production-checklist) |
| Cost | Tempo ≈ 14 vCPU / 55 GiB + Kafka + GCS; tail sampling cuts volume | [Tempo](tempo-distributed/README.md#-sizing), [Collector](otel-collector/README.md#-tail-sampling-documented-not-enabled) |
| SLOs | Ingest 99.9% success, query latency targets, Collector export success | [Tempo](tempo-distributed/README.md#-production-checklist), [Collector](otel-collector/README.md#-production-checklist) |
| Runbooks | Tempo mixin alerts → official runbook; Collector alerts → its troubleshooting table | [Tempo](tempo-distributed/README.md#-production-checklist), [Collector](otel-collector/README.md#-production-checklist) |
| Storage access | `roles/storage.objectUser` on each bucket only for its WIF principals (`observability/tempo`, plus `roles/storage.bucketViewer`; Thanos KSAs in `monitoring`) | [Tempo](tempo-distributed/README.md#-install), [`infra/`](../infra/README.md#-gcs-buckets-both-profiles) |
| Thanos | One compactor per bucket; same Thanos version everywhere; budget alert and Data Access audit logs on the bucket | [Thanos](thanos/README.md) |
| Limits | Tempo per-tenant ingest, live-trace, trace-size and generator-series limits set and watched | [Tempo](tempo-distributed/README.md#-limits) |
| Prometheus, Grafana | Retention, HA, alert routing, admin secret | [`kube-prometheus-stack/`](kube-prometheus-stack/), [`grafana/`](grafana/) |

## 🔗 References

- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [grafana-community Helm charts](https://github.com/grafana-community/helm-charts)
- [OpenTelemetry Helm charts](https://github.com/open-telemetry/opentelemetry-helm-charts)
- [Grafana Tempo documentation](https://grafana.com/docs/tempo/latest/)
- [Grafana documentation](https://grafana.com/docs/grafana/latest/)
- [OpenTelemetry Collector documentation](https://opentelemetry.io/docs/collector/)
