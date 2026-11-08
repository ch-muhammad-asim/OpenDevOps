# 🪣 SeaweedFS (lab S3 object store)

SeaweedFS as one `weed server` process (master, volume server, filer and S3 gateway together) in namespace
`object-storage`. **Why:** the lab profile needs an S3 bucket for Tempo trace blocks (`tempo-traces`) and Thanos
metric blocks (`thanos-metrics`), but the lab account cannot grant bucket IAM on GCS. SeaweedFS keeps both buckets on
one in-cluster persistent disk, free and open source (Apache-2.0), in a single small pod.

**Lab only.** Production uses GCS buckets with Workload Identity (`OBJECT_STORE=gcs`, see
[`../thanos/`](../thanos/README.md) and [`../tempo-distributed/`](../tempo-distributed/)); nothing in this directory
runs in production.

**Status (2026-11-08, SeaweedFS 4.52):** ✅ live tested on the lab cluster: `seaweedfs-0` Ready on its 100Gi PVC, both
buckets created by the bootstrap Job, Tempo writing blocks to `tempo-traces` (S3 requests 2xx only), Thanos sidecar
uploads to `thanos-metrics` succeeding and the store gateway loading them; `PROFILE=lab scripts/verify.sh` 32 PASS,
0 failures (includes "pods Ready in object-storage"). Also validated offline: `kubectl kustomize` + kubeconform strict
(Kubernetes 1.36, 12 resources valid), `promtool check rules` (6 rules) and Pod Security Standards `restricted`.

## 🏗️ Architecture

| Flow | From → to | Port / protocol |
|---|---|---|
| Trace blocks | Tempo (`observability`, `app.kubernetes.io/instance=tempo`) → `seaweedfs.object-storage:8333`, bucket `tempo-traces` | S3, plain HTTP in-cluster, path-style |
| Metric blocks | Thanos sidecar (in the Prometheus pod), store gateway, compactor, query (`monitoring`) → `:8333`, bucket `thanos-metrics` | Same |
| Bucket creation | Job `seaweedfs-bootstrap` → master 9333/19333 → filer 18888 | `weed shell`, HTTP + gRPC |
| Metrics | Prometheus → `seaweedfs:9327/metrics` | HTTP |
| Inside the pod | S3 gateway → filer (metadata, leveldb2 on the PV) → volume server (1 GiB volume files on the PV) | Pod-internal |

## 🧩 Components

| Name | What it does (one line) | Where defined | Security role |
|---|---|---|---|
| Namespace `object-storage` | Holds the object store only | [`namespace.yaml`](namespace.yaml) | PSS `restricted` enforced |
| StatefulSet `seaweedfs` (1 replica) | Master + volume server + filer + S3 gateway in one process | [`statefulset.yaml`](statefulset.yaml) | UID/GID 1000, non-root, read-only root FS, drop ALL, no SA token |
| PVC `data-seaweedfs-0` (100Gi, `standard-rwo`) | Volume files, filer metadata (`/data/filerldb2`), master state | `volumeClaimTemplates` | Zonal disk, RWO; kept when the StatefulSet is deleted |
| Service `seaweedfs` | 8333 S3, 9327 metrics | [`statefulset.yaml`](statefulset.yaml) | ClusterIP only |
| Service `seaweedfs-headless` | Stable pod DNS name used as the server's `-ip` | [`statefulset.yaml`](statefulset.yaml) | Headless; ports reachable only as NetworkPolicy allows |
| Secret `seaweedfs-s3-config` (key `s3.json`) | S3 identities, one per bucket | `scripts/deploy.sh` (never in Git) | Per-bucket least privilege |
| Job `seaweedfs-bootstrap` | Creates `tempo-traces` and `thanos-metrics` if missing | [`bootstrap-job.yaml`](bootstrap-job.yaml) | No S3 keys; same hardening as the server |
| ServiceMonitor `seaweedfs` | Prometheus scrapes 9327 (`job="seaweedfs"`) | [`servicemonitor.yaml`](servicemonitor.yaml) | — |
| PrometheusRule `seaweedfs` | Down, PV nearly full, low free space, S3 5xx, S3 403 | [`prometheusrule.yaml`](prometheusrule.yaml) | Read-only rules |
| NetworkPolicies | Default deny; 8333 from Tempo and Thanos, 9327 from Prometheus, internal ports from the pod and the Job | [`networkpolicies.yaml`](networkpolicies.yaml) | Network least privilege |
| ServiceAccount `seaweedfs` | Pod identity, no token, no RBAC | [`serviceaccount.yaml`](serviceaccount.yaml) | No Kubernetes API access |

## 🤔 Why SeaweedFS

| Option | Licence / status | Fit for this lab | Decision |
|---|---|---|---|
| **SeaweedFS** | Apache-2.0, active releases | One process serves S3; small memory; per-bucket identities in a JSON file; Prometheus metrics | ✅ Chosen |
| Garage | AGPL-3.0, active | Also light, but layout and keys are set with admin CLI calls after start, and it needs its own RPC secret | Not chosen |
| MinIO | Community edition no longer maintained as open source | No maintained free image to pin | ❌ Dropped |

## 📐 Sizing

| Item | Value | Why |
|---|---|---|
| PVC | 100Gi `standard-rwo` (pd-balanced, ~$10/month) | Tempo ~31 GB per 30 days ([`../tempo/`](../tempo/README.md#-retention-and-sizing)) + Thanos raw and downsampled 30 days ~15-40 GB + headroom for vacuum and growth |
| `-master.volumeSizeLimitMB` | 1024 | 1 GiB volume files: fine-grained on a 100Gi disk (default 30 GiB) |
| `-volume.max` | 85 | 85 × 1 GiB fits the PV with room for filer metadata and the 5% floor |
| `-volume.minFreeSpace` | 5 (%) | Below 5% free the volumes turn read-only instead of filling the disk |
| `-master.defaultReplication` | `000` | One copy: single node, single disk |
| Requests / limits | 100m / 256Mi, memory limit 1Gi, no CPU limit | Small lab load; no CPU throttling on uploads and vacuum |
| Bootstrap Job | 10m / 64Mi, limit 256Mi | Runs once |

Usage at the first live test (2026-11-08, a few hours of data): `tempo-traces` ~1.5 MB, `thanos-metrics` ~78 MB.

Deleted objects (Tempo and Thanos retention) free disk only after SeaweedFS vacuums a volume (automatic every 14 min
once 30% of a volume is garbage), so usage lags deletes.

## 🚀 Install

`scripts/deploy.sh` with `OBJECT_STORE=seaweedfs` (the lab default) does this in order: the `objectstore` step creates
the namespace and the three Secrets, the `prometheus` step applies the server and waits for the bucket Job (after the
CRDs), then installs Thanos. By hand:

| Step | Command | Why |
|---|---|---|
| 1 | `kubectl apply -f helm/seaweedfs/namespace.yaml` | Namespace first, so the Secret can be created |
| 2 | Create Secret `object-storage/seaweedfs-s3-config` from `s3.json` (format below), e.g. `kubectl -n object-storage create secret generic seaweedfs-s3-config --from-file=s3.json=<file>` | The server refuses to start without it (mounted file, read at start) |
| 3 | `kubectl apply -k helm/seaweedfs` | Server, Services, Job, monitoring, NetworkPolicies |
| 4 | `kubectl -n object-storage rollout status sts/seaweedfs --timeout=5m` | Wait for the S3 gateway |
| 5 | `kubectl -n object-storage wait --for=condition=complete job/seaweedfs-bootstrap --timeout=10m` | Buckets exist before Tempo and Thanos start |
| 6 | Create `observability/tempo-s3` and `monitoring/thanos-objstore` with the matching keys | Clients use the identities from step 2 |

Install after kube-prometheus-stack (ServiceMonitor and PrometheusRule CRDs).

### 🔑 Credentials (`s3.json`)

SeaweedFS identities format (`-s3.config`). Bucket-scoped actions are `<Action>:<bucket>`; `Write` covers put, delete
and multipart uploads. Replace the placeholders with generated random values (`scripts/deploy.sh` uses `openssl rand -hex 10`
for each access key and `openssl rand -hex 20` for each secret key):

```json
{
  "identities": [
    {
      "name": "tempo",
      "credentials": [
        { "accessKey": "<TEMPO_ACCESS_KEY>", "secretKey": "<TEMPO_SECRET_KEY>" }
      ],
      "actions": ["Read:tempo-traces", "Write:tempo-traces", "List:tempo-traces"]
    },
    {
      "name": "thanos",
      "credentials": [
        { "accessKey": "<THANOS_ACCESS_KEY>", "secretKey": "<THANOS_SECRET_KEY>" }
      ],
      "actions": ["Read:thanos-metrics", "Write:thanos-metrics", "List:thanos-metrics"]
    }
  ]
}
```

| Secret | Keys | Holds |
|---|---|---|
| `object-storage/seaweedfs-s3-config` | `s3.json` | Both identities (above) |
| `observability/tempo-s3` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Identity `tempo` ([`../tempo/values-s3.yaml`](../tempo/values-s3.yaml)) |
| `monitoring/thanos-objstore` | `objstore.yml` (`type: S3`, bucket `thanos-metrics`, endpoint `seaweedfs.object-storage:8333`, `insecure: true`) | Identity `thanos` ([`../thanos/`](../thanos/README.md)) |

No identity has `Admin`, and there is no anonymous identity: with `-s3.config` set, every unsigned request is denied.
Do not set `AWS_ACCESS_KEY_ID` on the SeaweedFS pod: SeaweedFS turns that pair into an extra **admin** identity.

## ✅ Verify

| Check | Command | Expected |
|---|---|---|
| Ready | `kubectl -n object-storage get pods -l app.kubernetes.io/name=seaweedfs` | `seaweedfs-0` `1/1 Running` |
| Image pinned | `kubectl -n object-storage get pod seaweedfs-0 -o jsonpath='{.status.containerStatuses[0].imageID}'` | Ends in `sha256:57877e32…ce59` |
| Non-root | `kubectl -n object-storage exec seaweedfs-0 -- id` | `uid=1000(seaweed) gid=1000(seaweed)` |
| Buckets | `kubectl -n object-storage logs job/seaweedfs-bootstrap` | `buckets ready: tempo-traces thanos-metrics` |
| Bucket list | `kubectl -n object-storage exec seaweedfs-0 -- sh -c 'echo s3.bucket.list \| weed shell -master=$(hostname).seaweedfs-headless.object-storage.svc:9333'` | Both buckets with their size |
| Scraped | PromQL `up{job="seaweedfs"}` | `1` |
| Tempo writes | PromQL `sum by (bucket, code) (rate(SeaweedFS_s3_request_total{bucket="tempo-traces"}[5m]))` | `200` codes once Tempo flushes blocks |

## 🛡️ Security

| Threat | Control | How it's enforced | Test that proves it |
|---|---|---|---|
| Another workload reads or deletes blocks | NetworkPolicy: 8333 only from Tempo and Thanos pods; S3 signature required | [`networkpolicies.yaml`](networkpolicies.yaml), `-s3.config` | `curl` from a `tempo-apps` pod to `seaweedfs.object-storage:8333` times out |
| Tempo key used on Thanos data (or the reverse) | One identity per bucket, `Read/Write/List:<bucket>` only | `s3.json` | Listing `thanos-metrics` with the `tempo` key returns `AccessDenied` |
| Bucket created or removed by a client | No `Admin` action; `-s3.autoCreateBucket=false`; buckets only via the Job (filer gRPC, not S3) | `s3.json`, args, `seaweedfs-internal` policy | Job is the only allowed source of 9333/18888 besides the pod |
| Credentials in Git or logs | Generated at deploy time into Secrets; mounted as a file / env vars | `scripts/deploy.sh` | `git grep -i secretKey` finds only placeholders |
| Container escape / privilege | Non-root 1000, read-only root FS, drop ALL, seccomp, no SA token, PSS `restricted` | [`statefulset.yaml`](statefulset.yaml), [`namespace.yaml`](namespace.yaml) | Server-side dry run in a `restricted` namespace passes |
| Image tampering | Tag + multi-arch index digest | `image:` | `imageID` matches the pinned digest |
| Data leaves the cluster | Telemetry off (`-master.telemetry=false`); Iceberg/Lance/IAM endpoints off | args | — |

**Not protected (honest):** S3 traffic is **plaintext HTTP** inside the cluster (keys are not sent, requests are
signed, but object bodies are readable on the node network); data at rest is protected only by the persistent disk's
default encryption; there is no audit log of object reads/writes. Acceptable for regenerable lab telemetry, not for
production. **Egress:** like the other namespaces, `object-storage` has default-deny **ingress** only; its egress is
not restricted (the server needs none beyond its own pod and DNS). The opt-in
[`../../k8s/networkpolicies-egress.yaml`](../../k8s/networkpolicies-egress.yaml) covers the client side (Tempo to 8333);
add an `object-storage` egress policy if you enforce egress cluster-wide.

## 🩺 Operations

| Topic | Lab |
|---|---|
| HA | None: one pod, one zonal disk. A restart pauses uploads; Tempo and the Thanos sidecar retry, data waits on their own disks |
| Health | Probes on S3 `/healthz` and `/readyz` (8333); alert `SeaweedFSDown` |
| Logs | stderr (`-logtostderr=true`) → `kubectl -n object-storage logs seaweedfs-0` |
| Capacity | `kubelet_volume_stats_available_bytes{persistentvolumeclaim="data-seaweedfs-0"}` and `SeaweedFS_volumeServer_resource{type="avail"}`; alerts at 15% and 8% free |
| Grow the PV | `kubectl -n object-storage patch pvc data-seaweedfs-0 -p '{"spec":{"resources":{"requests":{"storage":"200Gi"}}}}'` (online), then raise `-volume.max` and the template size (`delete sts seaweedfs --cascade=orphan`, re-apply) |
| Re-runs | `scripts/deploy.sh` generates the keys once and reuses the three Secrets on every re-run (never printed); it regenerates all three together only if one is missing |
| Rotate keys | Update all three Secrets, then `kubectl -n object-storage rollout restart sts/seaweedfs` (s3.json is read at start), then restart Tempo and the Thanos components |
| Backup | **None in the lab:** traces and metrics are regenerable demo data. Option: a `VolumeSnapshot` of `data-seaweedfs-0` (GKE PD CSI snapshot class) before risky changes |
| Restore | From a snapshot: new PVC from the snapshot named `data-seaweedfs-0`, then start the StatefulSet |
| Upgrade | Bump tag and digest together in both files, apply, check `seaweedfs-0` ready and `s3.bucket.list`; roll back by re-applying the previous image |

## 🛠️ Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `seaweedfs-0` stuck `ContainerCreating` | Secret `seaweedfs-s3-config` missing | Create it (Install step 2) |
| Pod exits: `fail to load config file /etc/seaweedfs/s3.json` | Invalid JSON in the Secret | Fix `s3.json`, recreate the Secret, restart the pod |
| Tempo or Thanos `AccessDenied` / `403` (alert `SeaweedFSS3AccessDenied`) | Client key not in `s3.json`, or wrong bucket | Compare the three Secrets; restart `seaweedfs-0` after changing `s3.json` |
| Client `connection timed out` to 8333 | Client pod labels not in `seaweedfs-s3-from-clients`, or egress policy in the client namespace | Check labels against [`networkpolicies.yaml`](networkpolicies.yaml); allow egress to `object-storage:8333` |
| Job `seaweedfs-bootstrap` keeps failing | Server not ready, or `seaweedfs-internal` policy blocks the Job | `kubectl -n object-storage logs job/seaweedfs-bootstrap`; check pod labels |
| `kubectl apply -k` fails: Job `field is immutable` | `bootstrap-job.yaml` changed while the old Job still exists | `kubectl -n object-storage delete job seaweedfs-bootstrap`, re-apply (idempotent) |
| Uploads fail with 5xx, volumes read-only | Free space below 5% | Grow the PVC or lower Tempo/Thanos retention |
| Disk usage does not drop after retention | Vacuum not yet run | Wait (every 14 min, 30% garbage threshold) |

## 📕 Runbooks

Alert rules: [`prometheusrule.yaml`](prometheusrule.yaml). Each alert's `runbook_url` points here.

### SeaweedFSDown

`up` is 0 or the target is missing for 5 minutes: Tempo and Thanos cannot write or read blocks (Tempo keeps
ingesting into its WAL; the Thanos sidecar retries uploads). Check `kubectl -n object-storage get pods`, events and
logs of `seaweedfs-0`; common causes are a missing `seaweedfs-s3-config` Secret or invalid `s3.json` (see
Troubleshooting). After a fix, confirm `kubectl -n monitoring logs prometheus-prometheus-kube-prometheus-prometheus-0 -c thanos-sidecar` shows uploads.

### SeaweedFSVolumeNearlyFull

The PVC `data-seaweedfs-0` has less than 15% free. Grow the PVC (`kubectl -n object-storage patch pvc data-seaweedfs-0`,
the storage class allows expansion) or lower Tempo/Thanos retention, before it reaches 5% (volumes turn read-only).

### SeaweedFSVolumeAlmostFull

Less than 8% free on `data-seaweedfs-0`: act now, as for SeaweedFSVolumeNearlyFull; below 5% uploads fail.

### SeaweedFSDiskLowFreeSpace

SeaweedFS's own view of its data directory reports less than 8% available. Same actions; also check that vacuum runs
(garbage reclaimed every 14 minutes above 30% garbage).

### SeaweedFSS3ServerErrors

More than 5% of S3 requests return 5xx. Check `seaweedfs-0` logs for disk-full or volume errors and the volume status
with `weed shell` (`volume.list`); a full disk is the usual cause.

### SeaweedFSS3AccessDenied

Requests to a bucket get 403. A client uses a key that is not in `s3.json` or the wrong bucket: compare the Secrets
`tempo-s3`, `thanos-objstore` and `seaweedfs-s3-config`, then restart `seaweedfs-0` (it reads `s3.json` only at start)
and the client.

## 🏁 Production checklist

Production does not use SeaweedFS (GCS with Workload Identity). If an in-cluster S3 store were ever needed beyond the lab:

- [ ] TLS on the S3 port (`-s3.cert.file`, `-s3.key.file`) and mTLS/`security.toml` for gRPC between components.
- [ ] HA: 3 masters, several volume servers across zones, replication `010` or higher, a shared filer store.
- [ ] Backups: scheduled `VolumeSnapshot`s or `weed filer.backup` to a second store; tested restore.
- [ ] Audit logging (`-s3.auditLogConfig`) and alerting on 403 bursts.
- [ ] Default-deny egress for `object-storage`.
- [ ] Key rotation schedule for the S3 identities.

## 📌 Pinned versions

| Item | Version | Digest (multi-arch index, read from the registry API on 2026-11-08) |
|---|---|---|
| `chrislusf/seaweedfs` (server and bootstrap Job) | 4.52 (latest release, 2026-11-02) | `sha256:57877e32bb90073b37dc109b438ba66e84fd5ed9ced5f5c04f56444ef243ce59` |

The image is Alpine-based, starts as root by default and drops to user `seaweed` (UID/GID 1000) in its entrypoint.
Here the entrypoint is skipped and `/usr/bin/weed` starts directly as 1000, so no root step runs at all.

## 🧹 Teardown

`kubectl delete -k helm/seaweedfs` removes everything except the PVC (kept on purpose); then
`kubectl -n object-storage delete pvc data-seaweedfs-0` (all buckets and objects) and
`kubectl delete namespace object-storage`.

## 🔗 References

- [SeaweedFS](https://github.com/seaweedfs/seaweedfs) and [releases](https://github.com/seaweedfs/seaweedfs/releases)
- [SeaweedFS Amazon S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [SeaweedFS S3 credentials](https://github.com/seaweedfs/seaweedfs/wiki/S3-Credentials)
- [SeaweedFS system metrics](https://github.com/seaweedfs/seaweedfs/wiki/System-Metrics)
- [SeaweedFS `weed shell`](https://github.com/seaweedfs/seaweedfs/wiki/weed-shell)
- [Tempo S3 backend](https://grafana.com/docs/tempo/latest/configuration/hosted-storage/s3/)
- [Thanos object storage (S3)](https://thanos.io/tip/thanos/storage.md/#s3)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
