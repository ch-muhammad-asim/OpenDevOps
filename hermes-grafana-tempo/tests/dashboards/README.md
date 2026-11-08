# 📊 Stress tests dashboard

[`stress-tests.yaml`](stress-tests.yaml) is a ConfigMap that the Grafana sidecar loads into the **Tests** folder as
**Stress tests**. Apply it with `kubectl apply -f tests/dashboards/stress-tests.yaml`.

| Row | Panels |
|---|---|
| k6 load | requests per second, p95 latency, error rate (non-2xx), virtual users per `testid`; app server p95 from Tempo span metrics |
| Pods in tempo-apps | CPU used vs limit, CPU throttling, working-set memory vs limit, restarts, OOMKilled, service-graph failed calls |
| Traces | Tempo tables for `stress.*` spans and error traces; dashboard links open Tempo Explore with TraceQL |

The `k6 test` variable filters by the `testid` tag that `tests/run.sh` sets on every run (`<app>-<scenario>-<HHMMSS>`).
