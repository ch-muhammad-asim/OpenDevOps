# ☸️ nodejs-orders: Kubernetes manifests

Kustomize manifests that run `nodejs-orders` in namespace `tempo-apps` as Service `nodejs` on port 3000.
They follow the Pod Security `restricted` profile, which namespace `tempo-apps` enforces (and warns/audits). App details, planted issues and TraceQL are in the [app README](../README.md).

## 🧩 Files

| File | What it does | Security role |
|---|---|---|
| [`deployment.yaml`](deployment.yaml) | 2 replicas (lab: 1), node/zone topology spread, surge-only rollout, preStop drain, OTel env vars, downward-API pod name, probes, resources | Non-root 10001, read-only root FS, drop ALL, seccomp `RuntimeDefault`, no service account token |
| [`service.yaml`](service.yaml) | ClusterIP `nodejs`, port 3000 -> container port `http` | Cluster-internal only; public access goes through Traefik |
| [`pdb.yaml`](pdb.yaml) | PodDisruptionBudget `maxUnavailable: 1` | Availability during drains/upgrades; never blocks a 1-replica lab drain |
| [`kustomization.yaml`](kustomization.yaml) | Sets namespace `tempo-apps`, lists the three files | - |

## 📋 Settings

| Setting | Value | Why |
|---|---|---|
| Image | `tempo-apps/nodejs:1.0.3` | `apps/deploy-apps.sh` replaces it with `<registry>/nodejs@sha256:<digest>` |
| Labels | `app.kubernetes.io/name=nodejs`, `app.kubernetes.io/part-of=tempo-apps` | Selector, NetworkPolicies, dashboards |
| Resources | requests 50m / 128Mi, limits 500m / 256Mi | The planted leak stops at a 120 MiB cache, about 165 MiB total, below the limit |
| Readiness | `GET /healthz` every 5 s, timeout 3 s, 3 failures | Takes the pod out of the Service while the event loop is blocked |
| Liveness | `GET /healthz` every 20 s, timeout 10 s, 6 failures (~2 min), 10 s delay | Tolerates the planted CPU hog and sustained CPU stress without restarts; readiness sheds traffic instead |
| `/tmp` | `emptyDir`, 16 Mi | The only writable path (root FS is read-only) |
| OTLP endpoint | `http://otel-collector.observability:4318` (http/protobuf) | Collector in namespace `observability` |
| Resource attributes | `deployment.environment.name=lab,service.namespace=tempo-apps,k8s.namespace.name,k8s.pod.name` | Pod name and namespace via the downward API |

## 🚀 Deploy

```bash
# Render and review (no cluster needed).
kubectl kustomize apps/nodejs/k8s

# Build and push the image, then apply all three apps with the registry set.
apps/build-push.sh nodejs
apps/deploy-apps.sh

# Wait for the rollout and check the pod.
kubectl -n tempo-apps rollout status deploy/nodejs
kubectl -n tempo-apps get pods -l app.kubernetes.io/name=nodejs
```

Expected: `deployment "nodejs" successfully rolled out` and 2 pods `1/1 Running` on different nodes (lab: 1), 0 restarts.

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` on `tempo-apps/nodejs:1.0.3` | Applied with `kubectl apply -k apps/nodejs/k8s` directly, so the registry prefix was not set | Deploy with `apps/deploy-apps.sh` |
| Pod Security warning on apply | A field from the `restricted` profile was removed | Restore the `securityContext` blocks in `deployment.yaml` |
| `OOMKilled` | Memory limit lowered below ~200 Mi while the leak is at its cap | Keep the 256 Mi limit, or `kubectl -n tempo-apps rollout restart deploy/nodejs` |
| Pod `0/1` for a few seconds under load | Planted CPU hog blocks readiness | Expected; it recovers without a restart |

## 🧹 Teardown

```bash
kubectl delete -k apps/nodejs/k8s
```

## 🏭 Production checklist

- [ ] Replicas, PDB and topology spread: done (2 replicas, `maxUnavailable: 1`, node hard / zone soft); use a regional cluster for real zone spread.
- [ ] Right-size `resources` from measured usage (VPA in recommendation mode) and add an HPA.
- [ ] Deploy only by digest through [`deploy-apps.sh`](../../deploy-apps.sh); roll back with `kubectl -n tempo-apps rollout undo deployment/nodejs`.
- [ ] Alerts and runbooks: [`apps/monitoring`](../../monitoring/README.md). Full list: [apps production checklist](../../README.md#-production-checklist).

## 🔗 References

- [Kubernetes: Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Kubernetes: expose pod information through environment variables](https://kubernetes.io/docs/tasks/inject-data-application/environment-variable-expose-pod-information/)
- [Kubernetes: liveness, readiness and startup probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [OpenTelemetry: SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
