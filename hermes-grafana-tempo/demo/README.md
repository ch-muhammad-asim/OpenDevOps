# 🎬 Demo: ask Hermes what is going on

A short, copy-paste demo for a YouTube walkthrough: an AI agent answers production questions about this cluster in
plain English, with real numbers, trace IDs and Grafana links.

## 🎬 What this demo shows

Three small apps (Next.js → Node.js → Python) carry real, deliberate bugs. They send OpenTelemetry traces and span
metrics through the OpenTelemetry Collector into Grafana Tempo and Prometheus/Thanos. Hermes Agent runs in the same
cluster, and its read-only observability skill can query Tempo (TraceQL), the metrics API (PromQL) and Grafana.

You then ask Hermes a normal question — *"which service is failing?"*, *"why is this route slow?"* — and it runs the
queries itself, ranks what it finds, and points at the file to change.

Why it matters: in production Hermes is connected to Slack, so an engineer types the question in a channel and gets
the diagnosis there, without opening four dashboards first.

## 🧭 Architecture in short

- **Sources:** the three sample apps and the Hermes gateway itself, over OTLP/HTTP.
- **Pipeline:** OpenTelemetry Collector → Tempo (traces) and → Prometheus/Thanos (metrics, service graph, alerts).
- **Answers:** Grafana for humans, Hermes for questions; Hermes reads only Tempo `:3200`, the Thanos querier
  `:10902` and Grafana `:3000` with a Viewer token (no writes, no Prometheus `:9090`).

No diagram on this page: the full set lives in [`../docs/diagrams/`](../docs/diagrams/) (start with the
[learning map](../docs/diagrams/learning-map.md)); the component and telemetry-flow diagrams are in the
[top-level README](../README.md).

## ✅ Before you start

- [ ] The GKE cluster is up: `kubectl get nodes` shows 3 `Ready`.
- [ ] Every hostname answers: `https://grafana-tempo.<domain>` → `200`/`302`,
      `https://hermes-gke.<domain>` → `302` to the Hermes login, the three `tempo-*` app hosts → `200`.
- [ ] The platform checks pass (0 failures):
      `PROFILE=lab DOMAIN=<domain> scripts/verify.sh`
- [ ] The Hermes checks pass (0 failures): `DOMAIN=<domain> hermes/verify.sh`
- [ ] There is fresh traffic — run `DOMAIN=<domain> scripts/load.sh public`, wait about 30 s for ingest, then open
      Grafana → Explore → Tempo to confirm traces exist.

`<domain>` is the domain you deployed with (`example.com` in the manifests). Everything below runs from
`hermes-grafana-tempo/`.

## 🔐 How to log in to Hermes

The login is generated at deploy time and lives only in a Kubernetes Secret. Read the username and password into your
terminal — never paste the values into a recording, a slide or a commit:

```bash
kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.password}' | base64 -d; echo
```

Open `https://hermes-gke.<domain>`, log in with provider **Username & Password**, then open **Chat**. Type (or paste)
one prompt at a time and wait for the answer.

## 💬 Copy-paste prompts

Each block is one prompt. Paste one, wait for the answer, then paste the next: the free model tier rate-limits, and
each turn can run several tool calls. The questions are grouped; on camera the health → diagnose → one drill-down
path is enough.

### 🩺 Health

"You have 30 seconds before the incident call — is the agent itself healthy, and what is already paging?"

```text
Is the Hermes gateway healthy, and which alerts are firing right now?
```

- **What Hermes should do:** run the observability skill twice — `obs.py hermes` for gateway health, then
  `obs.py alerts` for firing and pending alerts — and summarise.
- **What to look for:** `gateway_up=1`, state `running`, platform `api_server` up, then a list of alert names with
  their severity. Blur or hide the Grafana/Alertmanager URLs if you record it.

### 🔥 Incidents

"This is the question an on-call engineer actually asks at 02:00."

```text
Diagnose the platform and suggest the top issues, with Grafana links.
```

- **What Hermes should do:** run `obs.py diagnose` once: firing alerts, failing rules, Hermes health, every planted
  issue with a matching trace, RED anomalies against a baseline and failing service-graph edges; then rank by user
  impact.
- **What to look for:** a short ranked list, each item with a number (p95, error ratio), a **trace ID**, the file to
  look at, a suggested fix and a Grafana link.

```text
Which service has the highest error rate in the last 15 minutes, and why?
```

- **What Hermes should do:** query the span metrics (`traces_spanmetrics_calls_total` by `service` and by
  `span_name`), pick the worst service, then explain the failing route from a trace.
- **What to look for:** one service named with an error ratio in percent, the route that drives it, the exception and
  the file to change.

```text
Show me the errors in nodejs-orders in the last 15 minutes with example trace IDs.
```

- **What Hermes should do:** `obs.py errors nodejs --since 15m`, group the errors by route and quote example trace
  IDs.
- **What to look for:** several trace IDs you can paste into Grafana → Explore → Tempo, grouped by cause instead of
  one flat list.

### 🐢 Latency

"Slow is harder than broken. This is where the traces earn their keep."

```text
Find the slowest traces for the nextjs app in the last 30 minutes and explain the root cause.
```

- **What Hermes should do:** `obs.py slowest nextjs --since 30m --limit 5`, then `obs.py trace <id>` on the slowest
  one and read the span tree.
- **What to look for:** a table of trace IDs with durations, then the span where the time actually goes — usually one
  hop below the app the question named — with a Grafana link.

```text
Show me the request path from nextjs-web to python-inventory and where time is spent.
```

- **What Hermes should do:** combine the service graph with `obs.py trace <id>` on a slow cross-service request and
  print the span tree with each hop's duration.
- **What to look for:** the full chain Next.js → Node.js → Python with milliseconds per hop, the failing hop and the
  timeout that cuts it short.

```text
Which endpoint is slowest in python-inventory, and which file should I change to fix it?
```

- **What Hermes should do:** `obs.py slowest python --since 30m`, then `obs.py issue python` for the known pattern.
- **What to look for:** one endpoint, about 3 s per request, the span inside it (for example a synchronous supplier
  sync) and the file to change.

### 🕸️ Service graph

"One picture, built from spans: who calls whom, and where the failures start."

```text
What does the service graph look like, and which edge is failing?
```

- **What Hermes should do:** `obs.py graph`, i.e. `traces_service_graph_request_total` and
  `..._failed_total` by client and server.
- **What to look for:** the request chain and one named edge with failed-per-second and a percentage, plus the
  judgement that the deepest failing hop is the origin, not a symptom.

### 📈 Trends

"Yesterday's p95, this hour's memory: the questions that need 30 days of metrics."

```text
Is anything throttled or running out of memory? Check CPU and memory trends.
```

- **What Hermes should do:** `obs.py trends`, then PromQL for CPU throttling, container memory against limits,
  restarts and OOM kills.
- **What to look for:** a plain answer — throttling total or not — and a memory curve with numbers, the limit, and an
  estimate of how long until it is reached.

```text
Compare today's latency with yesterday for each service.
```

- **What Hermes should do:** `obs.py trends --range 1d` and report which comparison it could actually make.
- **What to look for:** per-service p95 numbers, and an honest note when the history is too short for day-over-day
  (a fresh lab has hours, not days) with the closest window instead.

### 🛠️ Fixes

"End the demo on the code, not on the dashboard."

```text
Summarise the planted issues you can find and how to fix each one.
```

- **What Hermes should do:** `obs.py diagnose` plus `obs.py issue <app>` per app, then group the findings by service.
- **What to look for:** one short section per app, each bug with evidence, root cause, file and fix, and a suggested
  order of work.

## 💼 Slack in production

Nothing above is Grafana-specific: Hermes is the same agent, and Slack is one of its gateway platforms. Connect the
gateway to a Slack workspace, invite the bot to a channel, and engineers ask in the channel exactly the prompts
above — "is anything throttled?", "diagnose the platform" — and get the same answers with trace links inline.
Alerts can be routed into the same channel, so the question and the evidence live in one thread.

- Hermes documentation (platforms, gateway, skills): <https://hermes-agent.nousresearch.com/docs>
- The skill used here: [`hermes/base/skills/grafana-tempo-observability/`](../hermes/base/skills/grafana-tempo-observability/README.md)
- Nothing to add for the demo: no Slack token, no extra secret, nothing in this repo changes.

## 🧪 Tested results

Run on 2026-11-11 against a freshly loaded lab, one prompt at a time through the in-pod OpenAI-compatible API server
(same method as [`../hermes/chat-proof.sh`](../hermes/chat-proof.sh)), model `opencode/deepseek-v4.1-flash-free`.
"Used skill" means the answer shows the skill's `obs.py` command in its tool trace; "real data" means numbers, trace
IDs or Grafana links taken from the live cluster, not invented.

| # | Prompt | Answered | Used skill | Real data | Time |
|---|---|---|---|---|---|
| 1 | Hermes gateway health + firing alerts | ✅ | ✅ `hermes`, `alerts` | ✅ alert names, `gateway_up=1`, severity | 26 s |
| 2 | Diagnose the platform, top issues + links | ✅ | ✅ `diagnose` | ✅ p95/error ratios, 7 trace IDs, Grafana links | 37 s |
| 3 | Highest error rate in the last 15 minutes | ✅ | ✅ `diagnose`, PromQL | ✅ 34.6% / 19.3% / 18.1%, routes, trace ID | 27 s |
| 4 | Slowest nextjs traces + root cause | ✅ | ✅ `slowest`, `trace`, `issue` | ✅ 5 trace IDs with ms, span tree | 27 s |
| 5 | Request path nextjs-web → python-inventory | ✅ | ✅ `trace`, `graph`, `issue` | ✅ per-hop ms, service-graph rate | 42 s |
| 6 | Throttling and memory trends | ✅ | ✅ `trends`, `diagnose`, PromQL | ✅ throttled ratios, MB vs limit, growth rate | 45 s |
| 7 | Today's latency vs yesterday | ⚠️ | ✅ `trends --range 1d`, `prom`, `traceql` | ⚠️ real p95 numbers, but only ~1.5 h of history: no yesterday data to compare, and it says so | 35 s |
| 8 | Service graph and the failing edge | ✅ | ✅ `graph` | ✅ req/s and failed/s per edge, percentages | 20 s |
| 9 | Planted issues and how to fix each | ✅ | ✅ `diagnose`, `issue` | ✅ 14 bugs across 3 apps, trace IDs, files | 40 s |
| 10 | Slowest python endpoint + file to change | ✅ | ✅ `slowest`, `issue` | ✅ ~3.0 s endpoint, span name, file | 34 s |
| 11 | nodejs-orders errors with trace IDs | ✅ | ✅ `errors`, `issue` | ✅ 3 error groups, 9 trace IDs | 52 s |

Honest notes:

- **11 of 11 answered**, all with live data, none rate-limited on this run. A free tier can still answer 429 or
  "Free usage limit reached" at any time; that is expected, not a bug in the demo.
- **#7 is the only partial one:** the lab had about 1.5 hours of metrics history, so day-over-day was impossible.
  Hermes said that and compared the last 45 minutes with the 45 before, which is the honest answer. On a cluster with
  24 h+ of data the same prompt is a real comparison.
- **#8 is short** on purpose: one question, one edge. It is the fastest prompt in the set and a good 20-second clip.
- Times are one run on a shared free tier, not a benchmark; expect 20–60 s per answer because each turn runs one to
  several tool calls.

## 🛟 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Free usage limit reached`, or HTTP 429 in the answer | The free model tier is shared and rate-limited | Wait for the limit to reset, or pick another free model in the Hermes model picker. Do not switch the demo to a paid model |
| "No traces" / empty answers for the apps | No traffic yet, or ingest has not flushed | `DOMAIN=<domain> scripts/load.sh public`, wait ~30 s, ask again |
| Hermes seems down (login or chat fails) | Gateway, dashboard or bridge not ready | `DOMAIN=<domain> hermes/verify.sh`, then `kubectl -n hermes get pods` |
| Skill answers "endpoint not reachable" | The Thanos querier or Tempo is down, or a NetworkPolicy changed | `kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-query`, and see [`../hermes/README.md`](../hermes/README.md#-operations-and-troubleshooting) |
| Skill calls return 401 from Grafana | Grafana restarted without a database, so the Viewer token is gone | Re-run `hermes/deploy.sh`, which re-creates the account and token |
| Answers are slow but correct | Several tool calls per turn on a free model | Normal; ask one question at a time |

More: [`../README.md`](../README.md#-operations-and-troubleshooting) and
[`../hermes/README.md`](../hermes/README.md#-operations-and-troubleshooting).
