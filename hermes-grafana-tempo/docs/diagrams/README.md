# 🗺️ Diagrams

Mermaid sources for the diagrams in the [top-level README](../../README.md). The README contains each file as a
`mermaid` code block, which GitHub renders.

| File | Shows (one line) | Embedded in |
|---|---|---|
| [`architecture.mmd`](architecture.mmd) | Namespaces and workloads on the GKE lab cluster: edge, sample apps, Hermes, observability, monitoring with Thanos, external GCS buckets with Workload Identity | [README](../../README.md), section Architecture |
| [`telemetry-flow.mmd`](telemetry-flow.mmd) | How traces, metrics, logs, queries and alerts move from the apps and Hermes to Grafana | [Telemetry flow](../../README.md#-telemetry-flow) |
| [`lab-vs-production.mmd`](lab-vs-production.mmd) | The two profiles: single-binary Tempo and Thanos (lab) vs tempo-distributed with Kafka, and Thanos (production); both use GCS buckets with Workload Identity and 30-day retention | [README](../../README.md), section Lab vs production |

Edit a diagram here, then copy it unchanged into the README's matching code block so both stay identical. Preview
locally with the [Mermaid Live Editor](https://mermaid.live/) or any Markdown viewer with Mermaid support.
