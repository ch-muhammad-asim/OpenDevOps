# 🛠️ Scripts

Operational scripts for hermes-grafana-tempo. Run them from the repository folder `hermes-grafana-tempo/`.

| Script | What it does (one line) | Usage |
|---|---|---|
| [deploy.sh](deploy.sh) | Installs the platform in order (object store, Prometheus + Thanos, edge, Tempo, Collector, Grafana, dashboards, routes, DNS); idempotent | `PROFILE=lab scripts/deploy.sh [step ...]` |
| [verify.sh](verify.sh) | End-to-end PASS/FAIL checks: releases, pods, health (incl. Thanos query and its stores), Grafana datasources, project alert rules loaded, test trace through Collector to Tempo and Grafana, scraping, NetworkPolicy, public HTTPS | `PROFILE=lab scripts/verify.sh [--read-only]` |
| [teardown.sh](teardown.sh) | Uninstalls releases and the project namespaces (incl. `hermes` and `object-storage`) and CRDs; safe to re-run; `--cluster` also deletes the bucket and cluster (asks first) | `scripts/teardown.sh [--cluster]` |
| [update-dns.sh](update-dns.sh) | Creates or updates one proxied Cloudflare A record (used by the `dns` step) | `CF_TOKEN_FILE=... scripts/update-dns.sh <host> <ipv4>` |
| [load.sh](load.sh) | Sends traffic that triggers every planted issue in the three sample apps, then prints a status-code summary | `scripts/load.sh [public\|local] [rounds]` |

## 🚀 deploy.sh / verify.sh

| Env | Default | Meaning |
|---|---|---|
| `PROFILE` | `prod` | `prod`: each chart's `values.yaml`, Tempo = tempo-distributed. `lab`: adds `values-lab.yaml` overlays, Tempo = single binary |
| `TLS_MODE` | `cloudflare` | `cloudflare`: HTTPS ends at the Cloudflare proxy, Traefik serves its default certificate (zone SSL mode **Full**). `letsencrypt`: cert-manager DNS-01 certificates patched into the routes (**Full (strict)**) |
| `OBJECT_STORE` | prod `gcs`, lab `seaweedfs` | `gcs`: dedicated GCS buckets with Workload Identity ([../infra/](../infra/README.md)); `seaweedfs`: in-cluster SeaweedFS S3 ([../helm/seaweedfs/](../helm/seaweedfs/README.md)), credentials generated once into Secrets, never printed |
| `TEMPO_STORAGE` | follows `OBJECT_STORE`: `gcs` or `s3` | `gcs`: bucket via [../infra/create-tempo-bucket.sh](../infra/create-tempo-bucket.sh) (Workload Identity scoped to the bucket); `s3`: SeaweedFS bucket `tempo-traces`; `local`: PVC only |
| `KAFKA_BOOTSTRAP` | — | Required for `PROFILE=prod`: Kafka-compatible queue for Tempo 3.x distributed mode |
| `CF_TOKEN_FILE` | — (required by `dns`, and by `certmanager` with `letsencrypt`) | Path to a Cloudflare API token file with Zone:DNS:Edit + Zone:Zone:Read (chmod 600); read into a private header file, never printed |

Steps (run any subset in this order): `namespaces objectstore prometheus certmanager traefik tempo collector grafana dashboards edge dns`.
`objectstore` (lab) creates namespace `object-storage` and the S3 credentials once (Secrets
`object-storage/seaweedfs-s3-config`, `observability/tempo-s3`, `monitoring/thanos-objstore`; reused on re-runs);
`prometheus` installs kube-prometheus-stack, then SeaweedFS and its bucket Job (lab), then Thanos (lab
`helm/thanos/overlays/lab`, prod `helm/thanos`).
`verify.sh` exits with the number of failed checks. Default mode starts two short-lived curl pods (`otlp-probe` in
`tempo-apps`, `netpol-probe` in `default`, both Pod Security `restricted`, deleted on exit) and writes one test span
(`service.name=verify-probe`); `--read-only` skips those two checks. It reads `TLS_MODE` like `deploy.sh`
(cert-manager checks only with `letsencrypt`).
Grafana's Alertmanager data source has no backend health endpoint in Grafana 13:
`GET /api/datasources/uid/alertmanager/health` returns `500 plugin.unavailable` although the data source works.
`verify.sh` therefore checks it through the data source proxy (`/api/datasources/proxy/uid/alertmanager/api/v2/status`,
HTTP 200), not `/health`. When Thanos is installed it also checks `thanos-query /-/ready` and that thanos-query sees the
sidecar and the store gateway; with namespace `object-storage` present it checks its pods are Ready.
Lab result 2026-11-08: 32 PASS, 0 failures (`PROFILE=lab`, `TLS_MODE=cloudflare`, cert-manager not installed).

## 🚦 load.sh

| Argument / env | Default | Meaning |
|---|---|---|
| `public` / `local` | `public` | `public`: `https://tempo-{nextjs,nodejs,python}.$DOMAIN`; `local`: the [apps/local](../apps/local/) stack on 127.0.0.1 |
| `rounds` | `20` | Each round is ~13 requests, ~0.5-3 s (longer while the stock call waits for its 2 s timeout) |
| `DOMAIN` | `saqlainmushtaq.com` | Public zone for the app hostnames |
| `NEXTJS_URL`, `NODEJS_URL`, `PYTHON_URL` | per mode | Override any single target |

Expected summary: mostly `200`, plus `500` (unhandled exceptions), `502` (order 7) and `504` (stock timeout).
Example local run (2026-11-08, 5 rounds): `200: 32, 500: 15, 502: 5, 504: 1`, 7 s. Wait ~30 s before searching in Tempo.

## 🏭 Production checklist (deploy/verify/teardown)

- [ ] Run `deploy.sh` from CI (or GitOps) with `PROFILE=prod`, pinned chart versions and a reviewed diff (`helm diff`) before every upgrade.
- [ ] Provide `KAFKA_BOOTSTRAP` (managed Kafka-compatible service, TLS + SASL) and let `deploy.sh` create the Tempo and Thanos buckets with `ACCESS_MODE=bucket` (`roles/storage.objectUser` on each bucket only).
- [ ] Prefer `TLS_MODE=letsencrypt` (or a Cloudflare Origin CA certificate) with Cloudflare **Full (strict)** so the origin certificate is validated.
- [ ] Run `verify.sh` after every deploy and alert on failures; keep `teardown.sh` out of production pipelines.

## 🏭 Production checklist (load.sh)

- [ ] Run `load.sh` only against lab or staging: it deliberately triggers errors, timeouts and a memory leak, and fires the app SLO alerts.
- [ ] For production load tests use a dedicated tool with rate limits and an agreed window.
