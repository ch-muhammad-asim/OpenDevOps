# 🐍 python-inventory (FastAPI)

A small inventory API (FastAPI + uvicorn, Python 3.14) with four planted, realistic code bugs. It sends OpenTelemetry
traces to the OpenTelemetry Collector, and Grafana Tempo shows each bug as spans, errors and latency that one TraceQL
query finds. `nodejs-orders` calls it; it calls nothing else (its database is in-process SQLite). **Why:** show what
zero-code Python instrumentation gives you for free, and where a few manual spans make a trace easier to read.

**Status:** ✅ tested locally on 2026-11-08 with the [`apps/local`](../local/) stack (Tempo 3.1.1, OpenTelemetry
Collector contrib 0.165.0): every endpoint called, every TraceQL query below returned the expected traces, image runs as
uid 10001 with a read-only root filesystem, manifests render with `kubectl kustomize`. Not yet tested: the GKE deploy.

## 🏗️ Architecture

The project [architecture diagram](../../docs/diagrams/architecture.mmd) shows the Python app in the call chain; it renders in the [top-level README](../../README.md). The table below lists the parts.

| Component | What it does (one line) |
|---|---|
| `nodejs-orders` | Calls this API over HTTP (`http://python:8000`, 2 s timeout on `/inventory/slow`) |
| `python-inventory` | FastAPI app in uvicorn, started by `opentelemetry-instrument` |
| SQLite (`/tmp/inventory.db`) | In-process database, recreated and seeded with `SKU-001`..`SKU-020` at startup |
| OpenTelemetry Collector | Receives OTLP over HTTP (port 4318) and forwards the traces to Tempo |

## 🧩 Components

| Name | What it does | Where defined | Security role |
|---|---|---|---|
| App code | Routes, planted bugs, manual spans | [`main.py`](main.py) | No secrets; reads only env vars |
| Dependencies | Exact pins, full resolved set | [`requirements.txt`](requirements.txt) | Reproducible build, wheels only |
| Image | Multi-stage build, venv only in the final stage | [`Dockerfile`](Dockerfile) | Non-root uid 10001, no compilers, no pip in the venv |
| Kubernetes | Deployment + ClusterIP Service `python` | [`k8s/`](k8s/) | PSS restricted, read-only root, no SA token |

## 🔭 How it is instrumented

| Layer | What | Spans you get |
|---|---|---|
| Zero-code | `opentelemetry-instrument uvicorn main:asgi` loads every installed instrumentation before the app starts | |
| `opentelemetry-instrumentation-fastapi` | Wraps the ASGI app | One `SERVER` span per request (`GET /inventory/report`), plus two short `http send` internal spans; unhandled exceptions become an `exception` event and `status = error` |
| `opentelemetry-instrumentation-sqlite3` | Wraps `sqlite3.connect()` | One `CLIENT` span per `cursor.execute()` with `db.system = sqlite` and `db.statement` |
| Manual (`opentelemetry-api`) | `tracer.start_as_current_span(...)`, `set_attribute`, `add_event` in [`main.py`](main.py) | `inventory.seed`, `inventory.report.build` (`app.items.count`), `legacy_supplier_sync` (`app.supplier.name`, lock events); attributes `app.item.sku`, `app.fib.n` on the server span |

- Packages are installed at build time from [`requirements.txt`](requirements.txt); `opentelemetry-bootstrap` is not run.
- Exporter: OTLP over HTTP with protobuf (`opentelemetry-exporter-otlp-proto-http`) to `<endpoint>/v1/traces`.
- Only traces are exported; metrics and logs exporters are off.
- Queries must use `conn.cursor().execute()`: the sqlite3 instrumentation does not trace the `conn.execute()` shortcut.

### Environment variables

| Variable | Value (k8s) | Set in | What it does |
|---|---|---|---|
| `OTEL_SERVICE_NAME` | `python-inventory` | Dockerfile, k8s | `service.name` on every span |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector.observability:4318` (compose: `http://otel-collector:4318`) | compose, k8s | Collector base URL; `/v1/traces` is appended |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | Dockerfile, k8s | OTLP over HTTP, not gRPC |
| `OTEL_TRACES_EXPORTER` | `otlp` | Dockerfile, k8s | Export traces with OTLP |
| `OTEL_METRICS_EXPORTER` | `none` | Dockerfile, k8s | No app metrics (Tempo derives RED metrics from spans) |
| `OTEL_LOGS_EXPORTER` | `none` | Dockerfile, k8s | No OTLP logs |
| `OTEL_TRACES_SAMPLER` | `parentbased_always_on` | Dockerfile, k8s | Keep every trace; follow the caller's sampling decision |
| `OTEL_PYTHON_EXCLUDED_URLS` | `healthz` | Dockerfile, k8s | No spans for probe traffic |
| `OTEL_RESOURCE_ATTRIBUTES` | `deployment.environment.name=lab,service.namespace=tempo-apps,service.version=1.0.2,k8s.namespace.name=…,k8s.pod.name=…` (compose: `deployment.environment.name=local,service.namespace=tempo-apps,service.version=dev`) | compose, k8s | Extra resource attributes; namespace and pod name come from the downward API |
| `INVENTORY_DB_PATH` | `/tmp/inventory.db` | Dockerfile, k8s | SQLite file; `/tmp` is the only writable path |
| `SUPPLIER_SYNC_SECONDS` | `3` (default) | code | Length of the planted wait in `/inventory/slow` |

## 🔌 API

| Method | Path | Returns | Traced |
|---|---|---|---|
| GET | `/` | JSON index: every endpoint, the issue it demonstrates and the TraceQL that finds it | yes |
| GET | `/healthz` | `200 {"status":"ok"}` | No (excluded) |
| GET | `/stress/cpu?ms=500` | Stress test: busy loop for `ms` (cap `STRESS_MAX_CPU_MS`, 5000); 404 unless `STRESS_ENABLED=true` and the request did not come through Traefik. See [tests](../../tests/README.md) | Yes, span `stress.cpu` |
| GET | `/stress/memory?mb=32&hold_s=5` | Stress test: holds `mb` MiB for `hold_s` s then releases (caps `STRESS_MAX_MB` 128 total, `STRESS_MAX_HOLD_S` 30); 429 when the budget is in use; same 404 rule | Yes, span `stress.memory` |
| GET | `/inventory/items` | All 20 items, one query (healthy baseline) | Yes |
| GET | `/inventory/items/{sku}` | One item; unknown SKU (`SKU-999`) -> `500` | Yes |
| GET | `/inventory/report` | Stock value per item and total | Yes |
| GET | `/inventory/slow` | `{"low_stock_items": N}` after ~3 s | Yes |
| GET | `/inventory/fib?n=30` | `{"n":30,"value":832040}`; `n` capped at 35 | Yes |

## 🐞 Planted issues

Each bug is marked `# PLANTED ISSUE:` in [`main.py`](main.py) with its fix.

| Issue | Endpoint | What it looks like in Tempo | TraceQL query that finds it | Fix |
|---|---|---|---|---|
| Unhandled exception | `/inventory/items/SKU-999` | Server span `status = error`, HTTP 500, `exception` event with `exception.type = KeyError` and the stack trace | `{ resource.service.name = "python-inventory" && event.exception.type = "KeyError" }` | `CATALOG.get(sku)` and return 404 |
| N+1 queries | `/inventory/report` | One server span with 21 `SELECT` client spans under `inventory.report.build` (`app.items.count = 20`) | `{ resource.service.name = "python-inventory" && kind = server } >> { span.db.system = "sqlite" } \| count() > 10` | One `SELECT` for all rows |
| Slow endpoint | `/inventory/slow` | ~3 s server span; almost all of it is the `legacy_supplier_sync` span (events `supplier.lock.wait` -> `supplier.lock.acquired`); the caller's 2 s timeout fires first | `{ resource.service.name = "python-inventory" && name = "legacy_supplier_sync" && span:duration > 2s }` | Run the sync as a background job; serve cached data |
| CPU hog | `/inventory/fib?n=35` | Long server span with no child spans (pure CPU); `app.fib.n` shows the input. Other requests that arrive meanwhile wait, but that wait shows only in the caller's span | `{ resource.service.name = "python-inventory" && span.http.route = "/inventory/fib" && span:duration > 150ms }` | Iterative fib; keep CPU work off the event loop |

Healthy baseline for comparison (exactly one query per request):
`{ resource.service.name = "python-inventory" && span.http.route = "/inventory/items" } >> { span.db.system = "sqlite" } | count() = 1`

## 📋 Prerequisites

| Item | Version / size |
|---|---|
| Docker with Compose v2 | Local build and test |
| `kubectl` | Client with kustomize; tested with client 1.32.3 against GKE 1.36.4 (works here, but use a client within one minor of the cluster) |
| Resources (k8s) | Requests 50m CPU / 96Mi, limits 500m CPU / 256Mi; image about 170 MB |

## 🚀 Build and run locally

Run from [`apps/local`](../local/); the stack sends traces to a local Tempo.

```bash
cd apps/local
docker compose up -d tempo otel-collector prometheus   # why: the trace pipeline the app exports to
docker compose up -d --build python                    # why: build this image and start it on port 18000
curl -s http://127.0.0.1:18000/healthz                 # expect: {"status":"ok"}
```

Call every endpoint (why: create one trace per planted issue):

```bash
B=http://127.0.0.1:18000
curl -s $B/inventory/items >/dev/null
curl -s -o /dev/null -w '%{http_code}\n' $B/inventory/items/SKU-999   # expect: 500
curl -s $B/inventory/report >/dev/null
curl -s -o /dev/null -w '%{time_total}\n' $B/inventory/slow           # expect: ~3.0
curl -s -o /dev/null -w '%{time_total}\n' "$B/inventory/fib?n=35"     # expect: seconds, CPU bound
```

## ☸️ Deploy to Kubernetes

```bash
apps/build-push.sh python   # why: build linux/amd64 and push <registry>/python:1.0.2
apps/deploy-apps.sh         # why: render the production profile (or `lab`), pin images by digest, apply, wait
kubectl -n tempo-apps rollout status deployment/python
```

Details of the manifests: [`k8s/`](k8s/).

## ✅ Verify

Wait 15-30 s after the calls (Tempo makes new traces searchable after a short delay), then run each query from
[Planted issues](#-planted-issues) in Grafana Explore (Tempo data source) or against the Tempo API:

```bash
curl -sG http://127.0.0.1:13200/api/search \
  --data-urlencode 'q={ resource.service.name = "python-inventory" && name = "legacy_supplier_sync" && span:duration > 2s }' \
  --data-urlencode start=$(( $(date +%s) - 900 )) --data-urlencode end=$(date +%s)
```

| Check | Result (2026-11-08, local stack) |
|---|---|
| `/healthz` not traced | `{ span.http.route = "/healthz" }` -> 0 traces |
| Unhandled exception | 500 in 0.02 s; query matched the `GET /inventory/items/{sku}` trace, event `exception.type = KeyError` |
| N+1 | Query matched 1 trace, `count() = 21` (1 + 20 SELECTs), 7 ms total |
| Baseline | `/inventory/items` query matched with `count() = 1` |
| Slow endpoint | `/inventory/slow` 3.00 s; `legacy_supplier_sync` > 2 s matched (3004 ms trace) |
| CPU hog | `n=30` 0.21 s, `n=35` 2.3 s; a `/healthz` sent during `n=35` waited 2.0 s |
| Read-only root, uid 10001 | `docker run --read-only --tmpfs /tmp -u 10001 --cap-drop ALL` served `/healthz` and `/inventory/report` |

TraceQL metrics (p95 per route) also work: `{ resource.service.name = "python-inventory" && kind = server } |
quantile_over_time(span:duration, .95) by (span.http.route)`.

## 🛡️ Security

| Threat | Control | How it is enforced | Test that proves it |
|---|---|---|---|
| Container escape / privilege gain | Non-root uid 10001, no privilege escalation, all capabilities dropped, RuntimeDefault seccomp | Dockerfile `USER`, [`k8s/deployment.yaml`](k8s/deployment.yaml) | Local and GKE (2026-11-08): uid/gid 10001; live pod has `allowPrivilegeEscalation: false`, `drop: [ALL]`; namespace enforces Pod Security `restricted` |
| Tampering with the image at runtime | Read-only root filesystem; only `/tmp` (emptyDir, 32Mi) is writable | `readOnlyRootFilesystem: true` | Local and GKE: writing to `/app` fails with "Read-only file system" |
| Kubernetes API abuse | No service account token mounted | `automountServiceAccountToken: false` | GKE: no token at `/var/run/secrets/kubernetes.io/serviceaccount/token` in the live pod |
| Unwanted inbound traffic | Ingress-only NetworkPolicies of namespace `tempo-apps` | [`k8s/networkpolicies.yaml`](../../k8s/networkpolicies.yaml) | GKE: `curl python.tempo-apps:8000` from namespace `default` times out; from `tempo-apps` returns 200 |

Not protected (by design, it is a demo): no authentication on the API, `db.statement` is recorded in spans (fine
here: parameters are bound, so values are not in the SQL text), stack traces are stored in Tempo.

## 🩺 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No traces in Tempo | Wrong `OTEL_EXPORTER_OTLP_ENDPOINT` or protocol | Endpoint is the base URL (`:4318`, no `/v1/traces`) with `http/protobuf`; check the Collector logs |
| Search returns nothing right after a call | Tempo makes new traces searchable after a short delay | Wait 15-30 s and widen the time range |
| Server span but no `SELECT` spans | Queries run through `conn.execute()` | Use `conn.cursor().execute()` |
| Pod briefly unready while `/inventory/fib?n=35` runs | Event loop blocked longer than the probe timeout (CPU limit 500m makes it slower) | Expected for this bug: one failed probe at most; liveness restarts only after ~60 s blocked (20 s period x 3 failures); the fix is in the code |
| `sqlite3.OperationalError: unable to open database file` | `/tmp` not writable with a read-only root | Mount an emptyDir (k8s) or `--tmpfs /tmp` (docker) |
| `/inventory/slow` shows an error in `nodejs-orders` but 200 here | The caller times out after 2 s; this service still finishes in 3 s | Expected; compare both spans in the same trace |

## 🏭 Production checklist

Manifests and image are production-grade; the endpoints contain planted bugs on purpose. For a real Python service:

| Area | Action |
|---|---|
| Code | `HTTPException(404)` for unknown SKUs, one JOIN instead of N+1 queries, cache or async the supplier sync, CPU work off the event loop |
| Data / backups | Replace in-process SQLite with a managed database (backups, PITR); the sample rebuilds its data at start |
| HA / sizing | 2+ replicas behind the PDB; scale out with an HPA; one uvicorn worker per pod keeps CPU limits honest |
| Tracing | Pin instrumentation packages explicitly (no `opentelemetry-bootstrap` at runtime); ratio sampling + Collector tail sampling at high volume |
| Upgrades | Bump `opentelemetry-*` (SDK `1.x` with contrib `0.xxbN`) together, rebuild with a new immutable `TAG`, roll back with `rollout undo` |
| SLO / runbooks | 99% availability, p95 < 1 s: [apps/monitoring](../monitoring/README.md) |
| More | [Apps production checklist](../README.md#-production-checklist) |

## 📌 Pinned versions

| Component | Version |
|---|---|
| Base image | `python:3.14.10-slim-trixie` (pinned by digest in the Dockerfile) |
| fastapi / starlette | 0.162.2 / 1.10.0 |
| uvicorn | 0.54.0 |
| opentelemetry-api / -sdk / -exporter-otlp | 1.45.2 |
| opentelemetry-distro / -instrumentation-fastapi / -instrumentation-sqlite3 | 0.66b2 |
| Full set | [`requirements.txt`](requirements.txt) |

## 🧹 Cleanup

```bash
docker compose -f apps/local/compose.yaml rm -sf python   # local: stop and remove only this service
kubectl -n tempo-apps delete -k apps/python/k8s           # cluster
```

## 📚 References

- [OpenTelemetry Python zero-code instrumentation](https://opentelemetry.io/docs/zero-code/python/)
- [Zero-code configuration (env vars)](https://opentelemetry.io/docs/zero-code/python/configuration/)
- [OpenTelemetry Python manual instrumentation](https://opentelemetry.io/docs/languages/python/instrumentation/)
- [OTLP exporter configuration](https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/)
- [TraceQL: construct queries](https://grafana.com/docs/tempo/latest/traceql/construct-traceql-queries/)
- [TraceQL metrics queries](https://grafana.com/docs/tempo/latest/metrics-from-traces/metrics-queries/)
- [FastAPI](https://fastapi.tiangolo.com/)
