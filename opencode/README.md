# 🆓 OpenCode — remote Desktop and compatibility bridges

This directory contains **two different integration patterns**: (1) a **verified OpenCode Desktop → GCP OpenCode server** connection via an SSH port-forward (no bridge needed), and (2) optional **OpenAI-compatible bridges** for clients requiring that inference API. Free-model availability can vary by provider and quota.

The remote Desktop/server connection uses the **native OpenCode server protocol**; it is not an OpenAI-compatible inference provider. The bridge subprojects are a separate use case.

| Folder | Target | Endpoint |
|--------|--------|----------|
| [`hermes-desktop/`](hermes-desktop) | 🖥️ Hermes desktop app on macOS / Linux (custom endpoint) | `http://127.0.0.1:18282/v1` |
| [`opentunnel/`](opentunnel) | ✅ [Verified Mac OpenCode Desktop → GCP OpenCode server](opentunnel/remote-desktop-gcp.md), with SSH forwarding, architecture diagrams; optional OpenTunnel/Herdr install | Private SSH `http://127.0.0.1:8443` |
| [`kubernetes/`](kubernetes) | ☸️ Production: Hermes + bridge sidecar on GKE, read-only SRE agent, Traefik dashboard | in-pod loopback `:18282` |

```bash
# laptop
cd hermes-desktop && ./install-opencode-bridge.sh

# cluster (self-contained Kustomize root)
cd kubernetes && kubectl apply -k .
```

**For Hermes using a VM bridge:** see the [complete OpenAI-compatible bridge → Hermes guide](opentunnel/hermes-bridge-gcp.md) (separate, not yet verified). This does not change the already working Mac Desktop server connection.

**For the verified Mac workflow:** OpenCode Desktop → **Settings → Servers → Add server** → `http://127.0.0.1:8443` while a local SSH tunnel to the VM is running. [Full illustrated guide](opentunnel/remote-desktop-gcp.md).

**For a separate OpenAI-compatible bridge client:** configure that client's custom provider with its deployed bridge endpoint (for example `http://127.0.0.1:18282/v1`) and matching model and API key.

> ⚠️ Click **Test** *before* **Save** — Save persists the catalogue Test discovered. Skipping it leaves a single-entry model dropdown that looks like a stale cache but isn't.

Full docs, configuration and troubleshooting: [`hermes-desktop/README.md`](hermes-desktop/README.md) · [`kubernetes/README.md`](kubernetes/README.md).

The cluster deployment adds a four-layer read-only posture (OpenCode permission policy → read-only `kubectl` wrapper → read-only RBAC → unprivileged container) so the agent can investigate production without being able to change it — at $0 inference cost.
