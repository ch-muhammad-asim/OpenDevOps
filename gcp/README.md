# ☁️ GCP Custom VPC + GKE Deployment (gcloud CLI)

Single-subnet custom VPC + a **public, zonal, cost-optimized** GKE cluster sized to fit the GCP cloud lab sandbox quotas (≈8 vCPU per region). Provisioned entirely with the `gcloud` CLI.

## 🏗️ Architecture

| Component | Name | CIDR / Config | Purpose |
|-----------|------|---------------|---------|
| VPC | custom-vpc | custom subnet mode | Isolated network |
| Subnet | gke-subnet | 10.10.0.0/24 (+ auto pod/service ranges) | GKE nodes, internet-facing |
| GKE | gke-cluster | **zonal**, `e2-medium` **on-demand** ×3, 100 GB pd-standard | Kubernetes workloads (public endpoint + Workload Identity) |

### GKE Cluster Details

| Property | Value | Why |
|----------|-------|-----|
| Cluster name | `gke-cluster` | |
| Location | **Zonal** (`us-central1-a`) | Regional spreads nodes ×3 zones → busts the 8-vCPU sandbox quota |
| Machine type | `e2-medium` (2 vCPU, 4 GB) | 3 nodes × 2 vCPU = 6 vCPU, under the 8-vCPU quota |
| Node count | **3** (static pool) | Always exactly 3 nodes |
| Provisioning | **On-demand** | Reliable (no preemption); the sandbox is time-boxed (~4 h) so cost is moot |
| Boot disk | 100 GB `pd-standard` | GKE default disk type and size |
| Release channel | `regular` | Keeps auto-upgrade managed (don't disable it) |
| Workload Identity | Enabled (`GKE_METADATA`) | Lets in-cluster services auth to Google APIs without node keys |
| Master access | Public (`0.0.0.0/0`) | Sandbox convenience; lock to your IP for anything real |
| IP aliasing | Enabled | VPC-native cluster |

> **Sandbox quotas:** ≈8 vCPU/region, max 6 nodes, 2 node pools, 2 clusters. Cloud Build is also throttled (~3 invocations) — build images locally with `docker build` instead of `gcloud builds submit`.

> **What changed vs. the old config:** dropped the unused private/database subnets + Cloud Router + Cloud NAT (the cluster only ever used one subnet, and public nodes egress via their own external IPs — no NAT needed); shrank `e2-standard-4` regional ×3 (**12 vCPU, fails to create**) down to `e2-medium` zonal on-demand ×3 (**6 vCPU**); added Workload Identity.

## ✅ Prerequisites

- gcloud CLI installed and authenticated (`gcloud auth login`)
- The sandbox's **real** project ID (the pre-filled one is often stale):

```bash
gcloud projects list
gcloud config set project <YOUR_REAL_PROJECT_ID>
```

## 🚀 Deploy

### ⚡ One command (recommended)

[`gcp-infra.sh`](gcp-infra.sh) runs every step below in order — APIs, VPC, subnet, both firewall rules,
the cluster, and `get-credentials` — then verifies Workload Identity and prints the nodes:

```bash
./gcp-infra.sh --project <YOUR_REAL_PROJECT_ID>

./gcp-infra.sh --dry-run --project <id>   # print the exact gcloud commands, change nothing
./gcp-infra.sh --help                     # all flags
```

It is **idempotent** — each step checks whether the resource exists first, so a re-run after a partial
failure continues instead of erroring out. Every value is overridable
(`--zone`, `--machine-type`, `--num-nodes`, `--master-networks`, …), and it warns if your node count ×
machine type would exceed the ~8 vCPU sandbox quota.

> 🔒 The default `--master-networks 0.0.0.0/0` is sandbox convenience. For anything real, pass your own
> CIDR: `./gcp-infra.sh --project <id> --master-networks "$(curl -s ifconfig.me)/32"`.

### 🛡️ Hermes + NVIDIA OpenShell on GKE (cloud lab sandbox)

For the guarded Hermes deployment ([`../sandbox/k8s/README.md` → Part 1](../sandbox/k8s/README.md#️-part-1-hermes-in-nvidia-openshell-on-gke-live-lab-deployment)), the same script takes four extra options, with defaults that keep the cluster above unchanged:

| Option / variable | Purpose |
|---|---|
| `--image-type UBUNTU_CONTAINERD` | Ubuntu nodes: OpenShell needs **Landlock**, which the COS kernel does not have (tested on COS 125 / GKE 1.35.8: `landlock_create_ruleset` → `ENOSYS`; see [Node image](../sandbox/k8s/README.md#-node-image-ubuntu-not-cos-tested-2026-11-01)) |
| `--dataplane-v2` | GKE Dataplane V2 (Cilium), so NetworkPolicies are enforced; creation time only |
| `--system-config-from-file ../sandbox/k8s/gke/node-system-config.yaml` | kubelet `podPidsLimit: 2048` |
| `--no-ssh-iap` | Skip the SSH-from-IAP firewall rule (cloud lab sandboxes do not support IAP) |
| `RELEASE_CHANNEL=stable CLUSTER_VERSION=1.35.8-gke.1796000` | Pin a GKE version (must be valid in that channel; `gcloud container get-server-config --zone <zone>` lists them) |
| `GCP_APIS="container.googleapis.com artifactregistry.googleapis.com"` | Enable only these APIs (default list also enables compute and iamcredentials) |

```bash
CLUSTER_NAME=hermes-gke ZONE=us-central1-b MACHINE_TYPE=e2-standard-2 NUM_NODES=2 DISK_TYPE=pd-balanced DISK_SIZE=30 \
MASTER_AUTHORIZED_NETWORKS="$(curl -s https://checkip.amazonaws.com)/32" \
GCP_APIS="container.googleapis.com artifactregistry.googleapis.com" \
./gcp-infra.sh --project <id> --image-type UBUNTU_CONTAINERD --dataplane-v2 --no-ssh-iap \
  --system-config-from-file ../sandbox/k8s/gke/node-system-config.yaml
```

> ⚠️ **Lab sandbox limits:** 8 GB memory per instance, about 12 vCPU in total, 10 instances, no Autopilot, and a machine-type allowlist (`e2-standard-4` and larger were denied). A 32 GiB instance got a sandbox shut down for "misuse". Use `e2-standard-2` and read [Lab limits](../sandbox/k8s/README.md#️-lab-limits-gcp-cloud-lab-sandbox-read-before-creating-anything) first. Never create test VMs to find limits.

The manual steps below are what the script automates — useful for understanding or cherry-picking.

### 1. Set Variables

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-central1"
export ZONE="us-central1-a"
export VPC_NAME="custom-vpc"
export SUBNET_NAME="gke-subnet"
export SUBNET_RANGE="10.10.0.0/24"
export CLUSTER_NAME="gke-cluster"
export WORKLOAD_POOL="${PROJECT_ID}.svc.id.goog"
```

### 2. Enable APIs

```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  iamcredentials.googleapis.com \
  --project=$PROJECT_ID
```

### 3. Create Custom VPC + Subnet

```bash
gcloud compute networks create $VPC_NAME \
  --project=$PROJECT_ID \
  --subnet-mode=custom \
  --bgp-routing-mode=regional

gcloud compute networks subnets create $SUBNET_NAME \
  --project=$PROJECT_ID \
  --region=$REGION \
  --network=$VPC_NAME \
  --range=$SUBNET_RANGE \
  --enable-private-ip-google-access
```

### 4. Create Firewall Rules

```bash
# Allow internal communication within the VPC
gcloud compute firewall-rules create ${VPC_NAME}-allow-internal \
  --project=$PROJECT_ID \
  --network=$VPC_NAME \
  --allow=tcp,udp,icmp \
  --source-ranges=$SUBNET_RANGE \
  --priority=1000

# Allow SSH only from Google IAP (no public 0.0.0.0/0 SSH)
gcloud compute firewall-rules create ${VPC_NAME}-allow-ssh-iap \
  --project=$PROJECT_ID \
  --network=$VPC_NAME \
  --allow=tcp:22 \
  --source-ranges=35.235.240.0/20 \
  --priority=1000
```

> GKE auto-manages firewall rules for LoadBalancer services and health checks, so you don't need to pre-open 80/443 yourself.

### 5. Create the Cost-Optimized GKE Cluster

```bash
gcloud container clusters create $CLUSTER_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE \
  --network=$VPC_NAME \
  --subnetwork=$SUBNET_NAME \
  --release-channel=regular \
  --machine-type=e2-medium \
  --num-nodes=3 \
  --disk-type=pd-standard \
  --disk-size=100 \
  --enable-ip-alias \
  --workload-pool=$WORKLOAD_POOL \
  --workload-metadata=GKE_METADATA \
  --enable-master-authorized-networks \
  --master-authorized-networks=0.0.0.0/0
```

> **Note:** a static, on-demand 3-node pool (no autoscaling, no Spot) so you always have exactly 3 nodes with no preemption. The sandbox auto-expires (~4 h), so on-demand pricing is a non-issue.

### 6. Get Cluster Credentials

```bash
gcloud container clusters get-credentials $CLUSTER_NAME \
  --project=$PROJECT_ID \
  --zone=$ZONE
```

## 🔍 Verify

```bash
gcloud compute networks list --project=$PROJECT_ID
gcloud compute networks subnets list --project=$PROJECT_ID
gcloud compute firewall-rules list --project=$PROJECT_ID
gcloud container clusters list --project=$PROJECT_ID

# Confirm Workload Identity is on
gcloud container clusters describe $CLUSTER_NAME \
  --zone=$ZONE --project=$PROJECT_ID \
  --format='yaml(workloadIdentityConfig)'

kubectl get nodes
kubectl cluster-info
```

## 🔗 Connect to GKE

```bash
gcloud container clusters get-credentials $CLUSTER_NAME --project=$PROJECT_ID --zone=$ZONE
kubectl get namespaces
kubectl run test --image=nginx --rm -it -- /bin/bash
```

## 🧹 Teardown

No manual cleanup needed — the GCP lab sandbox auto-shuts down and wipes the entire project (~4 h after launch; see the "Auto Shutdown" time in the sandbox UI).

## 🔐 Hermes dashboard credentials (GKE)

Hermes on GKE uses two login layers (Traefik basic auth, then Hermes's own login) with GKE-only credentials kept in `~/.config/hermes-sandbox/gke/` (folder `700`, files `600`), never in Kubernetes output or git:

- **How to log in, where each password lives, and how to rotate them:** [`../sandbox/k8s/README.md` → How to log in (two layers)](../sandbox/k8s/README.md#-how-to-log-in-two-layers).
- **Creating the credentials from scratch:** [Build it, step 3](../sandbox/k8s/README.md#-build-it-step-by-step).
- **Every Kubernetes Secret, what uses it and how to rotate it:** [Kubernetes Secrets](../sandbox/k8s/README.md#-kubernetes-secrets).

> Never print a Secret's value (`kubectl get secret … -o jsonpath | base64 -d`) or put a password on a command line (`--from-literal`, `echo`); create Secrets from files or stdin as those sections show. The password hash must be made with the Hermes image (scrypt).

## 📌 Project

- **Project ID:** your-gcp-project-id
- **Region/Zone:** us-central1 / us-central1-a
