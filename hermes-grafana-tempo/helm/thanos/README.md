# 🗄️ Thanos (30-day metrics on object storage, both profiles)

Thanos query, store gateway and compactor as plain Kubernetes manifests, plus the Thanos sidecar inside the Prometheus
pods (set in [`../kube-prometheus-stack/values.yaml`](../kube-prometheus-stack/values.yaml)). **Why:** Prometheus keeps
only 2 days on its disk; every 2-hour block goes to an object-storage bucket, and Grafana (and anything else that
speaks PromQL) reads 30 days of history through one endpoint, `http://thanos-query.monitoring:10902`, with the HA
Prometheus pair deduplicated and long ranges served from downsampled blocks. Both profiles store the blocks in a GCS
bucket reached keylessly through GKE Workload Identity. In-cluster SeaweedFS S3
([`../seaweedfs/`](../seaweedfs/README.md), `OBJECT_STORE=seaweedfs`) is an optional fallback for clusters without
cloud object storage.

**Cost:** All software is free and open source (Thanos, Prometheus: Apache-2.0; Tempo, Grafana: AGPL-3.0).
Only GCS storage/operations and persistent disks are billed.

**Status (2026-11-08, Thanos v0.42.5, kube-prometheus-stack 93.1.0):** ✅ **lab live on GCS** with Workload Identity
(bucket `thanos-metrics-<suffix>`, Secret `thanos-objstore` = `type: GCS` + bucket name, no key); sidecar, store gateway
and compactor reach GCS on 443; `PROFILE=lab scripts/verify.sh` VERIFY_COUNT PASS, 0 failures. **Production** (HA
sizing) is rendered and validated only: `kubectl kustomize` of [`kustomization.yaml`](kustomization.yaml) and
[`overlays/lab/`](overlays/lab/kustomization.yaml) + kubeconform strict (Kubernetes 1.36), `helm lint` / `helm template`
of kube-prometheus-stack and Grafana, `promtool check rules`. Earlier lab runs on SeaweedFS S3 are recorded in
[`../seaweedfs/`](../seaweedfs/README.md).

## 🏗️ Architecture

| Flow | From → to | Port / protocol |
|---|---|---|
| Recent data (last ~2 days, not yet uploaded) | thanos-query → Thanos sidecar in each Prometheus pod | 10901 gRPC (StoreAPI) |
| History (everything in the bucket) | thanos-query → thanos-store (prod 2, lab 1) | 10901 gRPC (StoreAPI) |
| Upload | Thanos sidecar → bucket (one 2h block per Prometheus replica every 2h) | GCS 443 HTTPS + Workload Identity (both profiles); fallback `seaweedfs.object-storage:8333` S3 (plain HTTP, in-cluster) |
| Compaction, downsampling, retention | thanos-compact (singleton) ↔ bucket | Same as upload |
| Reads | thanos-store → bucket (index-headers cached on its PVC) | Same as upload |
| Dashboards | Grafana data source uid `prometheus` → thanos-query | 10902 HTTP (PromQL API) |
| Metrics | Prometheus → every Thanos component | 10902 HTTP `/metrics` |

Prometheus itself is unchanged for writers: scrapes, the Tempo metrics-generator remote write and the Hermes remote
write still go to `prometheus-kube-prometheus-prometheus:9090`, and alert rules are still evaluated by Prometheus.

## 🧩 Components

| Name | What it does (one line) | Where defined | Security role |
|---|---|---|---|
| Thanos sidecar (container in `prometheus-*` pods) | Uploads each 2h TSDB block to the bucket; serves recent data over gRPC | [`../kube-prometheus-stack/values.yaml`](../kube-prometheus-stack/values.yaml) `prometheusSpec.thanos` (lab requests in `values-lab.yaml`) | KSA `prometheus-kube-prometheus-prometheus` with `objectUser` on the bucket (fallback: S3 key in the Secret) |
| Service `prometheus-kube-prometheus-thanos-discovery` | Headless; DNS SRV for the sidecars (gRPC 10901, HTTP 10902) | same file, `prometheus.thanosService` | ClusterIP None, in-cluster only |
| Deployment `thanos-query` (prod 2, lab 1) | PromQL API for Grafana; fans out, deduplicates on `prometheus_replica` | [`base/query.yaml`](base/query.yaml) | No bucket access, no SA token |
| StatefulSet `thanos-store` (prod 2, lab 1) | Serves all bucket blocks; index-header cache on a PVC (prod 10Gi, lab 5Gi) | [`base/store.yaml`](base/store.yaml) | Reads the bucket (KSA `thanos-store`; fallback: S3 key) |
| StatefulSet `thanos-compact` (1) | Compacts, downsamples (5m, 1h), deletes blocks older than 30 days | [`base/compact.yaml`](base/compact.yaml) | The only deleter (KSA `thanos-compact`; fallback: S3 key) |
| ServiceAccounts | Fixed names = Workload Identity principals | [`base/serviceaccounts.yaml`](base/serviceaccounts.yaml) | `automountServiceAccountToken: false` |
| ServiceMonitors (3) + sidecar ServiceMonitor | Prometheus scrapes every Thanos component | [`base/servicemonitors.yaml`](base/servicemonitors.yaml), kps `thanosServiceMonitor` | — |
| PrometheusRule `thanos` (19 alerts) | Upload failures, compactor halted, store/query errors, components absent | [`base/prometheusrule.yaml`](base/prometheusrule.yaml) | Read-only rules |
| NetworkPolicies (4) | Ingress allows on top of the `monitoring` default-deny | [`base/networkpolicies.yaml`](base/networkpolicies.yaml) | Least-privilege ports |
| Production entry point | `kubectl apply -k helm/thanos` = `base/` unchanged | [`kustomization.yaml`](kustomization.yaml) | — |
| Lab overlay | 1 replica each, small requests, no PDBs, smaller PVCs and caches | [`overlays/lab/`](overlays/lab/kustomization.yaml) | Same security settings as production |
| Secret `thanos-objstore` (not in Git) | `objstore.yml`: `type: GCS` + bucket name, no key (fallback: `type: S3` + SeaweedFS endpoint and access key) | created by `scripts/deploy.sh` | Read by sidecar, store, compactor |

## 🤔 Why Thanos

Requirement: 30 days of metrics, PromQL for Grafana and Hermes, free and open source software only, no keys in Git.

| | **Thanos (chosen)** | Grafana Mimir 3 | Prometheus local 30d on a PVC |
|---|---|---|---|
| License | Apache-2.0 | AGPL-3.0 | Apache-2.0 |
| Components | 4: sidecar, query, store gateway, compactor (3 Deployments/StatefulSets here + a container in Prometheus) | 7 required: distributor, ingester, querier, query-frontend, query-scheduler, store-gateway, compactor ([components](https://grafana.com/docs/mimir/latest/references/architecture/components/)); one binary with `-target=all` is for getting started, microservices are recommended for production ([deployment modes](https://grafana.com/docs/mimir/latest/references/architecture/deployment-modes/)) | 0 extra |
| Extra infrastructure | Object storage only | Object storage, plus Kafka in the ingest storage architecture, which is the preferred architecture from Mimir 3.0 ([architecture](https://grafana.com/docs/mimir/latest/get-started/about-grafana-mimir-architecture/)) | None |
| Minimum footprint | Lab: 110m CPU / 608Mi requests in total (below); Prometheus unchanged | Not measured here; at least the 7 components (plus Kafka in the preferred architecture), Prometheus remote-writes to it | Prometheus only |
| Write path | Prometheus unchanged; the sidecar uploads finished blocks | Prometheus remote-writes every sample to Mimir | Unchanged |
| Retention / downsampling | 30 days; 5m and 1h downsampled blocks | 30 days; no downsampling | 30 days raw, bounded by the PVC |
| Survives losing the cluster | Yes (GCS bucket, both profiles) | Same, depends on the object store | No |

Thanos keeps PromQL, Grafana, the existing alert rules and the remote-write receiver exactly as they are and adds the
fewest moving parts: no change to the write path, no queue. Mimir is the stronger choice for multi-tenant, very high
ingest; at 3,429 samples/s it is more to run for the same result. Google Cloud Managed Service for Prometheus was
rejected because it is a paid service (list price ~$533/month at the measured ingest,
[pricing](https://cloud.google.com/stackdriver/pricing)). Local 30-day retention does not survive the cluster.

## 📐 Sizing and cost

Measured on the lab cluster (2026-11-08, 1h rates, synthetic load plus Hermes): **3,429 samples/s**
(`rate(prometheus_tsdb_head_samples_appended_total[1h])`), **150,952 head series**.

| Quantity | Formula | Result |
|---|---|---|
| Samples per 30 days, one Prometheus replica | 3,429 × 2,592,000 s | **8.89 billion** |
| Same, HA pair (both replicas upload, bucket not deduplicated) | × 2 | 17.8 billion |
| Raw bytes per sample (assumption) | Prometheus TSDB with Gorilla compression | **1.3–2 B** |
| Raw blocks, one replica (lab) | 8.89e9 × 1.3–2 B, + ~10% index | **12.7–19.6 GB** |
| Raw blocks, HA pair (prod) | × 2 | **25–39 GB** |
| Downsampled blocks (5m, 1h) | Thanos docs: up to ~3× total; with 30d retention 5m covers ~28 of 30 days and 1h ~20 of 30 | ≤ 2.6× raw |
| **Bucket steady state** | | Prod **25–102 GB** (plan ~100 GB); lab **13–51 GB** |
| Local TSDB per Prometheus pod | 2 days × 3,429 × 1.3–2 B + WAL | ~1–2 GB (prod 100Gi PVC / 85GiB cap; lab 40Gi / 8GiB cap) |
| Compactor scratch | 2 × one replica's 14-day block (Thanos docs rule) | ~11–17 GB at this ingest (prod 50Gi PVC, lab 20Gi) |

### Production (GCS)

**GCS Standard, us-central1, list prices on 2026-11-08** ([Cloud Storage pricing](https://cloud.google.com/storage/pricing)):
storage **$0.020 per GB-month**, Class A operations **$0.005 per 1,000**, Class B operations **$0.0004 per 1,000**
(regional bucket, flat namespace), no egress charge inside the region.

| Cost item (per month) | Estimate | Assumption |
|---|---|---|
| Bucket storage | **$0.50–$2.05** | 25–102 GB × $0.020 |
| Class A operations (uploads, compactor writes, bucket listings) | ~$0.25 | ~50,000/month: 2 sidecars × 12 blocks/day × ~4 objects, compactor rewrites, compactor (5m) and store (15m) syncs |
| Class B operations (reads) | $0.40–$2.00 | 1–5 million GETs, driven by dashboard and Hermes trend queries |
| Soft-deleted bytes (if bucket soft delete stays at the 7-day default) | ~$0.35–$0.55 | Compaction deletes ~3× the raw volume per month, kept 7 days |
| PVCs: store 2 × 10Gi + compactor 50Gi, pd-balanced | $7.00 | $0.10 per GiB-month (below) |
| **Total, excluding node capacity** | **~$8.50–$11.80** | Node capacity: 1.35 vCPU / 5.5 GiB requests (query 2 × 250m/1Gi, store 2 × 250m/1Gi, compactor 250m/1Gi, sidecars 2 × 50m/256Mi) |

### Lab (GCS + persistent disks)

**pd-balanced, us-central1, list price on 2026-11-08:** $0.000136986 per GiB-hour = **$0.10 per GiB-month**
([Disk and image pricing](https://cloud.google.com/compute/disks-image-pricing), "Balanced provisioned space").

| Disk (pd-balanced, `standard-rwo`) | Size | Per month |
|---|---|---|
| Prometheus TSDB (unchanged; a PVC cannot shrink) | 40Gi | $4.00 |
| thanos-store index-header cache | 5Gi | $0.50 |
| thanos-compact scratch | 20Gi | $2.00 |
| **Total** | **65Gi** | **$6.50** |

Whole lab, adding the Tempo 50Gi (now mostly WAL), Grafana 1Gi and Hermes 10Gi PVCs: **126Gi ≈ $12.60/month**.

The lab bucket `thanos-metrics-<suffix>` is billed at the GCS prices above. Estimate from the same assumptions as
production, one sidecar instead of two (not measured):

| Cost item (per month) | Estimate | Assumption |
|---|---|---|
| Bucket storage | $0.26–$1.02 | 13–51 GB × $0.020 |
| Class A operations | ~$0.13 | ~25,000/month: half the production uploads (one sidecar) |
| Class B operations | $0.40–$2.00 | Same query-driven range as production |
| Soft-deleted bytes (7-day default) | ~$0.18–$0.28 | Half the production volume |
| **Total, Thanos bucket** | **~$1.00–$3.45** | Plus the Tempo bucket `tempo-traces-<suffix>`: ~$0.62/month storage for ~31 GB, operations not measured ([`../tempo/`](../tempo/README.md#-retention-and-sizing)) |

Lab requests (Thanos part): query 25m / 96Mi, store 25m / 192Mi, compactor 50m / 256Mi, sidecar 10m / 64Mi =
**110m CPU / 608Mi** (memory limits 192Mi / 384Mi / 512Mi / 256Mi). Node capacity is the existing 3 x e2-standard-2.

## ⚖️ Lab vs production

| Setting | Production (`kubectl apply -k helm/thanos`) | Lab (`kubectl apply -k helm/thanos/overlays/lab`) |
|---|---|---|
| Object store | GCS bucket `thanos-metrics-<project>` (`THANOS_BUCKET`), Workload Identity, no keys, `ACCESS_MODE=bucket` | Same, bucket `thanos-metrics-<suffix>`, `ACCESS_MODE=conditional` |
| Secret `monitoring/thanos-objstore` (key `objstore.yml`) | `type: GCS` + bucket name | Same |
| Prometheus local retention | `2d` / `85GiB` cap, 100Gi PVC, `disableCompaction: true` | `2d` / `8GiB` cap, 40Gi PVC, `disableCompaction: true` |
| Prometheus replicas (sidecars) | 2 (HA pair, deduplicated in thanos-query) | 1 |
| thanos-query | 2 replicas, 250m / 1Gi (4Gi limit), PDB, `max-concurrent=20` | 1, 25m / 96Mi (192Mi), no PDB, `max-concurrent=4` |
| thanos-store | 2 replicas, 250m / 1Gi (4Gi), PDB, 10Gi PVC, index cache 512MB, chunk pool 1GB | 1, 25m / 192Mi (384Mi), no PDB, 5Gi PVC, in-memory index cache 64MB (`--index-cache.config`, max item 16MB), chunk pool 128MB |
| thanos-compact | 1, 250m / 1Gi (3Gi), 50Gi PVC | 1, 50m / 256Mi (512Mi), 20Gi PVC |
| Retention / downsampling | 30 days raw, 5m and 1h | Same |
| Grafana `prometheus` data source | `http://thanos-query.monitoring:10902` | Same |
| Survives losing the cluster | Yes (bucket) | Same |
| Why different | — | The lab is 3 x e2-standard-2: sizing and replicas only |

## 🚀 Install (production)

Run from the repository root, in this order. `scripts/deploy.sh prometheus` (`PROFILE=prod`) runs steps 1–4.

1. Create the bucket and grant the three Kubernetes service accounts access to it (no keys; why: least privilege on
   one bucket):

   ```bash
   BUCKET="thanos-metrics-$PROJECT_ID" LIFECYCLE_DAYS=35 \
   KSAS="monitoring/prometheus-kube-prometheus-prometheus monitoring/thanos-store monitoring/thanos-compact" \
     infra/create-gcs-bucket.sh
   ```

   Expected: `gs://thanos-metrics-$PROJECT_ID ready: roles/storage.objectUser for [...]`.

2. Create the object-store Secret (why: the sidecar, store gateway and compactor all read it; it holds only the bucket
   name, credentials come from Workload Identity):

   ```bash
   kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
   printf 'type: GCS\nconfig:\n  bucket: %s\n' "thanos-metrics-$PROJECT_ID" > /tmp/objstore.yml
   kubectl -n monitoring create secret generic thanos-objstore --from-file=objstore.yml=/tmp/objstore.yml \
     --dry-run=client -o yaml | kubectl apply -f -
   rm /tmp/objstore.yml
   ```

3. Install or upgrade kube-prometheus-stack with the production values (why: adds the sidecar, the discovery Service and
   the 2-day local retention). The Secret from step 2 must exist first, or the Prometheus pods stay in
   `CreateContainerConfigError`:

   ```bash
   helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version 93.1.0 \
     --namespace monitoring -f helm/kube-prometheus-stack/values.yaml
   ```

4. Deploy query, store gateway, compactor, monitors, rules and NetworkPolicies:

   ```bash
   kubectl apply -k helm/thanos
   ```

5. Install or upgrade Grafana with the production values (why: data source uid `prometheus` points at thanos-query;
   dashboards keep working because the uid is unchanged):

   ```bash
   helm upgrade --install grafana grafana-community/grafana --version 14.4.0 \
     --namespace observability -f helm/grafana/values.yaml
   ```

## 🧪 Install (lab)

`PROFILE=lab ACCESS_MODE=conditional THANOS_BUCKET=thanos-metrics-<suffix> scripts/deploy.sh prometheus` does all of
this in order (object store `gcs` is the default for both profiles). By hand:

1. Bucket and IAM: production step 1 with `BUCKET=thanos-metrics-<suffix> ACCESS_MODE=conditional` (why: the lab binds
   at project level with an IAM condition limited to this bucket and its objects).
2. Secret `monitoring/thanos-objstore`: production step 2 with the lab bucket name (no key).
3. kube-prometheus-stack with the lab overlay (why: turns on the sidecar and the 2-day local retention):

   ```bash
   helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --version 93.1.0 \
     --namespace monitoring -f helm/kube-prometheus-stack/values.yaml -f helm/kube-prometheus-stack/values-lab.yaml
   ```

4. Thanos lab overlay:

   ```bash
   kubectl apply -k helm/thanos/overlays/lab
   ```

5. Grafana with the lab overlay (data source now `thanos-query:10902`):

   ```bash
   helm upgrade --install grafana grafana-community/grafana --version 14.4.0 \
     --namespace observability -f helm/grafana/values.yaml -f helm/grafana/values-lab.yaml
   ```

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| Pods ready | `kubectl -n monitoring get pods -l 'app.kubernetes.io/name in (thanos-query,thanos-store,thanos-compact)'` | Prod 2 + 2 + 1, lab 1 + 1 + 1 Running |
| Sidecar present | `kubectl -n monitoring get pod prometheus-prometheus-kube-prometheus-prometheus-0 -o jsonpath='{.spec.containers[*].name}'` | Includes `thanos-sidecar` |
| Local compaction off | same pod, `-o yaml \| grep block-duration` | `--storage.tsdb.min-block-duration=2h` and `--storage.tsdb.max-block-duration=2h` |
| Stores discovered | `kubectl -n monitoring port-forward svc/thanos-query 10902` then `curl -s localhost:10902/api/v1/stores` | Prod 2 `sidecar` + 2 `store`; lab 1 + 1 |
| First upload (after ≤ 2–3h) | `kubectl -n monitoring exec thanos-store-0 -- thanos tools bucket ls --objstore.config-file=/etc/thanos/objstore/objstore.yml` | Block ULIDs (works for GCS and S3) |
| Uploads healthy | PromQL `thanos_shipper_uploads_total` rising, `thanos_shipper_upload_failures_total` flat | — |
| Dedup works (prod) | PromQL `count(up)` via thanos-query vs via Prometheus 9090 | Equal (not doubled) |
| Grafana | Explore → Prometheus → `up` over 30 days | Data older than 2 days once the bucket has it |
| Scraped | PromQL `up{job=~"thanos-.*\|prometheus-kube-prometheus-thanos-discovery"}` | All `1` |

## 🔐 IAM and security

**IAM (both profiles):** `roles/storage.objectUser` (create, read, list, update, delete objects; no bucket admin) granted
**on the Thanos bucket only** to three Workload Identity Federation principals, created by
[`../../infra/create-gcs-bucket.sh`](../../infra/create-gcs-bucket.sh):
`principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<PROJECT_ID>.svc.id.goog/subject/ns/monitoring/sa/<KSA>`
for `<KSA>` = `prometheus-kube-prometheus-prometheus` (sidecar), `thanos-store`, `thanos-compact`. thanos-query has no
bucket access. No service account keys, no default compute service account. The store gateway only needs read access;
a custom read-only role (`storage.objects.get`, `storage.objects.list`) is a further tightening if wanted.
Production binds on the bucket (`ACCESS_MODE=bucket`, the script default); the lab uses `ACCESS_MODE=conditional`
(project-level binding with an IAM condition limited to the bucket and its objects).

**Fallback access (`OBJECT_STORE=seaweedfs`):** one SeaweedFS S3 identity `thanos` with read/write/list on bucket
`thanos-metrics` only; the key is generated at deploy time into Secret `monitoring/thanos-objstore`.

| Threat | Control | How it's enforced | Test that proves it |
|---|---|---|---|
| Leaked storage credentials | No keys; KSA principals scoped to one bucket | `objstore.yml` has no `service_account`; bucket-level or bucket-conditioned binding | `kubectl get secret thanos-objstore -o jsonpath='{.data.objstore\.yml}' \| base64 -d` shows bucket only |
| Leaked storage credentials (SeaweedFS fallback) | Static S3 key, scoped to one bucket, only in a Secret | Generated by `scripts/deploy.sh`, never printed or committed | Key works on `thanos-metrics`, is denied on `tempo-traces` |
| S3 traffic sniffed (SeaweedFS fallback) | **Not protected**: plain HTTP inside the cluster | Pod network only, no external exposure | — |
| Unauthenticated PromQL/StoreAPI in-cluster | **Not protected** by auth or mTLS (Thanos has none built in) | NetworkPolicies: only Grafana and Prometheus → 10902, only thanos-query → 10901 | `kubectl -n monitoring get networkpolicy thanos-query-ingress -o yaml` |
| Public exposure | ClusterIP / headless Services only | No Ingress, no `thanosServiceExternal` | `kubectl -n monitoring get svc -l app.kubernetes.io/part-of=thanos` |
| Two compactors corrupting the bucket | StatefulSet with 1 replica, `OrderedReady`; alert `ThanosCompactMultipleRunning` | [`base/compact.yaml`](base/compact.yaml), [`base/prometheusrule.yaml`](base/prometheusrule.yaml) | `promtool check rules` |
| Container privilege | PSS restricted: non-root 1001, `RuntimeDefault` seccomp, drop ALL, read-only root FS, no SA token | Pod and container `securityContext` (unchanged by the lab overlay) | Restricted-profile check on the rendered manifests |
| Image tampering | Tag + multi-arch index digest | All four Thanos containers | `kubectl get pods -o jsonpath` shows the digest |
| Bucket data deleted by mistake | Only the compactor deletes; lifecycle backstop at 35 days | IAM + compactor retention | — |

**Not protected:** anyone who can reach port 10902 of thanos-query inside the allowed sources can read all metrics;
Grafana's own authentication is the user-facing control.

## 🩺 Operations

| Topic | What to do |
|---|---|
| Health | `/-/ready` and `/-/healthy` on 10902 (probes); the 19 alerts in [`base/prometheusrule.yaml`](base/prometheusrule.yaml) |
| Key signals | `thanos_shipper_upload_failures_total`, `thanos_objstore_bucket_last_successful_upload_time`, `thanos_compact_halted`, `thanos_compact_group_compactions_failures_total`, `grpc_server_handled_total{job="thanos-store"}` |
| Logs | stdout (`logfmt`), collected by the cluster logging agent |
| Restart | Any pod can be deleted; prod query and store are HA, the lab has one of each (short gap), the compactor resumes from the bucket state |
| Compactor halted | Read its log for the block ULID; mark the block with `thanos tools bucket mark --marker=no-compact-mark.json`, or delete the local `/data` and restart |
| Capacity | `gcloud storage du -s gs://<THANOS_BUCKET>`; store memory via `go_memstats_heap_inuse_bytes` |
| Upgrade | Bump the tag and digest in `base/query.yaml`, `base/store.yaml`, `base/compact.yaml` and the kps `prometheusSpec.thanos.image` together; read the Thanos release notes; `kubectl apply -k` and `helm upgrade`; roll back by reverting the commit |
| Backup | The bucket is the backup of Prometheus; keep soft delete or copy to a second bucket with `thanos tools bucket replicate` |
| Object store changed | `scripts/deploy.sh prometheus` restarts the sidecar (deletes the Prometheus pod), `thanos-store` and `thanos-compact` when Secret `thanos-objstore` changes: they read `objstore.yml` only at start |

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Prometheus pods `CreateContainerConfigError` | Secret `thanos-objstore` missing | Install step 2 or `scripts/deploy.sh prometheus` |
| Sidecar logs `403` / `storage.objects.create` denied | Bucket IAM grant missing or wrong KSA name | Re-run `infra/create-gcs-bucket.sh` (same `ACCESS_MODE`); the KSA must be `prometheus-kube-prometheus-prometheus` |
| Sidecar logs `could not find default credentials` | Node pool without the GKE metadata server | Enable Workload Identity on the cluster and node pool |
| Sidecar/store still use the old bucket after a Secret change | They read `objstore.yml` only at start | Re-run `scripts/deploy.sh prometheus` (restarts them on change) or restart the Prometheus pod, `thanos-store`, `thanos-compact` |
| Sidecar/store logs `connection refused` or `i/o timeout` to `seaweedfs.object-storage:8333` (SeaweedFS fallback) | SeaweedFS down or its NetworkPolicy does not admit `monitoring` | Check the `seaweedfs` pod; allow 8333 from `prometheus`, `thanos-store`, `thanos-compact` |
| `AccessDenied` from S3 (SeaweedFS fallback) | Secret key does not match the SeaweedFS identity | Re-create both with `scripts/deploy.sh` (it writes the identity and the Secret together) |
| Grafana shows only ~2 days | Store gateway not discovered or not ready | `/api/v1/stores` on thanos-query; check `thanos-store` readiness and NetworkPolicy |
| Doubled series in Grafana (prod) | Dedup off | `--query.replica-label=prometheus_replica` in [`base/query.yaml`](base/query.yaml); query with dedup on |
| Bucket keeps growing | Compactor halted or down | Alerts `ThanosCompactHalted` / `ThanosCompactIsDown`; see Operations |
| Lab thanos-query or thanos-compact `OOMKilled` | Lab memory limits (192Mi / 512Mi) too small for a heavy 30-day query or a 14-day compaction | Raise the limit in [`overlays/lab/`](overlays/lab/kustomization.yaml) and re-apply |
| Long-range panels slow | Raw blocks only (young data) or no auto-downsampling | `--query.auto-downsampling` is set; 5m blocks appear after 40h, 1h after 10 days |

## 🏁 Production checklist

- [ ] **Backups:** the bucket is the system of record for history; decide on soft delete (7-day default, costs ~$0.50/month here) or `thanos tools bucket replicate` to a second-region bucket.
- [ ] **Bucket lifecycle:** delete-after-age rule at **35 days** as a backstop (> 30-day retention + 48h `--delete-delay`); retention itself is the compactor's job. Versioning off.
- [ ] **Cost:** budget alert on the bucket; watch Class B operations (query-driven) and node capacity, not storage.
- [ ] **Access logs:** enable Cloud Audit Logs **Data Access** logs (`DATA_READ`, `DATA_WRITE`) for Cloud Storage on the project, or bucket usage logs, to see every object read/write by principal.
- [ ] **Compactor singleton:** never scale `thanos-compact` above 1; one compactor per bucket.
- [ ] **Upgrades:** same Thanos version on sidecar, query, store and compactor; upgrade the compactor last.
- [ ] **SLOs:** query availability (`ThanosQueryHttpRequestQueryRangeErrorRateHigh`), upload freshness < 6h (`ThanosSidecarNoRecentUpload`), compaction progress < 24h (`ThanosCompactHasNotRun`).
- [ ] **Prometheus PVC:** with 2-day local retention the 100Gi PVC can be reduced (~20Gi) on a fresh install.

## 📌 Pinned versions

| Item | Version | Digest (multi-arch index, read from the registry API on 2026-11-08) |
|---|---|---|
| `quay.io/thanos/thanos` (sidecar, query, store, compact) | v0.42.5 (latest release, 2026-10-27) | `sha256:0a546b98a8dd47735456ab389983675ee363d68127e334937a9fceeea10da5e7` |
| kube-prometheus-stack (sidecar host) | 93.1.0 (operator v0.95.1) | see [`../kube-prometheus-stack/README.md`](../kube-prometheus-stack/README.md) |

## 🧹 Teardown

Prod `kubectl delete -k helm/thanos` (lab `kubectl delete -k helm/thanos/overlays/lab`), then
`kubectl -n monitoring delete pvc -l 'app.kubernetes.io/name in (thanos-store,thanos-compact)'`.
Bucket data stays until deleted with `gcloud storage rm -r gs://<THANOS_BUCKET>` (irreversible).

## 🔗 References

- [Thanos components: sidecar, query, store, compactor](https://thanos.io/tip/components/sidecar.md/)
- [Thanos compactor: downsampling and retention](https://thanos.io/tip/components/compact.md/)
- [Thanos object storage (GCS, S3)](https://thanos.io/tip/thanos/storage.md/)
- [Prometheus operator Thanos sidecar](https://prometheus-operator.dev/docs/platform/thanos/)
- [Workload Identity Federation for GKE](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)
- [Grafana Mimir architecture](https://grafana.com/docs/mimir/latest/get-started/about-grafana-mimir-architecture/), [components](https://grafana.com/docs/mimir/latest/references/architecture/components/)
- [Cloud Storage pricing](https://cloud.google.com/storage/pricing), [Disk and image pricing](https://cloud.google.com/compute/disks-image-pricing), [Google Cloud Observability pricing](https://cloud.google.com/stackdriver/pricing)
- [Thanos v0.42.5 release](https://github.com/thanos-io/thanos/releases/tag/v0.42.5)
