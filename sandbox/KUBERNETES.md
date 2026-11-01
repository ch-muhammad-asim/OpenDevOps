# ☸️ NVIDIA API Key for Hermes on Kubernetes (Secrets + OpenShell providers)

This guide shows how to give **Hermes Agent** its **NVIDIA API key** (`nvapi-…`, for `integrate.api.nvidia.com`) when OpenShell runs on **Kubernetes**, using a Kubernetes **Secret** as the source of truth, without ever handing the real key to Hermes.

On Docker, `sandbox/scripts/set_nvidia_key.sh` puts the key into OpenShell's credential store as the `nvidia` provider. On Kubernetes, the same idea works with manifests in [`k8s/`](k8s/). New to the setup? Read [README.md](README.md) and [SECURITY.md](SECURITY.md) first. 🙂

> 🧪 **Status.** The manifests are validated (kubeconform, server-side dry run, an end-to-end test on a local kind cluster with a **dummy** key; see [Validation record](#-validation-record)). The live demo server still runs OpenShell's **Docker** driver; nothing here is deployed there.

## 📖 Contents

0. [The short version](#-the-short-version)
1. [Native OpenShell features vs the pattern we add](#-native-openshell-features-vs-the-pattern-we-add)
2. [Step 1: Create the Secret](#-step-1-create-the-secret)
3. [Step 2: Consume it (file vs env) and hand it to OpenShell](#-step-2-consume-it-file-vs-env-and-hand-it-to-openshell)
4. [Step 3: Harden it](#️-step-3-harden-it)
5. [Step 4: Production secret sources](#-step-4-production-secret-sources)
6. [Step 5: Rotate the key](#-step-5-rotate-the-key)
7. [Step 6: Verify (without printing the key)](#-step-6-verify-without-printing-the-key)
8. [Files](#-files)
9. [Validation record](#-validation-record)

---

## ⚡ The short version

How the NVIDIA key travels on Kubernetes (the live Docker deployment's architecture is [README.md → Architecture at a glance](README.md#architecture-at-a-glance)):

```text
 kubectl (stdin) ──► Secret hermes/nvidia-api-key ──(read-only file)──► bootstrap Job
                                                                          │ openshell provider create|update --from-existing
                                                                          ▼
                                          OpenShell gateway credential store (encrypted DB, or
                                          the native kubernetes-secrets / vault credential driver)
                                                                          │
                     Hermes sandbox sees only  openshell:resolve:env:NVIDIA_API_KEY
                     supervisor injects the real key ONLY on POST /v1/chat/completions,
                     GET /v1/models at integrate.api.nvidia.com:443 (providers/hermes-nvidia.yaml)
```

```bash
read -rs NVIDIA_API_KEY                                  # 1. create the Secret from stdin
printf '%s' "$NVIDIA_API_KEY" | kubectl create secret generic nvidia-api-key -n hermes \
  --from-file=api-key=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
unset NVIDIA_API_KEY
kubectl apply -k sandbox/k8s                             # 2. RBAC, NetworkPolicy, bootstrap Job
kubectl -n hermes wait --for=condition=complete job/hermes-provider-bootstrap --timeout=180s
```

(Create the namespace first with `kubectl apply -f sandbox/k8s/namespace.yaml`, and the Job's inputs from [Step 2](#-step-2-consume-it-file-vs-env-and-hand-it-to-openshell).)

---

## 🧭 Native OpenShell features vs the pattern we add

Everything marked **Native** was checked in the OpenShell **v0.1.6** source and docs (paths below are in the [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) repo at tag `v0.1.6`). Everything marked **Pattern** is our recommendation, built from standard Kubernetes objects.

| | What | Where it is documented |
|---|---|---|
| ✅ **Native** | **Kubernetes compute driver**, installed with the Helm chart `oci://ghcr.io/nvidia/openshell/helm-chart`. The gateway creates a `Sandbox` resource (Agent Sandbox CRD `sandboxes.agents.x-k8s.io`, installed separately), a supervisor Pod, a Service and a workspace PVC. | `docs/kubernetes/setup.mdx` |
| ✅ **Native** | **NetworkPolicy** for sandboxes: OpenShell creates policies that allow only supervisor ingress to the workload and deny workload-initiated connections. The docs require a CNI that **enforces** ingress and egress NetworkPolicy. The chart also ships a sandbox SSH ingress policy (`networkPolicy.enabled`). | `docs/kubernetes/setup.mdx`, `deploy/helm/openshell/templates/networkpolicy.yaml` |
| ✅ **Native** | **Provider credential sources** in the CLI: `--from-existing` (profile `discovery`, reads `NVIDIA_API_KEY` from the CLI's environment), `--credential KEY=VALUE` or bare `--credential KEY` (env lookup), `--from-oidc-token`, `--from-gcloud-adc`, and `--runtime-credentials` (for token-grant profiles resolved at runtime, **not** for static API keys). | `docs/how-it-works/providers/overview.mdx`, `docs/how-it-works/providers/profiles.mdx`, `crates/openshell-cli/src/main.rs` |
| ✅ **Native** | **Where the gateway stores provider credentials.** Default: AES-256-GCM envelopes in the gateway database, with a key-encryption key the Helm chart keeps in a retained Secret (`server.credentialStorage.existingSecret` for GitOps). Optional **credential drivers** (one at a time): `kubernetes-secrets` (Helm `server.credentialDrivers.kubernetesSecrets.*`) or `vault` (`server.credentialDrivers.vault.*`, Kubernetes auth). | `docs/how-it-works/gateways/configuration.mdx#credential-drivers`, `docs/kubernetes/setup.mdx` ("Store provider credentials in Kubernetes Secrets"), `deploy/helm/openshell/values.yaml`, `docs/extensibility/drivers.mdx` |
| ✅ **Native** | **Placeholders**: the agent gets `openshell:resolve:env:KEY`; the supervisor resolves it only for the provider profile's endpoints and only if network policy allows the binary and destination. | `docs/how-it-works/providers/overview.mdx` ("How Credential Injection Works"), `docs/how-it-works/policies/schema.mdx` |
| ✅ **Native** | **Non-interactive CLI login**: with `OPENSHELL_OIDC_CLIENT_SECRET` set, the CLI uses the OIDC client-credentials flow ("Use that mode for CI and other non-interactive automation"). | `docs/how-it-works/gateways/authentication.mdx` |
| ❌ **Not native** | **A provider that references *your* existing Kubernetes Secret.** The `kubernetes-secrets` driver writes **OpenShell-managed** Secrets with hash-derived names in its own namespace and rejects handles outside that namespace; it does not import a Secret you created. Credential values still enter through `provider create/update` ("New provider create/update requests still submit credential values through the normal API"). | `docs/how-it-works/gateways/configuration.mdx`, `crates/openshell-driver-kubernetes-secrets/src/lib.rs` |
| ❌ **Not native** | An official OpenShell **CLI container image**. v0.1.6 publishes `gateway`, `supervisor`, `sandbox` images and Linux CLI `.deb`/`.rpm` packages with `openshell-checksums-sha256.txt`. | `docs/kubernetes/setup.mdx`, `install.sh` |
| 🧩 **Pattern** | **Bootstrap Job**: mount `hermes/nvidia-api-key` as a read-only file, run `openshell provider create|update --from-existing` against the gateway with the key only in that one process's environment. Re-run it to rotate. | [`k8s/provider-bootstrap-job.yaml`](k8s/provider-bootstrap-job.yaml), [`k8s/provider-bootstrap.sh`](k8s/provider-bootstrap.sh) |
| 🧩 **Pattern** | Dedicated namespace, `resourceNames` RBAC, default-deny NetworkPolicy, external secret managers, rotation runbook. | this guide |

> 💡 **Two Secrets, two jobs.** `hermes/nvidia-api-key` is *your* source of truth (what operators and secret managers write). The gateway's copy lives in *its* store (encrypted DB, or the `kubernetes-secrets`/`vault` driver). The bootstrap Job keeps the second in sync with the first. If you enable the `kubernetes-secrets` driver, use a **dedicated** credential namespace: the chart's Role grants the gateway read/write on **all** Secrets there, because managed names can't be listed in `resourceNames` (`configuration.mdx`).

---

## 🔐 Step 1: Create the Secret

**Namespace first** (Pod Security "restricted" is enforced on it):

```bash
kubectl apply -f sandbox/k8s/namespace.yaml
```

**From stdin, input hidden** (recommended). The key never appears in shell history, `ps` output or a file:

```bash
read -rs NVIDIA_API_KEY                     # paste nvapi-..., nothing is echoed
printf '%s' "$NVIDIA_API_KEY" | kubectl create secret generic nvidia-api-key -n hermes \
  --from-file=api-key=/dev/stdin
unset NVIDIA_API_KEY
```

**From a protected file** (for example one your password manager wrote, mode `0600`):

```bash
kubectl create secret generic nvidia-api-key -n hermes --from-file=api-key=/path/to/nvidia.key
shred -u /path/to/nvidia.key   # if it was a temporary file
```

`printf '%s'` matters: it adds no trailing newline. (The bootstrap script strips whitespace anyway.)

⚠️ **Avoid `--from-literal=api-key=nvapi-…`.** The key lands in your shell history and is visible to other users in `ps`/`/proc/<pid>/cmdline` while `kubectl` runs. If you used it, rotate the key and clear the history entry.

🚫 **Never commit a real key.** [`k8s/secret.example.yaml`](k8s/secret.example.yaml) is a **placeholder** that only documents the shape (name `nvidia-api-key`, namespace `hermes`, key `api-key`). It is deliberately **not** in `kustomization.yaml`: applying it would overwrite the real key. `stringData`/`data` in a manifest is only base64, not encryption. For GitOps, see [Step 4](#-step-4-production-secret-sources).

---

## 📦 Step 2: Consume it (file vs env) and hand it to OpenShell

### File mount vs environment variable

| | 📄 Read-only file (recommended) | 🌱 Env var via `secretKeyRef` (less preferable) |
|---|---|---|
| Child processes | Not inherited | Inherited by every process the container starts |
| Env dumps, debug pages, crash reports, core files | Not included | Included |
| `/proc/<pid>/environ` | n/a | Readable by anything with the same uid |
| `kubectl describe pod` | Shows the volume, not the value | Shows the reference, not the value |
| Rotation | kubelet refreshes the file (not for `subPath` mounts) | Fixed at start: needs `kubectl rollout restart` / new pod |
| Example | [`k8s/provider-bootstrap-job.yaml`](k8s/provider-bootstrap-job.yaml) | [`k8s/examples/env-secretkeyref.example.yaml`](k8s/examples/env-secretkeyref.example.yaml) |

The file is mounted at `/var/run/secrets/nvidia/api-key` with `defaultMode: 0400`, `readOnly: true`, no `subPath`. Because the container runs as uid `65532`, the pod sets `fsGroup: 65532`; the kubelet then makes the file **`0440 root:65532`** (tested: without `fsGroup` it is `0400 root:root` and the non-root container cannot read it). No world bits either way.

### Mapping onto OpenShell providers

Hermes never mounts this Secret. On Kubernetes, Hermes runs as an OpenShell sandbox workload created by the Kubernetes driver; it gets `NVIDIA_API_KEY=openshell:resolve:env:NVIDIA_API_KEY` from the attached `nvidia` provider, exactly as on Docker. The only open question is **how the key gets into the gateway**, and the answer is the CLI (or SDK/gRPC API); see the table above. So:

1. **Provider profile** (once): the Job imports [`providers/hermes-nvidia.yaml`](providers/hermes-nvidia.yaml) if the gateway doesn't have it. Give it to the Job as a ConfigMap (kustomize can't load files outside `k8s/`):
   ```bash
   kubectl -n hermes create configmap hermes-nvidia-profile \
     --from-file=hermes-nvidia.yaml=sandbox/providers/hermes-nvidia.yaml
   ```
2. **Gateway access for the Job.** Kubernetes gateways authenticate users with **OIDC** (recommended) or a trusted reverse proxy (`docs/kubernetes/access-control.mdx`). Create an IdP client for the Job with only the roles needed for profiles and providers, then:
   ```bash
   read -rs OIDC_SECRET; printf '%s' "$OIDC_SECRET" | kubectl -n hermes create secret generic \
     openshell-provider-bootstrap-oidc --from-file=client-secret=/dev/stdin; unset OIDC_SECRET
   # Private gateway CA (public data). The chart's CA is in openshell/openshell-client-tls (ca.crt):
   kubectl -n openshell get secret openshell-client-tls -o jsonpath='{.data.ca\.crt}' | base64 -d \
     | kubectl -n hermes create configmap openshell-gateway-ca --from-file=ca.crt=/dev/stdin
   ```
   Then set `GATEWAY_URL`, `OIDC_ISSUER`, `OIDC_CLIENT_ID` (and `OIDC_AUDIENCE`) in the Job. Make sure the gateway certificate's SANs cover the hostname in `GATEWAY_URL`.
3. **CLI image.** OpenShell v0.1.6 has no CLI image, so build a small one and pin it by digest (the Job's `image:` is a placeholder). Verify the package the same way `install.sh` does:
   ```dockerfile
   FROM debian:bookworm-slim@sha256:<digest>
   ARG OPENSHELL_VERSION=v0.1.6
   ARG OPENSHELL_DEB          # the openshell .deb for your arch, as named in the release checksums file
   ADD https://github.com/NVIDIA/OpenShell/releases/download/${OPENSHELL_VERSION}/openshell-checksums-sha256.txt /tmp/
   ADD https://github.com/NVIDIA/OpenShell/releases/download/${OPENSHELL_VERSION}/${OPENSHELL_DEB} /tmp/
   RUN cd /tmp && grep " \*\?${OPENSHELL_DEB}\$" openshell-checksums-sha256.txt | sed 's/ \*/  /' | sha256sum -c - \
    && apt-get update && apt-get install -y --no-install-recommends /tmp/${OPENSHELL_DEB} \
    && rm -rf /tmp/* /var/lib/apt/lists/*
   USER 65532:65532
   ```
4. **Run the Job.** It checks the file, registers the gateway, imports the profile if needed, then runs `provider update nvidia --from-existing --wait` (or `provider create … --type hermes-nvidia --from-existing`). `NVIDIA_API_KEY` exists only in the environment of that one CLI process; all CLI output is discarded; nothing is printed.
   ```bash
   kubectl apply -k sandbox/k8s
   kubectl -n hermes wait --for=condition=complete job/hermes-provider-bootstrap --timeout=180s
   kubectl -n hermes logs job/hermes-provider-bootstrap
   ```
5. **Attach** the provider to the Hermes sandbox: set `SANDBOX_NAME=hermes` in the Job, or create the sandbox with `--provider nvidia` (`docs/how-it-works/providers/overview.mdx`, "Attach Providers to Sandboxes").

> ℹ️ An **initContainer** variant works too (same script, in front of a long-running workload), but a Job is easier to re-run on rotation and keeps the key out of long-lived pods.

---

## 🛡️ Step 3: Harden it

### RBAC: one verb, one object

[`k8s/rbac.yaml`](k8s/rbac.yaml) gives the `hermes-provider-bootstrap` ServiceAccount **`get` on `secret/nvidia-api-key` only** (`resourceNames`), with no `list`/`watch` (a `list` returns every Secret's data in the namespace). The ServiceAccount has `automountServiceAccountToken: false`: the kubelet mounts Secret volumes for the pod, so the pod needs no API token. The Role bounds any API-based reader you add later and documents the grant.

For people: only the platform/on-call group should have `get` on Secrets in `hermes`. Remember that **anyone who can create pods** in the namespace can mount any Secret there; keep `create pods/jobs` as tight as `get secrets`.

### Encryption at rest with a KMS provider

Secrets are only base64 in etcd unless the API server encrypts them. Self-managed clusters: KMS v2 envelope encryption.

```yaml
# /etc/kubernetes/enc/encryption-config.yaml  (kube-apiserver --encryption-provider-config=...)
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - kms:
          apiVersion: v2
          name: cloud-kms                       # your KMS plugin
          endpoint: unix:///var/run/kmsplugin/socket.sock
          timeout: 3s
      - identity: {}                           # reads not-yet-encrypted data; keep it LAST
```

Then re-write existing Secrets so they are encrypted (output goes straight back to the API server, never to the terminal or a CI log): `kubectl get secrets -n hermes -o json | kubectl replace -f - >/dev/null`.

Managed clusters:

| Platform | Setting |
|---|---|
| ☁️ **EKS** | Envelope encryption with a customer-managed KMS key: `aws eks associate-encryption-config --cluster-name <c> --encryption-config '[{"resources":["secrets"],"provider":{"keyArn":"arn:aws:kms:..."}}]'` (or at creation). Recent EKS versions also apply default envelope encryption with an AWS-owned key (check your cluster version); a customer-managed key adds your own key policy, rotation and CloudTrail trail. |
| ☁️ **GKE** | Application-layer secrets encryption with a Cloud KMS key (`--database-encryption-key`). |
| ☁️ **AKS** | KMS etcd encryption with Azure Key Vault (`--enable-azure-keyvault-kms`). |

The OpenShell gateway's own copy is encrypted separately (AES-256-GCM in its DB, or in your `kubernetes-secrets`/`vault` backend). Back up the gateway DB **and** its key-encryption key together (`configuration.mdx`).

### Don't expose it

- 🚫 Never run `kubectl get secret … -o yaml|json` in CI or shared terminals: base64 is not encryption, and CI logs live for months. Use the checks in [Step 6](#-step-6-verify-without-printing-the-key).
- ✅ `kubectl describe secret nvidia-api-key -n hermes` shows only `api-key: <N> bytes`.
- 🚫 No `env`/`printenv`/`set -x` in pods that hold the key; no env-dumping debug endpoints. The bootstrap script never prints the key, its length or a prefix.
- 📝 **Audit policy at `Metadata` for Secrets** so audit logs record *who read which Secret* without the payload:
  ```yaml
  apiVersion: audit.k8s.io/v1
  kind: Policy
  omitStages: ["RequestReceived"]
  rules:
    - level: Metadata
      resources:
        - group: ""
          resources: ["secrets"]
    # ... your other rules; never Request/RequestResponse for secrets
  ```
  Alert on `get`/`list` of `secrets/nvidia-api-key` by anyone other than the expected identities.

### NetworkPolicy egress

[`k8s/networkpolicy.yaml`](k8s/networkpolicy.yaml) is default-deny for the `hermes` namespace, then:

- **bootstrap Job**: DNS + the OpenShell gateway (`openshell/openshell`, TCP 8080) only. It never talks to NVIDIA.
- **`hermes.opendevops.io/nvidia-egress: "true"`** pods (for example a one-request check): DNS + TCP 443 to public IPs.

⚠️ **NetworkPolicy matches IPs, not hostnames.** It cannot say "only `integrate.api.nvidia.com`". Options:

1. Keep the public-IP + port 443 rule (private, CGNAT, link-local and metadata `169.254.169.254` ranges excluded), or pin NVIDIA's ranges if you can maintain them.
2. Use a CNI with **FQDN policies**, for example Cilium:
   ```yaml
   apiVersion: cilium.io/v2
   kind: CiliumNetworkPolicy
   metadata: { name: nvidia-api-fqdn, namespace: hermes }
   spec:
     endpointSelector:
       matchLabels: { hermes.opendevops.io/nvidia-egress: "true" }
     egress:
       - toEndpoints:
           - matchLabels: { k8s:io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns }
         toPorts:
           - ports: [{ port: "53", protocol: ANY }]
             rules: { dns: [{ matchName: integrate.api.nvidia.com }] }
       - toFQDNs: [{ matchName: integrate.api.nvidia.com }]
         toPorts: [{ ports: [{ port: "443", protocol: TCP }] }]
   ```
3. Inside OpenShell sandboxes, the **hostname, method and path** control is OpenShell's own policy (`POST /v1/chat/completions`, `GET /v1/models` on `integrate.api.nvidia.com:443`, Hermes's Python only), enforced by the supervisor. Kubernetes NetworkPolicy is the outer layer.

And it only works if the CNI **enforces** it (OpenShell's docs make this a hard requirement for sandbox namespaces). Test it: a pod covered by the default-deny must fail to connect out.

---

## 🏭 Step 4: Production secret sources

All of these end in the same place: a Kubernetes Secret `hermes/nvidia-api-key` with key `api-key`, which the bootstrap Job reads. Pick by where your source of truth lives.

| Option | Choose it when | Notes |
|---|---|---|
| 🔄 **External Secrets Operator** (AWS Secrets Manager, Vault, GCP/Azure) | The key already lives in a cloud secret manager or Vault and you want rotation there to flow into the cluster. | Syncs into a normal Secret on `refreshInterval`; re-run the bootstrap Job after a sync (or trigger it from a controller). |
| 🔏 **Sealed Secrets** | Pure GitOps, no external secret manager; one cluster or a few. | Encrypted to the cluster's controller key: commit the `SealedSecret`, never the plain Secret. Back up the controller key. |
| 🧾 **SOPS** (age/KMS, with Flux or Argo CD plugins) | GitOps with keys in KMS/age, readable diffs, multi-cluster. | Only values are encrypted in git; decryption happens in the GitOps controller. |
| 💾 **Secrets Store CSI driver** | You want the key mounted **straight from the provider** as a file, optionally without a Kubernetes Secret at all. | Mount at `/var/run/secrets/nvidia/api-key` and the Job works unchanged. `secretObjects` sync to a Secret is optional. |
| 🏦 **OpenShell `vault` credential driver** (native) | You want the **gateway's** copy in Vault instead of its DB. | Complements the above; it changes where OpenShell stores credentials, not how you supply them. |

Example (External Secrets Operator; the `v1` API, use `v1beta1` on older ESO releases):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: nvidia-api-key, namespace: hermes }
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: aws-secrets-manager }
  target: { name: nvidia-api-key, creationPolicy: Owner }
  data:
    - secretKey: api-key
      remoteRef: { key: prod/hermes/nvidia-api-key }
```

---

## 🔁 Step 5: Rotate the key

1. **Create a new key** at build.nvidia.com (keep the old one until step 5 passes).
2. **Update the Secret from stdin** (idempotent, nothing printed):
   ```bash
   read -rs NVIDIA_API_KEY
   printf '%s' "$NVIDIA_API_KEY" | kubectl create secret generic nvidia-api-key -n hermes \
     --from-file=api-key=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
   unset NVIDIA_API_KEY
   ```
   (With ESO/Sealed Secrets/SOPS/CSI, rotate at the source instead.)
3. **Consumers pick it up:**
   - 📄 **Mounted files** are refreshed by the kubelet after its sync period plus cache delay (typically under a minute or two; 11 s in our kind test). **Not** for `subPath` mounts, which never update.
   - 🌱 **Env vars** do not change in running containers: `kubectl -n hermes rollout restart deployment/<name>` (or delete the pod).
4. **Push it into OpenShell** by re-running the bootstrap Job (Job pod templates are immutable, so delete first):
   ```bash
   kubectl -n hermes delete job hermes-provider-bootstrap --ignore-not-found
   kubectl apply -k sandbox/k8s
   kubectl -n hermes wait --for=condition=complete job/hermes-provider-bootstrap --timeout=180s
   ```
   `provider update --from-existing --wait` waits until attached sandboxes apply the new credentials for **new** processes. Placeholders are revision-scoped by default (`profiles.mdx`, `stable_placeholder`), so restart the Hermes processes afterwards, exactly as `set_nvidia_key.sh` does on Docker.
5. **Verify with one request** (see [Step 6](#-step-6-verify-without-printing-the-key)), then **revoke the old key** at NVIDIA.

---

## ✅ Step 6: Verify (without printing the key)

```bash
# Secret exists and has the expected key name (prints ["api-key"], never values)
kubectl get secret -n hermes nvidia-api-key -o jsonpath='{.data}' | jq 'keys'
kubectl describe secret -n hermes nvidia-api-key | sed -n '/^Data/,$p'     # api-key: N bytes

# RBAC: yes for the one Secret, no for anything else
SA=system:serviceaccount:hermes:hermes-provider-bootstrap
kubectl auth can-i get secret/nvidia-api-key --as=$SA -n hermes   # yes
kubectl auth can-i get secret/other          --as=$SA -n hermes   # no
kubectl auth can-i list secrets              --as=$SA -n hermes   # no

# File mode, owner, size inside a pod that mounts it (Job pods exit; use a debug pod with the same spec)
kubectl -n hermes exec <pod> -- stat -L -c '%a %U' /var/run/secrets/nvidia/api-key      # 440 root
kubectl -n hermes exec <pod> -- wc -c /var/run/secrets/nvidia/api-key                   # byte count only

# Bootstrap result
kubectl -n hermes logs job/hermes-provider-bootstrap                                     # "created" / "updated", no key
openshell provider get nvidia                       # credential key NAMES only, never values

# Hermes sees a placeholder, not the key
openshell sandbox exec -n hermes --no-tty -- sh -c \
  'case "$NVIDIA_API_KEY" in openshell:resolve:*) echo "OK placeholder";; "") echo "FAIL unset";; *) echo "FAIL real key";; esac'
```

**One test call** with the benchmark script (one round: a probe plus up to 3 small requests; the script redacts any `nvapi-…` in its output). The key goes through a file descriptor, not the environment or argv:

```bash
unset NVIDIA_API_KEY   # the script prefers the env var; make sure it reads the file
NVIDIA_API_KEY_FILE=<(kubectl get secret -n hermes nvidia-api-key -o jsonpath='{.data.api-key}' | base64 -d) \
  python3 sandbox/scripts/nvidia_bench.py --models <model-id> --requests 1 --out-dir "$(mktemp -d)"
```

For the end-to-end path through Hermes and the supervisor, send one chat to Hermes (`sandbox/scripts/verify.sh` with `LLM_CHECKS=1` on the Docker setup).

---

## 📁 Files

```
sandbox/k8s/
├── kustomization.yaml          🧩 kubectl apply -k: everything below except the two examples
├── namespace.yaml              🗂️ hermes namespace, Pod Security "restricted"
├── secret.example.yaml         🔐 PLACEHOLDER shape only, never applied, never a real key
├── rbac.yaml                   👤 ServiceAccount (no token) + get on secret/nvidia-api-key only
├── networkpolicy.yaml          🧱 default-deny, bootstrap → DNS + gateway, nvidia-egress → DNS + 443
├── provider-bootstrap-job.yaml 🚀 hardened Job, key as a read-only file
├── provider-bootstrap.sh       🔑 the Job's script (ConfigMap), never prints the key
└── examples/
    └── env-secretkeyref.example.yaml  ⚠️ env-var variant, less preferable
```

---

## 🧪 Validation record

Run on 2026-10-30 against the files above, with a **dummy** key (`nvapi-DUMMY-…`); the real NVIDIA key was never used in the cluster.

| Check | Command | Result |
|---|---|---|
| YAML parse | `python3 -c 'yaml.safe_load_all(...)'` per file; `sh -n provider-bootstrap.sh` | all OK |
| Schema | `kubeconform:v0.6.7 -strict -summary -kubernetes-version 1.34.0` (6 files; and the `kubectl kustomize` output) | 10/10 and 9/9 valid |
| Server dry run | `kubectl apply -k sandbox/k8s --dry-run=server` (kind v0.30.0, Kubernetes v1.34.0) | all objects accepted, no Pod Security warnings |
| Bootstrap Job | applied with a test overlay: `busybox:1.37.0` + a **stub** `openshell` that records calls | Job complete; ran `gateway add`, `profile lint/import`, `provider create --type hermes-nvidia --from-existing`; the stub confirmed `NVIDIA_API_KEY` was in env and matched the file |
| No leak | `grep` for the dummy value in Job logs, `kubectl describe pod`, events | 0 matches |
| File | `stat -L -c '%a %U %G'` | `440 root 65532` with `fsGroup`; `400 root root` and unreadable without it |
| Pod hardening | `id`, `/proc/self/status`, write to `/` | uid 65532, `CapEff 0`, `NoNewPrivs 1`, read-only root, no SA token mounted |
| RBAC | `kubectl auth can-i … --as=system:serviceaccount:hermes:hermes-provider-bootstrap` | get nvidia-api-key **yes**; get other / list / watch / update / get configmaps / other namespace **no** |
| NetworkPolicy | `nc -z` from pods | kindnetd v20250512 **enforced** egress: bootstrap pod DNS ok, 1.1.1.1:443 blocked; nvidia-egress pod 443 ok, port 80 blocked; unrestricted control pod reached both. Traffic to the API server ClusterIP was **not** blocked on kind. |
| Rotation | update Secret from stdin, watch the file hash | mounted file refreshed after 11 s; Job re-run (delete + apply) succeeded |

**Not exercised:** a real OpenShell gateway (no gateway, OIDC IdP or Agent Sandbox controller in kind), the real CLI image, provider attach, the Hermes placeholder check and the one-request NVIDIA call. Those steps follow the v0.1.6 docs cited above and the tested Docker flow in `set_nvidia_key.sh`.
