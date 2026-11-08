# 📈 kube-prometheus-stack

Prometheus, Alertmanager, the Prometheus operator, kube-state-metrics and node-exporter, plus this project's alert
rules for the Collector, Traefik, cert-manager and Grafana. **Why:** stores the span metrics and service-graph metrics
that Tempo's metrics-generator remote-writes, the OTLP metrics from the Collector and cluster metrics, with exemplars
so a latency spike links to the trace behind it, and routes alerts by severity.

**Status (2026-11-08, chart 93.1.0):** the **lab** profile (`values.yaml` + `values-lab.yaml`) matches the release
running on the lab cluster (same values; it adds image digests, the route tree, anti-affinity, config-reloader
requests of 5m / 16Mi per pod and no service account token in the Alertmanager pod).
Both profiles keep 2 days locally plus the Thanos sidecar (30 days via [`../thanos/`](../thanos/README.md)) uploading to
a GCS bucket through Workload Identity. The lab is live on GCS (2026-11-08: bucket `thanos-metrics-<suffix>`;
`PROFILE=lab scripts/verify.sh` 31 PASS, 0 failures). The **production** profile (`values.yaml`
alone: 2 days locally plus the Thanos sidecar uploading to GCS) passes
`helm lint`, `helm template`, kubeconform (Kubernetes 1.36, strict) and `promtool`; it has not been installed on a
multi-zone cluster yet.

## 🧩 Components

| Name | What it does (one line) | Where defined | Security role |
|---|---|---|---|
| Prometheus `prometheus-kube-prometheus-prometheus:9090` | Scrapes monitors in all namespaces, accepts remote write, keeps exemplars | [`values.yaml`](values.yaml) `prometheus` | Internal only; non-root UID 1000, read-only root FS |
| Thanos sidecar (both profiles) | Uploads each 2h block to the bucket (GCS: prod `thanos-metrics-<project>`, lab `thanos-metrics-<suffix>`); serves recent data to `thanos-query` | `prometheusSpec.thanos`, `thanosService`, `thanosServiceMonitor` ([`../thanos/`](../thanos/README.md)) | KSA `prometheus-kube-prometheus-prometheus` with `roles/storage.objectUser` via Workload Identity, no keys (both profiles) |
| Alertmanager `prometheus-kube-prometheus-alertmanager:9093` | Groups, inhibits and routes alerts by severity to Slack / PagerDuty | `alertmanager` | Credentials only as files from Secret `alertmanager-receivers` |
| Prometheus operator | Turns ServiceMonitor/PodMonitor/PrometheusRule objects into config; serves the admission webhook | `prometheusOperator` | Cluster-scoped RBAC from the chart |
| config-reloader | Reloads Prometheus/Alertmanager when their config changes | `prometheusOperator.prometheusConfigReloader` | Sidecar, same restricted context |
| kube-state-metrics | Kubernetes object metrics | `kube-state-metrics` | Read-only cluster access |
| node-exporter (DaemonSet) | Node CPU, memory, disk, network metrics | `prometheus-node-exporter` | Host access (PSS exception, see Security) |
| Dashboard ConfigMaps | Default dashboards for the separate Grafana release | `grafana.forceDeployDashboards` | Label `grafana_dashboard="1"` |
| Alert rules (4 PrometheusRules) | Collector, Traefik, cert-manager, Grafana alerts | [`rules/`](rules/) | Read-only config |

Other alert rules in this repo, picked up the same way: Tempo mixin
[`../tempo/prometheusrule-tempo-mixin.yaml`](../tempo/prometheusrule-tempo-mixin.yaml), sample apps
[`../../apps/monitoring/prometheusrule.yaml`](../../apps/monitoring/prometheusrule.yaml), Hermes
[`../../hermes/base/prometheusrule.yaml`](../../hermes/base/prometheusrule.yaml).

## ⚖️ Lab vs production

`values.yaml` = production defaults; [`values-lab.yaml`](values-lab.yaml) = lab overlay (3 x e2-standard-2, one zone).

| Setting | Production (`values.yaml`) | Lab (`+ values-lab.yaml`) |
|---|---|---|
| Prometheus replicas / PDB | 2, hard anti-affinity per node, spread over zones / `minAvailable: 1` | 1 / none |
| Prometheus retention / size cap / PVC | `2d` / `85GiB` / 100Gi `standard-rwo` (30 days in GCS via Thanos) | `2d` / `8GiB` / 40Gi `standard-rwo` (30 days in GCS via Thanos; the PVC was 40Gi before and cannot shrink) |
| Thanos sidecar / local compaction | Sidecar on (50m, 256Mi / 1Gi), `disableCompaction: true` | Sidecar on (10m, 64Mi / 256Mi), `disableCompaction: true` |
| Thanos object store (Secret `thanos-objstore`, key `objstore.yml`) | `type: GCS`, bucket name only (Workload Identity) | Same: `type: GCS`, bucket name only (`thanos-metrics-<suffix>`, written by `scripts/deploy.sh`) |
| Grafana / Hermes query endpoint | `http://thanos-query.monitoring:10902` | Same |
| Prometheus requests / memory limit | 1 CPU, 4Gi / 8Gi | 300m, 1Gi / 1536Mi |
| Alertmanager replicas / PDB / PVC | 2 (gossip cluster) / `minAvailable: 1` / 2Gi | 1 / none / none (emptyDir) |
| Alertmanager receivers | `default` (Slack), `critical` (PagerDuty + Slack), `null` | Same names, no integrations, no Secret |
| Alertmanager requests / limit | 50m, 128Mi / 256Mi | 10m, 32Mi / 128Mi |
| Operator requests / limit | 100m, 128Mi / 512Mi | 50m, 64Mi / 256Mi |
| config-reloader requests / limit (per pod) | 10m, 32Mi / 64Mi | 5m, 16Mi / 48Mi |
| Alertmanager service account token | Not mounted (`automountServiceAccountToken: false`) | Same |
| kube-state-metrics requests / limit | 50m, 128Mi / 512Mi | 10m, 64Mi / 256Mi |
| node-exporter requests / limit | 20m, 32Mi / 128Mi | 10m, 32Mi / 64Mi |
| Images | Tag + digest | Same |
| Selectors, remote-write receiver, exemplars, security contexts, route tree | As below | Same |

**Total requests** (3 nodes): production 2.35 vCPU / 8.72 GiB + 204Gi of PVCs, plus 2 × 50m / 256Mi for the Thanos
sidecars (Thanos query, store and compactor: [`../thanos/`](../thanos/README.md)); lab 0.42 vCPU / 1.34 GiB + 40Gi PVC
(the running lab release plus 10m / 32Mi for the two config-reloader sidecars and 10m / 64Mi for the Thanos sidecar).

## 🗓️ Retention

| Profile | Local TSDB | Long-term | Tested? |
|---|---|---|---|
| Lab | `retention: 2d`, `retentionSize: 8GiB` on a 40Gi PVC | Thanos: raw, 5m and 1h kept 30 days in GCS; bucket lifecycle 35 days | ✅ Live (2026-11-08) |
| Production | `retention: 2d`, `retentionSize: 85GiB` on a 100Gi PVC | Thanos: raw, 5m and 1h kept 30 days in GCS; bucket lifecycle 35 days | Rendered and validated only |

Measured lab ingest (2026-11-08): 3,429 samples/s, 150,952 head series, so 8.89 billion samples and ~12–18 GB raw per
replica in 30 days (in the bucket); 2 days locally is ~1–2 GB plus the WAL, so `8GiB` is a safety cap only. The lab
PVC stays 40Gi because a PVC cannot shrink; a smaller disk needs a new PVC on a fresh install. When the lab switched to
the sidecar, blocks that Prometheus had already compacted locally were not uploaded (the sidecar ships only 2h blocks), so
history older than the switch (a few hours in the lab) is gone after 2 days. History started on 2026-11-08, so 30-day
trends fill in over time.

**How the lab PVC was expanded (10Gi → 40Gi, online):** `standard-rwo` allows volume expansion. The PVC request was
raised to 40Gi, the new size set in `values-lab.yaml` (`storageSpec`) and applied with `helm upgrade`; the operator
then recreated its StatefulSet with the new `volumeClaimTemplates` (the pod and its data stay). Check with
`kubectl -n monitoring get pvc` (`CAPACITY 40Gi`). Prometheus operator guide:
[storage](https://prometheus-operator.dev/docs/platform/storage/).

## 📌 Pinned images

Multi-arch index digests read from each registry's v2 API (`HEAD /v2/<repo>/manifests/<tag>`) on 2026-11-08; the
digests of the images running in the lab match.

| Image | Tag | Digest | Runs |
|---|---|---|---|
| `quay.io/prometheus/prometheus` | `v3.16.0-distroless` | `sha256:9764044e09eb2c9e1abdb12d0f0188d4efb7384b0262d3c080f0fc59045c89ba` | Prometheus |
| `quay.io/prometheus/alertmanager` | `v0.34.2` | `sha256:39d8bb3966c694a124428a3a88fbcffd40bd069129ecd47c059f8a3f17c55f3b` | Alertmanager |
| `quay.io/prometheus-operator/prometheus-operator` | `v0.95.1` | `sha256:9c2490af910d58ec2abd77642d340e30bd5e2de5c80fd19ab4b49e28dc7bbb83` | Operator |
| `quay.io/prometheus-operator/prometheus-config-reloader` | `v0.95.1` | `sha256:39bdbade0c64f7c38bb6d18d6f602b14ad489bc189b709dc9266b49e6647aac1` | Init + sidecar in Prometheus/Alertmanager |
| `registry.k8s.io/kube-state-metrics/kube-state-metrics` | `v2.20.0` | `sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b` | kube-state-metrics |
| `quay.io/prometheus/node-exporter` | `v1.12.1-distroless` | `sha256:8c9bac11973b94b59be88d6e11fee4429aa743c8846cdc75d65b18db33f6a106` | node-exporter |
| `ghcr.io/jkroepke/kube-webhook-certgen` | `1.11.1` | `sha256:8009b04f9873f7279b5adee37fdd03b6a9aa7b6751d4f69fde2683010e41cd1f` | Webhook cert Jobs (install/upgrade) |
| `quay.io/prometheus-operator/admission-webhook` | `v0.95.1` | `sha256:5a5b2a9302e2373fc5ff5979d4d773690e05ab072b1ad49eb985529042199f3f` | Not deployed (pinned) |
| `quay.io/thanos/thanos` | `v0.42.5` | `sha256:0a546b98a8dd47735456ab389983675ee363d68127e334937a9fceeea10da5e7` | Thanos sidecar in the Prometheus pods (both profiles) |

Re-resolve a digest after a version bump, for example:

```bash
curl -sI -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
  https://quay.io/v2/prometheus/prometheus/manifests/v3.16.0-distroless | grep -i docker-content-digest
```

The digest field differs per chart: kube-prometheus-stack `sha:` takes the hex only, kube-state-metrics `sha:` takes
`sha256:<hex>`, node-exporter `digest:` takes `sha256:<hex>`.

## ⚙️ Key settings

| Setting | Value | Why |
|---|---|---|
| `grafana.enabled` / `forceDeployDashboards` | `false` / `true` | Grafana is its own release ([`../grafana/`](../grafana/)); keep the dashboard ConfigMaps |
| `grafana.sidecar.datasources.defaultDatasourceEnabled` | `false` | Prometheus uid `prometheus` is provisioned by the Grafana release; avoids a duplicate uid |
| `*SelectorNilUsesHelmValues` (serviceMonitor, podMonitor, rule) | `false` | Pick up monitors and rules from every namespace without a `release` label |
| `enableRemoteWriteReceiver` | `true` | Tempo metrics-generator (and Hermes, optional) push to `/api/v1/write` |
| `enableFeatures` | `[exemplar-storage]` | Stores trace IDs on histogram samples for metrics-to-traces links |
| `prometheus.service.sessionAffinity` | `ClientIP` | A Grafana pod keeps reading the same replica |
| `kubeProxy`, `kubeControllerManager`, `kubeScheduler`, `coreDns`, `kubeEtcd` | disabled (+ matching default rules) | GKE manages the control plane; these targets cannot be scraped |
| CPU limits | not set (memory limits everywhere) | CPU throttling causes missed scrapes and rule evaluations |

## 🚀 Install

1. Production only: create the receivers Secret (values read from local files, never typed on the command line):

   ```bash
   kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n monitoring create secret generic alertmanager-receivers \
     --from-file=slack-webhook-url="$SLACK_WEBHOOK_URL_FILE" \
     --from-file=pagerduty-routing-key="$PAGERDUTY_ROUTING_KEY_FILE" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

2. Install the chart (first of all releases: it creates the `ServiceMonitor` and `PrometheusRule` CRDs):

   ```bash
   # production
   helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version 93.1.0 \
     --namespace monitoring --create-namespace -f helm/kube-prometheus-stack/values.yaml
   # lab
   helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version 93.1.0 \
     --namespace monitoring --create-namespace -f helm/kube-prometheus-stack/values.yaml \
     -f helm/kube-prometheus-stack/values-lab.yaml
   ```

   `scripts/deploy.sh prometheus` does the same, selecting the profile with `PROFILE=prod|lab`.

3. Load the alert rules:

   ```bash
   kubectl apply -f helm/kube-prometheus-stack/rules/
   ```

## 🔔 Alert routing

The route tree lives in `alertmanager.config` ([`values.yaml`](values.yaml)) and contains no credentials.

| Match | Receiver | Repeat |
|---|---|---|
| `alertname =~ Watchdog\|InfoInhibitor` | `null` (dropped) | — |
| `severity = critical` | `critical`: PagerDuty + Slack | 1h |
| `severity = warning` | `default`: Slack | 4h |
| `severity = info` | `null` (visible in the UI only) | — |
| anything else | `default` | 4h |

Grouping `alertname, namespace, severity`; a critical alert inhibits the warning/info alert with the same name and
namespace; `InfoInhibitor` mutes info alerts.

**Credentials:** `alertmanagerSpec.secrets: [alertmanager-receivers]` mounts the Secret read-only at
`/etc/alertmanager/secrets/alertmanager-receivers/`; the receivers read it with `api_url_file` (Slack) and
`routing_key_file` (PagerDuty). The Secret can be created by hand (Install step 1) or by External Secrets Operator
from Google Secret Manager (an `ExternalSecret` whose target is `alertmanager-receivers` with the same two keys).

**Add or change a receiver:**

| Want | Do |
|---|---|
| Slack | Create an incoming webhook for the channel; put its URL in key `slack-webhook-url` |
| PagerDuty | Create an Events API v2 integration on the service; put its routing key in key `pagerduty-routing-key` |
| Another integration (email, Opsgenie, webhook) | Add a key to the Secret, add a receiver using that integration's `*_file` field pointing to `/etc/alertmanager/secrets/alertmanager-receivers/<key>`, route to it |
| Dead man's switch | Route `Watchdog` to a heartbeat service instead of `null` |

After a Secret change, Alertmanager reads the new file on the next notification; after a values change, re-run the
`helm upgrade`. Check the result with `amtool config routes` inside the pod or the Alertmanager UI → Status.

## 🚨 Alert rules and runbooks

| File | Alerts | Source metrics |
|---|---|---|
| [`rules/otel-collector.yaml`](rules/otel-collector.yaml) | 7 | Collector internal telemetry `otelcol_*` (job `otel-collector`, endpoint `metrics`) |
| [`rules/traefik.yaml`](rules/traefik.yaml) | 2 | `traefik_service_requests_total`, `up` (job `traefik-metrics`) |
| [`rules/cert-manager.yaml`](rules/cert-manager.yaml) | 4, label `tls_mode=letsencrypt` | `certmanager_certificate_*` (job `cert-manager`) |
| [`rules/grafana.yaml`](rules/grafana.yaml) | 2 | `up` (job `grafana`) |

The Collector 0.165.0 exposes its counters without the `_total` suffix (internal telemetry default
`without_type_suffix: true`), so the rules use `otelcol_receiver_refused_spans`, not `..._total`. cert-manager alerts
only apply with `TLS_MODE=letsencrypt` and need cert-manager metrics scraped (`prometheus.servicemonitor.enabled` in
`k8s/cert-manager-values.yaml` plus the NetworkPolicy allowing Prometheus to port 9402 in `k8s/cert-manager.yaml`);
with `TLS_MODE=cloudflare`, which the lab runs (cert-manager not installed), they match nothing and stay silent.

#### OtelCollectorDown
Critical. No Collector target answers. Check `kubectl -n observability get pods -l app.kubernetes.io/name=opentelemetry-collector`,
`kubectl -n observability logs deploy/otel-collector`; an OOMKill means the memory limit is too low for the load.

#### OtelCollectorReceiverRefusing
Warning. Receivers return retryable errors, usually because `memory_limiter` is above its limit or an exporter queue
is full. Check the two alerts below; scale the Collector out or raise its memory limit.

#### OtelCollectorReceiverFailed
Warning. Payloads the receiver could not decode or process. Check Collector logs for the sender and fix its exporter
(protocol, encoding, size).

#### OtelCollectorMemoryLimiterRefusing
Warning. The pod is near its memory limit and refuses data. Raise `resources.limits.memory` in
`helm/otel-collector/values*.yaml` or add replicas; check for a sender burst.

#### OtelCollectorExporterSendFailing
Critical. Over 1% of exports fail after all retries; that data is lost. Check the backend (`tempo` or
`tempo-distributor` in `observability`), its logs and the `observability` NetworkPolicies.

#### OtelCollectorExporterEnqueueFailed
Critical. The sending queue is full; new data is dropped. The backend is too slow or down: fix it first, then size
`sending_queue.queue_size`.

#### OtelCollectorExporterQueueSaturated
Warning. Queue above 80%: early warning before `OtelCollectorExporterEnqueueFailed`. Same checks.

#### TraefikDown
Critical. No Traefik pod is scraped: all public hosts are down. `kubectl -n traefik get pods,svc`, check the load
balancer and `kubectl -n traefik logs deploy/traefik`.

#### TraefikHigh5xxRatio
Warning. A routed service returns over 5% 5xx (above 0.1 req/s). Find the backend from `exported_service`, check its
pods and logs; Traefik itself returns 502/504 when the backend is unreachable or slow.

#### CertManagerDown
Warning (letsencrypt only). The controller is not scraped; renewals stop while it is down.
`kubectl -n cert-manager get pods`, logs of `deploy/cert-manager`.

#### CertManagerCertificateNotReady
Critical (letsencrypt only). `kubectl get certificate -A`, then `kubectl describe certificaterequest,order,challenge -n <ns>`;
DNS-01 failures are usually an expired or under-scoped Cloudflare token.

#### CertManagerCertificateExpiringSoon
Warning under 21 days, critical under 7 days (`CertManagerCertificateExpiryCritical`). Renewal has been failing for
over a week: same checks as `CertManagerCertificateNotReady`.

#### GrafanaDown
Critical. No Grafana pod is scraped. `kubectl -n observability get pods -l app.kubernetes.io/name=grafana`; common
causes: missing Secret `grafana-admin` or `grafana-db`, database unreachable (production). See
[`../grafana/README.md`](../grafana/README.md) (Troubleshooting).

#### GrafanaReplicaDown
Warning. One replica is down; the other still serves. Same checks as `GrafanaDown`.

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| Pods ready | `kubectl -n monitoring get pods` | Prometheus, Alertmanager, operator, kube-state-metrics, node-exporter `Running` (2 + 2 in production) |
| PDBs (production) | `kubectl -n monitoring get pdb` | Prometheus and Alertmanager, `ALLOWED DISRUPTIONS 1` |
| Remote-write receiver on | `kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090` then `curl -s localhost:9090/api/v1/status/flags \| grep remote-write-receiver` | `"web.enable-remote-write-receiver":"true"` |
| Targets | Prometheus UI → Status → Targets | `tempo`, `otel-collector`, `grafana`, `traefik-metrics` up |
| Rules loaded | `curl -s localhost:9090/api/v1/rules \| jq -r '.data.groups[].name' \| grep -E 'otel-collector\|traefik\|grafana\|cert-manager'` | 4 groups |
| Alertmanager cluster (production) | `kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-alertmanager 9093` then `curl -s localhost:9093/api/v2/status \| jq '.cluster.peers\|length'` | `2` |
| Span metrics arriving | Query `traces_spanmetrics_calls_total` | Series per `service` once apps send traffic |

## 🛡️ Security

| Threat | Control | How it's enforced | Test that proves it |
|---|---|---|---|
| Prometheus/Alertmanager exposed publicly | ClusterIP only, no Ingress; default-deny NetworkPolicy in `monitoring` | Values + `k8s/networkpolicies.yaml` | `kubectl -n monitoring get ingress` is empty |
| Receiver credentials in Git or in the rendered config | Credentials only as files from Secret `alertmanager-receivers` | `api_url_file`, `routing_key_file`, `alertmanagerSpec.secrets` | `grep -rE 'hooks.slack.com\|routing_key:' helm/` finds nothing |
| Anyone in-cluster can remote-write | NetworkPolicy allows 9090 only from Grafana, Tempo and the `hermes` namespace | `k8s/networkpolicies.yaml` | Not authenticated (Prometheus has no write auth) |
| Container privilege | Non-root, `RuntimeDefault` seccomp, read-only root FS, no privilege escalation, ALL capabilities dropped | `securityContext` + operator defaults | `kubectl -n monitoring get pod -o jsonpath='{..securityContext}'` |
| Stolen API token from Alertmanager | No service account token mounted (Alertmanager and its reloader read only mounted files) | `alertmanagerSpec.automountServiceAccountToken: false` | `kubectl -n monitoring get pod -l app.kubernetes.io/name=alertmanager -o jsonpath='{..automountServiceAccountToken}'` prints `false` |
| Moving image tags | Tag + digest on every image | `image.sha` / `image.digest` | `helm template ... \| grep 'image:'` shows `@sha256:` on all |

**Pod Security exception:** node-exporter needs `hostNetwork`, `hostPID` and read-only `hostPath` mounts of `/`,
`/proc` and `/sys` to read node metrics, which PSS `restricted` and `baseline` forbid. Namespace `monitoring`
therefore stays at `pod-security.kubernetes.io/enforce=privileged` (with `warn`/`audit=baseline`); node-exporter
still runs as UID 65534 with a read-only root FS, no privilege escalation and ALL capabilities dropped. Every other
pod in the namespace meets `restricted`.

**Not protected:** remote write has no authentication; the operator and kube-state-metrics have cluster-wide read
RBAC from the chart.

## 🏭 Production checklist

| Area | Production setting / action |
|---|---|
| HA sizing | 2 Prometheus (1 CPU / 4Gi request, 8Gi limit) and 2 Alertmanager replicas on different nodes, spread over zones, PDB `minAvailable: 1`. Re-size from `prometheus_tsdb_head_series` (roughly 4 KiB of RAM per active series incl. headroom) |
| Remote write to both replicas | The Service load-balances, so a remote-write sender pointed at it splits its data between replicas. Point senders (Tempo metrics-generator, Hermes) at both pods: `http://prometheus-prometheus-kube-prometheus-prometheus-0.prometheus-operated.monitoring:9090/api/v1/write` and `...-1...`. Reads go through `thanos-query`, which deduplicates the pair |
| Retention | Local `2d` (buffer for sidecar upload retries); 30 days of history in GCS via Thanos ([`../thanos/README.md`](../thanos/README.md)); bucket lifecycle 35 days (30 days + 48h compactor delete delay) |
| Thanos prerequisites | Secret `monitoring/thanos-objstore` (bucket name only, no key; created by `scripts/deploy.sh`) and `roles/storage.objectUser` on the bucket for KSA `prometheus-kube-prometheus-prometheus` before install |
| Disk | `85GiB` cap on a 100Gi PD; with 2-day retention ~1–2 GB is used, so a fresh install can use a smaller PVC (~20Gi); alert `KubePersistentVolumeFillingUp` (default rules) covers it |
| Backups | The Thanos bucket is the system of record for history (soft delete, default 7 days; versioning off by design); the local PVCs are not backed up. Alertmanager silences live on its 2Gi PVC and are replicated by gossip |
| Upgrades | Read the chart's UPGRADE notes; apply the new operator CRDs server-side first (below); `helm diff` then `helm upgrade`; rollback with `helm rollback prometheus <rev>` (CRDs are not rolled back) |
| Cost (requests) | 2.35 vCPU / 8.72 GiB requests and 204Gi `standard-rwo` for 3 nodes; node-exporter adds 20m / 32Mi per extra node |
| SLOs | Alerting pipeline: `Watchdog` always firing (route it to a dead man's switch to page when it stops); sample-app SLOs in [`../../apps/monitoring/prometheusrule.yaml`](../../apps/monitoring/prometheusrule.yaml) |
| Runbooks | Every project alert has `runbook_url` → [Alert rules and runbooks](#-alert-rules-and-runbooks); default kube-prometheus alerts link to runbooks.prometheus-operator.dev |
| Secrets | `alertmanager-receivers` from a Secret manager (External Secrets) in production, rotated there |

## 🔄 Upgrades (CRDs)

Chart 93.1.0 ships the operator v0.95.1 CRDs in its `crds` subchart, so Helm creates them on the first install. Helm
never updates CRDs on `helm upgrade`. Before upgrading to a chart with a newer operator, apply that operator's CRDs
server-side (replace `v0.95.1` with the new chart's `appVersion`):

```bash
kubectl apply --server-side --force-conflicts \
  -f https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.95.1/stripped-down-crds.yaml
```

## 🧪 Tests

Run on 2026-11-08 with chart 93.1.0, helm v3.17.3, kubeconform v0.8.0, promtool 3.16.0, amtool 0.34.2.

| Test | Command (from the repo dir) | Result |
|---|---|---|
| Lint, production | `helm lint <chart> -f helm/kube-prometheus-stack/values.yaml` | 0 failed |
| Lint, lab | `helm lint <chart> -f .../values.yaml -f .../values-lab.yaml` | 0 failed |
| Schema, production | `helm template ... \| kubeconform -strict -kubernetes-version 1.36.0` + CRDs-catalog | 97 valid, 0 invalid |
| Schema, lab | same with `values-lab.yaml` (adds the Thanos discovery Service and sidecar ServiceMonitor) | 95 valid, 0 invalid |
| Schema, rules | `kubeconform -strict ... helm/kube-prometheus-stack/rules/` | 4 valid |
| Rule syntax | `promtool check rules` on each rule file's `spec` | 15 rules, all `SUCCESS` |
| Rules on real data | Each expression queried on the lab Prometheus | All valid; none firing; source series present |
| Alertmanager config | `amtool check-config` (0.34.2) on the rendered config, both profiles | `SUCCESS`, 3 receivers, 4 inhibit rules |
| Routing | `amtool config routes test severity=critical` / `warning` / `info`, `alertname=Watchdog` | `critical` / `default` / `null` / `null` |
| Lab = live | `helm get values prometheus -n monitoring` vs the lab profile; pod requests | Same requests except the config-reloader requests (5m / 16Mi per pod, measured use ~1m / ~11Mi); diff = digests, route tree, anti-affinity, session affinity, reloader requests, Alertmanager token mount |
| Restricted context | Rendered pods checked for non-root, seccomp, no escalation, drop ALL, requests, memory limit, digest | All pass except node-exporter host access (documented) |

`<chart>` is `helm pull prometheus-community/kube-prometheus-stack --version 93.1.0 --untar`.

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Tempo/Collector install fails: no kind `ServiceMonitor` | CRDs not installed yet | Install this release first |
| Alertmanager pods `ContainerCreating`, event `secret "alertmanager-receivers" not found` | Production profile without the receivers Secret | Install step 1, or use the lab overlay |
| Second Prometheus/Alertmanager pod `Pending` (anti-affinity) | Fewer schedulable nodes than replicas | Add a node; the anti-affinity is hard on purpose |
| Span metrics missing on one replica only | Sender writes to the Service, not to both pods | See "Remote write to both replicas" |
| `remote write receiver needs to be enabled` errors in Tempo | Flag off | Check `enableRemoteWriteReceiver: true` and re-run the install |
| Prometheus PVC `Pending` | `standard-rwo` missing | `kubectl get storageclass`; GKE provides `standard-rwo` by default |
| Disk full / OOM | Too many series | Lower retention or drop labels; check `prometheus_tsdb_head_series` |
| Prometheus pods `CreateContainerConfigError` | Secret `thanos-objstore` missing (both profiles) | Create it ([`../thanos/README.md`](../thanos/README.md) Install) or run `scripts/deploy.sh prometheus` |
| `helm upgrade` changes the PVC size but the disk stays small | StatefulSet `volumeClaimTemplates` are immutable | Raise the PVC request (`kubectl patch pvc`), then let the operator recreate the StatefulSet ([Retention](#-retention)) |
| Collector alerts never fire | Metric names with `_total` | The rules already use the suffix-less names exposed by the Collector |

## 🔗 References

- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus operator releases](https://github.com/prometheus-operator/prometheus-operator/releases)
- [Prometheus operator high availability](https://prometheus-operator.dev/docs/platform/high-availability/)
- [Alertmanager configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [Prometheus remote-write receiver](https://prometheus.io/docs/prometheus/latest/querying/api/#remote-write-receiver)
- [Prometheus exemplar storage](https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage)
- [Collector internal telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/)
- [memory_limiter telemetry](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/documentation.md)
- [Traefik Prometheus metrics](https://doc.traefik.io/traefik/observability/metrics/prometheus/)
- [cert-manager Prometheus metrics](https://cert-manager.io/docs/devops-tips/prometheus-metrics/)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
