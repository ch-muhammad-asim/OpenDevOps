# ☸️ `gke/`: Hermes in NVIDIA OpenShell on GKE

Every manifest, Helm values file and script for the live GKE deployment: Traefik and cert-manager at the edge, the OpenShell gateway, the Hermes sandbox, the tunnel and the OpenCode bridge. Where it sits: see [Architecture (as running)](../README.md#️-architecture-as-running) and [Components, one line each](../README.md#-components-one-line-each).

## 📁 Files

| File | What it does |
|------|--------------|
| [`deploy.sh`](deploy.sh) | Runs every in-cluster step in order (`STEPS=` picks some); secrets go on stdin only; also the non-default `recreate-sandbox`, `restore-data`, `tunnel-restart` and `delete-sandbox` steps |
| [`openshell-cli.sh`](openshell-cli.sh) | Runs the OpenShell CLI (from the `hermes-tunnel:0.1.6` image) against the gateway through a `kubectl port-forward`, with the client certificate in a private temp dir for that run only |
| [`test-recreate-backup.sh`](test-recreate-backup.sh) | Offline test: `recreate-sandbox` never deletes the sandbox unless the backup is a readable archive with `hermes/config.yaml` (stub `docker`/`kubectl`/`gcloud`, no cluster) |
| [`node-system-config.yaml`](node-system-config.yaml) | Node system config for cluster creation: kubelet `podPidsLimit: 2048` on every pod |
| [`namespaces.yaml`](namespaces.yaml) | Namespaces `traefik`, `cert-manager`, `openshell`, `hermes-edge`, all with Pod Security `restricted` |
| [`limitrange.yaml`](limitrange.yaml) | Default requests (100m / 128Mi) and limits (1 CPU / 512Mi) in `openshell` for containers that set none (the supervisor pods) |
| [`openshell-values.yaml`](openshell-values.yaml) | OpenShell 0.1.6 chart values: sandbox uid/gid 10000, 5 Gi `standard-rwo` workspace, mTLS on, no unauthenticated users, telemetry off, runc only |
| [`cert-manager-values.yaml`](cert-manager-values.yaml) | cert-manager v1.21.2 chart values: CRDs kept, DNS-01 self-check against public resolvers, small requests/limits |
| [`cluster-issuer.yaml`](cluster-issuer.yaml) | ClusterIssuers `letsencrypt-staging` and `letsencrypt-prod`, DNS-01 through Cloudflare with Secret `cloudflare-api-token` |
| [`certificate.yaml`](certificate.yaml) | Origin certificate `hermes-gke-tls` in `hermes-edge` (ECDSA P-256, `letsencrypt-prod`) |
| [`traefik-values.yaml`](traefik-values.yaml) | Traefik chart 42.0.0 values: CRD provider only, namespaced RBAC, ports 8000/8443 (exposed 80/443), Cloudflare-only forwarded headers, `externalTrafficPolicy: Local`, non-root uid 65532, read-only rootfs |
| [`traefik-routes.yaml`](traefik-routes.yaml) | TLSOption (TLS 1.2+), middlewares (`cloudflare-only`, `security-headers`, `login-ratelimit`, `to-https`) and the IngressRoutes: `/v1`, `/v1/*` → `:8642`, the rest → `:9119` |
| [`hermes-tunnel.yaml`](hermes-tunnel.yaml) | `hermes-tunnel` Deployment and ClusterIP Service: `openshell forward` of 9119 (dashboard) and 8642 (API) through the gateway, uid 10001, mTLS client bundle installed by an init container |
| [`opencode-bridge.yaml`](opencode-bridge.yaml) | OpenCode bridge ConfigMap, 1 Gi PVC, Deployment (uid 1000, read-only rootfs) and ClusterIP Service on 18383 |
| [`networkpolicies.yaml`](networkpolicies.yaml) | Default-deny plus allow rules for `hermes-edge` and `traefik` (NodeLocal DNS included); `openshell` policies come from the chart |
| [`herdr/`](herdr/) | The herdr image layer for the dashboard Hermes: Dockerfile, entrypoint, `herdr` allowlist, managed config, skill and kill-guard test |
| `README.md` | This page |

## ⚙️ How it is used

Run from the repository root, after the cluster and the images exist (steps 1 to 3 in [Build it, step by step](../README.md#-build-it-step-by-step)):

```bash
sandbox/k8s/gke/deploy.sh                                   # base certmanager traefik netpol bridge openshell provider sandbox tunnel edge dns
STEPS="openshell sandbox" sandbox/k8s/gke/deploy.sh         # selected steps only
STEPS="recreate-sandbox sandbox restore-data tunnel-restart" sandbox/k8s/gke/deploy.sh   # roll to a new image with backup
sandbox/k8s/gke/openshell-cli.sh sandbox list               # any OpenShell CLI command
sandbox/k8s/gke/test-recreate-backup.sh                     # offline, touches no cluster
```

- Inputs: `kubectl` pointing at the cluster, `helm`, `docker`, `gcloud` (project and registry), the NVIDIA key and Cloudflare DNS token files, and `~/.config/hermes-sandbox/gke/hermes.env` (dashboard hash and API key). Paths and versions are variables at the top of `deploy.sh`.
- Outputs: the namespaces, charts, Secrets `cloudflare-api-token`, `nvidia-api-key` and the `hermes-edge` copy of `openshell-client-tls`, the OpenShell provider `nvidia`, the sandbox `hermes` (by image digest, 900m CPU / 3 GiB, `--restart-policy on-failure`, entrypoint `start-hermes-herdr`) and the proxied DNS record.
- Ports: Traefik 8000/8443 (LB 80/443) → `hermes-tunnel` 9119 (dashboard) and 8642 (API) → gateway 8080 (gRPC, mTLS) → sandbox; bridge 18383 (`host.openshell.internal:18383` in the sandbox); the CLI port-forward uses local 18080.
- Users: Hermes and herdr uid 10000, tunnel 10001, bridge 1000, Traefik 65532; all non-root with `RuntimeDefault` seccomp.
- Backups from `recreate-sandbox` go to `~/.config/hermes-sandbox/gke/hermes-data-backup-<UTC>.tgz` (mode 600).

## 🛡️ Security notes

- Enforces: Pod Security `restricted` in all four namespaces, default-deny NetworkPolicies, Cloudflare-only source IPs and a login rate limit at Traefik, mTLS to the gateway, Traefik limited to Secrets in `hermes-edge` and `traefik`.
- Trusts: the Cloudflare edge (source IP and `X-Forwarded-Proto`), the OpenShell gateway and supervisor (policy, key injection), and the operator's `kubectl` context.
- Secrets are read from local files and piped on stdin; the client certificate is copied without printing and the CLI temp dir is removed on exit. `recreate-sandbox` fails closed: nothing is deleted without a good backup.
- Must never contain keys, tokens, passwords, certificates, project IDs or addresses of this deployment (load balancer, nodes, control plane); the only IPs are Cloudflare's published ranges, the private/link-local/CGNAT exclusions and public resolvers; the registry is rendered from the current project at deploy time.

## 🧪 Tests

Results from 2026-11-07 (fresh rebuild on Hermes Agent v0.23.0, herdr 0.9.5, OpenShell 0.1.6), from [Verify](../README.md#-verify):

| Check | Result |
|-------|--------|
| HTTPS, redirect, auth | `http` → `301`; direct to the LB from a non-Cloudflare address `403`; `/api/auth/me` `401` without a session; wrong password `401`, more than 10 a minute `429`; `/v1/models` `401` without the key, `200` with it |
| Filesystem probes (`openshell-cli.sh sandbox exec`) | uid 10000, `CapEff 0`, `NoNewPrivs 1`, `Seccomp 2`; writes outside `/sandbox` and `/tmp` and reads of `/etc/shadow` → `Permission denied` |
| Network fence | A pod with the workload label reaches nothing (internet, Kubernetes API, gateway, DNS); metadata and `attacker.example` → `DENIED` in OCSF |
| Image roll with backup | Backup before the delete, restore with SHA-256 check, sessions 22 before = 22 after; [`test-recreate-backup.sh`](test-recreate-backup.sh) 6/6 |
| herdr kill guard | [`herdr/test-kill-guard.sh`](herdr/test-kill-guard.sh) 13/13 PASS; operator SIGTERM to herdr → sandbox recreated, herdr and Hermes back in about 50 s |

⬆️ Back to [`k8s/`](../README.md)
