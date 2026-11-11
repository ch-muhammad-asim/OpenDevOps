# 🤖 Hermes Agent → OpenTelemetry → Tempo + Prometheus + Grafana

[Hermes Agent](https://hermes-agent.nousresearch.com/docs/) v0.23.0 runs as a gateway plus its web dashboard in
namespace `hermes`; the dashboard (with its chat) is published at `https://hermes-gke.example.com` behind
Hermes's own login. Its model is free: OpenCode's free models through the in-cluster OpenCode bridge (default) or the
Cloudflare Workers AI free allocation (see [Model provider](#-model-provider)).
The gateway's **built-in gateway monitoring exporter** sends service-health metrics, spans and diagnostic logs over OTLP/HTTP
to the OpenTelemetry Collector. The Collector forwards spans to Tempo and metrics to Prometheus. A Grafana dashboard
shows the gateway's health with a link to its traces, and Prometheus alerts fire when the gateway goes down.
**Why:** watch an AI agent's gateway with the same open tooling as every other service, without exporting any
conversation content.

Part of [hermes-grafana-tempo](../README.md). Copy-paste demo prompts for the chat and the
[tested answers](../demo/README.md) are in [`../demo/`](../demo/README.md).

## 🔭 What Hermes exports (and what it doesn't)

Hermes has three telemetry paths. This setup uses **path 1 only**.

| Path | What | Content | Used here |
|---|---|---|---|
| 1. Gateway monitoring export ([docs](https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-monitoring)) | Health metrics, health/lifecycle spans, warning/error logs; built into Hermes | **None**: no prompts, messages, tool arguments or tool output | ✅ on |
| 2. NeMo Relay `gen_ai` spans ([docs](https://hermes-agent.nousresearch.com/docs/developer-guide/relay-shared-metrics)) | One span per model call | **Includes prompt and response text** | ❌ off (optional, see [below](#-optional-per-model-call-spans-path-2-off)) |
| 3. Community plugins (Hermes plugin catalog) | Session → LLM call → tool call span trees | Full content by default | ❌ not used (third-party code) |

Path 1 signals, as seen at the Collector:

| Signal | Name | Detail |
|---|---|---|
| Metrics (gauges, every 15 s) | `hermes.gateway.up`, `.state`, `.active_agents`, `.busy`, `.drainable`, `.restart_requested`, `.background_work`, `.background_delegations` | In Prometheus: `hermes_gateway_up` etc. |
| | `hermes.platform.up`, `hermes.platform.degraded` | Label `hermes_platform` (here: `api_server`) |
| | `hermes.cron.jobs.{enabled,running,overdue}`, `hermes.cron.scheduler.*`, `hermes.cron.store.*` | Cron scheduler health |
| Spans | `hermes.gateway_health` | Attribute `hermes.name` = `gateway.lifecycle` (start/stop) or `gateway.health_snapshot` (periodic) |
| | `hermes.gateway_diagnostic`, `hermes.cron_execution` | Diagnostics and cron runs |
| Logs | `gateway diagnostic` | e.g. `platform.state_change`, `gateway.log.warning` |
| Resource | `service.name=hermes-gateway`, `service.namespace=hermes`, `service.version=0.23.0`, `service.instance.id` | Instance id is a hash of `monitoring.install_id` |

The exporter needs the OpenTelemetry SDK. The official image already contains it (`opentelemetry-sdk` and
`opentelemetry-exporter-otlp-proto-http` 1.45.1), so the official image is deployed unchanged.

## 🏗️ Architecture

The project [architecture diagram](../docs/diagrams/architecture.mmd) and the [telemetry flow](../docs/diagrams/telemetry-flow.mmd) show the Hermes pod and its telemetry path; they render in the [top-level README](../README.md). The table below lists the parts.

| # | Component | What it does (one line) |
|---|---|---|
| 1 | `hermes-gateway` Deployment | Official Hermes Agent v0.23.0 image running `hermes gateway run`, non-root |
| 2 | API server platform | The gateway's one platform (OpenAI-compatible `/v1/chat/completions`), on `127.0.0.1:8642` inside the pod only |
| 2a | `dashboard` container | Hermes web dashboard on `:9119`, same `HERMES_HOME`, Hermes password login |
| 2b | Traefik `IngressRoute` | `hermes-gke.example.com` → Cloudflare-only allow list → dashboard (Hermes login) |
| 2c | Cloudflare | Proxied DNS record; serves the public HTTPS certificate (no Let's Encrypt for this host) |
| 2d | Model provider | OpenCode bridge (default: `opencode-bridge` Deployment + Service, OpenCode free models, OpenCode runs the tools in the bridge pod) or Cloudflare Workers AI free over HTTPS `:443`; model id, URL and key from Secret `hermes-model-key` |
| 2e | Observability skill | `grafana-tempo-observability`: read-only Prometheus, Tempo and Grafana (Viewer) queries, `diagnose` with ranked issues and links |
| 3 | `hermes-config` ConfigMap | `config.yaml` with `monitoring.*`, model and guardrails, copied into `HERMES_HOME` at start |
| 4 | OpenTelemetry Collector | Receives OTLP/HTTP on `otel-collector.observability:4318` |
| 5 | Tempo | Stores the `hermes.gateway_health` spans; TraceQL search |
| 6 | Prometheus | Stores `hermes_*` metrics; evaluates the `hermes-gateway` alert rules |
| 7 | Grafana | Dashboard "Hermes Agent gateway" (folder Hermes) with a Tempo trace table and link |

## 🧩 Files

Two profiles: **production** ([`base/`](base/README.md), the default) and **lab** ([`lab/`](lab/README.md), a
Kustomize overlay without the persistent disk and with smaller requests).

| File | What it does | Security role |
|---|---|---|
| [`base/config.yaml`](base/config.yaml) | Hermes config: OTLP export on, model via `${env:HERMES_MODEL...}` (custom provider), skill dir, guardrails (manual approvals, secret redaction, no private URLs, bounded runs), Nous usage metrics off, dashboard trusted proxies | No secrets; no content export |
| [`base/deployment.yaml`](base/deployment.yaml) | ServiceAccount + singleton Deployment: init container copies the config, `gateway` and `dashboard` containers, probes, zone spread | Non-root uid 10000, all capabilities dropped, read-only root FS, no SA token; public URL set only on `dashboard` |
| [`base/service.yaml`](base/service.yaml) | ClusterIP Service `hermes-dashboard:9119` | In-cluster only; reachable from Traefik only |
| [`base/ingress.yaml`](base/ingress.yaml) | IngressRoute + Middlewares `cloudflare-only`, `security-headers` | Only Cloudflare's edge may connect; HSTS, no framing; no proxy login |
| [`base/pvc.yaml`](base/pvc.yaml) | 10Gi PVC for `HERMES_HOME` | Sessions and memory survive restarts |
| [`base/pdb.yaml`](base/pdb.yaml) | PodDisruptionBudget (`maxUnavailable: 1`) | Never blocks node drains or GKE upgrades |
| [`base/namespace.yaml`](base/namespace.yaml) | Namespace `hermes` | Pod Security `restricted` enforced |
| [`base/networkpolicy.yaml`](base/networkpolicy.yaml) | Default deny; egress to DNS (kube-dns and NodeLocal DNSCache), Collector `:4318`, Thanos querier `:10902`, Tempo `:3200`, Grafana `:3000` (not Prometheus `:9090`) and public HTTPS `:443` (model API); ingress only from namespace `traefik` to `:9119` | No private, link-local/metadata or Service-range HTTPS egress; API server port never reachable |
| [`base/networkpolicy-observability.yaml`](base/networkpolicy-observability.yaml) | Ingress in `monitoring` / `observability`: only the Hermes pod to the Thanos querier `:10902`, Tempo `:3200`, Grafana `:3000` | Additive to the platform's default deny; opens nothing else |
| [`base/opencode-bridge.yaml`](base/opencode-bridge.yaml) | OpenCode bridge: ServiceAccount (no token), OpenCode policy ConfigMap, Deployment (pinned CLI installed by a non-root init container), Service `opencode-bridge:18282`; script reused from `../../opencode/kubernetes/bridge/` | Restricted PSS, file edits denied, only Hermes may call it |
| [`base/prometheusrule.yaml`](base/prometheusrule.yaml) | 5 alerts with `runbook_url` ([Runbooks](#-runbooks)) | Detects a down gateway or lost telemetry |
| [`base/hermes-gateway-dashboard.json`](base/hermes-gateway-dashboard.json) | Grafana dashboard (uid `hermes-gateway`) | Read-only view |
| [`base/skills/`](base/skills/README.md) | Read-only observability skill (`SKILL.md` + `scripts/obs.py`), shipped as ConfigMap `hermes-skill-observability` | Queries only; Grafana Viewer token |
| [`base/kustomization.yaml`](base/kustomization.yaml) | Builds the production profile; dashboard ConfigMap labelled `grafana_dashboard` | |
| [`lab/kustomization.yaml`](lab/kustomization.yaml) | Lab overlay: `emptyDir` instead of the PVC, 50m / 256Mi requests | |
| [`backup-snapshot.yaml`](backup-snapshot.yaml) | Optional: VolumeSnapshotClass + one snapshot of `hermes-home` (not applied by default) | Backup |
| [`deploy.sh`](deploy.sh) | Creates the namespace and Secrets (API key, dashboard login, model settings from a local file via `MODEL_PROVIDER`, Grafana Viewer token), applies a profile, waits for rollout | Random values; credentials read from files; never printed |
| [`verify.sh`](verify.sh) | End-to-end checks (pod, Prometheus, rules, Tempo, Grafana, public URL, Hermes login, model key; `VERIFY_CHAT=1` adds one model call) via `kubectl port-forward` | Credentials via files only |
| [`model-eval.sh`](model-eval.sh) | Deploys candidate models one by one and scores 5 tool-calling prompts through the API server | Model calls run sequentially; credentials from a file |
| [`chat-proof.sh`](chat-proof.sh) | Asks the two demo prompts (skills list, diagnose) through the API server, saves and checks the answers | Exactly 2 model calls; API key via a curl config file |

## 📋 Prerequisites

| Item | Requirement |
|---|---|
| Cluster + base charts | Installed from the [top-level README](../README.md): kube-prometheus-stack (PrometheusRule CRD), OTel Collector, Tempo, Grafana |
| Collector | OTLP/HTTP receiver on `:4318`, traces → Tempo, metrics → Prometheus ([`helm/otel-collector/`](../helm/otel-collector/)) |
| Traefik | `IngressRoute` CRD, entry point `websecure`, watching namespace `hermes` ([`k8s/`](../k8s/)) |
| DNS | Proxied Cloudflare A record `hermes-gke` → Traefik load balancer; zone SSL mode "Full" |
| Tools | `kubectl`, `python3`, `curl`, `base64` |
| Size (production) | Gateway 100m CPU / 384Mi (limit 1Gi), init 10m / 16Mi, 10Gi `standard-rwo` disk |
| Size (lab) | Gateway 50m CPU / 256Mi (limit 768Mi), no disk |
| Model | None for the default (OpenCode free models via the bridge); for Cloudflare Workers AI a local file with the account ID and token |

## 🚀 Run it

```bash
cd hermes-grafana-tempo
hermes/deploy.sh                      # production: namespace + Secrets + OpenCode bridge + apply -k hermes/base/ + rollout wait
# HERMES_PROFILE=lab hermes/deploy.sh # lab profile instead (hermes/lab/)
hermes/verify.sh                      # PASS/FAIL per check, no model calls; exit code = number of failures
hermes/chat-proof.sh                  # 2 real chats (skills list, diagnose); answers saved to ./chat-proof-<time>/
```

### 🧠 Model provider

Hermes talks to any OpenAI-compatible endpoint through its `custom` provider. `deploy.sh` writes the model id, base
URL and API key into Secret `hermes-model-key` (keys `HERMES_MODEL`, `HERMES_MODEL_BASE_URL`, `HERMES_MODEL_API_KEY`);
both containers load it with `envFrom`, and [`base/config.yaml`](base/config.yaml) references it as `${env:...}`, so no
account ID, URL or key is in Git. After a switch: `kubectl -n hermes rollout restart deploy/hermes-gateway`.

| Provider | Command | Default model | Cost | Credentials |
|---|---|---|---|---|
| **OpenCode free via bridge (default)** | `hermes/deploy.sh` | `opencode/deepseek-v4.1-flash-free` | Free (no key); OpenCode's free-usage limit applies | None (a random bridge key is generated) |
| Cloudflare Workers AI free (alternative) | `MODEL_PROVIDER=cloudflare CLOUDFLARE_AI_CREDS_FILE=<file> hermes/deploy.sh` | `@cf/qwen/qwen3.8-27b` | 10,000 Neurons/day free | File (outside the repo, mode 600): `Account ID: <cloudflare-account-id>` and `API: <workers-ai-api-token>` |
| OpenCode Zen / Go (paid, not used here) | `MODEL_PROVIDER=opencode OPENCODE_API_KEY_FILE=<file> hermes/deploy.sh` | `glm-5.3-flash` | Zen credits / Go subscription | OpenCode API key file |

Override Hermes's default model with `HERMES_MODEL=<id>` (for the bridge: any id from its `/v1/models`). The Hermes model picker includes the OpenCode Free provider and its configured catalog, and refreshes it from the bridge's `/v1/models`; individual OpenAI-compatible chat requests may also specify any advertised ID. Hermes's configured `HERMES_MODEL` is the initial default, not a restriction to one model. This setup is free-only:
the paid rows exist so the same scripts work if that changes.

#### OpenCode free via bridge (first choice; default)

The first-choice model is `opencode/deepseek-v4.1-flash-free` through the in-cluster OpenCode bridge. It uses the
free OpenCode model tier and requires no provider API key. `hermes/deploy.sh` configures this provider by default;
verify model availability and chat with `hermes/verify.sh` after deployment. If that model's free allowance is
unavailable, select another model from the Hermes model picker or set its ID as `HERMES_MODEL` when deploying. The configured catalog in `base/config.yaml` seeds all currently discovered free models so they remain visible before a live discovery succeeds; Hermes refreshes the list from the bridge. Listing a model confirms it is advertised, not that its upstream free quota is currently accepting requests. Requests may return provider quota errors, 429 (bridge busy), or time out while upstream inference is stalled. `./verify.sh` checks the bridge catalog and the Hermes picker catalog; optionally exercise one real alternate-model call with `VERIFY_BRIDGE_CHAT_MODEL=opencode/beam-free ./verify.sh` (this consumes shared free-tier capacity and has a 180-second timeout).

OpenCode's free models only work through the OpenCode client ([Zen docs](https://opencode.ai/docs/zen/): "Free-tier
chat models require OpenCode"). The bridge from this repository,
[`../../opencode/kubernetes/bridge/`](../../opencode/kubernetes/bridge/README.md), wraps that client in an
OpenAI-compatible endpoint; this setup **reuses it unchanged**: `deploy.sh` turns
`../../opencode/kubernetes/bridge/opencode_bridge.py` into ConfigMap `opencode-bridge-script`, and
[`base/opencode-bridge.yaml`](base/opencode-bridge.yaml) runs it as its own Deployment and Service in namespace `hermes`
(the [original deployment](../../opencode/kubernetes/README.md) runs it as a sidecar of a separate Hermes).

```text
Hermes (custom provider) --HTTP :18282, bearer key--> opencode-bridge pod: opencode_bridge.py
   --> `opencode run --format json --agent build` (one process per request, max 2) --> OpenCode free models (HTTPS)
```

How it works, and what is different from a normal model API:

Security posture of the bridge pod:

| Control | Setting |
|---|---|
| Pod Security | `restricted`: uid 10000, `drop: [ALL]`, no privilege escalation, read-only root FS, seccomp `RuntimeDefault` |
| Kubernetes API | No service-account token (`automountServiceAccountToken: false`), so OpenCode's bash cannot call the API |
| Files | OpenCode policy denies `edit`, `write`, `patch` and `external_directory` (the tools are removed from the model); writable paths are emptyDirs only |
| Install | Official OpenCode v1.19.5 Linux amd64 release installed by a non-root Python init container into an emptyDir, with the published SHA-256 verified before extraction (the npm Linux package lacks its executable) |
| Ingress | Only the Hermes gateway pod, TCP 18282, with a random bearer key (Secret `hermes-opencode-bridge`, env only, never on argv) |
| Egress | DNS; public HTTPS `:443` (OpenCode and GitHub release assets; private, link-local/metadata and Service ranges excluded); Thanos `:10902`, Tempo `:3200`, Grafana `:3000` (read-only skill). Not Prometheus `:9090` |
| Concurrency | Max 2 `opencode run` processes, queue wait 30 s (a burst gets a fast 429), 600 s timeout per request |

#### Choosing a model: `model-eval.sh`

Some models that support function calling still break inside an agent loop (leaked chat-template tokens or
repeated words after a tool result). [`model-eval.sh`](model-eval.sh) deploys each candidate in turn and asks 5
prompts that force a tool call plus a follow-up answer (skills list, skill view, diagnose, a PromQL query, a TraceQL
search) through the API server, then scores each reply *clean* (no `<|...|>` tokens, no repetition) and *correct*
(contains the real data). Calls run one at a time; the last model listed stays deployed.

```bash
CLOUDFLARE_AI_CREDS_FILE=~/keys/cloudflare-ai hermes/model-eval.sh @cf/openai/gpt-oss-20b @cf/qwen/qwen3.8-27b
```

Free providers impose quotas and can return HTTP 429. Run the model smoke check and tool-use evaluation
against your own deployment before selecting a default model.

### 💬 Chat

- Dashboard: log in, open **Chat** (`/chat`). The page runs a Hermes terminal (PTY) in the `dashboard` container that
  attaches to the gateway's control socket in the shared `HERMES_HOME` (`/opt/data/home`).
- API (inside the cluster only): `kubectl -n hermes port-forward deploy/hermes-gateway 8642:8642`, then
  `curl -H "Authorization: Bearer $(kubectl -n hermes get secret hermes-api-server -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d)" -H 'Content-Type: application/json' -d '{"model":"hermes-agent","messages":[{"role":"user","content":"hi"}]}' http://127.0.0.1:8642/v1/chat/completions`

Expected `verify.sh` output: every line `PASS`, then `failures: 0` (results in [Tests](#-tests)).
Set `HERMES_URL` to check a different public host.

Run `hermes/model-smoke.sh` from the project root to send one real inference request to **every** model in the
bridge's live free catalogue, or pass specific IDs such as `opencode/deepseek-v4.1-flash-free` and
`opencode/mimo-v2.6-flash-free`. Requests run sequentially. Each JSON result reports the model, pass/fail and latency;
the command exits nonzero if any model fails. It prints neither credentials nor response content. Catalogue and
picker checks establish availability; this smoke check establishes inference, while `model-eval.sh` evaluates tool use.

### 🔎 Observability skill (read-only)

Hermes ships with the skill [`grafana-tempo-observability`](base/skills/grafana-tempo-observability/README.md) (a
ConfigMap mounted read-only at `/opt/skills/...`, loaded through `skills.external_dirs`). Ask it in chat, e.g.
"diagnose the platform and suggest issues", "is the hermes gateway up and which alerts are firing?", "find the
slowest traces for the python app in the last 15 minutes". The agent runs `obs.py` (Python standard library) in its
terminal:

| Command | Answers |
|---|---|
| `diagnose` | Ranked issues: firing alerts, failing alert rules, Hermes health, every planted issue of the three apps (TraceQL match + example trace), RED anomalies vs a 6 h baseline, failing service-graph edges; each with evidence, probable root cause, file to look at, suggested fix and a Grafana Explore link |
| `trends [--range 30d]` | Ranked trends over up to 30 days: error-ratio and p95 changes per service and route (week-over-week, day-over-day, or last window vs the one before when history is short), error-budget burn against the 99% SLO, Tempo TraceQL p95 trends, CPU/memory growth and restarts; each explained, with a Grafana Explore link |
| `hermes`, `alerts`, `targets` | Gateway health, firing/pending alerts, scrape health |
| `red`, `graph`, `slowest`, `errors`, `issue`, `trace` | Span-metrics RED, service graph, slowest/error traces, planted issues per app, compact span tree |
| `prom`, `traceql`, `tags`, `dashboards`, `panels`, `gquery`, `link` | Raw PromQL/TraceQL, Grafana dashboards and panels, queries through Grafana, Explore deep links |

Read-only by design: the script only reads (HTTP GET; Grafana `/api/ds/query` is a query), Grafana access uses a
**Viewer** service account (`hermes-readonly`, token in Secret `hermes-grafana-token`, created once by `deploy.sh`;
a write returns 403, checked by `verify.sh`; the token expires after 90 days, `GRAFANA_TOKEN_TTL_DAYS`, and `deploy.sh`
re-mints it, revokes older tokens and resets the account to Viewer), and the NetworkPolicies open only the Thanos
querier `:10902`, Tempo `:3200` and
Grafana `:3000` from the Hermes pod ([`base/networkpolicy.yaml`](base/networkpolicy.yaml) egress plus
[`base/networkpolicy-observability.yaml`](base/networkpolicy-observability.yaml) ingress in `monitoring` and
`observability`). Output is compact JSON with bounded time ranges and limits; `diagnose` takes about 2 s in-cluster.

Optional scheduled diagnose (off by default, no model calls; the job runs the script and logs its summary):

```bash
kubectl -n hermes exec deploy/hermes-gateway -c gateway -- sh -c 'mkdir -p "$HERMES_HOME/scripts" && cat > "$HERMES_HOME/scripts/obs_diagnose.py" <<EOF
import runpy, sys
sys.argv = ["obs.py", "diagnose", "--summary"]
runpy.run_path("/opt/skills/observability/grafana-tempo-observability/scripts/obs.py", run_name="__main__")
EOF
hermes cron create "every 15m" --name obs-diagnose --no-agent --script obs_diagnose.py --deliver local'
# see runs: hermes cron runs obs-diagnose   remove: hermes cron remove obs-diagnose
```

The job lives in `HERMES_HOME` (the PVC in production; lost on restart in the lab profile).

### 🔑 Log in

Open `https://hermes-gke.example.com`; it redirects to the Hermes login page (provider "Username & Password").
The username and password are generated by `deploy.sh` and stored only in the Kubernetes Secret
`hermes-dashboard-auth` (the pod gets only the scrypt hash). Read them with:

```bash
kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.password}' | base64 -d; echo
```

Rotate: `kubectl -n hermes delete secret hermes-dashboard-auth`, run `hermes/deploy.sh`,
then `kubectl -n hermes rollout restart deploy/hermes-gateway` (the dashboard reads its Secret at start).

### Look at it yourself

| Where | Query | Expected |
|---|---|---|
| Prometheus | `max(hermes_gateway_up)` | `1` |
| Prometheus | `max by (hermes_platform) (hermes_platform_up)` | `api_server` → `1` |
| Prometheus | `max by (hermes_gateway_state) (hermes_gateway_state) == 1` | `running` |
| Tempo (TraceQL) | `{ name = "hermes.gateway_health" && span.hermes.name = "gateway.lifecycle" }` | One trace per gateway start |
| Tempo (TraceQL) | `{ resource.service.name = "hermes-gateway" }` | Lifecycle + a health snapshot every 15 s |
| Grafana | Dashboards → Hermes → **Hermes Agent gateway** | Gateway UP, state `running`, platform `api_server` UP, trace table |

> How the metrics get to Prometheus: Prometheus scrapes the Collector's `:8889` endpoint, so each series carries
> `job="otel-collector"` and the Hermes job as `exported_job="hermes/hermes-gateway"`. Queries and alerts aggregate
> by `service_instance_id` (with `max`), so a gateway counts once even while an old pod's series are still fresh after
> a restart.

## 🚨 Alerts

| Alert | Expression | For | Severity |
|---|---|---|---|
| HermesGatewayDown | `max by (service_instance_id) (hermes_gateway_up) < 1` | 2m | critical |
| HermesTelemetryAbsent | `absent(hermes_gateway_up)` | 5m | critical |
| HermesPlatformDown | `max by (service_instance_id, hermes_platform) (hermes_platform_up) < 1` | 5m | warning |
| HermesGatewayRestartRequested | `max by (service_instance_id) (hermes_gateway_restart_requested) > 0` | 10m | warning |
| HermesCronJobsOverdue | `max by (service_instance_id) (hermes_cron_jobs_overdue) > 0` | 15m | warning |

A crashed pod stops sending metrics instead of sending `0`, so `HermesTelemetryAbsent` covers that case once the
last samples go stale (about 5 minutes).

## 🗄️ Retention and storage

What the skill's `trends` command can look back on, and where it reads from:

| Signal | Lab (live) | Production | Endpoint for `trends` (env) |
|---|---|---|---|
| Traces (Tempo) | 720 h (30 days), GCS bucket via Workload Identity | 720 h, GCS bucket via Workload Identity (`roles/storage.objectUser` + `roles/storage.bucketViewer` on the bucket only) | `http://tempo.observability:3200` (lab) / `http://tempo-query-frontend.observability:3200` (prod), `OBS_TEMPO_URL`; TraceQL metrics `/api/metrics/query_range`, step >= 1 h for 30 days |
| Metrics | Prometheus 2 days local + Thanos (free OSS: sidecar, store-gateway, querier) 30 days in a GCS bucket via Workload Identity | Thanos: 2 days local + GCS, raw / 5m / 1h resolutions kept 30 days | `http://thanos-query.monitoring:10902` (`OBS_METRICS_URL`); Prometheus `:9090` is not reachable from Hermes |

## 🛡️ Security model

Not protected: the Collector → Tempo/Prometheus hops are plain HTTP/gRPC inside the cluster; Prometheus and the
Thanos querier have no authentication (Hermes reaches only the read-only Thanos querier, see the threat table); Cloudflare → Traefik
uses Traefik's default certificate (SSL mode "Full", not "Full (strict)"); anyone with Grafana Viewer access sees
gateway health and span metadata (never content); the dashboard can edit Hermes config and keys, so treat its login
as an admin credential. Port 443 egress is open to any public address (NetworkPolicy cannot match host names), so
the agent's web tools could reach other public HTTPS hosts; for a single-host allow list use an egress proxy or an
FQDN network policy. The model settings are in both containers' environment (`envFrom` Secret `hermes-model-key`;
the dashboard's chat runs the agent in its own container, so it needs them too); Hermes's own warning logs can show
the expanded base URL (for Workers AI it contains the account ID).

### Model-provider egress

Chat needs HTTPS to the model provider: with the default OpenCode bridge only the **bridge pod** talks to `opencode.ai`
(and GitHub release assets at start), and the Hermes pod only to the bridge `:18282`; with Workers AI the Hermes pod talks
to `api.cloudflare.com`. A NetworkPolicy cannot name hosts, so [`base/networkpolicy.yaml`](base/networkpolicy.yaml)
allows TCP 443 (for both pods) to
`0.0.0.0/0` **except** 10/8, 172.16/12, 192.168/16, 100.64/10, 169.254/16 (link-local, including the metadata server
169.254.169.254) and the GKE Service range 34.118.224.0/20. Everything else stays default-deny. Without a model
Secret the gateway still runs and exports telemetry; to remove model egress entirely delete that rule. For a
single-host allow list in production use an egress proxy (e.g. CONNECT allow list) or a FQDN network policy.

### Content boundary (what leaves the pod)

| Data | Goes to | Contains conversation content? |
|---|---|---|
| Gateway health metrics, `hermes.gateway_health` spans, diagnostic logs | OTel Collector → Prometheus / Tempo | **No**: Hermes's monitoring export is content-free by construction (allowlisted `hermes.*` fields; [docs](https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-monitoring)) |
| Chat prompts, tool results, replies | The OpenCode bridge, then OpenCode's free model provider over HTTPS (default), or Workers AI | **Yes**: that is the chat itself; provider terms apply (see [Model provider](#-model-provider)) |
| Observability skill queries | Prometheus, Tempo, Grafana (in-cluster) | Only the queries; results return to the model as tool output |
| Nous usage metrics | — | Off (`telemetry.shared_metrics`) |

Proof today is configuration plus vendor documentation, checked live: after real chats through both paths, 0 matches
for the prompts, replies, model name or key in 200 Tempo traces, every `hermes_*` series and the Collector's `:8889`
output. Not enforced by the pipeline: the Collector has no attribute/redaction processor; for production add one
(e.g. `redaction` or `attributes` processor on the Hermes pipeline) as a second line of defence.

## 📈 Optional: per-model-call spans (path 2, off)

Hermes bundles NeMo Relay, which can emit OpenTelemetry `gen_ai` spans for each model call (model, tokens, latency,
errors). It is **off** here because those spans **include prompt and response text**, and it needs a model key and
real model calls. To enable it on a private cluster, follow the
[Relay shared-metrics docs](https://hermes-agent.nousresearch.com/docs/developer-guide/relay-shared-metrics):
run `hermes migrate relay`, set `[components.config.opentelemetry] enabled = true` in the generated `plugins.toml`,
set `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability:4318`, and allow egress to the model API.

## 🛠️ Operations and troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `hermes_gateway_up` missing, gateway log `Failed to export ... timeout` | DNS blocked: egress allows `kube-dns` only, but GKE NodeLocal DNSCache answers from `node-local-dns` pods | Keep both labels in the DNS rule of `networkpolicy.yaml`; check with `hermes monitoring status` in the `gateway` container |
| Gateway exits 1 right after its banner, no traceback | `dashboard.public_url` set in the shared `config.yaml`: a non-loopback public URL turns on the login gate for the gateway's own loopback listener, which has no login provider | Set the public URL only on the `dashboard` container (`HERMES_DASHBOARD_PUBLIC_URL`), as in `deployment.yaml` |
| Public URL returns 403 | Request did not come through Cloudflare (`cloudflare-only`) | Use the proxied hostname; refresh the IP list from cloudflare.com/ips |
| Collector refuses connections from `hermes` | A NetworkPolicy in `observability` denies ingress | Allow ingress from namespace `hermes` to the Collector on TCP 4318 |
| Panel says "No data" | Wrong label key or name (e.g. `job` vs `exported_job`) | Inspect real labels first: `{__name__=~"hermes_.*"}`, then add one filter at a time |
| Two gateways shown after a restart | The old pod's series stay until they go stale (about 5 minutes) | Expected; queries use `max by (service_instance_id)` |
| No traces in TraceQL | Lifecycle span is written once per start | Widen the time range, or search `{ resource.service.name = "hermes-gateway" }` (snapshots every 15 s) |
| `verify.sh`: lifecycle TraceQL → 0 traces right after a Tempo storage change | Lifecycle spans are written only at gateway start; the earlier ones are in the old storage | `kubectl -n hermes rollout restart deploy/hermes-gateway`, wait a minute, re-run `verify.sh` |
| Pod rejected by admission | Pod Security `restricted` | Keep the `securityContext` from `deployment.yaml` |
| Dashboard chat shows `queued` / `retrying in 30s (attempt N)`, `tui_gateway_crash.log` repeats `scheduling gateway reconnect` | The chat terminal cannot attach to the gateway: `HERMES_HOME` not owned by the Hermes user (`unsafe_control_path`, e.g. the volume root), or no model configured | Keep `HERMES_HOME=/opt/data/home` created by the init container; check `deploy.sh` ran with `CLOUDFLARE_AI_CREDS_FILE` |
| Chat reply says the API key was rejected (HTTP 401/403) | Wrong token, token without Workers AI permission, or wrong account ID | Fix the credentials file, re-run `deploy.sh`, restart the pod |
| Gateway log `RateLimitError` / HTTP 429 | Workers AI rate limit or daily free allocation used up | Hermes retries 3 times; wait, or use a paid plan |
| Logs show `Auxiliary Nous client unavailable` | No main model configured, so auxiliary `auto` falls back to the Nous Portal | Configure `model:` in `config.yaml` (auxiliary `auto` then uses it) |
| `kubectl get --raw .../services/...:9090/proxy` times out | Default-deny ingress in `monitoring`/`observability` blocks the API server proxy | Use `kubectl port-forward` on a free local port (as `verify.sh` does) |
| Skill's Grafana calls return 401; `verify.sh` "skill -> Grafana: HTTP 401" | Grafana restarted without a persistent database, so the `hermes-readonly` service account and its token are gone | Re-run `hermes/deploy.sh`: it detects the rejected token, re-creates the Viewer account and token, and restarts the pod |
| Skill metric queries fail, `trends` shows `endpoint_note: ... not reachable` | The Thanos querier (`thanos-query.monitoring:10902`) is down or not ready | `kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-query`; the skill deliberately has no fallback to Prometheus `:9090` |

Health: the gateway probes call `http://127.0.0.1:8642/health`, the dashboard probes `http://127.0.0.1:9119/api/status`.
`HERMES_HOME` (`/opt/data/home`, created by the init container so the Hermes user owns it) lives on the `hermes-home`
PVC (production) or an `emptyDir` (lab). The init container rewrites
`config.yaml` from the ConfigMap on every start, so the ConfigMap is the only place to change it.

## 📖 Runbooks

### HermesGatewayDown

The gateway reports `hermes_gateway_up = 0`: it is starting, draining or failed to start a component.
1. `kubectl -n hermes get pods -l app.kubernetes.io/name=hermes-gateway` and `kubectl -n hermes logs deploy/hermes-gateway --tail=200`.
2. In Grafana, check **State** (e.g. `starting`, `draining`) and the trace table for `gateway.lifecycle` /
   `gateway.startup_failed` spans.
3. If it stays down: `kubectl -n hermes rollout restart deploy/hermes-gateway`, then `hermes/verify.sh`.

### HermesTelemetryAbsent

No `hermes_gateway_up` samples at all: the pod is gone, the export fails, or the Collector or its scrape is down.
1. Pod running? (`kubectl -n hermes get pods`). If not, `kubectl -n hermes describe pod` for scheduling or PVC errors.
2. Collector up and its `:8889` target healthy? (Prometheus → Status → Targets, job `otel-collector`).
3. Gateway logs for OTLP export errors; check the NetworkPolicies on both sides (egress `hermes` → Collector `:4318`).

### HermesPlatformDown

A gateway platform (here `api_server`) is not connected. Check the gateway logs for that platform and the
`platform.state_change` diagnostic logs; restart the gateway if the platform does not reconnect.

### HermesGatewayRestartRequested

A restart was requested (e.g. after a config change) but has not happened for 10 minutes, usually because agent
runs are still active. Wait for them to finish or run `kubectl -n hermes rollout restart deploy/hermes-gateway`.

### HermesCronJobsOverdue

Cron jobs missed their schedule. Check `hermes_cron_scheduler_heartbeat_age_seconds` and
`hermes_cron_store_writable` on the dashboard; an unwritable store usually means the `hermes-home` disk is full
(`kubectl -n hermes exec deploy/hermes-gateway -- df -h /opt/data/home`).

## ✅ Production checklist

| Area | Production default | Before go-live |
|---|---|---|
| Availability | Singleton gateway (platform connections must not be duplicated); Kubernetes restarts it; PDB never blocks drains | Accept a short gap during restarts and node upgrades (alert `for:` windows cover it) |
| Sizing | 100m / 384Mi request, 1Gi limit | Re-measure with real platforms and agent runs; add CPU if agents run tools in the pod |
| Storage | 10Gi zonal PD (`standard-rwo`) | For zone failure tolerance use a regional PD StorageClass; watch disk use |
| Backups | [`backup-snapshot.yaml`](backup-snapshot.yaml) (manual snapshot) | Schedule snapshots with Backup for GKE; test a restore |
| Secrets | API key, dashboard login and model key in Secrets, created by `deploy.sh`, never in Git | Prefer syncing them from Secret Manager; use a dedicated (not shared) model key |
| Grafana token | Viewer service account `hermes-readonly`; token expires after 90 days (`GRAFANA_TOKEN_TTL_DAYS`); `deploy.sh` re-mints a rejected/expired token, revokes older tokens and resets the role to Viewer | Run `deploy.sh` from a scheduled pipeline (or before expiry) so the token never lapses; keep Grafana's database on a PVC |
| Network | Default deny; egress DNS, Collector and public HTTPS `:443` (model API) | Restrict `:443` to the model host with an egress proxy or FQDN policy |
| Metrics API auth | Prometheus `:9090` (remote-write + lifecycle API on) and the Thanos querier `:10902` are unauthenticated inside the cluster; Hermes reaches only Thanos | Put an auth proxy (e.g. kube-rbac-proxy or oauth2-proxy) or a read-only Service in front of Prometheus/Thanos, and turn off `web.enable-lifecycle` if not needed |
| Upgrades | Image pinned by digest in [`base/deployment.yaml`](base/deployment.yaml) (both containers) | Read the Hermes release notes, change the digest, apply, run `verify.sh`; roll back with the previous digest |
| SLOs | Alerts: gateway down 2m, telemetry absent 5m | Suggested SLO: `hermes_gateway_up` = 1 for 99.5% of 30 days; page on `HermesGatewayDown` |
| Cost | ≈ 0.1 vCPU + 0.4 GiB + 10Gi PD | — |
| Runbooks | [Runbooks](#-runbooks), linked from every alert's `runbook_url` | Route `severity=critical` to on-call in Alertmanager |

## 🧪 Tests

Run `hermes/verify.sh` for deployment checks, `VERIFY_CHAT=1 hermes/verify.sh` for a real gateway chat,
and `hermes/model-smoke.sh` for every model in the live free catalogue. Provider quotas can prevent inference.

## 🧹 Teardown

```bash
kubectl delete -k hermes/base/ && kubectl -n hermes delete secret hermes-api-server --ignore-not-found   # or hermes/lab/
```

In production this also deletes the `hermes-home` PVC and its data; take a snapshot first ([`backup-snapshot.yaml`](backup-snapshot.yaml)).

## 📌 Pinned versions

| Component | Version |
|---|---|
| Hermes Agent image | `nousresearch/hermes-agent:v0.23.0@sha256:adb7890916de63245523492be8f68f9d2095fecbec4e2a6dab7960381f0fc002` |
| OpenTelemetry SDK in the image | `opentelemetry-sdk` / `opentelemetry-exporter-otlp-proto-http` 1.45.1 |
| OTLP transport | HTTP/protobuf, port 4318 |
| Model (default) | OpenCode free `opencode/deepseek-v4.1-flash-free` via the bridge (`opencode-ai` CLI 1.19.5); alternative `@cf/qwen/qwen3.8-27b` on Workers AI (`custom` provider; set by `deploy.sh`) |

## 🔗 References

- [Hermes gateway monitoring](https://hermes-agent.nousresearch.com/docs/developer-guide/gateway-monitoring)
- [Hermes Relay shared metrics](https://hermes-agent.nousresearch.com/docs/developer-guide/relay-shared-metrics)
- [OTLP specification](https://opentelemetry.io/docs/specs/otlp/)
- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [TraceQL](https://grafana.com/docs/tempo/latest/traceql/)
- [Grafana dashboard provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/#dashboards)
- [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
