# 🐍 obs.py

Read-only client for Prometheus (`prometheus-kube-prometheus-prometheus.monitoring:9090`), Tempo
(`tempo.observability:3200`) and Grafana (`grafana.observability`, Viewer token from env `GRAFANA_TOKEN`). HTTP GET
only, except Grafana's `/api/ds/query` (a datasource query). Output is compact JSON with bounded time ranges and
result limits; `trace` returns at most 60 spans. Run `python3 obs.py --help` for all commands.

| Command | What it returns (one line) |
|---|---|
| `diagnose [--window 15m] [--since 60m] [--summary]` | Ranked issues: alerts, failing rules, Hermes health, planted-issue TraceQL matches, RED anomalies, failing service-graph edges |
| `slowest <app>` / `errors <app>` | Slowest server spans / error traces with Explore links |
| `issue <app>` | Each planted issue of nextjs, nodejs or python: matches, example trace, root cause, file, fix |
| `red <app>` / `graph` | Span-metrics rate, error ratio, p95/p99 vs 6 h baseline / service-graph edges |
| `trace <id>` | Compact span tree with errors and exception events |
| `prom`, `traceql`, `tags` | Raw PromQL / TraceQL / tag lookups |
| `dashboards`, `panels <uid>`, `gquery`, `link` | Grafana dashboards, panels, queries through Grafana, Explore deep links |
