# ☁️ Infrastructure (GKE + Tempo bucket)

Scripts that create the Google Cloud resources for hermes-grafana-tempo: the GKE cluster and, for production, the GCS
bucket that stores Tempo trace blocks. Both scripts are idempotent and read settings from environment variables.

**Status:** `create-cluster.sh` `PROFILE=lab` tested 2026-11-08 (zonal, 3 × e2-standard-2, GKE 1.36, Dataplane V2).
`PROFILE=prod` (regional, autoscaling, private nodes + Cloud NAT, maintenance window) is checked offline only: `bash -n`,
the generated `gcloud` commands, and every flag against `gcloud ... --help`; no production cluster has been created.
`create-tempo-bucket.sh` with `ACCESS_MODE=principal` (production) is not tested live: the lab account may not edit
bucket IAM, so the lab keeps Tempo on a local PVC.

## 🧩 Files

| File | What it does (one line) | Security role |
|---|---|---|
| [create-cluster.sh](create-cluster.sh) | Enables the APIs, creates the GKE cluster (`PROFILE=lab` or `prod`; prod also a Cloud Router + Cloud NAT), fetches kubectl credentials | Workload Identity, Dataplane V2 (enforces NetworkPolicies), control plane limited to authorized networks; prod: private nodes, Shielded Nodes secure boot |
| [create-tempo-bucket.sh](create-tempo-bucket.sh) | Creates the private Tempo bucket with a lifecycle rule and grants the `observability/tempo` service account access to it | Keyless Workload Identity, access scoped to one bucket |

## 📋 Prerequisites

- `gcloud` authenticated with rights to create GKE clusters (and, for production, to set IAM on the bucket).
- `kubectl` 1.36 (matching the cluster minor version) and `helm` 3.x (used by [../scripts/deploy.sh](../scripts/deploy.sh)).
- Quota: lab 6 vCPU in one zone; prod at least 48 vCPU (6 × e2-standard-8) in the region, up to 96 vCPU at the
  autoscaler maximum, plus one external IP for Cloud NAT.

## 🚀 Run it

```bash
# Lab (default): zonal, 3 x e2-standard-2 (6 vCPU / 24 GB), 50 GB pd-standard per node
infra/create-cluster.sh

# Production: regional (3 zones), autoscaling 2-4 e2-standard-8 nodes per zone, pd-balanced,
# private nodes behind Cloud NAT, weekend maintenance window
PROFILE=prod REGION=us-central1 infra/create-cluster.sh
```

Expected: the last command prints the nodes (`kubectl get nodes -o wide`): 3 `Ready` in the lab, 6 (2 per zone) in
production. Re-running is safe: existing cluster, router and NAT are kept.

| Variable | Lab default | Prod default | Meaning |
|---|---|---|---|
| `PROFILE` | `lab` | — | `lab` or `prod` |
| `PROJECT_ID` | current `gcloud` project | same | Target project |
| `ZONE` / `REGION` | `us-central1-a` / empty | — / **required** | Zonal lab; `REGION` makes the cluster regional (3 zones) |
| `CLUSTER_NAME` | `tempo-demo` | same | Cluster name (prod router/NAT: `<name>-router`, `<name>-nat`) |
| `MACHINE_TYPE` | `e2-standard-2` | `e2-standard-8` | Node machine type |
| `NUM_NODES` | `3` | `2` | Initial nodes (per zone when regional) |
| `MIN_NODES` / `MAX_NODES` | — | `2` / `4` | Cluster autoscaler bounds per zone (6-12 nodes in 3 zones) |
| `DISK_TYPE`, `DISK_SIZE` | `pd-standard`, `50` | `pd-balanced`, `100` | Node boot disk |
| `NETWORK` | — | `default` | VPC for the nodes and the Cloud NAT |
| `PRIVATE_NODES` | — | `true` | Nodes without public IPs (`--enable-private-nodes`) |
| `CREATE_NAT` | — | = `PRIVATE_NODES` | Create Cloud Router + Cloud NAT so private nodes can pull images and reach external APIs; `false` if the VPC already has one in `REGION` |
| `MAINTENANCE_START` / `_END` / `_RECURRENCE` | — | `02:00`-`08:00` UTC, `FREQ=WEEKLY;BYDAY=SA,SU` | Weekly maintenance window for automatic upgrades |
| `RELEASE_CHANNEL` | `regular` | `regular` | GKE release channel |
| `AUTHORIZED_NETWORKS` | your public IP `/32` | same | CIDRs allowed to reach the Kubernetes API |

Both profiles: COS containerd, VPC-native (IP alias), Dataplane V2, Workload Identity, authorized networks, system
logging and monitoring. Prod adds surge upgrades (`max-surge 1`, `max-unavailable 0`) and Shielded Nodes secure boot +
integrity monitoring. The lab flags are exactly those the running lab cluster was created with.

Dataplane V2 can only be chosen when the cluster is created; without it NetworkPolicies are accepted but not enforced.

### 🪣 Tempo bucket (production)

`scripts/deploy.sh` runs this automatically when `TEMPO_STORAGE=gcs` (the production default).

```bash
infra/create-tempo-bucket.sh        # last two lines: bucket name, Google service account ("" in principal mode)
```

| `ACCESS_MODE` | How Tempo gets access | Use |
|---|---|---|
| `principal` (default) | `roles/storage.objectAdmin` on **this bucket only** for the Kubernetes service account itself (Workload Identity Federation principal) | ✅ Production |
| `gsa` | The Kubernetes service account impersonates an existing Google service account (`TEMPO_GSA`) | ⚠️ Not recommended: access is as broad as that account's roles; never use a default compute account with Editor |

The bucket has uniform bucket-level access, public access prevention, and a lifecycle rule (`LIFECYCLE_DAYS`, default 16; deploy.sh uses 16 for prod, 7 for lab)
as a safety net behind Tempo's own retention.

## 🛡️ Security model

| Threat | Control | How it's enforced | Check |
|---|---|---|---|
| Leaked storage keys | No key files: Workload Identity only | `--workload-pool`, `GKE_METADATA` | `kubectl -n observability get sa tempo -o yaml` has no key Secret |
| Tempo reads other buckets | Role bound on the Tempo bucket only | `create-tempo-bucket.sh` (principal mode) | `gcloud storage buckets get-iam-policy gs://$TEMPO_BUCKET` |
| Public trace data | Public access prevention | `--public-access-prevention` | `gcloud storage buckets describe gs://$TEMPO_BUCKET` |
| Open Kubernetes API | Authorized networks | `--master-authorized-networks` | `gcloud container clusters describe ... --format='value(masterAuthorizedNetworksConfig)'` |
| Lateral movement | NetworkPolicies enforced | `--enable-dataplane-v2` | `scripts/verify.sh` NetworkPolicy check |
| Node exposure (prod) | Private nodes, egress through Cloud NAT only | `--enable-private-nodes`, `CREATE_NAT` | `kubectl get nodes -o wide` shows no `EXTERNAL-IP` |

Not protected here: node OS hardening beyond GKE defaults; the lab nodes have public IPs (no NAT, smaller quota); the
control plane keeps a public endpoint limited by authorized networks in both profiles.

## 🏭 Production checklist

- [ ] **HA sizing:** `PROFILE=prod` (regional, autoscaling 2-4 e2-standard-8 per zone = 48-96 vCPU); size from [../helm/tempo-distributed/README.md](../helm/tempo-distributed/README.md) (≈14 vCPU / 55 GiB requests for Tempo alone at HPA minimum, ~10 vCPU / 27 GiB more at HPA maximum, plus Kafka) and [../helm/README.md](../helm/README.md).
- [ ] **Private cluster:** `PROFILE=prod` sets private nodes + Cloud NAT; limit `AUTHORIZED_NETWORKS` to the ops network or a bastion.
- [ ] **Release channel and maintenance:** `regular` or `stable`; `PROFILE=prod` sets a weekend window and surge upgrades; add maintenance exclusions around release freezes.
- [ ] **Backups:** Tempo blocks live in GCS (enable object versioning or a retention lock if traces are evidence); Backup for GKE for PVCs (Prometheus, Alertmanager).
- [ ] **Cost:** regional control plane fee, nodes, GCS storage and operations, Kafka; set budgets and alerts in the billing account.
- [ ] **Separate node pools** for observability vs workloads if noisy neighbours appear; `pd-balanced` disks.
- [ ] **Bucket IAM:** `ACCESS_MODE=principal` only; audit with `gcloud storage buckets get-iam-policy`.

## 🧹 Teardown

`scripts/teardown.sh --cluster` removes the releases, asks before deleting the bucket, then asks before deleting the cluster.
With `PROFILE=prod` and `CREATE_NAT=true`, delete the Cloud Router (its NAT goes with it) after the cluster:
`gcloud compute routers delete tempo-demo-router --region="$REGION"` (use your `CLUSTER_NAME`).

## 🔗 References

- [GKE Workload Identity Federation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [GKE Dataplane V2](https://cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2)
- [Regional clusters](https://cloud.google.com/kubernetes-engine/docs/concepts/regional-clusters)
- [Tempo GCS backend](https://grafana.com/docs/tempo/latest/configuration/hosted-storage/gcs/)
