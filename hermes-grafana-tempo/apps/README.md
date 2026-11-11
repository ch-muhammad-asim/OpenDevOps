# 🧪 Sample apps: Next.js, Node.js, Python

Three small services in three languages that call each other and carry deliberate, realistic bugs. Each exports
OpenTelemetry traces over OTLP to the Collector, so Grafana Tempo shows every bug as slow spans, error spans, exception
events or fan-out, and TraceQL finds it. **Why:** a reproducible way to learn what each class of bug looks like in a trace.

## 🏗️ Architecture

The project [architecture diagram](../docs/diagrams/architecture.mmd) shows the sample apps and their calls; it renders in the [top-level README](../README.md). The table below lists the parts.

| Hop | From → to | Protocol |
|---|---|---|
| 1 | Browser / `scripts/load.sh` → `nextjs` | HTTPS via Traefik (cluster) or HTTP (local) |
| 2 | `nextjs` → `nodejs` | HTTP, W3C `traceparent` header |
| 3 | `nodejs` → `python` | HTTP, W3C `traceparent` header |
| 4 | `python` → SQLite | in-process, one `db` span per query |
| 5 | every app → OTel Collector | OTLP/HTTP protobuf, port 4318 |

## 🧩 Components

| App | OTel `service.name` | What it does (one line) | Instrumentation | Port | README |
|---|---|---|---|---|---|
| `nextjs` | `nextjs-web` | Next.js 16 storefront: dashboard, checkout, stock and report routes | `@vercel/otel` in `instrumentation.ts` + manual spans | 3000 | [nextjs/](nextjs/README.md) |
| `nodejs` | `nodejs-orders` | Express 5 orders API; calls python for stock | Auto-instrumentations (`--require`) + manual spans | 3000 | [nodejs/](nodejs/README.md) |
| `python` | `python-inventory` | FastAPI inventory API on SQLite | Zero-code `opentelemetry-instrument` + manual spans | 8000 | [python/](python/README.md) |
| `local/` | - | Docker Compose stack: apps + Collector + Tempo + Prometheus | - | - | [local/](local/README.md) |
| `monitoring/` | - | PrometheusRule: 99% availability SLO burn-rate alerts, p95 latency, no spans, restarts, memory | - | - | [monitoring/](monitoring/README.md) |
| `lab/` | - | Kustomize overlay: production manifests with 1 replica per app for a small cluster | - | - | [lab/](lab/README.md) |

Every app: `GET /healthz` (excluded from tracing), traces only (no metric exporter; RED metrics come from
Tempo's metrics-generator), non-root uid 10001, read-only root filesystem, no service-account token.
Every app also has bounded `GET /stress/cpu` and `GET /stress/memory` for the [stress tests](../tests/README.md):
off by default (`STRESS_ENABLED=false`), capped by env, 404 for traffic through Traefik, traced as `stress.*` spans.

**Profiles:** production (default, [kustomization.yaml](kustomization.yaml)) runs 2 replicas per app with a PDB,
hostname + zone topology spread, surge-only rollouts and a 5 s preStop drain; the [lab profile](lab/) is the same
with 1 replica. Images are always deployed by digest.

## 🐞 Planted issues (summary)

Exact TraceQL, what each looks like in Tempo and the fix are in each app's README. Each bug is marked
`PLANTED ISSUE:` in the code.

| Issue class | Where | Trigger |
|---|---|---|
| N+1 HTTP fan-out (sequential waterfall) | nextjs | `GET /api/dashboard` |
| N+1 SQL queries | python | `GET /inventory/report` |
| Unhandled exception (500) | nextjs, nodejs, python | `POST /api/checkout {}`, `POST /orders {}`, `GET /inventory/items/SKU-999` |
| Cross-service error chain (502) | nodejs → python | `GET /orders/7` |
| External call timeout (504) | nodejs → python, cascades to nextjs | `GET /orders/:id/stock`, `GET /api/stock/:id` |
| Slow endpoint | python | `GET /inventory/slow` (~3 s) |
| CPU hog blocking the server | nodejs, python | `GET /orders/report`, `GET /inventory/fib?n=35` |
| Memory leak (capped at 120 MiB) | nodejs | every `GET /orders` |

Quick finds across all apps: `{ status = error }`, `{ event:name = "exception" }`, `{ span:duration > 1s }`.

## 📈 The same issues in PromQL (span metrics)

| Signal | PromQL | What it showed after `load.sh` |
|---|---|---|
| Errors per route (R**E**D) | `sum by (service, span_name) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[5m]))` | `GET /inventory/items/{sku}`, `GET /orders/:id`, `POST /orders`, `POST /api/checkout`, `GET /orders/:id/stock` |
| Slow routes, p95 > 1 s (RE**D**) | `histogram_quantile(0.95, sum by (le, service, span_name) (rate(traces_spanmetrics_latency_bucket{span_kind="SPAN_KIND_SERVER"}[5m]))) > 1` | `nodejs-orders GET /orders/report` (CPU hog) |
| Request rate per route (**R**ED) | `sum by (service, span_name) (rate(traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"}[5m]))` | all routes |
| Failing service-to-service edges | `sum by (client, server) (rate(traces_service_graph_request_failed_total[5m]))` | `nodejs-orders → python-inventory`, `nextjs-web → nodejs-orders` |
| Memory leak (cluster only, cAdvisor) | `container_memory_working_set_bytes{namespace="tempo-apps", container="nodejs"}` | not measured locally |

Debug "no data": list what exists with `{__name__=~"traces_.*"}` first.

## 📋 Prerequisites

| Tool | Version tested | For |
|---|---|---|
| Docker + Buildx | 28.3.3 / 0.26.1 | build images, local stack |
| gcloud | authenticated, project set | push to Artifact Registry |
| kubectl | client 1.32.3 against GKE 1.36.4 (use a client within one minor of the cluster) | deploy |

Sizing per pod (requests / limits): nextjs 50m·128Mi / 500m·384Mi, nodejs 50m·128Mi / 500m·256Mi,
python 50m·96Mi / 500m·256Mi. Totals (requests): production 300m / 704Mi (6 pods, needs >= 2 nodes for the
hostname spread); lab 150m / 352Mi (3 pods).

## 🚀 Run it

**Locally** (no cloud needed): see [local/README.md](local/README.md).

**On the cluster** (namespace `tempo-apps` and the Collector must already exist, see the [top-level README](../README.md)):

```bash
# 1. One-time: an Artifact Registry Docker repo; immutable tags so a pushed tag can never be overwritten
gcloud artifacts repositories create tempo-apps --repository-format=docker --location=us-central1 --immutable-tags
# 2. Build linux/amd64 images and push them (tag 1.0.3)
apps/build-push.sh
# 3. Apply all three apps pinned by digest (tag resolved to sha256), waits for rollout
apps/deploy-apps.sh          # production profile; use `apps/deploy-apps.sh lab` on a 3 x e2-standard-2 cluster
# 4. Generate traffic that triggers every issue
DOMAIN=<your-domain> scripts/load.sh public 20
```

| Script | What it does |
|---|---|
| [build-push.sh](build-push.sh) | Builds and pushes `<region>-docker.pkg.dev/<project>/tempo-apps/<app>:1.0.3`; `apps/build-push.sh nodejs` builds one. Tags are immutable: after a code change set a new `TAG` (e.g. `TAG=1.0.4`) |
| [deploy-apps.sh](deploy-apps.sh) | `[production\|lab]`: resolves each `TAG` to its digest, renders the profile with `image: <registry>/<app>@sha256:...`, applies, waits for rollout |
| [kustomization.yaml](kustomization.yaml) | Production profile: the three `*/k8s` folders + `monitoring/` |

Env overrides for both scripts: `PROJECT_ID` (default: gcloud config), `REGION` (`us-central1`), `AR_REPO`
(`tempo-apps`), `TAG` (`1.0.3`).

## ✅ Verify

```bash
kubectl -n tempo-apps get pods -l app.kubernetes.io/part-of=tempo-apps   # 6 pods (lab: 3) Running, READY 1/1
kubectl -n tempo-apps get pdb,prometheusrule                              # 3 PDBs, rule tempo-apps
kubectl -n tempo-apps run curl --rm -i --restart=Never --image=curlimages/curl:8.23.0 -- \
  curl -s http://nextjs:3000/api/dashboard                               # JSON with "partial": true (order 7)
```

In Grafana → Explore → Tempo, run `{ resource.service.name = "nextjs-web" } >> { resource.service.name = "python-inventory" }`:
one trace spans all three services. The Service Graph tab shows `nextjs-web → nodejs-orders → python-inventory → sqlite`.

## 🛡️ Security

| Threat | Control | Enforced by |
|---|---|---|
| Container breakout / privilege escalation | non-root uid 10001, `allowPrivilegeEscalation: false`, drop ALL capabilities, `RuntimeDefault` seccomp | `*/k8s/deployment.yaml`, Pod Security `restricted` (warn/audit) |
| Tampering with app files at runtime | `readOnlyRootFilesystem: true`, writable `emptyDir` only for `/tmp` (and Next.js cache) | `*/k8s/deployment.yaml` |
| Kubernetes API abuse from a pod | `automountServiceAccountToken: false` | `*/k8s/deployment.yaml` |
| Cloud metadata / account IDs in public traces | Node.js cloud resource detectors disabled | `nodejs` env `OTEL_NODE_RESOURCE_DETECTORS`, nextjs drops platform attributes |
| Unwanted inbound traffic | default-deny ingress; only Traefik, same-namespace and Prometheus allowed | [../k8s/networkpolicies.yaml](../k8s/networkpolicies.yaml) |
| Running an unreviewed image | Artifact Registry immutable tags; Deployments reference `@sha256` digests | [build-push.sh](build-push.sh), [deploy-apps.sh](deploy-apps.sh) |
| Outage during node drain / upgrade | PDB `maxUnavailable: 1`, 2 replicas spread over nodes, `maxUnavailable: 0` rollouts | `*/k8s/pdb.yaml`, `*/k8s/deployment.yaml` |

Not protected (by design, demo apps): no authentication on the APIs, and the planted bugs are reachable from the public
hostnames (Cloudflare-only allow-list in front). Traces carry no secrets or user data, only synthetic orders.

## 🩺 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` | Image not pushed, or nodes can't read the repo | Run `apps/build-push.sh`; give the node service account `roles/artifactregistry.reader` |
| No traces in Tempo | Collector unreachable from `tempo-apps` | `kubectl -n observability get svc otel-collector`; check the `otel-collector-from-senders` NetworkPolicy |
| Trace stops at one service | `traceparent` not forwarded | See each app README; nextjs needs `ORDERS_URL` in `propagateContextUrls` |
| New traces missing from a time-ranged search | Spans take 30-60 s to become searchable | Wait, or search without a time range |
| nodejs pod memory climbs to ~165 MiB | Planted leak, capped at 120 MiB of cache | Expected; `kubectl -n tempo-apps rollout restart deploy/nodejs` resets it |

## 🏭 Production checklist

The **manifests, images and alerts** are production-grade; the **app code is not**: it contains planted bugs on
purpose. Use these as a template for real services, never ship the sample apps themselves.

| Area | Done here | Still to do for a real service |
|---|---|---|
| HA sizing | 2 replicas, PDB, node (hard) + zone (soft) spread, surge-only rollouts, preStop drain | Size from load tests; add an HPA on CPU/RPS; regional cluster for real zone spread |
| Supply chain | Pinned base images (python by digest), lockfiles, `npm audit` 0, immutable AR tags, digest deploys | Vulnerability scanning in CI, signed images (Binary Authorization), SBOM |
| Security | PSS restricted fields, read-only rootfs, no SA token, default-deny NetworkPolicy, TLS at Traefik | Authentication, rate limiting, egress NetworkPolicy, secrets via Secret Manager |
| Observability | Traces to the Collector, span-metrics SLO + alerts with runbooks ([monitoring/](monitoring/README.md)) | Tail sampling at the Collector at high volume (keep errors and slow traces); logs with trace IDs |
| Backups | Stateless apps (python's SQLite is rebuilt at start) | A managed database with backups for real data |
| Upgrades | New code = new immutable `TAG`, `deploy-apps.sh` rolls out; `kubectl rollout undo` rolls back | Progressive delivery (canary) gated on the SLO alerts |
| Cost | Requests 300m / 704Mi for 6 pods | Right-size from measured usage (VPA recommendations) |
| SLOs | 99% availability, p95 < 1 s per route | Agree targets with service owners; error-budget policy |
| Runbooks | [monitoring/README.md](monitoring/README.md#-alerts-and-runbooks), troubleshooting table above | Link from your on-call tool |

## 🧹 Teardown

```bash
kubectl delete -k apps/                                           # the three apps, PDBs and alert rules
gcloud artifacts repositories delete tempo-apps --location=us-central1   # images
```

## 📚 References

- [OpenTelemetry JavaScript: Node.js](https://opentelemetry.io/docs/languages/js/getting-started/nodejs/) ·
  [zero-code JS](https://opentelemetry.io/docs/zero-code/js/) ·
  [Python](https://opentelemetry.io/docs/languages/python/getting-started/) ·
  [zero-code Python](https://opentelemetry.io/docs/zero-code/python/)
- [Next.js OpenTelemetry guide](https://nextjs.org/docs/app/guides/open-telemetry)
- [TraceQL](https://grafana.com/docs/tempo/latest/traceql/construct-traceql-queries/) ·
  [Tempo service graphs](https://grafana.com/docs/tempo/latest/metrics-from-traces/service_graphs/)
- [Artifact Registry: push and pull images](https://cloud.google.com/artifact-registry/docs/docker/pushing-and-pulling)
