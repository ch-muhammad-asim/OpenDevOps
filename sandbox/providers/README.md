# 🔑 `providers/`: OpenShell credential providers

OpenShell **provider profiles**. A provider keeps an API key **outside** the sandbox: Hermes only sees the placeholder `openshell:resolve:env:NVIDIA_API_KEY`, and the OpenShell supervisor swaps in the real key **only** on requests that match the profile's endpoint rules.

> 📘 Background: [`../README.md`](../README.md) (NVIDIA models) · Kubernetes: [`../KUBERNETES.md`](../KUBERNETES.md) · variables: [`../ENVIRONMENT.md` §6.3](../ENVIRONMENT.md#63-set-by-openshell-credential-provider)

---

## 📁 Files

| File | What it does |
|---|---|
| [`hermes-nvidia.yaml`](hermes-nvidia.yaml) | Profile `hermes-nvidia` for the **NVIDIA API Catalog**. One credential (`NVIDIA_API_KEY`, sent as `Authorization: Bearer`). Endpoint `integrate.api.nvidia.com:443`, REST rules **enforced**: only `POST /v1/chat/completions` and `GET /v1/models`. Only Hermes's bundled Python may use it (programs it starts inherit that; [`../SECURITY.md`](../SECURITY.md) R5). |

---

## ▶️ How it's used

You don't run it by hand. [`../scripts/set_nvidia_key.sh`](../scripts/set_nvidia_key.sh) lints and imports the profile, stores the key (typed at a hidden prompt) as provider `nvidia` and attaches it to the sandbox. On Kubernetes, the bootstrap Job in [`../k8s/`](../k8s/) does the same with the profile mounted from a ConfigMap. The manual equivalent:

```bash
openshell profile lint   -f sandbox/providers/hermes-nvidia.yaml
openshell profile import -f sandbox/providers/hermes-nvidia.yaml
read -rs NVIDIA_API_KEY; export NVIDIA_API_KEY
openshell provider create --name nvidia --type hermes-nvidia --from-existing
unset NVIDIA_API_KEY
openshell sandbox provider attach hermes nvidia --wait
```

---

## ✏️ Changing it

- Adding a route widens what Hermes can do with the key. Keep the list minimal, and check with [`../scripts/policy_check.sh`](../scripts/policy_check.sh), which proves the **effective** policy (including this provider's rule) stays inside [`../security/boundary.yaml`](../security/boundary.yaml).
- After a Hermes image upgrade, check the Python path under `binaries:` still exists in the image.
