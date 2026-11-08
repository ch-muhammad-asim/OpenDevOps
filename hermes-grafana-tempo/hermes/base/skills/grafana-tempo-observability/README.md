# 🔎 grafana-tempo-observability skill

Read-only observability skill for Hermes. [`SKILL.md`](SKILL.md) tells the agent when and how to use it;
[`scripts/obs.py`](scripts/README.md) does the queries (Python standard library only; the image has no curl or jq).
Mounted at `/opt/skills/observability/grafana-tempo-observability/`. Usage, security and tests:
[`../../../README.md`](../../../README.md#-observability-skill-read-only).

| File | What it does (one line) |
|---|---|
| [`SKILL.md`](SKILL.md) | Skill instructions: command table, how to answer efficiently, the services, how the telemetry works, useful queries |
| [`scripts/obs.py`](scripts/obs.py) | `diagnose`, `hermes`, `alerts`, `red`, `graph`, `slowest`, `errors`, `issue`, `trace`, `traceql`, `prom`, `dashboards`, `panels`, `gquery`, `link` |
