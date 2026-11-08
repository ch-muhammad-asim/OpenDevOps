# 🧪 Lab profile (Kustomize overlay)

The production app manifests, resized for a small 3 x e2-standard-2 lab cluster. **Why:** one set of manifests;
the lab differs only where it must, so what you test is what you would ship.

| Setting | Production ([../kustomization.yaml](../kustomization.yaml)) | Lab ([kustomization.yaml](kustomization.yaml)) |
|---|---|---|
| Replicas per app | 2 | 1 |
| `deployment.environment.name` (trace resource attribute) | `production` | `lab` |
| PDB, topology spread, probes, security context, resources, PrometheusRule | same | same |

PDBs use `maxUnavailable: 1`, so a single lab replica never blocks a node drain or GKE upgrade.

## ▶️ Use it

```bash
apps/deploy-apps.sh lab                 # digest-pinned images, 1 replica per app
kubectl kustomize apps/lab | less       # inspect the rendered manifests
```

## 🏭 Production checklist

Use the production profile (`apps/deploy-apps.sh` with no argument) and see the
[apps production checklist](../README.md#-production-checklist).
