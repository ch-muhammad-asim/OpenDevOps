# 🟩 nodejs-orders: Express 5 orders API with planted bugs

A small Express 5 API that serves orders and asks `python-inventory` for stock. It is traced with
OpenTelemetry (automatic HTTP/Express/fetch spans plus a few manual spans, attributes and events) and
exports to Grafana Tempo through the OpenTelemetry Collector. Five realistic code issues are planted on
purpose, so you can see how each one looks in a trace and which TraceQL query finds it.

| Item | Value |
|---|---|
| OTel `service.name` | `nodejs-orders` |
| Kubernetes Service | `nodejs` (namespace `tempo-apps`, port 3000) |
| Called by | `nextjs-web` (`http://nodejs:3000`) |
| Calls | `python-inventory` (`INVENTORY_URL`, default `http://python:8000`) |
| Image | `tempo-apps/nodejs:1.0.3` (registry prefix set at deploy time) |

## 🧩 Files

| File | What it does | Security role |
|---|---|---|
| [`server.js`](server.js) | Express app: routes, manual spans/attributes/events, the five planted issues | No secrets; input is not validated on purpose (planted issue) |
| [`instrumentation.js`](instrumentation.js) | Starts the OpenTelemetry Node SDK before the app (`node --require`) | Keeps `/healthz` out of traces; cloud resource detectors off |
| [`package.json`](package.json), [`package-lock.json`](package-lock.json) | Exact dependency pins and the lockfile used by `npm ci` | Reproducible installs; `npm audit --omit=dev`: 0 known vulnerabilities |
| [`Dockerfile`](Dockerfile) | Two-stage build on `node:26.13.0-alpine3.24` | Runs as UID 10001; app files owned by root (read-only) |
| [`.dockerignore`](.dockerignore) | Keeps `node_modules`, docs and manifests out of the build context | Smaller context, no local files leak into the image |
| [`k8s/`](k8s/README.md) | Deployment, Service, kustomization | Pod Security `restricted` settings |

## 📡 Instrumentation

| Layer | How | Spans you get |
|---|---|---|
| Automatic | `node --require ./instrumentation.js server.js` loads `@opentelemetry/sdk-node` with `@opentelemetry/auto-instrumentations-node` | `GET /orders/:id` (HTTP server), `request handler - /orders/:id` and `middleware - jsonParser` (Express), `GET` (fetch/undici client) |
| Manual | `@opentelemetry/api` in `server.js` | Span `orders.build_report`; attributes `app.cache.entries`, `app.cache.bytes`, `app.order.id`, `app.order.sku`, `app.stock.timeout_ms`, `app.report.rounds`; events `report.signed`, `order.created`; `recordException()` + `setStatus(ERROR)` on handled errors |

**Why `instrumentation.js` and not `@opentelemetry/auto-instrumentations-node/register`:** the stock
`register` script is configured only by environment variables, and there is no variable to skip a URL
path in the HTTP instrumentation. `instrumentation.js` is the same script plus one option,
`ignoreIncomingRequestHook`, so Kubernetes probes on `/healthz` do not create traces. Every other
setting still comes from the `OTEL_*` variables below.

**Context propagation:** the app calls python with Node's global `fetch` (built on undici). The undici
instrumentation starts a client span and adds the W3C `traceparent` header to the request. The Python
OpenTelemetry instrumentation reads that header, so python's server span joins the same trace. One
trace therefore runs `nextjs-web -> nodejs-orders -> python-inventory`.

### Environment variables

| Variable | Value | Why |
|---|---|---|
| `OTEL_SERVICE_NAME` | `nodejs-orders` | Service name in Tempo and the service graph |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector.observability:4318` (cluster), `http://otel-collector:4318` (Compose) | Collector OTLP/HTTP; the SDK appends `/v1/traces` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | OTLP over HTTP with protobuf (`exporter-trace-otlp-proto`) |
| `OTEL_TRACES_EXPORTER` | `otlp` | Send spans to the Collector |
| `OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER` | `none` | Traces only; no app metrics endpoint |
| `OTEL_TRACES_SAMPLER` | `parentbased_always_on` | Keep every trace; follow the caller's sampling decision |
| `OTEL_NODE_ENABLED_INSTRUMENTATIONS` | `http,express,undici` | Load only the three instrumentations this app needs |
| `OTEL_NODE_RESOURCE_DETECTORS` | `env,host,os,serviceinstance` | Skip the cloud detectors: no metadata-server calls, no cloud account IDs in public traces |
| `OTEL_RESOURCE_ATTRIBUTES` | `deployment.environment.name=lab,service.namespace=tempo-apps,service.version=1.0.3,k8s.namespace.name=...,k8s.pod.name=...` | Pod name and namespace come from the Kubernetes downward API |
| `INVENTORY_URL` | `http://python:8000` | Base URL of python-inventory |
| `PORT` | `3000` | Listen port |
| `REPORT_ROUNDS` | `10` (default) | Work done by the CPU hog (10 x 100,000 PBKDF2 iterations) |

## 🌐 API

| Method and path | Normal result | Calls python | Planted issue |
|---|---|---|---|
| `GET /` | JSON index: every endpoint, its planted issue and the TraceQL that finds it | no | - |
| `GET /healthz` | `200 {"status":"ok"}`, not traced | No | - |
| `GET /stress/cpu?ms=500` | Stress test: busy loop for `ms` (cap `STRESS_MAX_CPU_MS`, 5000), span `stress.cpu`; 404 unless `STRESS_ENABLED=true` and the request did not come through Traefik | No | - |
| `GET /stress/memory?mb=32&hold_s=5` | Stress test: holds `mb` MiB for `hold_s` s then releases (caps `STRESS_MAX_MB` 128 total, `STRESS_MAX_HOLD_S` 30), span `stress.memory`, 429 when the budget is in use; same 404 rule. See [tests](../../tests/README.md) | No | - |
| `GET /orders` | `200`, 10 orders (ids 1-10, SKUs `SKU-001`...; order 7 has `SKU-999`) | No | Memory leak |
| `GET /orders/:id` | `200`, order plus `inventory`; `404` for an unknown id | `GET /inventory/items/{sku}` | Order 7: cross-service error chain (`502`) |
| `GET /orders/:id/stock` | Always `504` after 2 s | `GET /inventory/slow` (~3 s) | External call timeout |
| `GET /orders/report` | `200` after ~1.3 s | No | CPU hog on the event loop |
| `POST /orders` | `201` with body `{"customer":"c1","items":[{"sku":"SKU-001","quantity":2}]}` | No | No body or `{}`: unhandled `TypeError` -> `500` |

## 🐞 Planted issues and how to find them in Tempo

Every planted line in [`server.js`](server.js) is marked `PLANTED ISSUE:` with its fix.

| Issue | Endpoint | How it shows in Tempo | TraceQL that finds it | Fix |
|---|---|---|---|---|
| Memory leak (unbounded audit cache) | `GET /orders` | Fast spans, but `app.cache.entries` and `app.cache.bytes` on `request handler - /orders` rise on every call (1 MiB each) up to the 120 MiB lab cap | `{ resource.service.name = "nodejs-orders" && span.app.cache.bytes > 100000000 }`; trend: `{ resource.service.name = "nodejs-orders" && span.app.cache.bytes > 0 } \| max_over_time(span.app.cache.bytes)` | Do not keep per-request copies in memory; if needed keep `subarray(0, written)` in a bounded LRU with TTL |
| Cross-service error chain | `GET /orders/7` | python's server span errors (HTTP 500 on `SKU-999`), the fetch client span errors, nodejs's handler span has an `exception` event, nodejs's server span is `502` | `{ resource.service.name = "nodejs-orders" && kind = server && status = error } >> { resource.service.name = "python-inventory" && status = error }` or `{ resource.service.name = "nodejs-orders" && span.app.order.sku = "SKU-999" && status = error }` | Fix the python handler/data; here, return the order without stock instead of failing |
| External call timeout | `GET /orders/:id/stock` | Client span `GET` (`url.full` = `.../inventory/slow`) errors at exactly 2 s with `The operation was aborted due to timeout`; the handler span has an `exception` event of type `TimeoutError`; python's `/inventory/slow` span runs ~3 s, longer than its caller | `{ resource.service.name = "nodejs-orders" && kind = client && status = error && span:duration >= 2s }` | Call a fast/cached endpoint; set the timeout from the dependency's p99 and add a fallback |
| CPU hog (sync crypto on the event loop) | `GET /orders/report` | `orders.build_report` takes ~1.3 s with no child spans (pure CPU). Requests that arrive meanwhile wait, but their nodejs server span starts only after the loop is free, so the wait shows as a gap: the caller's client span is long, the nodejs span under it is short | `{ resource.service.name = "nodejs-orders" && name = "orders.build_report" && span:duration > 1s }`; blocked callers: `{ resource.service.name = "nextjs-web" && kind = client && span:duration > 500ms } > { resource.service.name = "nodejs-orders" && kind = server && span:duration < 100ms }` | Async `crypto.pbkdf2` or a `worker_thread`, or precompute/cache the report |
| Unhandled exception | `POST /orders` (no body or `{}`) | Server span `POST /orders` is `500`; `request handler - /orders` has an `exception` event: `TypeError: Cannot destructure property 'items' of 'req.body' as it is undefined.` or `Cannot read properties of undefined (reading 'length')` | `{ resource.service.name = "nodejs-orders" && name = "POST /orders" && status = error } && { event.exception.type = "TypeError" }` | Validate the body and answer `400` |

**Memory leak in Prometheus (cluster):** cAdvisor reports the pod's memory. It climbs ~1 MiB per
`GET /orders` call and then stays flat at the cap (about 165 MiB measured locally, limit 256 Mi):

```promql
container_memory_working_set_bytes{namespace="tempo-apps", container="nodejs"}
```

A restart frees it, which is the classic sign of a leak rather than real load.

## 🚀 Run it locally

From the repository root, with the local stack in [`apps/local`](../local) (Tempo, Collector,
Prometheus, python) already running:

```bash
# Build and start only this app (do not recreate the others).
cd apps/local
docker compose up -d --build --no-deps nodejs

# Smoke test: expect {"status":"ok"} then a JSON list of 10 orders.
curl -s http://127.0.0.1:13001/healthz
curl -s http://127.0.0.1:13001/orders
```

Trigger every planted issue once:

```bash
B=http://127.0.0.1:13001
curl -s -o /dev/null -w '%{http_code}\n' $B/orders            # 200, leaks 1 MiB
curl -s -o /dev/null -w '%{http_code}\n' $B/orders/3          # 200 (via python)
curl -s -o /dev/null -w '%{http_code}\n' $B/orders/7          # 502 (python 500)
curl -s -o /dev/null -w '%{http_code}\n' $B/orders/2/stock    # 504 after 2 s
curl -s -o /dev/null -w '%{http_code}\n' $B/orders/report     # 200 after ~1.3 s
curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/orders    # 500 TypeError
```

Search Tempo (local port 13200). New traces are searchable after about 30-60 s:

```bash
curl -sG http://127.0.0.1:13200/api/search \
  --data-urlencode 'q={ resource.service.name = "nodejs-orders" && kind = client && status = error && span:duration >= 2s }'
```

## ☸️ Deploy to Kubernetes

See [`k8s/README.md`](k8s/README.md). In short, the image is built and pushed by
`apps/build-push.sh nodejs`, and `apps/deploy-apps.sh [production|lab]` renders the profile with kustomize, pins the image by
digest (`<registry>/nodejs@sha256:...`) and applies all three apps.

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| Pod ready | `kubectl -n tempo-apps get pods -l app.kubernetes.io/name=nodejs` | 2 pods `1/1 Running` on different nodes (lab: 1), 0 restarts |
| Health | `kubectl -n tempo-apps port-forward svc/nodejs 3000:3000` then `curl -s localhost:3000/healthz` | `{"status":"ok"}` |
| Traces arrive | Grafana Explore, Tempo, `{ resource.service.name = "nodejs-orders" }` | Traces within a minute |
| Propagation | `{ resource.service.name = "nodejs-orders" } >> { resource.service.name = "python-inventory" }` | Traces with both services |
| Probes not traced | `{ resource.service.name = "nodejs-orders" && span.url.path = "/healthz" }` | No results |

## 🛡️ Security

| Threat | Control | Where |
|---|---|---|
| Container breakout / privilege gain | Non-root UID 10001, `allowPrivilegeEscalation: false`, drop ALL capabilities, seccomp `RuntimeDefault` | `Dockerfile`, `k8s/deployment.yaml` |
| Tampering with app files at runtime | `readOnlyRootFilesystem: true`; app files owned by root; only `/tmp` (emptyDir, 16 Mi) is writable | `k8s/deployment.yaml` |
| Kubernetes API access from a compromised pod | `automountServiceAccountToken: false` | `k8s/deployment.yaml` |
| Unwanted network access | Namespace NetworkPolicies allow ingress only from Traefik, same namespace and Prometheus | [`k8s/networkpolicies.yaml`](../../k8s/networkpolicies.yaml) |
| Cloud identifiers in public traces | Cloud resource detectors disabled (`OTEL_NODE_RESOURCE_DETECTORS`) | `Dockerfile`, `k8s/deployment.yaml` |

Not protected (on purpose, this is a demo): no authentication, no input validation on `POST /orders`,
and the planted issues themselves. Do not expose this app beyond a lab.

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No `nodejs-orders` traces in Tempo | Wrong `OTEL_EXPORTER_OTLP_ENDPOINT`, or Collector unreachable | Check the env var; set `OTEL_LOG_LEVEL=debug` and read the pod log for export errors |
| Search finds nothing right after a request | Tempo has not made the spans searchable yet | Wait 30-60 s and search again |
| `GET /orders/:id` returns 502 `fetch failed` | python not reachable (`INVENTORY_URL` or DNS) | `kubectl -n tempo-apps get svc python`; check `INVENTORY_URL` |
| nodejs and python appear as separate traces | `traceparent` not propagated | Keep `undici` in `OTEL_NODE_ENABLED_INSTRUMENTATIONS`; use `fetch`, not a raw socket client |
| Pod memory grows and stays high | Planted memory leak (`GET /orders`) | Expected; `kubectl -n tempo-apps rollout restart deploy/nodejs` resets it |
| Pod briefly not ready during load | Planted CPU hog blocks the event loop, so readiness times out | Expected; liveness is tolerant (6 x 20 s, 10 s timeout) so the pod is not restarted |
| `CreateContainerConfigError: ... non-root` | Image without a numeric `USER` | Use this Dockerfile (`USER 10001:10001`) |

## 🏭 Production checklist

Manifests and image are production-grade; the endpoints contain planted bugs on purpose. For a real Node.js service:

| Area | Action |
|---|---|
| Code | Remove the unbounded cache (bounded LRU + TTL), move CPU work to `worker_threads` or async crypto, validate request bodies (`400`), keep the 2 s dependency timeout with a fallback |
| HA / sizing | 2+ replicas behind the PDB; one event loop per pod, so scale out (HPA) rather than up |
| Tracing | Keep cloud resource detectors off in public traces; limit instrumentations to what you use; ratio sampling + Collector tail sampling at high volume |
| Upgrades | Bump `@opentelemetry/*` together (same release train), rebuild with a new immutable `TAG`, roll back with `rollout undo` |
| SLO / runbooks | 99% availability, p95 < 1 s: [apps/monitoring](../monitoring/README.md) |
| More | [Apps production checklist](../README.md#-production-checklist) |

## 📌 Pinned versions

| Component | Version |
|---|---|
| Base image | `node:26.13.0-alpine3.24` pinned by digest `sha256:8996bb58…` (Node.js 26 LTS, multi-arch index) |
| `express` | 5.3.0 |
| `@opentelemetry/api` | 1.10.0 |
| `@opentelemetry/sdk-node` | 0.301.0 |
| `@opentelemetry/auto-instrumentations-node` | 0.83.0 (brings `instrumentation-http` 0.301.0, `instrumentation-express` 0.73.0, `instrumentation-undici` 0.35.0) |
| `@opentelemetry/exporter-trace-otlp-proto` | 0.301.0 |
| Tested with | Tempo 3.1.1, OTel Collector contrib 0.165.0 |

## 🔗 References

- [OpenTelemetry JS: Node.js getting started](https://opentelemetry.io/docs/languages/js/getting-started/nodejs/)
- [OpenTelemetry JS zero-code instrumentation](https://opentelemetry.io/docs/zero-code/js/)
- [OpenTelemetry JS zero-code configuration (env vars)](https://opentelemetry.io/docs/zero-code/js/configuration/)
- [OpenTelemetry JS manual instrumentation](https://opentelemetry.io/docs/languages/js/instrumentation/)
- [OpenTelemetry JS exporters](https://opentelemetry.io/docs/languages/js/exporters/)
- [Tempo: construct a TraceQL query](https://grafana.com/docs/tempo/latest/traceql/construct-traceql-queries/)
- [Tempo: TraceQL metrics functions](https://grafana.com/docs/tempo/latest/metrics-from-traces/metrics-queries/functions/)
- [Express 5 migration guide](https://expressjs.com/en/guide/migrating-5.html)
- [Express error handling](https://expressjs.com/en/guide/error-handling.html)
