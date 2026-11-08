# 📊 Tempo dashboards (Grafana sidecar ConfigMaps)

The official Tempo mixin dashboards from `grafana/tempo` tag `v3.1.1` (`operations/tempo-mixin-compiled`, Apache-2.0),
adapted to the single-binary Tempo of the lab and packed as one ConfigMap each. **Why:** Tempo's own health (ingest,
queries, backend jobs, resources) next to the application traces, without hand-maintained JSON.

**Status (2026-11-08, Grafana 13.3.0, Tempo 3.1.1):** the 8 dashboards run in the lab Grafana (folder "Tempo"). Every
query of the rewritten Service Graph dashboard was run against the lab Prometheus and returns data (4 source nodes,
4 target nodes, 6 edges over 6 hours).

## 🧩 Files

| File | What it is (one line) |
|---|---|
| [`generate-tempo-mixin.py`](generate-tempo-mixin.py) | Downloads the compiled mixin at `TEMPO_TAG`, rewrites it for single-binary Tempo and writes the files below |
| [`tempo-mixin-operational.yaml`](tempo-mixin-operational.yaml) | ConfigMap with "Tempo Operational": request rates, errors, backend, ring |
| [`tempo-mixin-writes.yaml`](tempo-mixin-writes.yaml) | ConfigMap with "Tempo / Writes": distributor and live-store ingest path |
| [`tempo-mixin-reads.yaml`](tempo-mixin-reads.yaml) | ConfigMap with "Tempo / Reads": query-frontend and querier path |
| [`tempo-mixin-resources.yaml`](tempo-mixin-resources.yaml) | ConfigMap with "Tempo / Resources": CPU, memory and Go heap of the Tempo pod |
| [`tempo-mixin-livestore.yaml`](tempo-mixin-livestore.yaml) | ConfigMap with "Tempo / Livestore": recent traces held before flush |
| [`tempo-mixin-backendwork.yaml`](tempo-mixin-backendwork.yaml) | ConfigMap with "Tempo - Backend Work": compaction, retention and redaction jobs |
| [`tempo-mixin-tenants.yaml`](tempo-mixin-tenants.yaml) | ConfigMap with "Tempo / Tenants": per-tenant usage (`single-tenant`) |
| [`tempo-mixin-service-graph.yaml`](tempo-mixin-service-graph.yaml) | ConfigMap with "Tempo Service Graph": service topology from `traces_service_graph_request_total` |

The script also writes [`../../tempo/prometheusrule-tempo-mixin.yaml`](../../tempo/prometheusrule-tempo-mixin.yaml)
(recording rules + the alerts that apply to single-binary Tempo).

Every ConfigMap is in namespace `observability`, labelled `grafana_dashboard: "1"` (picked up by the Grafana dashboard
sidecar, [`../values.yaml`](../values.yaml) `sidecar.dashboards`) and annotated `grafana_folder: Tempo`. What each
dashboard shows and which panels stay empty in single-binary mode: [`../README.md`](../README.md#-official-tempo-dashboards).
Plain-language guide to every dashboard in Grafana (all folders, panels, queries, how to read them):
[`docs/dashboards/`](../../../docs/dashboards/README.md).

## 🚀 Apply

`scripts/deploy.sh dashboards` applies this directory together with the alert rules:

```bash
kubectl apply -f helm/grafana/dashboards/   # only the *.yaml files; the script and this README are ignored
```

The sidecar loads new or changed ConfigMaps within about a minute; no Grafana restart.

## 🔁 Regenerate

After a Tempo upgrade, set `TEMPO_TAG` in the script to the new image tag, then from the repository root (Python 3
standard library only, needs HTTPS access to `raw.githubusercontent.com`):

```bash
python3 helm/grafana/dashboards/generate-tempo-mixin.py
```

Review the diff (`git diff helm/grafana/dashboards/ helm/tempo/prometheusrule-tempo-mixin.yaml`), then apply as above.
Do not edit the generated YAML by hand: the next run overwrites it.

| Rewrite in the script | Why |
|---|---|
| `job="<namespace>/<component>"`, `container`, `deployment`/`statefulset`, `pod` selectors → `job="tempo"`, `container="tempo"`, `pod=~"tempo-.*"` | The upstream mixin targets the microservices deployment |
| Every Prometheus data source → uid `prometheus` | Upstream hard-codes some UIDs |
| `cluster` / `namespace` variables optional (`.*`) | This stack has no `cluster` label |
| Service Graph: `traces_service_graph_connection_info` → `group by (client, server) (max_over_time(traces_service_graph_request_total{...}[$__range]))` | The connection-info gauge needs the opt-in processor `service-graphs-connection-info`; the request counter is always written |

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| ConfigMaps present | `kubectl -n observability get cm -l app.kubernetes.io/part-of=tempo-mixin` | 8 `grafana-dashboard-tempo-*` |
| Loaded by Grafana | Dashboards → folder "Tempo" | 8 dashboards |
| Service Graph data | Prometheus query `group by (client, server) (max_over_time(traces_service_graph_request_total[6h]))` | One series per client → server pair |

## 🏭 Production checklist

| Area | Item |
|---|---|
| Selectors | These dashboards target single-binary Tempo (`job="tempo"`). With [`../../tempo-distributed/`](../../tempo-distributed/README.md) use the upstream compiled mixin unchanged (`job="<namespace>/<component>"`) |
| Upgrades | Bump `TEMPO_TAG` with the Tempo image, regenerate, review the diff, apply; roll back with `git checkout` of the previous files and re-apply |
| Ownership | Dashboards are code: edits made in the Grafana UI are lost when the sidecar reloads the ConfigMap |

## 🔗 References

- [Tempo mixin source (v3.1.1)](https://github.com/grafana/tempo/tree/v3.1.1/operations/tempo-mixin-compiled)
- [Monitor Tempo](https://grafana.com/docs/tempo/latest/operations/monitor/)
- [Tempo service graphs](https://grafana.com/docs/tempo/latest/metrics-from-traces/service_graphs/)
- [Grafana chart sidecar for dashboards](https://github.com/grafana-community/helm-charts/tree/main/charts/grafana#sidecar-for-dashboards)
