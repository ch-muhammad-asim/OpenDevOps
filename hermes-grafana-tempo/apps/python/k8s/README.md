# ☸️ python-inventory: Kubernetes manifests

Kustomize manifests that run [`python-inventory`](../) in namespace `tempo-apps` as Deployment `python` behind
ClusterIP Service `python` on port 8000. **Status:** ✅ renders with `kubectl kustomize` and passes
`kubectl apply --dry-run=server` on GKE 1.36; running live on GKE since 2026-11-08 (lab profile, 1 replica, image by digest).

## 🧩 Files

| File | What it defines (one line) |
|---|---|
| [`deployment.yaml`](deployment.yaml) | 2 replicas (lab: 1), node/zone topology spread, surge-only rollout, preStop drain, image `tempo-apps/python:1.0.2`, OTel env, probes, resources, restricted security context |
| [`service.yaml`](service.yaml) | ClusterIP `python`, port 8000 -> container port `http` (8000) |
| [`pdb.yaml`](pdb.yaml) | PodDisruptionBudget `maxUnavailable: 1`: drains/upgrades keep a pod serving, never block with 1 replica |
| [`kustomization.yaml`](kustomization.yaml) | Lists the three files; included by [`apps/kustomization.yaml`](../../kustomization.yaml) |

## ⚙️ Key settings

| Setting | Value | Why |
|---|---|---|
| Labels | `app.kubernetes.io/name=python`, `app.kubernetes.io/part-of=tempo-apps` | Selectors, NetworkPolicies, `kubectl get -l` |
| Image | `tempo-apps/python:1.0.2` | [`apps/deploy-apps.sh`](../../deploy-apps.sh) replaces it with `<registry>/python@sha256:<digest>` |
| OTLP endpoint | `http://otel-collector.observability:4318`, `http/protobuf` | The single Collector entry point |
| Resource attributes | `deployment.environment.name=lab`, `service.namespace=tempo-apps`, `k8s.namespace.name`, `k8s.pod.name` | Namespace and pod name come from the downward API (`$(VAR)` expansion) |
| Resources | Requests 50m / 96Mi, limits 500m / 256Mi | Fits small nodes; CPU limit makes the CPU-hog bug easy to see |
| Probes | Readiness and liveness `GET /healthz`, timeouts 3 s / 5 s | `/healthz` is not traced; the timeouts tolerate the planted event-loop block |
| Security context | `runAsNonRoot`, uid/gid 10001, `allowPrivilegeEscalation: false`, drop `ALL`, `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true` | Meets Pod Security "restricted" (namespace warns/audits at restricted) |
| Writable path | emptyDir on `/tmp` (32Mi) | SQLite database file |
| Service account token | `automountServiceAccountToken: false` | The app never calls the Kubernetes API |

## 🚀 Apply and verify

```bash
kubectl kustomize apps/python/k8s                              # why: render and review
apps/deploy-apps.sh                                            # why: pin images by digest and apply all apps (add `lab` for 1 replica)
kubectl -n tempo-apps get pods -l app.kubernetes.io/name=python   # expect: 2 pods 1/1 Running (lab: 1)
kubectl -n tempo-apps port-forward svc/python 8000:8000 &      # why: reach the API from your machine
curl -s http://127.0.0.1:8000/healthz                          # expect: {"status":"ok"}
```

## 🩺 Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` on `tempo-apps/python:1.0.2` | Applied with plain `kubectl apply -k`, registry not set | Use `apps/deploy-apps.sh` |
| PodSecurity warning on apply | A security context field was removed | Restore the fields in [`deployment.yaml`](deployment.yaml) |
| No traces from the pod | Collector unreachable | Check the `otel-collector-from-senders` NetworkPolicy and the Collector Service in `observability` |

## 🏭 Production checklist

- [ ] Replicas, PDB and topology spread: done (2 replicas, `maxUnavailable: 1`, node hard / zone soft); use a regional cluster for real zone spread.
- [ ] Right-size `resources` from measured usage (VPA in recommendation mode) and add an HPA.
- [ ] Deploy only by digest through [`deploy-apps.sh`](../../deploy-apps.sh); roll back with `kubectl -n tempo-apps rollout undo deployment/python`.
- [ ] Alerts and runbooks: [`apps/monitoring`](../../monitoring/README.md). Full list: [apps production checklist](../../README.md#-production-checklist).

## 📚 References

- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Downward API](https://kubernetes.io/docs/concepts/workloads/pods/downward-api/)
- [OTLP exporter configuration](https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/)
