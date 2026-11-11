# 🧪 Local test stack (Docker Compose)

Runs the three sample apps with an OpenTelemetry Collector, Grafana Tempo and Prometheus on one machine, so you can
see every planted issue in Tempo before deploying to Kubernetes. Same data path as the cluster:
app → OTLP/HTTP → Collector → OTLP/gRPC → Tempo → metrics-generator → Prometheus.

## 🧩 Components

| Service | What it does (one line) | Defined in | Host port |
|---|---|---|---|
| `tempo` | Tempo single binary: OTLP in, TraceQL API, metrics-generator (span metrics + service graph) | [tempo.yaml](tempo.yaml) | 13200 (HTTP API) |
| `otel-collector` | Receives OTLP from the apps, batches, forwards to Tempo | [otel-collector.yaml](otel-collector.yaml) | 14317 (gRPC), 14318 (HTTP) |
| `prometheus` | Receives span/service-graph metrics from Tempo via remote write | [prometheus.yaml](prometheus.yaml) | 19090 |
| `python` | `python-inventory` sample app | [../python](../python/) | 18000 |
| `nodejs` | `nodejs-orders` sample app | [../nodejs](../nodejs/) | 13001 |
| `nextjs` | `nextjs-web` sample app | [../nextjs](../nextjs/) | 13000 |

Host ports are offset (1xxxx) so they don't clash with other local services. Nothing is exposed beyond what Docker
publishes; there is no authentication, so run it only on a trusted machine.

## ✅ Prerequisites

- Docker Engine with the Compose v2 plugin; about 2 vCPU, 3 GB RAM and 3 GB disk free.
- `curl` (and `jq` for the optional pretty-printing below).

## ▶️ Run it

```bash
cd apps/local
docker compose up -d --build          # builds the 3 app images, starts all 6 services
docker compose ps                     # all services "running"
curl -s 127.0.0.1:13200/ready         # Tempo answers "ready" after ~15 s
DOMAIN=<your-domain> ../../scripts/load.sh local 5   # traffic that triggers every planted issue
```

Then query Tempo (allow ~30 s after the load):

```bash
# Every trace with an error, newest first
curl -sG 127.0.0.1:13200/api/search --data-urlencode 'q={ status = error }' --data-urlencode limit=20 | jq '.traces[] | {rootServiceName, rootTraceName, durationMs}'
# One trace by ID
curl -s 127.0.0.1:13200/api/traces/<trace-id> | jq '.batches | length'
# Service graph edges produced by the metrics-generator
curl -sG 127.0.0.1:19090/api/v1/query --data-urlencode 'query=sum by (client, server) (traces_service_graph_request_total)' | jq '.data.result[] | .metric'
```

The TraceQL query for each planted issue is in each app's README: [nextjs](../nextjs/README.md),
[nodejs](../nodejs/README.md), [python](../python/README.md).

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `curl 127.0.0.1:13200` hangs while other ports work | A host route (VPN/overlay network) covers the container IP | The Compose network is pinned to `172.29.40.0/24`; change `networks.default` in [compose.yaml](compose.yaml) to a free range (`ip route` lists used ones) |
| `error getting credentials` on pull/build | `~/.docker/config.json` names a credential helper that isn't installed | `export DOCKER_CONFIG=$(mktemp -d)` with an empty `config.json`, or remove `credsStore` |
| Search returns no traces | Spans not flushed yet, or app can't reach the Collector | Wait 30 s; `docker compose logs otel-collector` should show `TracesExporter` lines |
| Tempo restarts with permission errors on `/var/tempo` | Volume owned by root; Tempo runs as uid 10001 | `docker compose down -v` and start again |

## 🏭 Production checklist

This stack is for local testing only (no auth, no TLS, no persistence guarantees). For production use the
Kubernetes manifests and the Helm values in [`helm/`](../../helm/); see the [apps production checklist](../README.md#-production-checklist).

## 🧹 Teardown

```bash
docker compose down -v                # removes containers, network and the Tempo volume
```

## 📌 Pinned versions

| Image | Tag |
|---|---|
| grafana/tempo | 3.1.1 |
| otel/opentelemetry-collector-contrib | 0.165.0 |
| prom/prometheus | v3.16.0 |

## 🔗 References

- [Tempo single-binary Docker Compose example](https://github.com/grafana/tempo/tree/main/example/docker-compose/single-binary)
- [Tempo configuration](https://grafana.com/docs/tempo/latest/configuration/)
- [Tempo metrics-generator](https://grafana.com/docs/tempo/latest/metrics-from-traces/metrics-generator/)
- [OpenTelemetry Collector configuration](https://opentelemetry.io/docs/collector/configuration/)
