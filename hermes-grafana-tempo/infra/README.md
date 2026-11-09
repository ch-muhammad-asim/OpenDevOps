# ☁️ Infrastructure (GKE + GCS buckets)

Scripts that create the Google Cloud resources for hermes-grafana-tempo: the GKE cluster and the dedicated GCS buckets
(both profiles) that keep 30 days of Tempo trace blocks and Thanos metric blocks. All scripts are idempotent and read
settings from environment variables.

## 🧩 Files

| File | What it does (one line) | Security role |
|---|---|---|
| [create-cluster.sh](create-cluster.sh) | Enables the APIs, creates the GKE cluster (`PROFILE=lab` or `prod`; prod also a Cloud Router + Cloud NAT), fetches kubectl credentials | Workload Identity, Dataplane V2 (enforces NetworkPolicies), control plane limited to authorized networks; prod: private nodes, Shielded Nodes secure boot |
| [create-gcs-bucket.sh](create-gcs-bucket.sh) | Creates one dedicated bucket (uniform access, public access prevention, versioning off, lifecycle) and grants `ROLES` (default `roles/storage.objectUser`) to the given KSAs (`ACCESS_MODE=bucket`, `conditional` or `gsa`) | Keyless Workload Identity, access scoped to one bucket |
| [create-tempo-bucket.sh](create-tempo-bucket.sh) | Wrapper: bucket `tempo-traces-<project>` (`TEMPO_BUCKET`), KSA `observability/tempo`, roles `objectUser` + `bucketViewer`, lifecycle 33 days | Same as above |

## 📋 Prerequisites

- `gcloud` authenticated with rights to create GKE clusters, plus the bucket and IAM permissions of the chosen `ACCESS_MODE`.
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

## 🪣 GCS buckets (both profiles)

Both profiles keep 30 days of traces (Tempo) and metrics (Thanos) in two dedicated buckets per environment.
`scripts/deploy.sh` (`OBJECT_STORE=gcs`, the default) creates both; names come from `TEMPO_BUCKET` and `THANOS_BUCKET`
(lab: `tempo-traces-<suffix>`, `thanos-metrics-<suffix>`). In-cluster SeaweedFS
([`../helm/seaweedfs/`](../helm/seaweedfs/README.md)) is an optional fallback for clusters without cloud object storage.

| Bucket | Created by | KSAs granted | Roles | Lifecycle | Application retention |
|---|---|---|---|---|---|
| `tempo-traces-<project>` | `infra/create-tempo-bucket.sh` | `observability/tempo` | `roles/storage.objectUser` + `roles/storage.bucketViewer` | 33 days | Tempo `block_retention: 720h` |
| `thanos-metrics-<project>` | `infra/create-gcs-bucket.sh` (from `scripts/deploy.sh`) | `monitoring/prometheus-kube-prometheus-prometheus`, `monitoring/thanos-store`, `monitoring/thanos-compact` | `roles/storage.objectUser` | 35 days | Thanos compactor 30 days (+ 48h delete delay) |

Why `bucketViewer` for Tempo: its GCS backend reads the bucket attributes at start (`storage.buckets.get`), which
`objectUser` does not include; without it Tempo crash-loops with `403` `storage.buckets.get`.

```bash
infra/create-tempo-bucket.sh        # last two lines: bucket name, dedicated GSA email ("" unless ACCESS_MODE=gsa)
BUCKET=thanos-metrics-prod LIFECYCLE_DAYS=35 \
  KSAS="monitoring/prometheus-kube-prometheus-prometheus monitoring/thanos-store monitoring/thanos-compact" \
  infra/create-gcs-bucket.sh        # what deploy.sh runs for Thanos (bucket name defaults to thanos-metrics-<project>)
```

Expected on stderr: `gs://<bucket> ready: <roles> for [<KSAs>] via <mode>, lifecycle <N>d, versioning off`.

Every bucket: uniform bucket-level access, public access prevention, versioning off (blocks are rewritten by
compaction), and a lifecycle `Delete` rule (`LIFECYCLE_DAYS`, default 33) as a backstop behind the application's own
retention. Roles: `ROLES`, default `roles/storage.objectUser` (create, read, list, update, delete objects; no bucket
admin); every role gets the same scope. Never JSON keys.

| `ACCESS_MODE` | How access is granted | Needs | Use |
|---|---|---|---|
| `bucket` (default) | Each role bound **on the bucket** to the Workload Identity Federation principal of each KSA (`principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<PROJECT_ID>.svc.id.goog/subject/ns/<ns>/sa/<ksa>`) | `storage.buckets.getIamPolicy` + `setIamPolicy` | ✅ Production |
| `conditional` | Same roles bound at project level to each KSA principal, with an IAM condition limited to this bucket and its objects | `resourcemanager.projects.getIamPolicy` + `setIamPolicy` | ✅ Lab (live) |
| `gsa` | A **dedicated** Google service account (`GSA_NAME`, created by the script; never a default compute account) gets the role with the same bucket condition; each KSA impersonates it via `roles/iam.workloadIdentityUser` | `iam.serviceAccounts.create` + project IAM | When principal bindings are not possible. **Tempo only:** `scripts/deploy.sh` annotates the Tempo KSA and refuses `gsa` for the Thanos bucket (use `bucket` or `conditional`) |

| Variable | Default | Meaning |
|---|---|---|
| `BUCKET` / `TEMPO_BUCKET` | — / `tempo-traces-<project>` | Bucket name (`create-gcs-bucket.sh` requires `BUCKET`) |
| `KSAS` / `TEMPO_KSAS` | — / `observability/tempo` | Space-separated `<namespace>/<serviceaccount>` pairs |
| `ROLES` | `roles/storage.objectUser` (Tempo wrapper: `roles/storage.objectUser roles/storage.bucketViewer`) | Space-separated roles granted to each KSA |
| `LIFECYCLE_DAYS` | `33` (Thanos: `35`) | Delete-after-age backstop in days |
| `ACCESS_MODE` | `bucket` | `bucket`, `conditional` or `gsa` |
| `GSA_NAME` | `tempo-gcs` in the Tempo wrapper | Dedicated Google service account, `ACCESS_MODE=gsa` only |
| `PROJECT_ID`, `REGION` | current `gcloud` project, `us-central1` | Bucket project and location |

## 🛡️ Security model

| Threat | Control | How it's enforced | Check |
|---|---|---|---|
| Leaked storage keys | No key files: Workload Identity only | `--workload-pool`, `GKE_METADATA` | `kubectl -n observability get sa tempo -o yaml` has no key Secret |
| Tempo or Thanos reads other buckets | `roles/storage.objectUser` (Tempo also `roles/storage.bucketViewer`) bound on its own bucket only (or a condition limited to it) | `create-gcs-bucket.sh` | `bucket`: `gcloud storage buckets get-iam-policy gs://$BUCKET`; `conditional`: `gcloud projects get-iam-policy $PROJECT_ID` shows the `only-<bucket>` condition |
| Broad service account reused | No default compute account; `gsa` mode creates a dedicated one | `create-gcs-bucket.sh` | `gcloud iam service-accounts list` |
| Public trace or metric data | Public access prevention, uniform bucket-level access | `--public-access-prevention`, `--uniform-bucket-level-access` | `gcloud storage buckets describe gs://$BUCKET` |
| Open Kubernetes API | Authorized networks | `--master-authorized-networks` | `gcloud container clusters describe ... --format='value(masterAuthorizedNetworksConfig)'` |
| Lateral movement | NetworkPolicies enforced | `--enable-dataplane-v2` | `scripts/verify.sh` NetworkPolicy check |
| Node exposure (prod) | Private nodes, egress through Cloud NAT only | `--enable-private-nodes`, `CREATE_NAT` | `kubectl get nodes -o wide` shows no `EXTERNAL-IP` |

Not protected here: node OS hardening beyond GKE defaults; the lab nodes have public IPs (no NAT, smaller quota); the
control plane keeps a public endpoint limited by authorized networks in both profiles.

## 🏭 Production checklist

- [ ] **HA sizing:** `PROFILE=prod` (regional, autoscaling 2-4 e2-standard-8 per zone = 48-96 vCPU); size from [../helm/tempo-distributed/README.md](../helm/tempo-distributed/README.md) (≈14 vCPU / 55 GiB requests for Tempo alone at HPA minimum, ~10 vCPU / 27 GiB more at HPA maximum, plus Kafka) and [../helm/README.md](../helm/README.md).
- [ ] **Private cluster:** `PROFILE=prod` sets private nodes + Cloud NAT; limit `AUTHORIZED_NETWORKS` to the ops network or a bastion.
- [ ] **Release channel and maintenance:** `regular` or `stable`; `PROFILE=prod` sets a weekend window and surge upgrades; add maintenance exclusions around release freezes.
- [ ] **Backups:** GCS is the system of record for traces and metrics history; versioning off by design; GCS soft delete (default 7 days) covers accidental deletes; Bucket Lock or a retention policy only if compliance requires it.
- [ ] **Bucket lifecycle:** traces 33 days, metrics 35 days, always above the application retention (720h / 30 days).
- [ ] **Cost:** regional control plane fee, nodes, GCS storage and operations (traces ~31 GB ≈ $0.62/month at the measured lab ingest; Thanos ~$8.50–$11.80/month incl. PVCs), Kafka; set budgets and alerts in the billing account.
- [ ] **Access logs:** enable Cloud Audit Logs **Data Access** (`DATA_READ`, `DATA_WRITE`) for Cloud Storage to record every object read and write by principal.
- [ ] **Separate node pools** for observability vs workloads if noisy neighbours appear; `pd-balanced` disks.
- [ ] **Bucket IAM:** `ACCESS_MODE=bucket` preferred; audit with `gcloud storage buckets get-iam-policy`.

## 🧹 Teardown

`scripts/teardown.sh --cluster` removes the releases, asks before deleting each bucket (`TEMPO_BUCKET`, `THANOS_BUCKET`;
irreversible), then asks for the cluster name before deleting the cluster. IAM bindings are left in place; remove them
if unused.
With `PROFILE=prod` and `CREATE_NAT=true`, delete the Cloud Router (its NAT goes with it) after the cluster:
`gcloud compute routers delete tempo-demo-router --region="$REGION"` (use your `CLUSTER_NAME`).

## 🔗 References

- [GKE Workload Identity Federation](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [GKE Dataplane V2](https://cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2)
- [Regional clusters](https://cloud.google.com/kubernetes-engine/docs/concepts/regional-clusters)
- [Tempo GCS backend](https://grafana.com/docs/tempo/latest/configuration/hosted-storage/gcs/)
- [Cloud Storage IAM roles](https://cloud.google.com/storage/docs/access-control/iam-roles) · [Soft delete](https://cloud.google.com/storage/docs/soft-delete) · [Object lifecycle](https://cloud.google.com/storage/docs/lifecycle)
