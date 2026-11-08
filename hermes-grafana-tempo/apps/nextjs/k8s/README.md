# ☸️ nextjs-web Kubernetes manifests

Deployment and Service for `nextjs-web` in namespace `tempo-apps`. Back to the [app README](../README.md).

| File | What it does |
|---|---|
| [`deployment.yaml`](deployment.yaml) | 2 replicas (lab: 1), node/zone topology spread, surge-only rollout, preStop drain, image `tempo-apps/nextjs:1.0.2`, OTel env, probes on `/healthz`, Pod Security `restricted` |
| [`service.yaml`](service.yaml) | ClusterIP `nextjs`, port 3000 (target of the `tempo-nextjs` IngressRoute) |
| [`pdb.yaml`](pdb.yaml) | PodDisruptionBudget `maxUnavailable: 1`: drains/upgrades keep a pod serving, never block with 1 replica |
| [`kustomization.yaml`](kustomization.yaml) | Sets namespace `tempo-apps`; included by [`apps/kustomization.yaml`](../../kustomization.yaml) |

| Setting | Value |
|---|---|
| Resources | requests `50m` / `128Mi`, limits `500m` / `384Mi` |
| Probes | readiness and liveness `GET /healthz` on port `http` (3000) |
| Security context | `runAsNonRoot`, UID/GID 10001, `allowPrivilegeEscalation: false`, drop ALL, seccomp `RuntimeDefault`, `readOnlyRootFilesystem: true`, no service account token |
| Writable paths | `/tmp` (emptyDir, 64Mi), `/app/.next/cache` (emptyDir, 128Mi) |
| Labels | `app.kubernetes.io/name=nextjs`, `app.kubernetes.io/part-of=tempo-apps` |

## 🚀 Deploy

```bash
# Build and push the image (sets the registry path).
apps/build-push.sh nextjs
# Render the production profile (or `lab`), pin images by digest, apply, wait for rollout.
apps/deploy-apps.sh
# Check the pod.
kubectl -n tempo-apps rollout status deploy/nextjs
```

Render only this app (no cluster needed): `kubectl kustomize apps/nextjs/k8s`.

## 🏭 Production checklist

- [ ] Replicas, PDB and topology spread: done (2 replicas, `maxUnavailable: 1`, node hard / zone soft); use a regional cluster for real zone spread.
- [ ] Right-size `resources` from measured usage (VPA in recommendation mode) and add an HPA.
- [ ] Deploy only by digest through [`deploy-apps.sh`](../../deploy-apps.sh); roll back with `kubectl -n tempo-apps rollout undo deployment/nextjs`.
- [ ] Alerts and runbooks: [`apps/monitoring`](../../monitoring/README.md). Full list: [apps production checklist](../../README.md#-production-checklist).

## 🧹 Remove

```bash
kubectl delete -k apps/nextjs/k8s
```
