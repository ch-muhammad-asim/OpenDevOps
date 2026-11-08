# 🚨 Platform alert rules (PrometheusRules)

Alert rules for the parts of the stack that kube-prometheus-stack's default rules do not cover: the OpenTelemetry
Collector, Traefik, cert-manager and Grafana. **Why:** a broken telemetry pipeline or edge must page someone before the
dashboards silently go empty.

**Status (2026-11-08, Prometheus 3.16.0, operator v0.95.1):** 4 files, 15 alerts, `promtool check rules` `SUCCESS`
on each file's `spec`, `kubeconform -strict` valid; every alert has a `runbook_url`.

## 🧩 Files

| File | What it is (one line) | Alerts |
|---|---|---|
| [`otel-collector.yaml`](otel-collector.yaml) | PrometheusRule `otel-collector`: Collector up, receivers, memory limiter, exporters and queue | `OtelCollectorDown`, `OtelCollectorReceiverRefusing`, `OtelCollectorReceiverFailed`, `OtelCollectorMemoryLimiterRefusing`, `OtelCollectorExporterSendFailing`, `OtelCollectorExporterEnqueueFailed`, `OtelCollectorExporterQueueSaturated` |
| [`traefik.yaml`](traefik.yaml) | PrometheusRule `traefik`: edge up and 5xx ratio | `TraefikDown`, `TraefikHigh5xxRatio` |
| [`cert-manager.yaml`](cert-manager.yaml) | PrometheusRule `cert-manager`: controller up, certificate readiness and expiry (label `tls_mode=letsencrypt`) | `CertManagerDown`, `CertManagerCertificateNotReady`, `CertManagerCertificateExpiringSoon`, `CertManagerCertificateExpiryCritical` |
| [`grafana.yaml`](grafana.yaml) | PrometheusRule `grafana`: all replicas or one replica down | `GrafanaDown`, `GrafanaReplicaDown` |

**Collector rule pattern:** each signal (`spans`, `metric_points`, `log_records`) is aggregated on its own and tagged
with a `signal` label (`label_replace`), then the three results are joined with `or`. A single regex selector such as
`rate({__name__=~"otelcol_receiver_refused_(spans|metric_points|log_records)"}[5m])` fails at evaluation time in
Prometheus 3 ("vector cannot contain metrics with the same labelset") because `rate()` drops `__name__`. Check rule
health after any change: `/api/v1/rules` must show `health: ok` for every rule, and `PrometheusRuleFailures` must stay
inactive.

All four live in namespace `monitoring`; Prometheus selects them because `ruleSelectorNilUsesHelmValues: false`
([`../values.yaml`](../values.yaml)). Severities, routing and one runbook per alert:
[`../README.md`](../README.md#-alert-rules-and-runbooks).

cert-manager alerts only match with `TLS_MODE=letsencrypt`. The lab runs `TLS_MODE=cloudflare` (no cert-manager), so
they match nothing there and stay silent; there is deliberately no `absent()` alert.

## 🚀 Apply

`scripts/deploy.sh dashboards` applies this directory together with the Tempo mixin rules and the Grafana dashboards:

```bash
kubectl apply -f helm/kube-prometheus-stack/rules/   # only the *.yaml files; this README is ignored
```

The operator validates each PrometheusRule in its admission webhook and reloads Prometheus within about a minute.

## ✅ Check

Syntax with promtool (it reads plain rule groups, so check each file's `spec`):

```bash
for f in helm/kube-prometheus-stack/rules/*.yaml; do
  python3 -c 'import sys, yaml; yaml.safe_dump(yaml.safe_load(open(sys.argv[1]))["spec"], sys.stdout)' "$f" \
    > /tmp/rules-spec.yaml && promtool check rules /tmp/rules-spec.yaml
done
```

Expected: `SUCCESS: 7 / 2 / 4 / 2 rules found` (otel-collector, traefik, cert-manager, grafana).

Loaded on the cluster (Prometheus port-forwarded to 9090):

```bash
kubectl -n monitoring get prometheusrule otel-collector traefik cert-manager grafana
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[].name' | grep -xE 'otel-collector|traefik|cert-manager|grafana'
```

## 🏭 Production checklist

| Area | Item |
|---|---|
| Routing | `critical` pages (PagerDuty + Slack), `warning` goes to Slack: receivers in [`../values.yaml`](../values.yaml) |
| Tuning | Thresholds are starting points; adjust `for:` and ratios after a week of real traffic |
| cert-manager | With `TLS_MODE=letsencrypt`, cert-manager metrics must be scraped (ServiceMonitor + 9402 allow in `k8s/cert-manager.yaml`) or these alerts never fire |
| Changes | Run promtool (above) before every apply; the operator webhook rejects invalid rules at apply time |

## 🔗 References

- [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
- [promtool rule checks](https://prometheus.io/docs/prometheus/latest/command-line/promtool/)
- [PrometheusRule API](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1.PrometheusRule)
