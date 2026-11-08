# 🌐 Edge: Traefik, cert-manager, NetworkPolicies

The public edge and in-cluster isolation for hermes-grafana-tempo. Traefik serves four HTTPS hostnames behind the
Cloudflare proxy, NetworkPolicies limit which pods can talk to Grafana, Tempo, the OpenTelemetry Collector, Prometheus
and the sample apps, and Pod Security admission plus quotas bound what can run. cert-manager (Let's Encrypt over DNS-01)
is optional. **Why:** only Grafana and the sample apps are public, only through Cloudflare, and the telemetry backends
stay internal.

**Status:** ✅ lab profile running on GKE 1.36 (3 x e2-standard-2, one zone) with `TLS_MODE=cloudflare`: routes
`tls: {}`, Traefik's default certificate, Cloudflare SSL mode "Full", cert-manager not installed; tested end to end on
2026-11-08. `TLS_MODE=letsencrypt` is optional; it was tested on the same cluster earlier on 2026-11-08 (4 certificates
issued and `READY`, Cloudflare "Full (strict)"). 🚧 The production profile (HA values, PDBs, quota, opt-in egress
policies) is validated offline only (2026-11-08: `kubeconform` strict on Kubernetes 1.36, `helm lint` + `helm template`
for Traefik 42.3.1 and cert-manager v1.21.3, `kubectl apply --dry-run=server` for every manifest here). It has not run
on a multi-zone cluster yet.

## 🏗️ Architecture

The project [architecture diagram](../docs/diagrams/architecture.mmd) shows the edge (Cloudflare, Traefik) and every namespace; it renders in the [top-level README](../README.md). The table below lists the parts.

| Public host | Namespace | Backend (Service:port) | Certificate (`TLS_MODE=letsencrypt` only) |
|---|---|---|---|
| `grafana-tempo.saqlainmushtaq.com` | observability | `grafana:80` | `grafana-tempo-tls` |
| `tempo-nextjs.saqlainmushtaq.com` | tempo-apps | `nextjs:3000` | `tempo-nextjs-tls` |
| `tempo-python.saqlainmushtaq.com` | tempo-apps | `python:8000` | `tempo-python-tls` |
| `tempo-nodejs.saqlainmushtaq.com` | tempo-apps | `nodejs:3000` | `tempo-nodejs-tls` |

## 🧩 Files

| File | What it does (one line) | Security role |
|---|---|---|
| [`namespaces.yaml`](namespaces.yaml) | Creates traefik, observability, tempo-apps, hermes, monitoring with Pod Security labels (namespace `object-storage` of the optional SeaweedFS fallback is defined in [`../helm/seaweedfs/namespace.yaml`](../helm/seaweedfs/namespace.yaml)) | `restricted` everywhere except monitoring (`privileged`, node-exporter) |
| [`cert-manager.yaml`](cert-manager.yaml) | Namespace cert-manager + its NetworkPolicies (`TLS_MODE=letsencrypt` only) | `restricted`, default-deny ingress, webhook 10250 and metrics 9402 allows |
| [`traefik-values.yaml`](traefik-values.yaml) | Traefik 42.3.1 production values: 3 replicas, PDB, node/zone spread, digest-pinned image, CRD provider on 4 namespaces | Non-root, read-only rootfs, no dashboard/API, Cloudflare-only `trustedIPs` and LB `loadBalancerSourceRanges` |
| [`traefik-values-lab.yaml`](traefik-values-lab.yaml) | Lab overlay: 1 replica, no PDB/spread, small requests | Same security settings (inherits them) |
| [`cert-manager-values.yaml`](cert-manager-values.yaml) | cert-manager v1.21.3 production values (`TLS_MODE=letsencrypt` only): 2 replicas each, PDBs, spread, digest-pinned images | Pod Security `restricted` settings pinned |
| [`cert-manager-values-lab.yaml`](cert-manager-values-lab.yaml) | Lab overlay: 1 replica each, no PDBs | Same security settings (inherits them) |
| [`cluster-issuer.yaml`](cluster-issuer.yaml) | Let's Encrypt staging + prod ClusterIssuers, DNS-01 via Cloudflare for `saqlainmushtaq.com` | Token read from Secret `cloudflare-api-token` |
| [`certificates.yaml`](certificates.yaml) | One Certificate per public host, issuer `letsencrypt-prod`, ECDSA P-256 (`TLS_MODE=letsencrypt` only) | Publicly trusted origin TLS |
| [`ingressroutes.yaml`](ingressroutes.yaml) | Default TLSOption, per-namespace Middlewares, IngressRoutes for the 4 hosts | Cloudflare-only allow-list, security headers, HTTP to HTTPS |
| [`networkpolicies.yaml`](networkpolicies.yaml) | Default-deny ingress in every namespace above (hermes has its own) + explicit allows | East-west isolation |
| [`networkpolicies-egress.yaml`](networkpolicies-egress.yaml) | Opt-in default-deny egress for observability and tempo-apps with every needed flow | Exfiltration and metadata-server lockdown |
| [`limitrange.yaml`](limitrange.yaml) | tempo-apps LimitRange (defaults + per-container max) and ResourceQuota | No BestEffort pods, bounded namespace budget, no LoadBalancer/NodePort |

## 🔐 TLS modes

`scripts/deploy.sh` selects the mode with `TLS_MODE` (default `cloudflare`). Visitors always get Cloudflare's
publicly trusted certificate; the mode only changes the Cloudflare-to-origin hop.

| | `TLS_MODE=cloudflare` (default) | `TLS_MODE=letsencrypt` |
|---|---|---|
| Origin certificate | Traefik's built-in self-signed default certificate | Let's Encrypt certificate per host (cert-manager, DNS-01) |
| cert-manager | Not installed (the lab runs this mode) | `cert-manager.yaml`, then the chart (`cert-manager-values.yaml`), ClusterIssuers + `certificates.yaml` |
| IngressRoutes | `tls: {}` as committed | `deploy.sh` patches `spec.tls.secretName: <host>-tls` into the 4 `*-websecure` routes |
| Cloudflare SSL mode | **Full** (encrypted, origin certificate not validated) | **Full (strict)** (encrypted and validated) |
| Extra secrets | None | Cloudflare API token (Zone: DNS: Edit) in `cert-manager/cloudflare-api-token` |
| Moving parts | Fewer (no issuance, no renewals) | Issuance and renewal every ~60 days; DNS-01 needs the token |

"Full (strict)" with `TLS_MODE=cloudflare` fails (Cloudflare 526), because the default certificate is self-signed.
"Flexible" also works (the `*-web` routes serve requests that arrived over HTTPS at Cloudflare), but the origin hop is
then plain HTTP; do not use it in production.

## ⚖️ Profiles

`PROFILE=prod` (default) uses `<name>-values.yaml`; `PROFILE=lab` adds `<name>-values-lab.yaml` on top.
The plain manifests (`*.yaml` without `values`) are the same in both profiles.

| Setting | Production (`PROFILE=prod`) | Lab (`PROFILE=lab`) |
|---|---|---|
| Traefik replicas | 3, PDB `minAvailable: 2`, hard spread per node, soft per zone | 1, no PDB, no spread |
| Traefik resources (each) | 200m / 192Mi request, 1 CPU / 512Mi limit | 50m / 64Mi request, 500m / 256Mi limit |
| cert-manager (letsencrypt only) | controller, webhook, cainjector x2 with PDBs and spread | x1 each, no PDBs |
| cert-manager requests | controller 50m / 128Mi, webhook 20m / 64Mi, cainjector 20m / 128Mi | 10m / 64Mi, 10m / 32Mi, 10m / 64Mi |
| Images | Tag + digest pinned | Same |
| NetworkPolicies, Pod Security, quota | Same | Same |
| Egress policies | Apply `networkpolicies-egress.yaml` after a staging test | Not applied |

## 📋 Prerequisites

| Item | Version / note |
|---|---|
| `kubectl`, `helm` | kubectl matching the cluster minor version (1.36 tested), Helm 3.x |
| Helm charts | `traefik/traefik` 42.3.1 (Traefik v3.7.17), `jetstack/cert-manager` v1.21.3 |
| Cluster | GKE with Dataplane V2 (NetworkPolicy enforcement). Production: 3+ nodes across 3 zones (Traefik needs one node per replica) |
| Cloudflare | Zone `saqlainmushtaq.com`, proxied DNS records for the 4 hosts, SSL mode per [TLS modes](#-tls-modes) |
| Cloudflare token (letsencrypt only) | API token with **Zone: DNS: Edit**, saved in a file (`CF_TOKEN_FILE`) |
| kube-prometheus-stack | Installed before Traefik (see [`../helm/`](../helm/)): the Traefik chart renders a ServiceMonitor and refuses to install without the `monitoring.coreos.com/v1` CRDs |

## 🚀 Run it

The normal path is the repository script, which runs every step in the right order:

```bash
# Production defaults, TLS_MODE=cloudflare, Cloudflare SSL mode "Full".
scripts/deploy.sh
# Lab cluster (smaller values), TLS_MODE=cloudflare: what the lab runs.
PROFILE=lab scripts/deploy.sh
# Optional: Let's Encrypt origin certificates, Cloudflare "Full (strict)".
PROFILE=lab TLS_MODE=letsencrypt scripts/deploy.sh
```

Apply order (what `deploy.sh` does for this directory; run from `k8s/` to do it by hand):

```bash
# 1. Namespaces first: everything else lands in them, Pod Security applies from the start.
kubectl apply -f namespaces.yaml

# 2. (kube-prometheus-stack from ../helm/ goes here: its CRDs are needed by step 4.)

# 3. TLS_MODE=letsencrypt only: namespace + NetworkPolicies, cert-manager + CRDs, the DNS token
#    from a file, the issuers. Lab: add  -f cert-manager-values-lab.yaml
kubectl apply -f cert-manager.yaml
helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.3 \
  -n cert-manager -f cert-manager-values.yaml --wait
kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-file=api-token="$CF_TOKEN_FILE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f cluster-issuer.yaml

# 4. Traefik + its CRDs (needed before the IngressRoutes). Lab: add  -f traefik-values-lab.yaml
helm upgrade --install traefik traefik/traefik --version 42.3.1 \
  -n traefik -f traefik-values.yaml --wait

# 5. (Tempo, Collector, Grafana from ../helm/ go here.)

# 6. Routes, then (letsencrypt only) certificates + secretName patch, then isolation and limits.
kubectl apply -f ingressroutes.yaml
kubectl apply -f certificates.yaml        # letsencrypt only; deploy.sh then patches secretName
kubectl apply -f networkpolicies.yaml
kubectl apply -f limitrange.yaml

# 7. Production, after a staging run of scripts/verify.sh with it applied:
kubectl apply -f networkpolicies-egress.yaml
```

`CF_TOKEN_FILE` is the path to a file that holds only the token; it never goes on the command line or into Git.

Rendering Traefik on its own (`helm template traefik/traefik --version 42.3.1 -f traefik-values.yaml`) fails with
`You have to deploy monitoring.coreos.com/v1 first`, because the chart checks for the ServiceMonitor API. Add
`--api-versions monitoring.coreos.com/v1` to render offline; on a cluster, installing kube-prometheus-stack first
(step 2) satisfies the check.

Verify:

| Check | Command | Expected |
|---|---|---|
| Traefik pods | `kubectl -n traefik get pods -o wide` | prod: 3 `Running` on 3 different nodes; lab: 1 |
| Traefik PDB (prod) | `kubectl -n traefik get pdb` | `MIN AVAILABLE 2`, `ALLOWED DISRUPTIONS 1` |
| Traefik scraped | Prometheus query `up{namespace="traefik"}` | `1` per pod |
| LB address | `kubectl -n traefik get svc traefik` | `EXTERNAL-IP` set; the 4 proxied Cloudflare records point at it |
| LB source ranges | `kubectl -n traefik get svc traefik -o jsonpath='{.spec.loadBalancerSourceRanges}'` | The 15 Cloudflare IPv4 ranges |
| Public HTTPS | `curl -sI https://grafana-tempo.saqlainmushtaq.com/login` | `HTTP/2 200`, `strict-transport-security` header |
| HTTP redirect | `curl -sI http://grafana-tempo.saqlainmushtaq.com/` | `301`/`308` to `https://` |
| Origin bypass blocked | `curl -sk -m 10 --resolve grafana-tempo.saqlainmushtaq.com:443:$LB_IP https://grafana-tempo.saqlainmushtaq.com/` (`LB_IP` = the `EXTERNAL-IP` above) | Connection times out (L4 source ranges); `403 Forbidden` from Traefik if the source ranges are not applied |
| Issuers + certificates (letsencrypt) | `kubectl get clusterissuer; kubectl get certificate -A` | both issuers and 4 certificates `READY True` (DNS-01: 1-3 min) |
| Pod Security | `kubectl label --dry-run=server --overwrite ns observability pod-security.kubernetes.io/enforce=restricted` | No `Warning:` lines (running pods comply) |
| Quota | `kubectl -n tempo-apps describe resourcequota tempo-apps-budget` | `Used` well below `Hard` |
| Isolation | `scripts/verify.sh` | Pod in `default` cannot reach Tempo 3200 |

To test Let's Encrypt issuance on staging first, set `issuerRef.name: letsencrypt-staging` in
[`certificates.yaml`](certificates.yaml), wait for `Ready`, switch back to `letsencrypt-prod`, re-apply and delete the
`<host>-tls` Secret to force a production certificate.

## 🛡️ Security model

| Threat | Control | How it's enforced | Test that proves it |
|---|---|---|---|
| Direct hits on the origin LB, bypassing Cloudflare | L4: `loadBalancerSourceRanges` = Cloudflare IPv4 ranges; L7: `cloudflare-only` ipAllowList on every route | GKE LB firewall rule from the Service; Traefik Middleware with the real source IP (`externalTrafficPolicy: Local`) | `--resolve` curl above times out (403 at L7 if only the Middleware applies) |
| Spoofed `X-Forwarded-For` / `-Proto` | `forwardedHeaders.trustedIPs` = Cloudflare ranges only; alias headers deleted | Traefik entry points, `global.aliasHeadersStrategy: delete` | Header from a non-Cloudflare source is overwritten |
| Eavesdropping between Cloudflare and origin | TLS on the origin hop in both modes; TLSOption `default` min TLS 1.2, AEAD ciphers; HSTS | Traefik TLSOption in `traefik`; Cloudflare SSL mode | `curl --tls-max 1.1` to the origin fails; HSTS header present |
| Origin impersonation (MITM between Cloudflare and origin) | `TLS_MODE=letsencrypt` + Cloudflare "Full (strict)" | Cloudflare validates the publicly trusted origin certificate | Not covered by the default mode, see below |
| Public access to Tempo, Collector, Prometheus, Alertmanager | No routes for them; default-deny ingress in every namespace | IngressRoutes exist only for the 4 hosts; NetworkPolicies | No public hostname; pods in other namespaces cannot connect |
| Lateral movement inside the cluster | Explicit allows only (table below) | GKE Dataplane V2 NetworkPolicies | `kubectl run` a pod in `default` and connect to `tempo.observability:3200`: times out |
| Data exfiltration / metadata-server abuse (prod) | Default-deny egress in observability and tempo-apps; only Tempo may reach the GKE metadata server | `networkpolicies-egress.yaml` | From a tempo-apps pod, `curl -m 5 https://example.com` times out |
| Traefik reading cluster Secrets | Namespaced RBAC, provider limited to traefik/observability/tempo-apps/hermes, cross-namespace refs off | Chart `rbac.namespaced: true` (Roles only in those 4 namespaces) | `kubectl auth can-i get secrets -n monitoring --as=system:serviceaccount:traefik:traefik`: `no` |
| Image tampering / tag drift | Every Traefik and cert-manager image pinned by digest | Helm values `image.tag@digest` / `image.digest` | `kubectl get pods -o jsonpath='{..imageID}'` equals the digests in the values files |
| Privileged or root pods | Pod Security `restricted` in traefik, cert-manager, observability, tempo-apps, hermes (and lab `object-storage`) | Namespace labels (enforce + warn + audit) | A pod without `runAsNonRoot`/seccomp in tempo-apps is rejected at admission |
| Noisy neighbour / runaway sample app | LimitRange max 1 CPU / 1Gi per container, ResourceQuota on tempo-apps | `limitrange.yaml` | A pod asking for 2 CPU in tempo-apps is rejected |
| DNS token leak (letsencrypt) | Token only in Secret `cloudflare-api-token`, created from a file, scoped to DNS edit | `kubectl create secret --from-file` | Token never appears in Git or shell history |
| Losing the edge in a node drain (prod) | 3 replicas, PDB `minAvailable: 2`, one per node | Traefik chart PDB + topology spread | `kubectl drain` waits instead of evicting a second Traefik pod |

Ingress flows allowed (container ports):

| To | From | Ports |
|---|---|---|
| Traefik | Cloudflare IPv4 ranges at the LB (`loadBalancerSourceRanges`); NetworkPolicy allows any source, the route allow-list filters per request | 8000, 8443 |
| Traefik | Prometheus | 9100 |
| cert-manager webhook (letsencrypt only, `cert-manager.yaml`) | any source (kube-apiserver admission) | 10250 |
| cert-manager controller (letsencrypt only, `cert-manager.yaml`) | Prometheus | 9402 |
| Grafana | Traefik | 3000 |
| OTel Collector | tempo-apps, hermes, other Collector pods (load-balancing tier) | 4317, 4318 |
| Tempo (lab `tempo-0`; prod every tempo-distributed pod) | Collector 4317/4318 (prod: distributor); Grafana 3200 (prod: query-frontend); Tempo pods to each other, all ports (memberlist 7946, gRPC 9095, memcached 11211) | 4317, 4318, 3200, all |
| Tempo rollout-operator (prod) | any source (kube-apiserver admission: pod-eviction, downscale webhooks) | 8443 |
| Test Kafka (prod test only) | Tempo; Kafka itself | 9092 (+9093 KRaft) |
| Every observability / tempo-apps pod | Prometheus | all |
| Sample apps | Traefik 3000/8000; same namespace | 3000, 8000 |
| Prometheus | Grafana, Tempo (9090); monitoring namespace | 9090, all |
| Thanos query, store, compactor ([`../helm/thanos/`](../helm/thanos/README.md)) | query: Grafana, Hermes gateway (10902); sidecar and store: thanos-query (10901); Prometheus scrapes all (10902) | 10902, 10901 |
| SeaweedFS S3, optional fallback, not deployed in the lab ([`../helm/seaweedfs/`](../helm/seaweedfs/README.md)) | Tempo, Thanos sidecar / store / compactor / query (8333); Prometheus (9327) | 8333, 9327 |
| Alertmanager | Prometheus (9093, 8080), Grafana (9093), Alertmanager peers (9094 TCP/UDP) | 9093, 8080, 9094 |
| Prometheus operator | any source (kube-apiserver admission + Prometheus scrape) | 10250 |
| kube-state-metrics | Prometheus | 8080, 8081 |

Egress flows allowed by `networkpolicies-egress.yaml` (all other egress from the two namespaces is dropped):

| From | To | Ports |
|---|---|---|
| Every pod in observability and tempo-apps | kube-dns and NodeLocal DNSCache pods in kube-system | 53 UDP/TCP |
| Sample apps | Same namespace; OTel Collector | any; 4317, 4318 |
| Grafana | Prometheus 9090, Thanos query 10902, Alertmanager 9093, Tempo 3200; other Grafana pods 9094 TCP/UDP (alerting gossip); external database in `GRAFANA_DB_CIDR` (default `10.0.0.0/8`, narrow it to the Cloud SQL private range); HTTPS anywhere except the metadata server (kube-apiserver for sidecars) | 9090, 10902, 9093, 3200, 9094, 5432, 3306, 443 |
| OTel Collector | Tempo 4317/4318; other Collector pods 4317/4318; HTTPS anywhere except the metadata server (kube-apiserver for `k8sattributes` and the load-balancing exporter's k8s resolver) | 4317, 4318, 443 |
| Tempo | Tempo components; Prometheus (remote write); SeaweedFS S3 in `object-storage` (optional fallback only); test Kafka; HTTPS + Kafka anywhere except the metadata server (GCS, kube-apiserver, managed Kafka) | all, 9090, 8333, 9092, 9093, 443 |
| Tempo | GKE metadata server for Workload Identity: `169.254.169.254` ports 80 and 988, `169.254.169.252` port 988 | 80, 988 |

What is **not** protected:

- With the default `TLS_MODE=cloudflare` and SSL mode "Full", the Cloudflare-to-origin hop is encrypted but Cloudflare
  does **not** validate the origin certificate, so an attacker who can intercept that path could impersonate the
  origin. "Full (strict)" closes this: use `TLS_MODE=letsencrypt`, or load a Cloudflare Origin CA certificate as
  Traefik's default certificate (not automated here).
- The allow-list trusts every Cloudflare edge IP, not just this zone; Authenticated Origin Pulls (mTLS from Cloudflare)
  are not configured.
- `loadBalancerSourceRanges` lists only Cloudflare's IPv4 ranges because the LB is IPv4-only; the IPv6 ranges in the
  Middlewares and `trustedIPs` are inert there. An IPv6 or dual-stack LB needs the IPv6 list added to the Service.
- The sample apps have no login and include a CPU/memory-heavy endpoint on purpose; Cloudflare rate limits are not set.
- Grafana's own login is the only authentication for the UI.
- Admission webhook ports (cert-manager 10250, Prometheus operator 10250, Tempo rollout-operator 8443) accept connections from any pod, because the
  kube-apiserver source cannot be selected portably on GKE. They only serve TLS admission requests.
- Without `networkpolicies-egress.yaml` (the lab), egress is open in every namespace. traefik, cert-manager and
  monitoring keep open egress in production too (Cloudflare API, Let's Encrypt, Alertmanager receivers, scrape targets
  on node IPs).
- monitoring is Pod Security `privileged` (node-exporter needs hostNetwork, hostPID, hostPort and host mounts);
  node-exporter is outside NetworkPolicy because it uses the host network.

## ✅ Production checklist

| Area | Item | Where / how |
|---|---|---|
| HA sizing | 3+ nodes in 3 zones so the hard node spread and the soft zone spread place 3 Traefik pods | Node pool; `traefik-values.yaml` |
| HA sizing | Re-size Traefik from load tests: CPU throttling, `traefik_entrypoint_request_duration_seconds` p99, memory vs 460MiB `GOMEMLIMIT` | Grafana; raise `resources` and/or replicas |
| HA sizing | Optional: HPA (`autoscaling.enabled`, 3-6 replicas on CPU) instead of a fixed 3 | `traefik-values.yaml` |
| TLS | Prefer "Full (strict)": `TLS_MODE=letsencrypt`, or a Cloudflare Origin CA certificate as Traefik's default | [TLS modes](#-tls-modes) |
| TLS | Consider Authenticated Origin Pulls so only this zone's Cloudflare traffic is accepted | Cloudflare + Traefik `clientAuth` TLSOption |
| Network | Apply `networkpolicies-egress.yaml` after `scripts/verify.sh` passes with it on a staging cluster | [Run it](#-run-it) step 7 |
| Network | Set the Kafka ports in `tempo-egress` if the managed service does not use 9092/9093 | `networkpolicies-egress.yaml` |
| Network | Keep the Cloudflare ranges in sync in `traefik-values.yaml` (`trustedIPs`, `loadBalancerSourceRanges`) and both `cloudflare-only` Middlewares | [Cloudflare IP ranges](https://www.cloudflare.com/ips/) |
| Network | Set `GRAFANA_DB_CIDR` in `grafana-egress` to the database's private range (default `10.0.0.0/8`) and keep only its port | `networkpolicies-egress.yaml` |
| Backups | Nothing here is stateful except certificates (letsencrypt): they are re-issued automatically; back up the ACME account key Secrets `letsencrypt-*-account-key` only to avoid re-registration. Everything else is re-created from Git | `kubectl -n cert-manager get secret` |
| Upgrades | Bump chart version + image tag + digest together; render with `helm template` and diff; roll out to the lab first; PDBs keep the edge up during the rollout | `scripts/deploy.sh` pins |
| Upgrades | Rollback: `helm rollback <release> -n <namespace>`; cert-manager CRDs are kept on uninstall (`crds.keep: true`) | |
| Monitoring | Add PrometheusRules for the edge SLOs below; with letsencrypt, cert-manager metrics are scraped (`prometheus.servicemonitor.enabled: true`, 9402 allow) for `helm/kube-prometheus-stack/rules/cert-manager.yaml` | `cert-manager-values.yaml`, `cert-manager.yaml` |
| SLOs | Edge availability 99.9% / 30 days: share of `traefik_service_requests_total` without `code=~"5.."` | Prometheus |
| SLOs | Edge latency: p95 of `traefik_entrypoint_request_duration_seconds` on `websecure` < 1 s (includes backend time; matches the apps' p95 SLO) | Prometheus |
| Cost | Production adds 2 Traefik pods (0.4 vCPU / 384Mi requested) and, with letsencrypt, 3 cert-manager pods; the LB and Cloudflare are unchanged | `traefik-values.yaml` |
| Quota | Revisit `tempo-apps-budget` when replica counts change; consider a quota for hermes in its own manifests (its containers set no CPU limit, so a `limits.cpu` quota would reject them) | `limitrange.yaml` |
| Runbooks | Edge troubleshooting below; [Traefik ping/health check](https://doc.traefik.io/traefik/operations/ping/); [cert-manager troubleshooting](https://cert-manager.io/docs/troubleshooting/); [Cloudflare 5xx errors](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/) | |

## 🛠️ Operations and troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Every request returns 403 | Source IP SNATed (LB not `Local`) or Cloudflare ranges changed | Check `externalTrafficPolicy`; update ranges from the Cloudflare IP list in both Traefik files |
| Cloudflare error 526 | SSL mode "Full (strict)" with `TLS_MODE=cloudflare` (self-signed default cert), or a letsencrypt certificate not ready | Use "Full", or `TLS_MODE=letsencrypt` and wait for `READY True` |
| Cloudflare error 525 | TLS handshake to the origin failed (Traefik down or 443 blocked) | `kubectl -n traefik get pods,svc`; check `traefik-ingress` NetworkPolicy |
| Certificate stuck `False` | Token missing/wrong scope, or DNS-01 propagation | `kubectl describe challenge -A`; recreate the Secret from the file |
| Creating any cert-manager resource times out | Webhook unreachable | `kubectl -n cert-manager get netpol webhook-from-apiserver` (from `cert-manager.yaml`); webhook pods ready |
| Grafana crash-loops with the egress file applied (prod) | Database egress blocked | Check `GRAFANA_DB_CIDR` and the port in `grafana-egress` |
| Cloudflare error 522 / origin unreachable after changing ranges | `loadBalancerSourceRanges` out of date | Update the list from the Cloudflare IPv4 ranges and re-run the Traefik `helm upgrade` |
| `helm upgrade` of kube-prometheus-stack or a PrometheusRule apply times out | Operator admission webhook unreachable | `kubectl -n monitoring get netpol operator-webhook-ingress`; operator pod ready |
| 404 from Traefik | IngressRoute namespace not watched, or Service/port missing | Check `providers.kubernetesCRD.namespaces`; `kubectl get svc -n tempo-apps` |
| Traefik pod `Pending` (prod) | Fewer schedulable nodes than replicas (hard node spread) | Add nodes, or scale down; the lab overlay uses 1 replica |
| `kubectl drain` waits on a Traefik pod | PDB `minAvailable: 2` with a replica not ready | Wait for the replacement pod to become ready |
| Redirect loop in the browser | Cloudflare "Flexible" without `X-Forwarded-Proto: https` | Use SSL mode "Full" or "Full (strict)" |
| Pod rejected: `violates PodSecurity "restricted:latest"` | Missing `runAsNonRoot`, seccomp, `allowPrivilegeEscalation: false` or `drop: [ALL]` | Add them (debug pods: `kubectl run --overrides`) |
| Pod rejected: `exceeded quota: tempo-apps-budget` | Namespace budget used up | `kubectl -n tempo-apps describe quota`; raise it in `limitrange.yaml` |
| Apps send no traces | NetworkPolicy blocks 4317/4318 (ingress or, with the egress file, egress) | `kubectl -n observability get netpol otel-collector-from-senders`; `kubectl -n tempo-apps get netpol apps-egress` |
| Grafana shows no span metrics | Tempo remote write blocked | Check `prometheus-ingress` in monitoring allows Tempo on 9090 |
| Tempo cannot write to GCS (egress file applied) | Metadata server or 443 blocked | `kubectl -n observability get netpol tempo-egress -o yaml` |
| Name resolution fails (egress file applied) | DNS pods carry other labels than `k8s-app=kube-dns` / `node-local-dns` | `kubectl -n kube-system get pods --show-labels` and adjust the DNS rule |
| Node drain or Tempo scale-down rejected: `failed calling webhook ... tempo-rollout-operator` (prod) | Rollout-operator webhook port blocked or pod down | `kubectl -n observability get netpol tempo-rollout-operator-webhook`; rollout-operator pod ready |
| Grafana has no Alertmanager data | `alertmanager-ingress` missing | `kubectl -n monitoring get netpol alertmanager-ingress` |
| Traefik install fails: `You have to deploy monitoring.coreos.com/v1 first` | kube-prometheus-stack not installed yet | Install kube-prometheus-stack first, then re-run the Traefik `helm upgrade` |
| `up{namespace="traefik"}` is 0 | NetworkPolicy or metrics Service missing | `kubectl -n traefik get netpol/traefik-metrics-from-prometheus svc/traefik-metrics` |

Upgrade: bump the `--version` (and image tag + digest) and re-run `scripts/deploy.sh traefik` or `certmanager`.
Rollback: `helm rollback <release> -n <namespace>`. Logs: `kubectl -n traefik logs deploy/traefik` (JSON access log,
request headers dropped).

## 🧪 Tests

| Test (2026-11-08) | Command (from `k8s/`) | Result | What it proves |
|---|---|---|---|
| Schema, strict | `kubeconform -strict -kubernetes-version 1.36.0` + CRDs catalog on all manifests | 59/59 valid (8 files) | Manifests match the Kubernetes 1.36 and Traefik/cert-manager CRD schemas |
| Charts, prod + lab | `helm lint` and `helm template` with `*-values.yaml` (+ `*-values-lab.yaml`; Traefik with `--api-versions monitoring.coreos.com/v1`), rendered output through `kubeconform` | 0 failures; all rendered objects valid | Values keys exist in Traefik 42.3.1 / cert-manager v1.21.3 and render valid objects |
| Server-side dry run | `kubectl apply --dry-run=server -f <file>` for namespaces, both NetworkPolicy files, limitrange | Accepted | The API server admits every object |
| Pod Security | `kubectl label --dry-run=server --overwrite ns <ns> pod-security.kubernetes.io/enforce=restricted` | No violations in traefik, observability, tempo-apps, hermes (and cert-manager while letsencrypt ran); node-exporter violates in monitoring | Running pods comply where `restricted` is enforced |
| Lab overlay = live | `helm template` with the lab overlay vs `helm get manifest` | Same except the image digest pin and Traefik shutdown grace settings | The lab profile reproduces the running lab without growing requests |
| Origin TLS in `cloudflare` mode | Route with `tls: {}` through Cloudflare "Full" | Origin presents Traefik's default certificate; `/api/health` 200 via Cloudflare | Mode `cloudflare` works without cert-manager |
| End to end | `scripts/verify.sh` | See [`../scripts/`](../scripts/) | Routing, isolation and the trace pipeline on the live cluster |

Schema gaps (reported by kubeconform as "could not find schema", not as invalid): the cert-manager chart's own
CustomResourceDefinitions and Tempo's `ZoneAwarePodDisruptionBudget` (rollout-operator CRD, production Tempo) have no
schema in the Kubernetes or CRDs-catalog sets; they are checked by `helm lint` (and a server-side dry run where the
CRDs are installed) only.

## 🧹 Teardown

```bash
kubectl delete --ignore-not-found -f networkpolicies-egress.yaml
kubectl delete -f limitrange.yaml -f networkpolicies.yaml -f ingressroutes.yaml
kubectl delete --ignore-not-found -f certificates.yaml
helm uninstall traefik -n traefik
kubectl delete --ignore-not-found -f cluster-issuer.yaml
helm uninstall cert-manager -n cert-manager   # letsencrypt only; CRDs are kept (crds.keep: true)
kubectl delete --ignore-not-found -f cert-manager.yaml
```

`scripts/teardown.sh` removes the releases and the namespaces for the whole project.

## 📌 Pinned versions

| Component | Chart | Image (tag @ digest) |
|---|---|---|
| Traefik | traefik/traefik 42.3.1 | `docker.io/traefik:v3.7.17@sha256:f4bb143d1135a579b630ed491e17ec50f6f7c9c6a30585ff3d385471d2a86f5a` |
| cert-manager controller | jetstack/cert-manager v1.21.3 | `quay.io/jetstack/cert-manager-controller:v1.21.3@sha256:9f4f96a33c7774cef24466fcd85031997531a03a8d117f151126baa8d1290dcc` |
| cert-manager webhook | (same chart) | `quay.io/jetstack/cert-manager-webhook:v1.21.3@sha256:055ac8e9de6a0ba6763794838fe38944acc650f68ebe1b01dd8be079e580f458` |
| cert-manager cainjector | (same chart) | `quay.io/jetstack/cert-manager-cainjector:v1.21.3@sha256:083d0e906f8eb44e255fe4ff817ae54e49f9ed82e22f1011bb4e9e4f4b8a641f` |
| cert-manager startupapicheck | (same chart) | `quay.io/jetstack/cert-manager-startupapicheck:v1.21.3@sha256:1c519d4afca1413d1e4ccd78bdc756184418ab55a34569a3b3de39d32f9974e1` |
| cert-manager acmesolver | (same chart) | `quay.io/jetstack/cert-manager-acmesolver:v1.21.3@sha256:c8c1225bb2fe8ab37a330b77f0d8c2ee6a41210fcb54fc07ca606ab9a022b8b7` |

All digests are multi-arch indexes (manifest lists), so they work on amd64 and arm64 nodes.

## 🔗 References

- [Traefik Kubernetes CRD provider](https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-crd/)
- [Traefik Helm chart](https://github.com/traefik/traefik-helm-chart)
- [Traefik Prometheus metrics](https://doc.traefik.io/traefik/reference/install-configuration/observability/metrics/)
- [cert-manager Cloudflare DNS-01](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
- [cert-manager best practice (HA, PDBs, NetworkPolicies)](https://cert-manager.io/docs/installation/best-practice/)
- [Let's Encrypt staging environment](https://letsencrypt.org/docs/staging-environment/)
- [Cloudflare SSL/TLS encryption modes](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/)
- [Cloudflare Origin CA certificates](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
- [Cloudflare IP ranges](https://www.cloudflare.com/ips/)
- [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [GKE Workload Identity Federation (metadata server and network policy)](https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity)
- [GKE NodeLocal DNSCache](https://cloud.google.com/kubernetes-engine/docs/how-to/nodelocal-dns-cache)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Resource quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
