# ☸️ k8s: the herdr + Hermes POC on Kubernetes (GKE)

Kustomize manifests and scripts that run the POC's four images as single-replica Deployments in namespace
`hermes-herdr`, plus the wrapper that runs the POC's unchanged e2e suite against them.
Architecture and the Docker version: [../README.md → Architecture](../README.md#️-architecture);
GKE design and results: [../README.md → Run on GKE](../README.md#️-run-on-gke-tested-2026-11-07).

**Status:** tested 2026-11-07 on a fresh GKE 1.36.4-gke.2046003 cluster (Standard, Dataplane V2, 3 × `e2-standard-2`
Ubuntu 24.04 nodes) built from these docs, Hermes Agent v0.23.0, herdr 0.9.5: **19/19 in two consecutive runs**
(see [Tests](#-tests)). The round-2 runs used the suite before tests 17-19 gained their final controls (run 37 on the VM); the final suite was not run on GKE (the lab ended during the round-3 run); round 3 re-deployed from these docs and passed the dashboard checks and the kill guard 13/13.

## 📁 Files

| File | What it does |
|---|---|
| [`kustomization.yaml`](kustomization.yaml) | Lists the resources and the four image names; `deploy.sh` adds registry + digest to a temp copy |
| [`namespace.yaml`](namespace.yaml) | Namespace `hermes-herdr` with Pod Security `restricted` enforced |
| [`networkpolicies.yaml`](networkpolicies.yaml) | `default-deny`, `allow-dns` and one policy per component (the only allowed flows) |
| [`herdr-hermes.yaml`](herdr-hermes.yaml) | PVC (2 Gi) + Deployment: herdr server and Hermes TUI; key-install init container; NVIDIA key file mount; no Service |
| [`workbench.yaml`](workbench.yaml) | PVC (1 Gi) + Service `:2222` + Deployment: where Hermes's tools and the work panes run |
| [`work.yaml`](work.yaml) | PVC (1 Gi) + Service `:2222` + Deployment: work herdr server behind herdr-broker |
| [`egress.yaml`](egress.yaml) | ConfigMap (`tinyproxy.conf`, `Allow @POD_CIDR@` rendered by `deploy.sh`) + Service `:8888` + Deployment: the allowlist proxy to the model API |
| [`make-secrets.sh`](make-secrets.sh) | Creates `nvidia-api-key` and one SSH-key Secret per pod; idempotent, `ROTATE=1` replaces the SSH keys |
| [`deploy.sh`](deploy.sh) | Builds and pushes the four images, pins them by digest, renders the cluster's pod range into `tinyproxy.conf`, applies, creates Secrets, waits for rollout |
| [`e2e-gke.sh`](e2e-gke.sh) | Runs `../scripts/e2e-test.sh` unchanged against the cluster, through the `docker` shim |
| [`bin/`](bin/README.md) | `docker` → `kubectl` shim used by `e2e-gke.sh` and `scripts/hh` |

## 🚀 Run it

```bash
# Needs: kubectl on the cluster, gcloud (Artifact Registry), Docker with buildx, the NVIDIA key file,
# and the dashboard cluster from sandbox/k8s (it fills 2 nodes): add a third e2-standard-2 node first.
ZONE=$(gcloud container clusters list --filter=name=hermes-gke --format='value(location)')   # step 1 may have used another zone
gcloud container clusters resize hermes-gke --node-pool default-pool --num-nodes 3 --zone "$ZONE" --quiet
herdr/hermes-herdr/k8s/deploy.sh            # build + push, pin by digest, apply, Secrets, wait
BUILD=0 herdr/hermes-herdr/k8s/deploy.sh    # only after a run that pushed: reuses the images in the registry
herdr/hermes-herdr/k8s/e2e-gke.sh           # e2e suite; evidence in ./hermes-herdr-e2e-gke.log
PATH="$PWD/herdr/hermes-herdr/k8s/bin:$PATH" herdr/hermes-herdr/scripts/hh agent list   # control Hermes
```

Expected: four pods `Running` in `hermes-herdr`; `hh agent list` shows agent `hermes`.

| Input (env) | Default | Used by |
|---|---|---|
| `PROJECT` | `gcloud config get-value project` | `deploy.sh` (registry path) |
| `REGISTRY` | `us-central1-docker.pkg.dev/$PROJECT/hermes` | `deploy.sh` |
| `HERMES_VERSION` | `v0.23.0` | `deploy.sh` (Hermes base image) |
| `BUILD` | `1` | `deploy.sh` (`0` = skip build/push; stops with "not in the registry" if an image was never pushed, as a local `docker build` alone doesn't push) |
| `CLUSTER_NAME`, `ZONE` | `hermes-gke`, the cluster's location | `deploy.sh` (same names as `gcp/gcp-infra.sh`; used to read the pod range) |
| `POD_CIDR` | `gcloud container clusters describe … --format='value(clusterIpv4Cidr)'` | `deploy.sh` (tinyproxy `Allow`; set it for a non-GKE cluster) |
| `NVIDIA_KEY_FILE` | `~/Desktop/sandbox/creds/nvidia/api` | `make-secrets.sh` |
| `ROTATE` | `0` | `make-secrets.sh` (`1` = new SSH keys) |
| `EVIDENCE` | `./hermes-herdr-e2e-gke.log` | `e2e-gke.sh` |
| `EGRESS_WB_EXPECT`, `HOST_HERDR_CHECK`, `EXISTING_URL`, `EXISTING_CMD` | `blocked`, `0`, the GKE dashboard checks | `e2e-gke.sh` → `e2e-test.sh` |

| Pod | uid:gid | Ports | Mounts (main container) | Requests → limits |
|---|---|---|---|---|
| `herdr-hermes` | 10000:10000 | none (no Service) | `/data` (PVC), `/keys`, `/tmp`, `/opt/data`, key file `/run/secrets/nvidia_api_key` (read-only) | 300m / 1 Gi → 1 / 2 Gi |
| `hermes-workbench` | 10000:10000 | 2222 | `/work/workspace` (PVC), `/var/lib/workbench`, `/keys` + `/panekeys` (read-only), `/ctlkeys`, `/tmp` | 100m / 256 Mi → 1 / 1 Gi |
| `hermes-herdr-work` | 10000:10000 | 2222 | `/data` (PVC), `/ctlkeys` (read-only), `/panekeys`, `/tmp` | 100m / 128 Mi → 500m / 512 Mi |
| `hermes-herdr-egress` | 65534:65534 | 8888 | `/etc/tinyproxy/tinyproxy.conf` (ConfigMap, read-only) | 20m / 32 Mi → 250m / 64 Mi |

Teardown: `kubectl delete namespace hermes-herdr` (also deletes the PVCs and Secrets), then
`gcloud container clusters resize hermes-gke --node-pool default-pool --num-nodes 2 --zone "$ZONE" --quiet` (`ZONE` as above).

## 🛡️ Security notes

- **Enforces:** Pod Security `restricted` (non-root, read-only root filesystem, all capabilities dropped,
  no privilege escalation, seccomp `RuntimeDefault`, no service-account token); default-deny NetworkPolicies;
  only the proxy may leave the cluster (TCP 443, private ranges excluded); the proxy's own allowlist limits it
  to the model endpoint. tinyproxy's `Allow` is the cluster's pod range (it differs per cluster, so `deploy.sh`
  reads it; apply through `deploy.sh`, not `kubectl apply -k`); the NetworkPolicy is what limits callers to
  `herdr-hermes`.
- **Secrets:** created only by `make-secrets.sh` from the key file and a private temp dir, never printed or
  committed. Only `herdr-hermes` mounts `nvidia-api-key`, as a read-only file (no environment variable).
  Init containers install SSH keys with `install -m 0600/0644`; `fsGroupChangePolicy: OnRootMismatch` keeps those modes.
- **Trusts:** the images built from this repo (pinned by digest), the cluster's DNS, and the registry.
- **Must never contain:** keys, tokens, server IPs or project IDs. Registry and project come from `gcloud` or env at run time.

## 🧪 Tests

`e2e-gke.sh` runs the 19 tests of [`scripts/e2e-test.sh`](../scripts/e2e-test.sh) (16-19 are the redaction
tests). Results on 2026-11-07, GKE 1.36.4-gke.2046003, Hermes Agent v0.23.0, herdr 0.9.5:

| Cluster | Runs | Result | Notes |
|---|---|---|---|
| Fresh cluster built from these docs (pod range `10.208.0.0/14`) | 2 back-to-back | **19/19** and **19/19** | After the egress fix below; test 7: model API `200`, example.com refused, workbench direct and via the proxy blocked. The round-2 runs used the suite before tests 17-19 gained their final controls (run 37 on the VM); the final suite was not run on GKE (the lab ended during the round-3 run); round 3 re-deployed from these docs and passed the dashboard checks and the kill guard 13/13. |
| First cluster (pod range `10.196.0.0/14`) | 3 back-to-back | 18/19, 17/19, 18/19 | Failures were model or model-API behaviour (fake test key shown once in the Hermes pane, model API `429`, a command not run); every Kubernetes-specific test passed |

**Egress fix found by the fresh cluster:** `egress.yaml` used to hardcode tinyproxy's `Allow` to the first
cluster's pod range, so on a new cluster tinyproxy refused `herdr-hermes` (`Unauthorized connection`) and Hermes
could not reach the model. `deploy.sh` now reads the pod range from the cluster (`POD_CIDR` overrides it); the
NetworkPolicy remains the control that admits only `herdr-hermes`.
Per-test detail: [../README.md → Results on GKE](../README.md#-results-on-gke-2026-11-07).

## 🔗 See also

- Parent: [../README.md](../README.md)
- Shim: [bin/README.md](bin/README.md)
- The GKE dashboard stack this runs next to: [../../../sandbox/k8s/README.md](../../../sandbox/k8s/README.md)
