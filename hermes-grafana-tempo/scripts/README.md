# 🛠️ Scripts

Operational scripts for hermes-grafana-tempo. Run them from the repository folder `hermes-grafana-tempo/`.

| Script | What it does (one line) | Usage |
|---|---|---|
| [deploy.sh](deploy.sh) | Installs the platform in order (Prometheus, edge, Tempo, Collector, Grafana, dashboards, routes, DNS); idempotent | `PROFILE=lab scripts/deploy.sh [step ...]` |
| [verify.sh](verify.sh) | End-to-end PASS/FAIL checks: releases, pods, health, Grafana datasources, project alert rules loaded, test trace through Collector to Tempo and Grafana, scraping, NetworkPolicy, public HTTPS | `PROFILE=lab scripts/verify.sh [--read-only]` |
| [teardown.sh](teardown.sh) | Uninstalls releases and the project namespaces (incl. `hermes`) and CRDs; safe to re-run; `--cluster` also deletes the bucket and cluster (asks first) | `scripts/teardown.sh [--cluster]` |
| [update-dns.sh](update-dns.sh) | Creates or updates one proxied Cloudflare A record (used by the `dns` step) | `CF_TOKEN_FILE=... scripts/update-dns.sh <host> <ipv4>` |
| [load.sh](load.sh) | Sends traffic that triggers every planted issue in the three sample apps, then prints a status-code summary | `scripts/load.sh [public\|local] [rounds]` |

## 🚀 deploy.sh / verify.sh

| Env | Default | Meaning |
|---|---|---|
| `PROFILE` | `prod` | `prod`: each chart's `values.yaml`, Tempo = tempo-distributed. `lab`: adds `values-lab.yaml` overlays, Tempo = single binary |
| `TLS_MODE` | `cloudflare` | `cloudflare`: HTTPS ends at the Cloudflare proxy, Traefik serves its default certificate (zone SSL mode **Full**). `letsencrypt`: cert-manager DNS-01 certificates patched into the routes (**Full (strict)**) |
| `TEMPO_STORAGE` | prod `gcs`, lab `local` | `gcs`: bucket via [../infra/create-tempo-bucket.sh](../infra/create-tempo-bucket.sh) (Workload Identity scoped to the bucket); `local`: PVC |
| `KAFKA_BOOTSTRAP` | — | Required for `PROFILE=prod`: Kafka-compatible queue for Tempo 3.x distributed mode |
| `CF_TOKEN_FILE` | — (required by `dns`, and by `certmanager` with `letsencrypt`) | Path to a Cloudflare API token file with Zone:DNS:Edit + Zone:Zone:Read (chmod 600); read into a private header file, never printed |

Steps (run any subset in this order): `namespaces prometheus certmanager traefik tempo collector grafana dashboards edge dns`.
`verify.sh` exits with the number of failed checks. Default mode starts two short-lived curl pods (`otlp-probe` in
`tempo-apps`, `netpol-probe` in `default`, both Pod Security `restricted`, deleted on exit) and writes one test span
(`service.name=verify-probe`); `--read-only` skips those two checks. It reads `TLS_MODE` like `deploy.sh`
(cert-manager checks only with `letsencrypt`). Lab result 2026-11-08: 29 PASS, 0 failures on two consecutive runs (`PROFILE=lab`, `TLS_MODE=cloudflare`, cert-manager not installed).

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
- [ ] Provide `KAFKA_BOOTSTRAP` (managed Kafka-compatible service, TLS + SASL) and run the bucket script with `ACCESS_MODE=principal`.
- [ ] Prefer `TLS_MODE=letsencrypt` (or a Cloudflare Origin CA certificate) with Cloudflare **Full (strict)** so the origin certificate is validated.
- [ ] Run `verify.sh` after every deploy and alert on failures; keep `teardown.sh` out of production pipelines.

## 🏭 Production checklist (load.sh)

- [ ] Run `load.sh` only against lab or staging: it deliberately triggers errors, timeouts and a memory leak, and fires the app SLO alerts.
- [ ] For production load tests use a dedicated tool with rate limits and an agreed window.
