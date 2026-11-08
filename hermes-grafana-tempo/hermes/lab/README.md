# 🧪 Hermes lab profile

A Kustomize overlay on the production profile in [`../`](../README.md) for a small, short-lived cluster
(3 × `e2-standard-2`).

| Setting | Production (`hermes/`) | Lab (`hermes/lab/`) |
|---|---|---|
| `HERMES_HOME` | 10Gi PVC `hermes-home` (`standard-rwo`) | `emptyDir` (1Gi), wiped on restart |
| Gateway requests / limit | 100m CPU, 384Mi / 1Gi | 50m CPU, 256Mi / 768Mi |
| Everything else | Same: non-root, Pod Security `restricted`, default-deny NetworkPolicy, alerts, dashboard | Same |

```bash
HERMES_PROFILE=lab hermes/deploy.sh     # or: kubectl apply -k hermes/lab/
hermes/verify.sh
```

Telemetry, alerts and the dashboard behave the same in both profiles; only sessions, memory and `state.db`
are lost when the lab pod restarts.
