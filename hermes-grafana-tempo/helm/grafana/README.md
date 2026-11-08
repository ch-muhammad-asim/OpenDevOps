# 📊 Grafana

Grafana as its own release, the only public UI of the stack, served at `https://grafana-tempo.saqlainmushtaq.com`.
**Why:** one place to search traces with TraceQL, jump from a latency spike (exemplar) to its trace, from a span to its
service's RED metrics, and to see the service graph.

**Status (2026-11-08, chart 14.4.0, Grafana 13.3.0):** the **lab** profile (`values.yaml` + `values-lab.yaml`) matches
the release running on the lab cluster (same settings and requests; it adds image digests, stricter security headers,
spread constraints and the Prometheus and Tempo URLs through environment variables). Both profiles point the
Prometheus data source at the Thanos querier; the lab switch from Prometheus `:9090` to Thanos is live (2026-11-08:
data source healthy; Thanos on GCS, `PROFILE=lab scripts/verify.sh` 31 PASS, 0 failures), and the lab keeps its SQLite database on a
1Gi PVC. The **production** profile (`values.yaml`
alone: 2 replicas on an external database) passes `helm lint`, `helm template` and kubeconform (Kubernetes 1.36,
strict); it has not been installed yet.

## 🧩 Components

| Name | What it does (one line) | Where defined | Security role |
|---|---|---|---|
| Deployment `grafana` | UI on Service `grafana:80` (2 replicas in production) | [`values.yaml`](values.yaml) | Non-root UID 472, read-only root FS, ALL capabilities dropped |
| Service `grafana-headless:9094` (production) | Gossip between replicas for Grafana-managed alert state | `headlessService`, `grafana.ini unified_alerting` | Cluster-internal only |
| External database (production) | Shared users, sessions, annotations, alert state | Secret `grafana-db` → `envFromSecret` | Credentials only in the Secret |
| Data source Prometheus (uid `prometheus`) | Metrics; exemplars with label `trace_id` link to uid `tempo` | `datasources`, URL from `env.PROMETHEUS_QUERY_URL` | Read-only, `editable: false` |
| Data source Tempo (uid `tempo`) | TraceQL search, traces-to-metrics, service map, node graph, streaming | `datasources`, URL from `env.TEMPO_QUERY_URL` | Read-only, `editable: false` |
| Data source Alertmanager (uid `alertmanager`) | Alert and silence view for the kube-prometheus-stack Alertmanager (`implementation: prometheus`) | `datasources` | Read-only, `editable: false` |
| Dashboard sidecar | Loads ConfigMaps labelled `grafana_dashboard` from all namespaces | `sidecar.dashboards` | Watches ConfigMaps only |
| Data source sidecar | Loads ConfigMaps labelled `grafana_datasource` from all namespaces | `sidecar.datasources` | Watches ConfigMaps only |
| ServiceMonitor `grafana` | Prometheus scrapes Grafana's own metrics (alerts in [`../kube-prometheus-stack/rules/grafana.yaml`](../kube-prometheus-stack/rules/grafana.yaml)) | `serviceMonitor` | — |
| Tempo dashboards (8 ConfigMaps, folder "Tempo") | Official Tempo mixin dashboards, adapted to single-binary Tempo | [`dashboards/`](dashboards/) | Read-only ConfigMaps |

## ⚖️ Lab vs production

`values.yaml` = production defaults; [`values-lab.yaml`](values-lab.yaml) = lab overlay (3 x e2-standard-2, one zone).

| Setting | Production (`values.yaml`) | Lab (`+ values-lab.yaml`) |
|---|---|---|
| Replicas / PDB | 2, one per node (`DoNotSchedule`), spread over zones / `minAvailable: 1` | 1 / none |
| Database | External PostgreSQL/MySQL from Secret `grafana-db` | SQLite on a 1Gi PVC `standard-rwo` (service accounts, tokens, UI dashboards and annotations survive restarts) |
| Deployment strategy | Rolling update (chart default) | `Recreate` (RWO disk, one replica: the old pod releases it first); no root `init-chown-data` container (fsGroup 472) |
| Alerting HA | Gossip on 9094 via `grafana-headless` | Off (`ha_peers: ""`) |
| Prometheus data source URL (`PROMETHEUS_QUERY_URL`) | `http://thanos-query.monitoring:10902` (Thanos: 30 days from GCS, HA pair deduplicated) | Same URL (Thanos: 30 days from GCS, one Prometheus) |
| Tempo data source URL (`TEMPO_QUERY_URL`) | `http://tempo-query-frontend.observability:3200` (tempo-distributed) | `http://tempo.observability:3200` (single binary) |
| Grafana image | `grafana/grafana:13.3.0-distroless` + digest | `grafana/grafana:13.3.0` + digest (the image the lab runs) |
| Grafana requests / memory limit | 250m, 512Mi / 1Gi | 100m, 256Mi / 512Mi |
| Sidecar requests / limit (each) | 10m, 64Mi / 128Mi | Same |
| Security settings, data source UIDs, sidecars, ServiceMonitor | As below | Same |

**Total requests:** production 2 x (250m + 2 x 10m) = 0.54 vCPU / 1.25 GiB; lab 0.12 vCPU / 384Mi (unchanged from the
running lab release).

## 📌 Pinned images

Multi-arch index digests read from each registry's v2 API on 2026-11-08; the lab's running digests match.

| Image | Tag | Digest | Runs |
|---|---|---|---|
| `docker.io/grafana/grafana` | `13.3.0-distroless` | `sha256:540b8afb775bf34aefce417e4329039daa5d44b6f2fbda6881397b1b247ca7df` | Grafana (production) |
| `docker.io/grafana/grafana` | `13.3.0` | `sha256:488984b716c0862639f91a698adbe2862677a5a07bad42da5f03f3030883b205` | Grafana (lab) |
| `quay.io/kiwigrid/k8s-sidecar` | `2.14.3` | `sha256:52d311dcedd587421a236c4d6c621f05614c40a51386e955e0699dca97ec0880` | Dashboard + data source sidecars |
| `docker.io/library/busybox` | `1.38.0` | `sha256:a46257e06c82ad85242d0d38077d0a52d9896389ca60a1a59d3463db586e5fa4` | `init-chown-data` (not deployed: production has no PVC, the lab disables it) |
| `docker.io/curlimages/curl` | `8.23.0` | `sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93` | `download-dashboards` (only with remote dashboards; not deployed) |

The chart's `sha:` fields take the hex only (the chart adds `@sha256:`).

## ⚙️ Key settings

| Setting | Value | Why |
|---|---|---|
| `admin.existingSecret` | `grafana-admin` (keys `admin-user`, `admin-password`) | Credentials never in values or Git |
| `envFromSecret` | `grafana-db` (production) | `GF_DATABASE_*` from a Secret; required for more than one replica |
| `grafana.ini` `auth.anonymous.enabled` | `false` | Public host: login required |
| `grafana.ini` `users.allow_sign_up` / `allow_org_create` | `false` / `false` | No self-registration |
| `grafana.ini` `security.cookie_secure`, `cookie_samesite` | `true`, `lax` | Cookies only over HTTPS |
| `grafana.ini` `security.strict_transport_security` (+ `max_age_seconds: 31536000`) | `true` | HSTS for one year |
| `grafana.ini` `security.content_security_policy`, `x_content_type_options`, `x_xss_protection`, `allow_embedding: false` | on | CSP, `nosniff`, XSS header, no framing |
| `grafana.ini` `snapshots.external_enabled` | `false` | No publishing to an external snapshot service |
| `grafana.ini` `server.root_url` | `https://grafana-tempo.saqlainmushtaq.com` | Correct redirects and links behind the proxy |
| `grafana.ini` `unified_alerting.ha_*` | `${POD_IP}:9094`, peers `grafana-headless...:9094` | Official Kubernetes HA settings |
| `env.PROMETHEUS_QUERY_URL` | per profile (table above) | Grafana expands `${PROMETHEUS_QUERY_URL}` in the provisioned Prometheus data source |
| `env.TEMPO_QUERY_URL` | per profile (table above) | Grafana expands `${TEMPO_QUERY_URL}` in the provisioned Tempo data source |
| `persistence.enabled` | `false` (production); lab `true`, 1Gi | State is in the database (production) or in SQLite on a small PVC (lab) |
| Tempo `tracesToMetrics` | `service.name` → `service`; rate, error rate, p95 from `traces_spanmetrics_*` | Span → RED metrics of its service |
| Tempo `streamingEnabled` | search + metrics | Needs `stream_over_http_enabled` in Tempo (set in both Tempo profiles) |
| CPU limit | not set (requests + memory limit) | CPU throttling slows dashboards; the chart sets `GOMEMLIMIT` from the memory limit |

**`$$` in queries:** Grafana expands `$VAR` in provisioning files, so `$__tags` is written as `$$__tags`; the single
`$` in `${PROMETHEUS_QUERY_URL}` and `${TEMPO_QUERY_URL}` is expanded on purpose.

## 📊 Official Tempo dashboards

[`dashboards/`](dashboards/) holds the official Tempo dashboards from `grafana/tempo` tag `v3.1.1`
(`operations/tempo-mixin-compiled`), one ConfigMap each, labelled `grafana_dashboard: "1"` and annotated
`grafana_folder: Tempo`. They show the health of Tempo itself; application traces are in **Explore → Tempo**.

The upstream mixin targets the microservices deployment (`job="<namespace>/<component>"`, one container per
component). [`generate-tempo-mixin.py`](dashboards/generate-tempo-mixin.py) rewrites those selectors to the single
process (`job="tempo"`, `container="tempo"`, pod `tempo-.*`), sets the data source to uid `prometheus`, makes
`cluster`/`namespace` optional (`.*`, this stack has no `cluster` label), rewrites the Service Graph dashboard (below)
and pins UIDs. It also writes
[`../tempo/prometheusrule-tempo-mixin.yaml`](../tempo/prometheusrule-tempo-mixin.yaml). Re-run it after a Tempo upgrade
(set `TEMPO_TAG` in the script first):

```bash
python3 helm/grafana/dashboards/generate-tempo-mixin.py
```

| Dashboard | Use it for | Empty or partial in monolithic mode |
|---|---|---|
| Tempo Operational | First stop: request rates, errors, backend, ring | Memcached and Vulture panels; Loki log panels (no Loki); `component` variable has no effect |
| Tempo / Writes | Ingest path: distributor, live-store | Envoy and Kafka panels |
| Tempo / Reads | Query path: query-frontend, querier | Partition-lag panels |
| Tempo / Resources | CPU, memory, Go heap of the Tempo pod | Per-component rows all show the same `tempo-0` pod |
| Tempo / Livestore | Recent traces held in memory before flush | "by zone" panels show one unlabelled series; partition-lag panels empty |
| Tempo - Backend Work | Backend scheduler/worker: compaction, retention, redaction | Redaction panels until a redaction job runs |
| Tempo / Tenants | Per-tenant usage (one tenant: `single-tenant`) | — |
| Tempo Service Graph | Service topology (nodes and edges) over the dashboard time range | — (rewritten, see below) |

Upstream "Tempo Service Graph" reads `traces_service_graph_connection_info`, a presence gauge that Tempo 3.1 only
writes with the opt-in processor `service-graphs-connection-info`, which this stack does not enable. The script
rewrites it to `group by (client, server) (max_over_time(traces_service_graph_request_total{...}[$__range]))`: the
default `service-graphs` processor always writes that counter, `max_over_time` keeps pairs that were idle for part of
the range, and `group by` merges the series of several metrics-generator replicas into one edge.

Not shipped: **Block builder** (Kafka-based microservices path only) and **Rollout progress** (per-component
microservices rollout). Panels written for a separate gateway (`cortex-gw`) now read Tempo's own HTTP/gRPC routes.

## 🔑 Secrets

Neither Secret is stored in this repo; values are read from local files, never typed on the command line.

| Secret (ns `observability`) | Keys | Needed by | Created by |
|---|---|---|---|
| `grafana-admin` | `admin-user`, `admin-password` | Both profiles | `scripts/deploy.sh` (random password) or by hand |
| `grafana-db` | `GF_DATABASE_TYPE` (`postgres`), `GF_DATABASE_HOST` (`host:5432`), `GF_DATABASE_NAME`, `GF_DATABASE_USER`, `GF_DATABASE_PASSWORD`, `GF_DATABASE_SSL_MODE` (`require`) | Production | By hand or External Secrets |

With External Secrets Operator, an `ExternalSecret` per Secret reads the values from Google Secret Manager and
writes the same keys; rotation then happens in Secret Manager (restart Grafana to pick up a new database password).

## 🚀 Install

1. Create the admin Secret (set the two file paths first):

   ```bash
   kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n observability create secret generic grafana-admin \
     --from-file=admin-user="$GRAFANA_ADMIN_USER_FILE" \
     --from-file=admin-password="$GRAFANA_ADMIN_PASSWORD_FILE" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

2. Production only: create the database (for example Cloud SQL for PostgreSQL with private IP, an empty database
   and a dedicated user) and its Secret from an env file (`KEY=value` lines, chmod 600):

   ```bash
   kubectl -n observability create secret generic grafana-db --from-env-file="$GRAFANA_DB_ENV_FILE" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

3. Install the chart (after kube-prometheus-stack, Tempo and the Collector):

   ```bash
   # production
   helm upgrade --install grafana grafana-community/grafana --version 14.4.0 \
     --namespace observability --create-namespace -f helm/grafana/values.yaml
   # lab
   helm upgrade --install grafana grafana-community/grafana --version 14.4.0 \
     --namespace observability --create-namespace -f helm/grafana/values.yaml -f helm/grafana/values-lab.yaml
   ```

   `scripts/deploy.sh grafana` does the same, selecting the profile with `PROFILE=prod|lab`.

4. Load the Tempo dashboards (the sidecar picks them up within a minute):

   ```bash
   kubectl apply -f helm/grafana/dashboards/
   ```

Public HTTPS routing (Traefik, Cloudflare-only allow-list; origin TLS by `TLS_MODE`: the lab runs `cloudflare` with
Traefik's default certificate and no cert-manager, `letsencrypt` is optional) and NetworkPolicies are defined in
[`../../k8s/`](../../k8s/README.md), not in this chart.

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| Ready | `kubectl -n observability get pods -l app.kubernetes.io/name=grafana` | `3/3 Running` per pod (Grafana + 2 sidecars); 2 pods on different nodes in production |
| PVC (lab) | `kubectl -n observability get pvc grafana` | `Bound`, `1Gi` |
| PDB (production) | `kubectl -n observability get pdb grafana` | `MIN AVAILABLE 1`, `ALLOWED DISRUPTIONS 1` |
| Health | `kubectl -n observability port-forward svc/grafana 3000:80` then `curl -s localhost:3000/api/health` | `"database": "ok"` |
| Anonymous blocked | `curl -s -o /dev/null -w '%{http_code}' localhost:3000/api/datasources` | `401` |
| Security headers | `curl -sI localhost:3000/login \| grep -iE 'content-security-policy\|x-content-type-options\|x-frame-options'` | All three present |
| Data source URLs per profile | Connections → Data sources → Prometheus / Tempo | Both profiles `thanos-query...:10902`; Tempo production `tempo-query-frontend...:3200`, lab `tempo...:3200` |
| Data sources | Prometheus / Tempo → **Save & test** | Both succeed |
| Alertmanager data source | `curl -s -u "$GF_USER:$GF_PASS" localhost:3000/api/datasources/proxy/uid/alertmanager/api/v2/status` (credentials read from Secret `grafana-admin` into variables) | HTTP 200 with the Alertmanager status JSON |
| Dashboards | Dashboards list | kube-prometheus-stack dashboards present; folder "Tempo" has 8 dashboards |

## 🛡️ Security

| Threat | Control | How it's enforced | Test that proves it |
|---|---|---|---|
| Anonymous access on a public host | Anonymous off, sign-up off | `grafana.ini` | `401` on `/api/datasources` without a session |
| Leaked admin or database password | Existing Secrets only; chart `assertNoLeakedSecrets` | `admin.existingSecret`, `envFromSecret` | `grep -riE 'password\|GF_DATABASE' helm/grafana/values*.yaml` finds no value |
| Session theft over HTTP | Secure cookies + HSTS | `grafana.ini security` | Browser shows `Secure` cookie flag; `Strict-Transport-Security` header |
| Clickjacking / XSS / MIME sniffing | CSP, `X-Frame-Options: deny`, `nosniff`, XSS header | `grafana.ini security` | Security headers check above |
| Data-source tampering | Provisioned, `editable: false` | `datasources` | UI shows "provisioned" lock |
| Container breakout | PSS restricted: non-root, `RuntimeDefault`, read-only root FS, ALL capabilities dropped, distroless image (production) | `securityContext` + chart `containerSecurityContext` | `kubectl -n observability get pod -l app.kubernetes.io/name=grafana -o jsonpath='{..securityContext}'` |
| Moving image tags | Tag + digest on every image | `image.sha`, `sidecar.image.sha` | `helm template ... \| grep 'image:'` shows `@sha256:` |

**Not protected:** the chart's ClusterRole lets the sidecars `get/list/watch` Secrets in all namespaces even though
they only watch ConfigMaps (`resource: configmap`); the chart has no switch to drop that rule short of a custom
ClusterRole (`rbac.useExistingClusterRole`).

## 🏭 Production checklist

| Area | Production setting / action |
|---|---|
| HA sizing | 2 replicas (250m / 512Mi request, 1Gi limit) on different nodes, spread over zones, PDB `minAvailable: 1`. Add replicas for more concurrent users; the database is the shared state |
| Database | Managed PostgreSQL (for example Cloud SQL, private IP, SSL `require`, automated backups + point-in-time recovery). Without it, keep 1 replica: two SQLite pods do not share logins |
| Network | Ingress: Grafana → Grafana on 9094 TCP/UDP (alerting gossip) is allowed in `k8s/networkpolicies.yaml`. Egress (opt-in `k8s/networkpolicies-egress.yaml`, `grafana-egress`): 9094 TCP/UDP to the other replicas and 5432 / 3306 TCP to the database range `GRAFANA_DB_CIDR` (default `10.0.0.0/8`; narrow it to the Cloud SQL private range) |
| Backups | The database holds everything not in Git (users, UI-made dashboards, annotations): its backups are the Grafana backup. Data sources and project dashboards are rebuilt from Git |
| Upgrades | Pin a new chart version and image digest here, read the Grafana "What's new / breaking changes", `helm diff upgrade`, then `helm upgrade`; Grafana migrates the database schema on start, so take a database snapshot first. Roll back with `helm rollback grafana <rev>` plus the snapshot if the schema changed |
| Cost (requests) | 0.54 vCPU / 1.25 GiB for 2 pods, plus the database instance |
| SLOs | Availability from `up{job="grafana"}`; alerts `GrafanaDown` (critical) and `GrafanaReplicaDown` (warning) |
| Runbooks | [GrafanaDown](../kube-prometheus-stack/README.md#grafanadown), [GrafanaReplicaDown](../kube-prometheus-stack/README.md#grafanareplicadown) |
| Secrets | `grafana-admin` and `grafana-db` from a Secret manager (External Secrets) in production; consider SSO (`auth.generic_oauth`) and disabling the login form afterwards |
| Tempo dashboards | The 8 dashboards in [`dashboards/`](dashboards/) are rewritten for single-binary Tempo (`job="tempo"`); with tempo-distributed use the upstream mixin selectors (`job="<namespace>/<component>"`) |

## 🧪 Tests

Run on 2026-11-08 with chart 14.4.0, helm v3.17.3, kubeconform v0.8.0.

| Test | Command (from the repo dir) | Result |
|---|---|---|
| Lint, production | `helm lint <chart> -f helm/grafana/values.yaml` | 0 failed |
| Lint, lab | `helm lint <chart> -f helm/grafana/values.yaml -f helm/grafana/values-lab.yaml` | 0 failed |
| Schema, production | `helm template ... \| kubeconform -strict -kubernetes-version 1.36.0` + CRDs-catalog | 10 valid, 0 invalid |
| Schema, lab | same with `values-lab.yaml` | 8 valid, 0 invalid |
| Lab = live | `helm get values grafana -n observability` vs the lab profile; pod requests | Same requests; diff = digests, security headers, spread, Prometheus and Tempo URLs via env |
| Restricted context | Rendered containers checked for non-root, seccomp, no escalation, drop ALL, requests, memory limit, digest | All pass |

`<chart>` is `helm pull grafana-community/grafana --version 14.4.0 --untar`.

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pod `CreateContainerConfigError` | Secret `grafana-admin` or (production) `grafana-db` missing | Create it (Install steps 1-2) |
| Pod restarts, log `failed to connect to database` | Database unreachable or wrong `GF_DATABASE_*` | Check the Secret keys, the database firewall and the NetworkPolicy egress |
| Logged out when the page reloads (production) | Replicas on separate SQLite databases | `envFromSecret: grafana-db` must be set and the Secret must hold the database settings |
| Duplicate Grafana-managed alert notifications | Gossip on 9094 blocked | Allow 9094 TCP/UDP between Grafana pods; check `grafana-headless` endpoints |
| Second replica `Pending` | Only one schedulable node (hard spread per node) | Add a node or use the lab overlay |
| Tempo data source error `lookup tempo-query-frontend` | Production profile against single-binary Tempo | Use the lab overlay, or deploy `helm/tempo-distributed/` |
| Prometheus data source error `lookup thanos-query` | Thanos not installed (both profiles need it) | Deploy [`../thanos/`](../thanos/README.md) (lab: `kubectl apply -k helm/thanos/overlays/lab`) |
| Redirect loop or wrong links | `root_url` mismatch | Must match the public host exactly |
| No "View trace" button on exemplars | Exemplar label mismatch | Tempo `trace_id_label_name` must be `trace_id` |
| Service map empty | No `traces_service_graph_*` series | Check Tempo metrics-generator and remote write |
| Alertmanager data source: API `GET /api/datasources/uid/alertmanager/health` returns `500 plugin.unavailable` | Expected on Grafana 13: Alertmanager is a core frontend-only data source plugin without a backend, so the backend health endpoint has nothing to call; queries go through the data source proxy | Check it through the proxy (Verify table) or the UI **Save & test**; the Alerting UI lists its alerts and silences |
| Tempo dashboard panels empty | Prometheus not scraping Tempo, or panel is microservices-only | Check `up{job="tempo"}`; see the table under "Official Tempo dashboards" |
| `Data source ... already exists` on start | Same uid provisioned twice | Keep `grafana.sidecar.datasources.defaultDatasourceEnabled: false` in kube-prometheus-stack |

## 🔗 References

- [Grafana documentation](https://grafana.com/docs/grafana/latest/)
- [Grafana configuration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
- [Grafana high availability](https://grafana.com/docs/grafana/latest/setup-grafana/set-up-for-high-availability/)
- [Alerting high availability](https://grafana.com/docs/grafana/latest/alerting/set-up/configure-high-availability/)
- [Configure security hardening](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-security-hardening/)
- [Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Tempo data source](https://grafana.com/docs/grafana/latest/datasources/tempo/configure-tempo-data-source/)
- [Prometheus data source](https://grafana.com/docs/grafana/latest/datasources/prometheus/configure/)
- [Tempo monitoring mixin](https://grafana.com/docs/tempo/latest/operations/monitor/)
- [Tempo mixin source (v3.1.1)](https://github.com/grafana/tempo/tree/v3.1.1/operations/tempo-mixin-compiled)
- [grafana-community/grafana chart](https://github.com/grafana-community/helm-charts/tree/main/charts/grafana)
