# ▲ nextjs-web: Next.js front end with planted bugs

A small Next.js 16 (App Router) app that calls `nodejs-orders` and shows how Grafana Tempo exposes
code issues in a front-end/BFF layer. It is traced with OpenTelemetry through `@vercel/otel`, the
path the Next.js docs recommend, plus a few manual spans, attributes and events. Three realistic
issues are planted on purpose (two more table rows show how upstream problems look from here), so you can see how each one looks in a trace and which TraceQL query
finds it.

**Status:** tested locally with Docker Compose (`apps/local`) on 2026-11-08: Node.js 26.13.0,
Next.js 16.4.5, `@vercel/otel` 2.3.0, Tempo 3.1.1, OTel Collector contrib 0.165.0. Every route and
every TraceQL query below was run against that stack, including one trace that spans
`nextjs-web -> nodejs-orders -> python-inventory`, and the image was run with a read-only root
filesystem as UID 10001. The Kubernetes manifests pass `kubectl kustomize`; they were not applied to
a cluster in this test.

| Item | Value |
|---|---|
| OTel `service.name` | `nextjs-web` |
| Kubernetes Service | `nextjs` (namespace `tempo-apps`, port 3000) |
| Public host | `tempo-nextjs.<domain>` (Traefik IngressRoute in [`k8s/ingressroutes.yaml`](../../k8s/ingressroutes.yaml)) |
| Calls | `nodejs-orders` (`ORDERS_URL`, `http://nodejs:3000`) |
| Image | `tempo-apps/nextjs:1.0.2` (registry prefix set at deploy time) |

## 🧩 Files

| File | What it does | Security role |
|---|---|---|
| [`instrumentation.ts`](instrumentation.ts) | Next.js hook: loads the OTel setup in the Node.js runtime only | - |
| [`instrumentation.node.ts`](instrumentation.node.ts) | `registerOTel()`: exporter, sampler, fetch propagation | Keeps `/healthz` out of traces; propagates `traceparent` only to `ORDERS_URL` |
| [`orders.ts`](orders.ts) | Tiny `fetch` client for `nodejs-orders` | No secrets |
| [`app/`](app/README.md) | Page and route handlers, the four planted issues | Input is not validated on purpose (planted issue) |
| [`next.config.ts`](next.config.ts) | `output: 'standalone'`, no `X-Powered-By` header | Small runtime image without dev dependencies |
| [`package.json`](package.json), [`package-lock.json`](package-lock.json) | Exact dependency pins and the lockfile used by `npm ci` | Reproducible installs; `npm audit --omit=dev`: 0 known vulnerabilities |
| [`tsconfig.json`](tsconfig.json) | TypeScript strict mode | - |
| [`Dockerfile`](Dockerfile) | Three-stage build on `node:26.13.0-alpine3.24`, runs `server.js` | Runs as UID 10001; app files owned by root (read-only) |
| [`.dockerignore`](.dockerignore) | Keeps `node_modules`, `.next`, docs and manifests out of the build context | No local files leak into the image |
| [`k8s/`](k8s/README.md) | Deployment, Service, kustomization | Pod Security `restricted` settings |

## 📡 Instrumentation

| Layer | How | Spans you get |
|---|---|---|
| Next.js built-in | Next.js wraps each request in spans when a tracer provider is registered | `GET /api/dashboard` (SERVER, attribute `next.route`, `http.status_code`), `executing api route (app) /api/dashboard`, `resolve page components`, `render route (app) /` |
| `@vercel/otel` | `registerOTel()` in `instrumentation.node.ts`: tracer provider, W3C propagator, `fetch` instrumentation, OTLP exporter | `fetch GET http://nodejs:3000/orders/1` (CLIENT, `http.status_code`, error status on `>= 500`) |
| Manual | `@opentelemetry/api` in [`app/api/dashboard/route.ts`](app/api/dashboard/route.ts) | Span `dashboard.load_orders`; attributes `app.orders.count`, `app.orders.failed`, `app.orders.requests`; event `order.fetch_failed`; `recordException()` + `setStatus(ERROR)` if the list call fails |

**Why `@vercel/otel` and not a manual `NodeSDK`:** it is the setup the Next.js OpenTelemetry guide
recommends, it works with the standalone output and it needs no bundler changes. A manual
`@opentelemetry/sdk-node` setup also works, but must be kept out of the bundle and adds more code.
Despite the name, `@vercel/otel` is a plain OpenTelemetry SDK wrapper and runs anywhere; this app
removes its Vercel-only resource attributes (`cloud.provider`, `vercel.runtime`).

**Exporter:** `@vercel/otel` reads `OTEL_EXPORTER_OTLP_PROTOCOL` (`http/protobuf`) and sends spans to
`$OTEL_EXPORTER_OTLP_ENDPOINT/v1/traces`. With `OTEL_LOG_LEVEL=debug` the log shows
`Configure trace exporter: http/protobuf http://otel-collector:4318/v1/traces` and `onSuccess 200`.

**Context propagation:** `@vercel/otel` adds the W3C `traceparent` header only to URLs listed in
`propagateContextUrls`. `instrumentation.node.ts` sets that list to `ORDERS_URL`, so every call to
`nodejs-orders` joins the same trace, and nodejs passes it on to `python-inventory`. Calls to any
other host get no trace headers.

**Sampling and noise:** `instrumentation.node.ts` wraps the sampler named by `OTEL_TRACES_SAMPLER`
(default `parentbased_always_on`) and drops two kinds of root spans: `GET /healthz` (probes) and
non-SERVER roots (Next.js start-up work such as `register instrumentation` and `load route module`).
Children of a dropped root are dropped too. `NEXT_OTEL_VERBOSE` is left unset: the default Next.js
spans already show the route, its status and its timing, and verbose mode adds many tiny internal
spans per request.

### Environment variables

| Variable | Value | Why |
|---|---|---|
| `OTEL_SERVICE_NAME` | `nextjs-web` | Service name in Tempo and the service graph |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://otel-collector.observability:4318` (cluster), `http://otel-collector:4318` (Compose) | Collector OTLP/HTTP; `/v1/traces` is appended |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | OTLP over HTTP with protobuf |
| `OTEL_TRACES_SAMPLER` | `parentbased_always_on` | Keep every trace; follow the caller's sampling decision |
| `OTEL_RESOURCE_ATTRIBUTES` | `deployment.environment.name=lab,service.namespace=tempo-apps,service.version=1.0.2,k8s.pod.name=...` | Pod name comes from the Kubernetes downward API |
| `ORDERS_URL` | `http://nodejs:3000` | Base URL of nodejs-orders; also the only URL that gets `traceparent` |
| `PORT`, `HOSTNAME` | `3000`, `0.0.0.0` | Listen address of the standalone server (Kubernetes sets `HOSTNAME` to the pod name, so the Deployment overrides it) |
| `NEXT_TELEMETRY_DISABLED` | `1` | No Next.js usage telemetry |
| `NEXT_OTEL_VERBOSE` | unset | Default (non-verbose) Next.js spans |

## 🌐 Routes

| Method and path | Normal result | Calls nodejs-orders | Planted issue |
|---|---|---|---|
| `GET /healthz` | `200 {"status":"ok"}`, not traced | No | - |
| `GET /stress/cpu?ms=500` | Stress test: busy loop for `ms` (cap `STRESS_MAX_CPU_MS`, 5000), span `stress.cpu`; 404 unless `STRESS_ENABLED=true` and the request did not come through Traefik | No | - |
| `GET /stress/memory?mb=32&hold_s=5` | Stress test: holds `mb` MiB for `hold_s` s then releases (caps `STRESS_MAX_MB` 128 total, `STRESS_MAX_HOLD_S` 30), span `stress.memory`, 429 when the budget is in use; same 404 rule. See [tests](../../tests/README.md) | No | - |
| `GET /` | `200`, server-rendered list of the scenarios | No | - |
| `GET /api/dashboard` | `200` with all orders; `"partial": true` and the failed ids when a detail call fails | `GET /orders`, then `GET /orders/:id` for each order | N+1 HTTP fan-out |
| `POST /api/checkout` | `201` with body `{"customer":"c1","items":[{"sku":"SKU-001","quantity":2,"price":9.5}]}` | `POST /orders` | No body or `{}`: unhandled `TypeError` -> `500` |
| `GET /api/stock/:id` | Passes on the upstream answer: `504` after ~2 s | `GET /orders/:id/stock` | Cascading timeout |
| `GET /api/report` | `200` after ~1.3 s, with `upstreamMs` | `GET /orders/report` | Slow upstream (CPU hog in nodejs) |

## 🐞 Planted issues and how to find them in Tempo

Every planted line in [`app/`](app/README.md) is marked `PLANTED ISSUE:` with its fix.

| Issue | Route | How it shows in Tempo | TraceQL that finds it | Fix |
|---|---|---|---|---|
| N+1 HTTP fan-out | `GET /api/dashboard` | Under `dashboard.load_orders`, 11 `fetch GET` CLIENT spans in a waterfall (1 list + 10 details), each starting after the previous one ends; `app.orders.requests` = 11 | `{ resource.service.name = "nextjs-web" && kind = server } >> { resource.service.name = "nextjs-web" && kind = client } \| count() > 10` | Batch endpoint (details in `GET /orders`), or `Promise.all` with a concurrency limit |
| Hidden downstream failure (handled) | `GET /api/dashboard` | Response is `200`, but `dashboard.load_orders` has an `order.fetch_failed` event per failed order (order 7: `502`) and the failed `fetch` span is red | `{ resource.service.name = "nextjs-web" && event:name = "order.fetch_failed" }` | Already degrades gracefully; alert on the event rate and fix the failing dependency |
| Unhandled exception | `POST /api/checkout` (no body or `{}`) | Server span `POST /api/checkout` is error with `http.status_code` `500`; `executing api route (app) /api/checkout` has an `exception` event: `TypeError: Cannot read properties of undefined (reading 'reduce')` with the stack trace | `{ resource.service.name = "nextjs-web" && event.exception.type = "TypeError" }` | Validate the cart and answer `400` |
| Cascading timeout | `GET /api/stock/:id` | The `fetch` CLIENT span waits ~2.01 s and ends in error (`504`); below it nodejs aborts its own call at 2 s while python's `/inventory/slow` runs ~3 s; the `504` reaches the user | `{ resource.service.name = "nextjs-web" && kind = client && status = error && span:duration > 2s }` | Own budget (`AbortSignal.timeout(500)`), fallback value, fix the slow dependency |
| Slow upstream (CPU hog in nodejs) | `GET /api/report` | `GET /api/report` takes ~1.3 s; almost all of it is the `fetch` CLIENT span, and under it nodejs's `orders.build_report` span has no children (pure CPU) | `{ resource.service.name = "nextjs-web" && kind = client && span:duration > 1s } >> { name = "orders.build_report" }` | Fix in nodejs (async crypto, worker thread or cache); here, cache the report |

**Note on `>` vs `>>`:** Next.js nests app code under `executing api route (app) ...`, so the
`fetch` spans are grandchildren of the SERVER span. The generic N+1 query
`{ kind = server } > { kind = client } | count() > 10` (direct child) returns no `nextjs-web`
traces; use the descendant operator `>>` as above, or start from the manual span:
`{ name = "dashboard.load_orders" } > { kind = client } | count() > 10`.

Full chain in one trace: `{ resource.service.name = "nextjs-web" } >> { resource.service.name = "python-inventory" }`.

## 🚀 Run it locally

From the repository root, with the local stack in [`apps/local`](../local) (Tempo, Collector,
Prometheus, python, nodejs) running:

```bash
# Build and start only this app (do not recreate the others).
cd apps/local
docker compose up -d --build --no-deps nextjs

# Smoke test: expect {"status":"ok"} then the scenario page.
curl -s http://127.0.0.1:13000/healthz
curl -s http://127.0.0.1:13000/ | head -c 300
```

Trigger every planted issue once:

```bash
B=http://127.0.0.1:13000
curl -s -o /dev/null -w '%{http_code}\n' $B/api/dashboard               # 200, 11 sequential calls
curl -s -o /dev/null -w '%{http_code}\n' -X POST $B/api/checkout        # 500 TypeError
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'content-type: application/json' \
  -d '{"customer":"c1","items":[{"sku":"SKU-001","quantity":2,"price":9.5}]}' $B/api/checkout  # 201
curl -s -o /dev/null -w '%{http_code}\n' $B/api/stock/3                 # 504 after ~2 s
curl -s -o /dev/null -w '%{http_code}\n' $B/api/report                  # 200 after ~1.3 s
```

Search Tempo (local port 13200). New traces are searchable after about 15-60 s:

```bash
curl -sG http://127.0.0.1:13200/api/search \
  --data-urlencode 'q={ resource.service.name = "nextjs-web" && event.exception.type = "TypeError" }'
```

Without Docker (needs Node.js 26 and a reachable nodejs-orders and Collector):

```bash
npm ci
ORDERS_URL=http://127.0.0.1:13001 OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318 npm run dev
```

## ☸️ Deploy to Kubernetes

See [`k8s/README.md`](k8s/README.md). In short, the image is built and pushed by
`apps/build-push.sh nextjs`, and `apps/deploy-apps.sh [production|lab]` renders the profile with kustomize, pins the image by
digest (`<registry>/nextjs@sha256:...`) and applies all three apps.

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| Pod ready | `kubectl -n tempo-apps get pods -l app.kubernetes.io/name=nextjs` | 2 pods `1/1 Running` on different nodes (lab: 1), 0 restarts |
| Health | `kubectl -n tempo-apps port-forward svc/nextjs 3000:3000` then `curl -s localhost:3000/healthz` | `{"status":"ok"}` |
| Traces arrive | Grafana Explore, Tempo, `{ resource.service.name = "nextjs-web" }` | Traces within a minute |
| Propagation | `{ resource.service.name = "nextjs-web" } >> { resource.service.name = "nodejs-orders" }` | Traces with both services |
| Probes not traced | `{ resource.service.name = "nextjs-web" && name = "GET /healthz" }` | No results |

## 🧪 Tests (local, 2026-11-08)

Docker Compose stack in `apps/local`; one request per route; times from `curl`.

| Test | Result | What it proves |
|---|---|---|
| `GET /api/dashboard` | `200` in 0.12-0.21 s; trace has 11 `fetch` CLIENT spans under `dashboard.load_orders`, `app.orders.count` = 9, 1 `order.fetch_failed` event (order 7) | N+1 waterfall visible; errors handled as partial data |
| `POST /api/checkout` (`{}`) | `500` in 10-30 ms; `exception` event, `exception.type` = `TypeError` | Unhandled exception recorded by Next.js |
| `POST /api/checkout` (valid cart) | `201` | Happy path still works |
| `GET /api/stock/3` | `504` in 2.01-2.03 s; CLIENT span 2006-2010 ms, error | Timeout cascades to the user |
| `GET /api/report` | `200` in 1.26-1.36 s; CLIENT span 1.25-1.29 s over `orders.build_report` 1.25-1.29 s | Upstream CPU time shows in the caller's trace |
| 3 x `GET /healthz` | `200`; 0 traces for `name = "GET /healthz"` | Probes create no traces |
| Start-up spans | 0 `register instrumentation` / `load route module` root traces after the sampler change | No start-up noise |
| One trace, three services | `{ resource.service.name = "nextjs-web" } >> { resource.service.name = "python-inventory" }` matches dashboard and stock traces | `traceparent` reaches nodejs and python |
| Read-only root, UID 10001 | `docker run --read-only --tmpfs /tmp --tmpfs /app/.next/cache:uid=10001,gid=10001 --cap-drop ALL`: all routes answer, traces exported, `touch /app/x` fails with `Read-only file system` | Works under the Kubernetes security context |
| Image size | 218 MB | Standalone output keeps the image small |

Not tested: the cluster deployment itself (manifests only rendered with `kubectl kustomize`).

## 🛡️ Security

| Threat | Control | Where |
|---|---|---|
| Container breakout / privilege gain | Non-root UID 10001, `allowPrivilegeEscalation: false`, drop ALL capabilities, seccomp `RuntimeDefault` | `Dockerfile`, `k8s/deployment.yaml` |
| Tampering with app files at runtime | `readOnlyRootFilesystem: true`; app files owned by root; only `/tmp` and `/app/.next/cache` (emptyDir) are writable | `k8s/deployment.yaml` |
| Kubernetes API access from a compromised pod | `automountServiceAccountToken: false` | `k8s/deployment.yaml` |
| Unwanted network access | Namespace NetworkPolicies allow ingress only from Traefik, same namespace and Prometheus | [`k8s/networkpolicies.yaml`](../../k8s/networkpolicies.yaml) |
| Trace context leaking to third parties | `traceparent` is sent only to `ORDERS_URL` (`propagateContextUrls`) | `instrumentation.node.ts` |
| Platform metadata in public traces | Vercel default resource attributes removed; only `OTEL_RESOURCE_ATTRIBUTES` added | `instrumentation.node.ts` |

Not protected (on purpose, this is a demo): no authentication, no rate limiting, no input validation
on `POST /api/checkout`, and the planted issues themselves. OTLP to the Collector is plain HTTP inside
the cluster. Do not expose this app beyond a lab.

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No `nextjs-web` traces in Tempo | Wrong `OTEL_EXPORTER_OTLP_ENDPOINT`, or Collector unreachable | Set `OTEL_LOG_LEVEL=debug`; the log must show `Configure trace exporter: http/protobuf <endpoint>/v1/traces` and `onSuccess 200` |
| Search finds nothing right after a request | Spans are batched (~5 s) and Tempo needs a few seconds to index them | Wait 15-60 s and search again |
| nextjs and nodejs appear as separate traces | Call URL does not start with `ORDERS_URL`, so no `traceparent` is sent | Call nodejs only through `orders.ts`; keep `ORDERS_URL` equal to the base URL used |
| Last requests missing after `docker rm -f` / SIGKILL | The batch was not flushed | Expected for a hard kill; stop gracefully |
| Pod not ready, log shows it listening on the pod name | `HOSTNAME` set by Kubernetes | Keep `HOSTNAME=0.0.0.0` in the Deployment |
| `EROFS: read-only file system` under `.next/cache` | Read-only root without a writable cache | Mount the `next-cache` emptyDir at `/app/.next/cache` |
| `POST /api/checkout` returns `500` | Planted issue: no `items` in the body | Expected; send a cart with `items` |
| `GET /api/dashboard` shows `"partial": true` | Order 7 (and any failing order) returns `502` from nodejs | Expected; see the trace for the failing call |

## 🏭 Production checklist

Manifests and image are production-grade; the routes contain planted bugs on purpose. For a real Next.js service:

| Area | Action |
|---|---|
| Code | Fix the planted issues: parallel or batched order fetch (`Promise.all` / one bulk endpoint), validate the checkout body (`400`), set a timeout + fallback on `/api/stock` |
| HA / sizing | 2+ replicas behind the PDB; serve `/_next/static` from a CDN; size memory from the standalone server's RSS under load |
| Tracing | Keep `NEXT_OTEL_VERBOSE` off; set `OTEL_TRACES_SAMPLER=parentbased_traceidratio` at high volume and tail-sample at the Collector |
| Upgrades | Bump `next`/`@vercel/otel` together (SDK peer ranges), rebuild with a new immutable `TAG`, roll back with `rollout undo` |
| SLO / runbooks | 99% availability, p95 < 1 s: [apps/monitoring](../monitoring/README.md) |
| More | [Apps production checklist](../README.md#-production-checklist) |

## 📌 Pinned versions

| Component | Version |
|---|---|
| Base image | `node:26.13.0-alpine3.24` pinned by digest `sha256:8996bb58…` (Node.js 26 LTS, multi-arch index) |
| `next` | 16.4.5 |
| `react`, `react-dom` | 19.3.1 |
| `@vercel/otel` | 2.3.0 |
| `@opentelemetry/api` | 1.9.1 (1.10.0 is not allowed: the 2.x SDK packages that `@vercel/otel` 2.3.0 needs require `< 1.10.0`) |
| `@opentelemetry/sdk-trace-base`, `resources`, `sdk-metrics` | 2.12.0 (peer dependencies of `@vercel/otel`) |
| `@opentelemetry/api-logs`, `sdk-logs`, `instrumentation` | 0.223.0 (peer dependencies of `@vercel/otel`) |
| `typescript` | 7.0.2 (build only) |
| Tested with | Tempo 3.1.1, OTel Collector contrib 0.165.0 |

## 🔗 References

- [Next.js: OpenTelemetry guide](https://nextjs.org/docs/app/guides/open-telemetry)
- [Next.js: `instrumentation.ts` file convention](https://nextjs.org/docs/app/api-reference/file-conventions/instrumentation)
- [Next.js: `output: 'standalone'`](https://nextjs.org/docs/app/api-reference/config/next-config-js/output)
- [OpenTelemetry JS: manual instrumentation](https://opentelemetry.io/docs/languages/js/instrumentation/)
- [OpenTelemetry JS: exporters](https://opentelemetry.io/docs/languages/js/exporters/)
- [OpenTelemetry: SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
- [Tempo: construct a TraceQL query](https://grafana.com/docs/tempo/latest/traceql/construct-traceql-queries/)
