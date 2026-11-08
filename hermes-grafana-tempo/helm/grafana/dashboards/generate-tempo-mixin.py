#!/usr/bin/env python3
"""Regenerate the official Tempo mixin dashboards and rules for monolithic Tempo.

Source: grafana/tempo, operations/tempo-mixin-compiled, at the tag that matches the
pinned Tempo image (TEMPO_TAG). The upstream mixin targets the microservices
deployment (job="<namespace>/<component>", one container per component). This
stack runs Tempo as one process (job="tempo", container="tempo", pod "tempo-0"),
so the script rewrites those selectors, points every Prometheus data source at uid
"prometheus" (upstream also hard-codes some UIDs), makes the cluster/namespace variables
optional (".*"), rewrites the Service Graph dashboard from the opt-in
traces_service_graph_connection_info gauge to traces_service_graph_request_total, pins UIDs
and writes:

  helm/grafana/dashboards/tempo-mixin-<name>.yaml     ConfigMaps for the Grafana sidecar
  helm/tempo/prometheusrule-tempo-mixin.yaml          PrometheusRule (recording + alerts)

Usage (from the repository root, Python 3 standard library only):
  python3 helm/grafana/dashboards/generate-tempo-mixin.py
"""

import json
import os
import re
import sys
import urllib.request

TEMPO_TAG = "v3.1.1"
SRC = f"https://raw.githubusercontent.com/grafana/tempo/{TEMPO_TAG}/operations/tempo-mixin-compiled"
HERE = os.path.dirname(os.path.abspath(__file__))
RULE_OUT = os.path.join(HERE, "..", "..", "tempo", "prometheusrule-tempo-mixin.yaml")
NAMESPACE = "observability"
FOLDER = "Tempo"

# Dashboards that have data in monolithic mode. Left out:
#   tempo-block-builder      block-builder only runs in the Kafka-based microservices path
#   tempo-rollout-progress   per-component rollout of the microservices deployment
DASHBOARDS = [
    "operational", "writes", "reads", "resources",
    "livestore", "backendwork", "tenants", "service-graph",
]

# Alerts that can fire in monolithic mode (no Kafka, no memcached, no vulture,
# no zones, no user-configurable overrides, no usage tracker).
ALERTS = {
    "TempoDistributorUnhealthy", "TempoLiveStoreUnhealthy", "TempoMetricsGeneratorUnhealthy",
    "TempoCompactionsFailing", "TempoPollsFailing", "TempoTenantIndexFailures",
    "TempoNoTenantIndexBuilders", "TempoTenantIndexTooOld", "TempoBadOverrides",
    "TempoCompactionTooManyOutstandingBlocks",
    "TempoBackendSchedulerJobsFailureRateHigh", "TempoBackendSchedulerRetryRateHigh",
    "TempoBackendSchedulerCompactionEmptyJobRateHigh", "TempoBackendWorkerBadJobsRateHigh",
    "TempoBackendWorkerCallRetriesHigh", "TempoMetricsGeneratorProcessorUpdatesFailing",
    "TempoMetricsGeneratorServiceGraphsDroppingSpans", "TempoMetricsGeneratorCollectionsFailing",
}

COMPONENTS = ("backend-scheduler", "backend-worker", "block-builder", "compactor", "cortex-gw",
              "distributor", "live-store", "metrics-generator", "querier", "query-frontend")
Q = r'\\?"'  # a quote, JSON-escaped inside dashboard strings or plain in rules


def fetch(path):
    with urllib.request.urlopen(f"{SRC}/{path}", timeout=30) as r:
        return r.read().decode()


def is_component(value):
    return any(c in value for c in COMPONENTS)


def monolithic(text):
    """Point component selectors at the single Tempo process."""
    def job(m):
        return f'job={m.group(1)}tempo{m.group(1)}' if "/" in m.group(2) else m.group(0)

    def container(m):
        return f'container={m.group(1)}tempo{m.group(1)}' if is_component(m.group(2)) else m.group(0)

    def workload(m):
        return f'{m.group(1)}={m.group(2)}tempo{m.group(2)}' if is_component(m.group(3)) else m.group(0)

    def pod(m):
        v = m.group(2)
        if "$component" in v or "live-store" in v:
            return f'pod=~{m.group(1)}tempo-.*{m.group(1)}'
        return m.group(0)

    text = re.sub(rf'job=~?({Q})([^"\\]*)\1', job, text)
    text = re.sub(rf'container=~?({Q})([^"\\]*)\1', container, text)
    text = re.sub(rf'(statefulset|deployment)=~?({Q})([^"\\]*)\2', workload, text)
    text = re.sub(rf'pod=~?({Q})([^"\\]*)\1', pod, text)
    return text


def service_graph(text):
    """Upstream "Tempo Service Graph" reads traces_service_graph_connection_info, an opt-in
    presence gauge (processor "service-graphs-connection-info") this stack does not enable.
    Derive the same client/server presence from traces_service_graph_request_total, which the
    default "service-graphs" processor always writes. max_over_time over the dashboard range
    keeps edges whose counters went stale (idle pairs), and group by () collapses duplicate
    series from several metrics-generator replicas into one edge."""
    text = re.sub(r'traces_service_graph_connection_info(\{[^}]*\})',
                  r'group by (client, server) (max_over_time(traces_service_graph_request_total\1[$__range]))',
                  text)
    text = text.replace("traces_service_graph_connection_info", "traces_service_graph_request_total")
    return text.replace("service-graphs connection_info gauge", "service-graphs request counter")


def pin_datasources(node):
    """Upstream panels sometimes hard-code Grafana Labs' own Prometheus UIDs; use ours."""
    if isinstance(node, dict):
        ds = node.get("datasource")
        if isinstance(ds, dict) and ds.get("type") == "prometheus" and not str(ds.get("uid", "")).startswith("$"):
            ds["uid"] = "prometheus"
        for v in node.values():
            pin_datasources(v)
    elif isinstance(node, list):
        for v in node:
            pin_datasources(v)


def dashboard(name):
    text = monolithic(fetch(f"dashboards/tempo-{name}.json"))
    if name == "service-graph":
        text = service_graph(text)
    d = json.loads(text)
    pin_datasources(d.get("panels", []))
    d.pop("id", None)
    d["uid"] = d.get("uid") or f"tempo-{name}"
    d["tags"] = sorted(set(d.get("tags", [])) | {"tempo", "tempo-mixin"})
    for v in d.get("templating", {}).get("list", []):
        if v.get("type") == "datasource" and v.get("query") == "prometheus":
            v["current"] = {"text": "Prometheus", "value": "prometheus"}
        elif v.get("type") == "datasource":
            v["current"] = {}  # e.g. Loki: not part of this stack, log panels stay empty
        elif v.get("type") == "query":
            if v["name"] in ("cluster", "namespace"):
                v["includeAll"] = True
                v["current"] = {"selected": True, "text": "All", "value": "$__all"}
            if v.get("includeAll"):
                v["allValue"] = "tempo-.*" if v["name"] == "pod" else ".*"
    body = json.dumps(d, separators=(",", ":"), sort_keys=True)
    return (
        f"# Generated by generate-tempo-mixin.py from grafana/tempo {TEMPO_TAG}\n"
        f"# operations/tempo-mixin-compiled/dashboards/tempo-{name}.json (Apache-2.0). Do not edit by hand.\n"
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n"
        f"  name: grafana-dashboard-tempo-{name}\n  namespace: {NAMESPACE}\n"
        "  labels:\n    grafana_dashboard: \"1\"\n    app.kubernetes.io/part-of: tempo-mixin\n"
        f"  annotations:\n    grafana_folder: {FOLDER}\n"
        f"data:\n  tempo-{name}.json: |-\n    {body}\n"
    )


def rules():
    # The compiled files are YAML with quoted keys; reuse them line by line without a YAML library.
    rec = fetch("rules.yaml")
    alerts = fetch("alerts.yaml")
    blocks, cur = [], []
    for line in alerts.splitlines()[3:]:  # skip groups/name/rules header
        if line.startswith("  - \"alert\":") and cur:
            blocks.append(cur)
            cur = []
        cur.append(line)
    blocks.append(cur)
    keep = [b for b in blocks if re.search(r'"alert": "(\w+)"', b[0]).group(1) in ALERTS]
    alert_text = monolithic("\n".join("\n".join(b) for b in keep))
    rec_body = "\n".join(rec.splitlines()[1:])  # drop the top-level "groups" key
    return (
        f"# Generated by helm/grafana/dashboards/generate-tempo-mixin.py from grafana/tempo {TEMPO_TAG}\n"
        "# operations/tempo-mixin-compiled/{rules,alerts}.yaml (Apache-2.0). Do not edit by hand.\n"
        "# Only alerts that apply to monolithic Tempo are kept; component selectors point at container \"tempo\".\n"
        "apiVersion: monitoring.coreos.com/v1\nkind: PrometheusRule\nmetadata:\n"
        f"  name: tempo-mixin\n  namespace: {NAMESPACE}\n"
        "  labels:\n    release: prometheus\n    app.kubernetes.io/part-of: tempo-mixin\n"
        "spec:\n  groups:\n"
        + "\n".join("  " + l for l in rec_body.splitlines()) + "\n"
        + "  - \"name\": \"tempo_alerts\"\n    \"rules\":\n"
        + "\n".join("  " + l for l in alert_text.splitlines()) + "\n"
    )


def main():
    for name in DASHBOARDS:
        out = os.path.join(HERE, f"tempo-mixin-{name}.yaml")
        with open(out, "w") as f:
            f.write(dashboard(name))
        print("wrote", os.path.relpath(out))
    with open(RULE_OUT, "w") as f:
        f.write(rules())
    print("wrote", os.path.relpath(RULE_OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
