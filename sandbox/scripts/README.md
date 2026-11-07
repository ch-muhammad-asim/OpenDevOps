# 🧰 `scripts/`: set up, operate and test the sandbox

Every script for running Hermes in the OpenShell sandbox: bring it up, put it behind HTTPS, manage keys and DNS, keep the disk clean, and prove it all works.

> 📘 Step-by-step setup: [`../README.md`](../README.md) · every variable and credential: [`../ENVIRONMENT.md`](../ENVIRONMENT.md) (§8 scripts, §9 tests, §10 benchmarks)

---

## 📁 Scripts

**Where:** 🖥️ server, 💻 your laptop (Cloudflare challenges scripts on cloud IPs), 🌐 either.

### 🚀 Setup and operations

| Script | Where | What it does | Credential | Changes things? |
|---|---|---|---|---|
| [`up.sh`](up.sh) | 🖥️ | Starts the OpenShell gateway, builds `hermes-openshell:v0.23.0`, creates the `hermes-data` volume and the sandbox (policy, secrets via `--env-from`, CPU/memory limits), opens host forwards. Idempotent. | `~/.config/hermes-sandbox/hermes.env` | ✅ |
| [`down.sh`](down.sh) | 🖥️ | Deletes the sandbox (the `hermes-data` volume is kept) and stops the host forwards; Traefik and the tunnel keep running. `--purge` also stops Traefik, the tunnel and the gateway and removes `hermes-data` (`/var/lib/openshell` stays; remove it with sudo). | – | ✅ |
| [`https_up.sh`](https_up.sh) | 🖥️ | Starts `hermes-tunnel` and Traefik on 80/443; enables the origin certificate if present. Idempotent. | optional origin key (`600`) | ✅ |
| [`set_nvidia_key.sh`](set_nvidia_key.sh) | 🖥️ | Stores or rotates the NVIDIA key in OpenShell (provider `nvidia`), attaches it, restarts the Hermes processes and the tunnel (`--no-restart` skips). Key from a hidden prompt or stdin. | 🔑 NVIDIA key | ✅ (open chats reload) |
| [`update_dns.sh`](update_dns.sh) | 💻 | Points the Cloudflare `A` record at the IP in [`../site.env`](../site.env) (`--detect` on the server, `--dry-run` to preview). | 🔑 Cloudflare DNS token | ✅ DNS |
| [`housekeeping.sh`](housekeeping.sh) | 🖥️ | Frees disk: build cache, dangling images, old demo logs. `--install-cron` runs it daily. | – | ✅ (only recreatable things) |

### 🧪 Tests

| Script | Where | What it checks | Credential | Changes things? |
|---|---|---|---|---|
| [`verify.sh`](verify.sh) | 🖥️ | Up to 27 end-to-end checks (23 without a dashboard password; `LLM_CHECKS=1` adds a model call): OpenShell, Landlock, network policy, dashboard login and chat, API, Traefik refusing non-Cloudflare clients, disk, bridge on loopback. `LLM_CHECKS=1` adds model calls. | optional dashboard password | deletes only its own test sessions |
| [`verify_https.sh`](verify_https.sh) | 💻 | Public HTTPS in 12 sections: DNS, Cloudflare edge and certificates, origin lockdown, login, API, WebSocket soak, disk, a **real browser** (below). | optional dashboard password, API key | deletes only its own test sessions; `--cleanup` (on the server, when nobody is mid-chat) also deletes empty chat sessions |
| [`browser_check.sh`](browser_check.sh) + [`browser_check.js`](browser_check.js) | 💻 | Real Chrome (playwright-core): login, the 3 chat WebSockets stay open while idle and after a reload, the chat terminal is **in colour**. `SWITCH_CHECK=1` switches the model and back. | 🔑 dashboard password | `SWITCH_CHECK=1` changes the live default for 1–2 min |
| [`chat_e2e.py`](chat_e2e.py) | (helper) | Drives the Chat page like a browser: ticket, PTY, optional question. Started by `verify.sh` / `verify_https.sh`. | password on stdin | – |
| [`ws_soak.py`](ws_soak.py) | (helper) | Keeps the 3 dashboard WebSockets idle and checks they stay open. Started by `verify_https.sh`. | password on stdin | – |

### 🛡️ Security

| Script | Where | What it does | Credential | Changes things? |
|---|---|---|---|---|
| [`policy_check.sh`](policy_check.sh) | 🌐 | Proves (SMT solver) that [`../hermes/policy.yaml`](../hermes/policy.yaml), and the live effective policy, stay inside [`../security/boundary.yaml`](../security/boundary.yaml), and that risky edits are caught. | – | – |
| [`scan.sh`](scan.sh) | 🌐 | gitleaks, hadolint, shellcheck, Trivy config/image scans, `policy_check.sh` and an SBOM, all from pinned images. `SKIP_IMAGES=1` = CI mode. | – | writes reports to `~/hermes-security-reports` |
| [`security_compare.sh`](security_compare.sh) | 🖥️ | Runs the 22 attacker probes plus a resource-limit check (23 results) with and without OpenShell; rewrites [`../security/COMPARISON.md`](../security/COMPARISON.md). | – | temporary baseline container, always removed |

### 📊 Benchmarks

| Script | Where | What it does | Credential |
|---|---|---|---|
| [`nvidia_bench.py`](nvidia_bench.py) | 💻 | Tests every NVIDIA chat model (answers, tool calls, latency); writes [`../benchmarks/`](../benchmarks/). | 🔑 NVIDIA key file |

Cloudflare Workers AI has its own test: [`../cloudflare-ai/cf_ai_bench.py`](../cloudflare-ai/cf_ai_bench.py).

---

## ▶️ Typical runs

```bash
# server
sandbox/scripts/up.sh && sandbox/scripts/https_up.sh
read -rs HERMES_DASHBOARD_PASSWORD; export HERMES_DASHBOARD_PASSWORD
sandbox/scripts/verify.sh                          # 👉 all PASS

# laptop, after a server restart that changed the IP
$EDITOR sandbox/site.env                           # HERMES_ORIGIN_IP=<new ip>
sandbox/scripts/update_dns.sh
sandbox/scripts/verify_https.sh                    # 👉 all PASS (2 WARN without an origin certificate)
```

🔐 None of these scripts prints a secret or puts one on a command line: they read secrets from `600` files, hidden prompts or stdin. Model calls are **opt-in** (`LLM_CHECKS=1`) to save free quota.
