# 📦 Helm values

Values files for the Helm releases that make up the observability stack. Every `values.yaml` holds the
**production** defaults; a `values-lab.yaml` next to it shrinks sizes for the small lab cluster. Every file starts
with a header that gives the chart, chart version, app version and the exact `helm upgrade --install` command.

**Status:** ✅ the lab profile runs on the lab cluster (2026-11-08). Every profile below renders with
`helm template` and passes `helm lint` and `kubeconform -strict` (Kubernetes 1.36) against the pinned chart; the
production profiles have not been run on a cluster. Each folder's README is authoritative for its chart.

## 🧩 Releases

| Dir | Release / namespace | What it does (one line) |
|---|---|---|
| [`kube-prometheus-stack/`](kube-prometheus-stack/) | `prometheus` / `monitoring` | Prometheus (remote-write receiver + exemplars), Alertmanager, operator, exporters, CRDs |
| [`tempo-distributed/`](tempo-distributed/) | `tempo` / `observability` | Production trace store: Tempo microservices, GCS blocks, external Kafka, HA |
| [`tempo/`](tempo/) | `tempo` / `observability` | Lab trace store: Tempo single binary on a local PV; metrics-generator; Tempo rules/alerts |
| [`otel-collector/`](otel-collector/) | `otel-collector` / `observability` | Single OTLP entry point: traces to Tempo, metrics to Prometheus, logs to debug |
| [`grafana/`](grafana/) | `grafana` / `observability` | UI with Prometheus, Tempo and Alertmanager data sources; official Tempo dashboards as ConfigMaps |

## 🎚️ Profiles

`scripts/deploy.sh` picks the files with `PROFILE=prod|lab` (default `prod`): `values.yaml`, plus `values-lab.yaml`
when `PROFILE=lab` and the file exists.

| Chart | Production (`PROFILE=prod`) | Lab (`PROFILE=lab`) |
|---|---|---|
| kube-prometheus-stack | `kube-prometheus-stack/values.yaml` | `+ kube-prometheus-stack/values-lab.yaml` |
| Tempo | `tempo-distributed/values.yaml` + `--set storage.trace.gcs.bucket_name=…` + `--set ingest.kafka.address=$KAFKA_BOOTSTRAP` | `tempo/values.yaml` (single binary, local PV; it is the lab profile, no overlay). Optional, not used in the lab: `+ tempo/values-gcs.yaml` with `TEMPO_STORAGE=gcs` |
| OTel Collector | `otel-collector/values.yaml` (HPA 3–12, PDB, zone spread, exports to `tempo-distributor:4317`) | `+ otel-collector/values-lab.yaml` (1 replica, 100m / 256Mi, exports to `tempo:4317`) |
| Grafana | `grafana/values.yaml` | `+ grafana/values-lab.yaml` when present |

Tempo endpoints per profile:

| Profile | Collector exporter | Grafana Tempo data source |
|---|---|---|
| Production | `tempo-distributor.observability:4317` | `http://tempo-query-frontend.observability:3200` |
| Lab | `tempo.observability:4317` | `http://tempo.observability:3200` |

Trace storage: production keeps blocks in GCS with Workload Identity scoped to the bucket
(`infra/create-tempo-bucket.sh`, `ACCESS_MODE=principal`, no keys, no Google service account). The lab keeps blocks
on a local PV. The script's `ACCESS_MODE=gsa` (impersonate an existing Google service account) is **not
recommended**: that account is usually project-wide.

## 🚀 Install order

Same order as `scripts/deploy.sh` (`namespaces prometheus certmanager traefik tempo collector grafana dashboards edge dns`);
the chart steps:

| Step | Command | Why |
|---|---|---|
| 1 | `helm repo add grafana-community https://grafana-community.github.io/helm-charts` | Tempo + Grafana charts (the old `grafana/helm-charts` ones are deprecated) |
| 2 | `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts` | kube-prometheus-stack |
| 3 | `helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts` | OTel Collector |
| 4 | `helm repo update` | Fetch the pinned chart versions |
| 5 | kube-prometheus-stack (command in its header) | **First:** creates the ServiceMonitor/PrometheusRule CRDs the other charts use |
| 6 | Tempo: prod `tempo-distributed` (after bucket + Kafka), lab `tempo` | Must exist before the Collector sends traces |
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
| open-telemetry/opentelemetry-collector | 0.178.2 | `otel/opentelemetry-collector-contrib:0.165.0` | `sha256:e40d61f10c9a617cca1ffd1be4d7e2b3a4b0f0001798ff07e58cabe82e618cea` |
| grafana-community/grafana | 14.4.0 | `grafana/grafana:13.3.0` | see [`grafana/`](grafana/) |

## 📏 Sizing (requests)

| Release | Production | Lab |
|---|---|---|
| Tempo | ≈ 14.2 vCPU / 54.7 GiB at HPA minimum, plus Kafka ([details](tempo-distributed/README.md#-sizing)) | 250m / 1Gi (limit 2Gi), 10Gi PVC `standard-rwo`, 24h retention |
| OTel Collector | 3 × 500m / 1Gi (limit 2Gi), HPA up to 12 | 100m / 256Mi (limit 512Mi) |
| kube-prometheus-stack, Grafana | see their folders | see their folders |

## 📋 Production checklist

Summary; each linked checklist has the details.

| Area | What to check | Details |
|---|---|---|
| HA sizing | Regional cluster ≥ 2 zones; Tempo live-stores zone-aware, Kafka partitions = live-store = block-builder replicas; Collector ≥ 3 replicas with PDB and zone spread | [Tempo](tempo-distributed/README.md#-production-checklist), [Collector](otel-collector/README.md#-production-checklist) |
| Kafka | External Kafka-compatible service, RF 3, TLS + SCRAM, topic pre-created | [Tempo](tempo-distributed/README.md#-kafka-required-in-tempo-3x-microservices-mode) |
| Backups | Trace blocks in GCS (soft delete; lifecycle 16 days above 14-day retention); Collector stateless | [Tempo](tempo-distributed/README.md#-production-checklist) |
| Upgrades | Bump chart + tag + digest together, `helm diff`, validate the Collector config with the new binary | [Tempo](tempo-distributed/README.md#-production-checklist), [Collector](otel-collector/README.md#-production-checklist) |
| Cost | Tempo ≈ 14 vCPU / 55 GiB + Kafka + GCS; tail sampling cuts volume | [Tempo](tempo-distributed/README.md#-sizing), [Collector](otel-collector/README.md#-tail-sampling-documented-not-enabled) |
| SLOs | Ingest 99.9% success, query latency targets, Collector export success | [Tempo](tempo-distributed/README.md#-production-checklist), [Collector](otel-collector/README.md#-production-checklist) |
| Runbooks | Tempo mixin alerts → official runbook; Collector alerts → its troubleshooting table | [Tempo](tempo-distributed/README.md#-production-checklist), [Collector](otel-collector/README.md#-production-checklist) |
| Storage access | Bucket IAM only for the WIF principal `ns/observability/sa/tempo` | [Tempo](tempo-distributed/README.md#-install) |
| Limits | Tempo per-tenant ingest, live-trace, trace-size and generator-series limits set and watched | [Tempo](tempo-distributed/README.md#-limits) |
| Prometheus, Grafana | Retention, HA, alert routing, admin secret | [`kube-prometheus-stack/`](kube-prometheus-stack/), [`grafana/`](grafana/) |

## 🔗 References

- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [grafana-community Helm charts](https://github.com/grafana-community/helm-charts)
- [OpenTelemetry Helm charts](https://github.com/open-telemetry/opentelemetry-helm-charts)
- [Grafana Tempo documentation](https://grafana.com/docs/tempo/latest/)
- [Grafana documentation](https://grafana.com/docs/grafana/latest/)
- [OpenTelemetry Collector documentation](https://opentelemetry.io/docs/collector/)
