# OpenTunnel + OpenCode + Herdr on a cloud VM

This folder documents the working Ubuntu/Debian **OpenCode + [OpenTunnel](https://opentunnel.xyz/) + [Herdr](https://herdr.dev/)** demo and secure ways to access services on a GCP VM from a local laptop.

**Observed on 2026-11-10:** In a fresh GCP browser-SSH session, OpenCode **v2.2.6**, OpenTunnel **v0.6.2**, a demo HTTP server on `127.0.0.1:3000`, and an OpenTunnel route were successfully created. The example `opencode/deepseek-v4.1-flash-free` prompt returned **`OK`**. Older attempts on other GCP/AWS VMs returned **“Free usage limit reached”**. That is consistent with a transient/upstream provider restriction, but the exact cause has **not** been independently established. Neither the script nor OpenTunnel guarantees free-model availability.

> **Networking distinction:** OpenTunnel exposes **incoming HTTPS** traffic to a locally running service. It is **not an outbound proxy**, does not change a VM's outbound IP, and does not bypass upstream quotas. SSH `-L` creates a private tunnel *from your laptop to a remote service*. Neither requires opening the demo application's port in the GCP firewall.

## ✅ Verified: OpenCode Desktop on Mac → GCP via private SSH

**End-to-end test passed on 2026-11-10.** OpenCode Desktop on macOS successfully connected to the GCP-hosted OpenCode server at `http://127.0.0.1:8443` over an encrypted SSH tunnel, and **DeepSeek V4.1 Flash Free returned responses**. Configure **Desktop → Settings → Servers → Add server → `gcp-vm`**, not Settings → Providers. This needs **no OpenAI-compatible bridge, no Hermes, and no OpenTunnel public route**.

👉 **[Complete verified setup, diagrams, request flow and troubleshooting](remote-desktop-gcp.md)**

## Files

- [`setup.sh`](setup.sh) — install OpenCode, OpenTunnel and Herdr, run a local-only HTTP demo, create a public demo route, and test an optional free model.
- [`remote-desktop-gcp.md`](remote-desktop-gcp.md) — the verified Mac OpenCode Desktop → GCP OpenCode backend solution, with three Mermaid diagrams, commands, test results, and security boundaries.
- This README — installer, GCP connectivity, SSH forwarding, OpenCode remote access, and troubleshooting.

## 1. Install on a fresh Ubuntu VM

```bash
git clone https://github.com/ch-muhammad-asim/OpenDevOps.git
cd OpenDevOps/opencode/opentunnel
chmod +x setup.sh
./setup.sh
```

The script needs `sudo` for apt packages. It downloads installer scripts from the **OpenCode/OpenTunnel/Herdr installer domains**: review those installer sources before using this on a sensitive machine. OpenCode CLI version defaults to `2.2.6` (override with `OPENCODE_VERSION`); OpenTunnel and Herdr installers install their currently published binaries. A successful setup should show:

```text
opencode v2.2.6
opentunnel 0.6.2
Hello from OpenTunnel!
Added route ... -> 127.0.0.1:3000
OK
```

The public `https://<route>.<tunnel>.opentunnel.xyz` URL forwards to the **demo server only**. OpenTunnel's URL is public: anyone possessing it may reach the exposed service. The installer may print a different OpenTunnel version later.

To check locally on the VM:

```bash
curl -fsS http://127.0.0.1:3000/
opentunnel --version
opencode --version
command -v herdr || echo 'Check Herdr installer output for PATH setup'
```

Herdr is installed using:

```bash
curl -fsSL https://herdr.dev/install.sh | sh
```

Herdr was **not part of the earlier successful GCP screenshot test**; the combined installer has not yet been run end-to-end. Reopen the terminal if the installer adds a new binary directory to your PATH. This script does not automatically run or expose Herdr.

## 2. Connect to the GCP VM using gcloud

Install and authenticate the [Google Cloud CLI](https://cloud.google.com/sdk/docs/install) on **your laptop**:

```bash
gcloud auth login
gcloud config set project YOUR_GCP_PROJECT_ID
gcloud compute instances list --project YOUR_GCP_PROJECT_ID
```

SSH into a VM (use its **instance name** and **zone**, not just the region):

```bash
gcloud compute ssh INSTANCE_NAME \
  --project YOUR_GCP_PROJECT_ID \
  --zone us-central1-c
```

If your VM has no external IP and your IAM/network setup permits Identity-Aware Proxy:

```bash
gcloud compute ssh INSTANCE_NAME \
  --project YOUR_GCP_PROJECT_ID --zone us-central1-c \
  --tunnel-through-iap
```

GCP access depends on your account's IAM permissions and OS Login/SSH-key configuration; IAP also needs the necessary IAM grant and firewall connectivity to SSH.

## 3. Use a PRIVATE SSH port-forward (recommended)

### A. Standard SSH, using an existing SSH hostname

**On the VM**, start a demo server that listens on loopback only (use a free port):

```bash
python3 -m http.server 8443 --bind 127.0.0.1
```

**On the laptop**, in a *different terminal*:

```bash
ssh -N -L 127.0.0.1:8443:127.0.0.1:8443 \
  cloud_user@d8d0041c.mylabserver.com
```

Open **http://127.0.0.1:8443/** on your laptop. This example uses HTTP on port 8443; **a port number does not imply HTTPS**. Replace the destination hostname and user with your actual SSH details.

The parts of `-L local_bind:local_port:remote_target:remote_port` are:

- `127.0.0.1:8443` before the second colon: bind only to your **laptop's loopback**.
- `127.0.0.1:8443` after it: the service reachable from the **remote VM**.
- `-N`: only forward ports; do not start a remote shell.

**Do not use `0.0.0.0` as the remote destination** (your example used `8443:0.0.0.0:8443`). `0.0.0.0` is a *listening/bind address*, not a reliable destination address. Use `127.0.0.1` if the remote service listens there.

### B. Forward over gcloud compute ssh

**On the VM**, keep the demo server or other service listening at `127.0.0.1:8443`. **On the laptop**:

```bash
gcloud compute ssh INSTANCE_NAME \
  --project YOUR_GCP_PROJECT_ID \
  --zone us-central1-c \
  -- -N -L 127.0.0.1:8443:127.0.0.1:8443
```

For a VM accessed through IAP, include `--tunnel-through-iap` **before** `--`:

```bash
gcloud compute ssh INSTANCE_NAME \
  --project YOUR_GCP_PROJECT_ID \
  --zone us-central1-c --tunnel-through-iap \
  -- -N -L 127.0.0.1:8443:127.0.0.1:8443
```

Then visit `http://127.0.0.1:8443/`. Keep the SSH process running while you use the service; press Ctrl-C to close the forward. A loopback SSH forward is preferable to publishing ports in VPC firewall rules.

## 4. OpenCode locally through SSH, without publishing it

**On the VM**, start the OpenCode HTTP server with authentication and a loopback bind:

```bash
# Choose a strong, unique password; do not commit it to Git.
read -rs -p "OpenCode server password: " OPENCODE_SERVER_PASSWORD; echo
export OPENCODE_SERVER_PASSWORD
opencode serve --hostname 127.0.0.1 --port 8443
```

**On your laptop**, forward `8443` using the SSH or gcloud command above. From the laptop, point an OpenCode client at:

```bash
opencode --server http://127.0.0.1:8443
```

Or test the endpoint:

```bash
curl -u opencode http://127.0.0.1:8443/api/info
```

This is **HTTP carried inside encrypted SSH**, so use `http://` locally, not `https://` unless you've separately configured TLS. OpenCode's server is an API server; to use a browser UI instead, run `opencode web --hostname 127.0.0.1 --port 8443` on the VM and open `http://127.0.0.1:8443/` via the same forward.

See [official OpenCode server documentation](https://opencode.ai/docs/server/) and [web UI documentation](https://opencode.ai/docs/cli/web).

## 5. Verified OpenCode Desktop → GCP remote server

**This workflow was tested successfully.** For exact Desktop UI steps, authenticated GCP OpenCode startup, SSH tunnel, three architecture/sequence diagrams, and the successful model-response evidence, see **[OpenCode Desktop on macOS → OpenCode on GCP](remote-desktop-gcp.md)**.

The Mac Desktop app connects using **Settings → Servers**, not **Settings → Providers**. Point the remote server entry at `http://127.0.0.1:8443` while the SSH tunnel is running. The server is **not** an OpenAI-compatible `/v1/models` inference endpoint.

## 6. If you intentionally need a public OpenTunnel route

The installer publishes **only the disposable demo** to OpenTunnel. Do **not** publish an unauthenticated OpenCode server or a service with cloud credentials, internal dashboards, or admin endpoints. The safe default for OpenCode access is **SSH forwarding above**, not a public URL.

If you choose to expose a protected service publicly, first confirm its authentication, authorization, TLS configuration and restrictions. An OpenTunnel URL is not an authentication mechanism.

## 7. Troubleshooting

| Symptom | Check |
|---|---|
| `opentunnel: command not found` | `export PATH="$HOME/.local/bin:$PATH"` and reopen the terminal |
| Local demo unreachable | `curl -v http://127.0.0.1:3000/`; inspect `~/opentunnel-demo/server.log` |
| Route added but remote URL unreachable | Check tunnel process/route state and the service locally; route creation alone is not proof of public reachability |
| Local SSH forward fails to bind | Port 8443 may be in use on your laptop; choose a different **local** port |
| `gcloud compute ssh` denied | Confirm project, zone, IAM, SSH, OS Login and, if used, IAP permissions |
| OpenCode says `Free usage limit reached` | Upstream free-tier quota/rate/access policy; reinstalling and OpenTunnel do not fix it |
| `No authenticated integrations` | Normal for anonymous OpenCode Zen free-model tests; does not prove inference access |
| OpenCode API returns 401 | Use the correct `OPENCODE_SERVER_PASSWORD`; don't remove authentication |

## Scope / safety

- Tested model request `OK` was observed **on one GCP VM**; it is not a general availability or production SLO claim.
- The script sets up a **public, harmless demo page**. Stop/remove routes when not needed.
- `opencode run` sends prompts to its configured **external model provider**. It does not send traffic through OpenTunnel.
