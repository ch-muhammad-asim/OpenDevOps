# 🚨 App alerts and SLOs (PrometheusRule)

Alerting rules for the three sample apps, built from Tempo span metrics (`traces_spanmetrics_*`, written to
Prometheus by Tempo's metrics-generator) and from kube-state-metrics / cAdvisor. **Why:** traces show *what* broke;
these rules tell you *when* to look, and every alert links back to a TraceQL query.

**Status:** rules pass `promtool check rules` (Prometheus v3.16.0, 12 rules). The span-metrics expressions were
evaluated on the [local stack](../local/) on 2026-11-08. After `scripts/load.sh` the planted bugs push the server
error ratio to 11-35%, so `TempoAppsErrorBudgetFastBurn` **fires by design** in the demo.

## 🧩 Components

| File | What it does (one line) |
|---|---|
| [prometheusrule.yaml](prometheusrule.yaml) | 5 recording rules (error ratio 5m/30m/1h/6h, p95 per route) + 7 alerts, namespace `tempo-apps` |
| [kustomization.yaml](kustomization.yaml) | Included by both profiles ([production](../kustomization.yaml), [lab](../lab/kustomization.yaml)) |

Requires the kube-prometheus-stack CRDs and `prometheusSpec.ruleSelectorNilUsesHelmValues: false`
([values](../../helm/kube-prometheus-stack/values.yaml)), so rules in any namespace are loaded.

## 🎯 SLO

| SLI | Target | Window | Source |
|---|---|---|---|
| Availability: share of SERVER spans without error status, per service | 99% | 30 days | `traces_spanmetrics_calls_total{span_kind="SPAN_KIND_SERVER"}` |
| Latency: p95 of SERVER spans per route | < 1 s | 5 min | `traces_spanmetrics_latency_bucket` |

Burn-rate alerts follow the multi-window method (fast: 14.4x over 1h and 5m; slow: 6x over 6h and 30m).

## 🔔 Alerts and runbooks

| Alert | Severity | Fires when |
|---|---|---|
| [TempoAppsErrorBudgetFastBurn / SlowBurn](#errorbudgetburn) | critical / warning | Error ratio burns the 1% budget 14.4x / 6x too fast |
| [TempoAppsHighLatencyP95](#highlatencyp95) | warning | A route's p95 > 1 s for 10 min |
| [TempoAppsNoSpans](#nospans) | warning | No span metrics from an app for 15 min |
| [TempoAppsPodRestarting](#podrestarting) | warning | > 2 restarts in 30 min |
| [TempoAppsMemoryNearLimit](#memorynearlimit) | warning | Working set > 85% of the memory limit for 10 min |
| [TempoAppsReplicasUnavailable](#replicasunavailable) | warning | Available < desired replicas for 10 min |

### ErrorBudgetBurn

1. In Grafana → Explore → Tempo: `{ resource.service.name = "<service>" && status = error }`. Open the newest trace.
2. Find the first red span; if it is a CLIENT span, the cause is downstream (follow the child service).
3. Check `event:name = "exception"` on the span for the type and stack trace.
4. Recent deploy? `kubectl -n tempo-apps rollout undo deployment/<app>`.

### HighLatencyP95

1. TraceQL: `{ resource.service.name = "<service>" && name = "<span_name>" && span:duration > 1s }`.
2. Long span with no children = CPU-bound work in the app; many sequential children = N+1; a long CLIENT span = slow dependency.
3. Check CPU throttling: `rate(container_cpu_cfs_throttled_periods_total{namespace="tempo-apps"}[5m])`.

### NoSpans

1. `kubectl -n tempo-apps get pods` - is the app running?
2. `kubectl -n observability logs deploy/otel-collector | tail` - export errors?
3. Tempo metrics-generator running? `{__name__=~"traces_spanmetrics.*"}` in Prometheus.

### PodRestarting

1. `kubectl -n tempo-apps describe pod <pod>` → `Last State`: `OOMKilled` = memory, `Error` + probe events = liveness.
2. OOMKilled: see [MemoryNearLimit](#memorynearlimit). Liveness: a blocked event loop (CPU hog) longer than the probe budget.

### MemoryNearLimit

1. Steady climb that never drops = leak. TraceQL for the nodejs leak: `{ resource.service.name = "nodejs-orders" && span.app.cache.bytes > 0 } | max_over_time(span.app.cache.bytes)`.
2. Short-term: `kubectl -n tempo-apps rollout restart deployment/<app>`; long-term: fix the code or raise the limit.

### ReplicasUnavailable

1. `kubectl -n tempo-apps get pods -o wide` - `Pending` = capacity or the hostname topology spread (needs as many nodes as replicas).
2. Not ready = probe failing; `kubectl -n tempo-apps describe pod <pod>`.

## 🏭 Production checklist

- [ ] Route `severity=critical` to paging and `warning` to a ticket/chat channel in Alertmanager (platform values).
- [ ] Tune the SLO targets per service; remove the planted-bug services' expected alerts from paging.
- [ ] Add a Grafana SLO dashboard from the recording rules (`service:spanmetrics_server_error_ratio:*`).
- [ ] Keep `runbook_url` pointing at a maintained copy of this page.

## 📚 References

- [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/) ·
  [recording rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/)
- [Prometheus Operator: PrometheusRule](https://prometheus-operator.dev/docs/developer/alerting/)
- [Tempo span metrics](https://grafana.com/docs/tempo/latest/metrics-from-traces/span-metrics/)
- [Google SRE workbook: alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
