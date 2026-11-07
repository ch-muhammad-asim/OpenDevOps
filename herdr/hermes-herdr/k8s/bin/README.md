# 🔀 k8s/bin: `docker` → `kubectl` shim

A small `docker` command that lets the POC's scripts ([`scripts/hh`](../../scripts/hh),
[`scripts/e2e-test.sh`](../../scripts/e2e-test.sh)) run unchanged against the Kubernetes deployment in
[`../`](../README.md). Architecture: [../../README.md → Architecture](../../README.md#️-architecture).

## 📁 Files

| File | What it does |
|---|---|
| [`docker`](docker) | Maps the `docker` subcommands the scripts use to `kubectl` in namespace `hermes-herdr`; anything else exits 125 |

## 🚀 How it is used

Put this folder first on `PATH`; [`../e2e-gke.sh`](../e2e-gke.sh) does that for the e2e suite.

```bash
PATH="$PWD/herdr/hermes-herdr/k8s/bin:$PATH" herdr/hermes-herdr/scripts/hh agent list
```

A container name maps 1:1 to a Deployment and its container (label `app.kubernetes.io/name`).

| `docker` call | Becomes |
|---|---|
| `exec [-i] [-t] NAME CMD…` | `kubectl exec deploy/NAME -c NAME -- CMD…`; drops kubectl's extra `command terminated with exit code N` line and keeps the exit code |
| `logs NAME` | `kubectl logs deploy/NAME -c NAME` |
| `restart NAME…` | `kubectl rollout restart` + `rollout status` (300 s timeout) |
| `port NAME` | hostPorts of the Deployment, and NodePort/LoadBalancer Services selecting it (ClusterIP only = nothing printed) |
| `inspect NAME` | The hardening fields of the running pod, in Docker's terms (user, read-only root, capabilities, no-new-privileges, seccomp, hostPorts, memory limit, mounts); with `.Config.Env`, the pod-spec environment with `valueFrom` shown by reference, never resolved |
| `ps` | Deployments with all replicas ready |

| Env | Default | Purpose |
|---|---|---|
| `HERMES_HERDR_NS` | `hermes-herdr` | Namespace |
| `DOCKER_SHIM_RETRY_LOG` | `./docker-shim-retries.log` | Where retries are recorded |

## 🛡️ Security notes

- Uses the caller's `kubectl` context and rights; adds no credentials, listeners or cluster objects.
- Never resolves Secret references (`inspect … .Config.Env` prints `NAME=<secretKeyRef>`).
- `exec` retries once only on an API-server transport error (connection reset, stream lost, timeout) and only
  without `-i`, since stdin can't be replayed. Every retry is logged, so test evidence shows it.
- Unsupported subcommands or flags fail loudly (exit 125) instead of guessing.

## 🧪 Tests

Exercised by every `docker` call of the e2e suite through [`../e2e-gke.sh`](../e2e-gke.sh). On 2026-11-07
(GKE 1.36.4-gke.2046003, Hermes Agent v0.23.0, herdr 0.9.5) tests 8 (`inspect`), 13 (`port`) and 14 (`restart`)
passed in all five runs on two clusters; the last two runs were 19/19 on an earlier revision of tests 17-19 (the final suite has not run on GKE). Results:
[../README.md → Tests](../README.md#-tests).

## 🔗 See also

- Parent: [../README.md](../README.md)
- POC: [../../README.md](../../README.md)
