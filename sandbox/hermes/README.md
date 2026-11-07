# 🤖 `hermes/`: Hermes Agent made sandbox-ready

Everything needed to run the stock **Hermes Agent** image (`nousresearch/hermes-agent`) as an **NVIDIA OpenShell** sandbox workload: the image changes, the start script, Hermes's first-start config, the sandbox policy and the template for Hermes's secrets. Why: OpenShell refuses root workloads and replaces the image's `ENTRYPOINT`, so the stock image can't run in a sandbox unchanged.

> **Status (2026-11-07):** Hermes Agent **v0.23.0** (`hermes-openshell:v0.23.0`) on OpenShell **v0.1.6**, live on the reference server; `verify.sh`, `verify_https.sh`, `policy_check.sh` and the 10 guardrail prompts pass ([results](../README.md#-latest-test-results)). Not covered here: the Kubernetes deployment ([`../k8s/`](../k8s/README.md)).
>
> 📘 Setup and background: [`../README.md`](../README.md) · architecture: [`../README.md` → Architecture at a glance](../README.md#architecture-at-a-glance) · every variable: [`../ENVIRONMENT.md` §6](../ENVIRONMENT.md#-6-hermes-inside-the-sandbox) · security: [`../SECURITY.md`](../SECURITY.md)

---

## 📁 Files

| File | What it does | Security role |
|---|---|---|
| [`Dockerfile`](Dockerfile) | Builds `hermes-openshell:v0.23.0` `FROM nousresearch/hermes-agent:v0.23.0` (`HERMES_IMAGE` build arg). Runs as the image's `hermes` user (uid/gid `10000`), moves `HERMES_HOME` to `/sandbox/hermes` (the `hermes-data` volume) and adds `start-hermes`. | Non-root workload; no credentials baked in |
| [`start-hermes.sh`](start-hermes.sh) | The sandbox's main process (`/usr/local/bin/start-hermes`): runs the **dashboard** (`:9119`) and the **gateway/API** (`:8642`), which s6 supervises in the stock image; if either exits, both stop and OpenShell restarts them. On every start it sets `TERM=xterm-256color`, `COLORTERM=truecolor`, `LANG=C.UTF-8` (OpenShell starts it with `TERM=dumb`), seeds `config.yaml` once and restores the default `model:` block. | Keeps the default model pinned after side-panel switches |
| [`config.yaml`](config.yaml) | Seed config, copied to `/sandbox/hermes/config.yaml` only if none exists: default model `nvidia/nemotron-3.5-super-vl-120b-a12b`, fallbacks `openai/gpt-oss-20b` and `meta/muse-glimmer-30b` (chosen by [`../benchmarks/`](../benchmarks/)), the optional `opencode-bridge` provider, `approvals.timeout: 45`, WebSocket keepalive 25 s / 90 s. | Unattended approvals fail closed after 45 s |
| [`policy.yaml`](policy.yaml) | The **OpenShell policy**: Landlock filesystem allow-list (fail closed), uid `10000`, deny-by-default egress with one rule (`opencode_bridge`: three REST routes, Hermes's bundled Python only). The NVIDIA rule comes from the provider ([`../providers/`](../providers/)). | The enforced boundary; proven by [`../scripts/policy_check.sh`](../scripts/policy_check.sh) |
| [`hermes.env.example`](hermes.env.example) | Template for Hermes's own secrets: dashboard login (username, scrypt hash, session secret) and `API_SERVER_KEY`. Copy to `~/.config/hermes-sandbox/hermes.env` (`600`). | Passed with `--env-from`, never as arguments; never committed |

---

## ✅ Prerequisites

OpenShell CLI and gateway **0.1.6**, Docker with Compose, and the NVIDIA provider ([`../providers/`](../providers/README.md)). The sandbox gets **2 CPUs, 4 GiB RAM, 2048 PIDs** and a 512 MiB `/tmp` (set in [`../scripts/up.sh`](../scripts/up.sh)); each Hermes image needs about 4.6 GB of disk. Full list: [`../README.md` → What you need](../README.md#-what-you-need-before-you-start).

---

## ▶️ How it's used

```bash
install -d -m 700 ~/.config/hermes-sandbox
install -m 600 sandbox/hermes/hermes.env.example ~/.config/hermes-sandbox/hermes.env   # fill in REPLACE
sandbox/scripts/up.sh          # builds the image, creates the sandbox with policy.yaml, runs start-hermes
```

`up.sh` builds the image (`docker build --build-arg HERMES_IMAGE=…`), prunes the build cache, creates the sandbox with `--policy hermes/policy.yaml`, passes `hermes.env` with `--env-from` and starts `start-hermes`. Verify with `sandbox/scripts/verify.sh` (expected: `0 failed`).

---

## 🔒 Security notes

- **Approvals:** the sandbox runs Hermes's default `approvals.mode: smart` (`config.yaml` sets only `approvals.timeout`), so Hermes's auxiliary model, not a human, clears most commands it flags as risky. OpenShell's policy is the enforced control; Hermes's approvals are not a human gate in this setup.
- **Model key:** Hermes only sees an `openshell:resolve:env:…` placeholder; the supervisor adds the real key to NVIDIA requests only.
- **Python path:** `policy.yaml` names Hermes's bundled Python (`/opt/hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3.14`). It belongs to the image; check it after every upgrade, or Hermes loses access to its models.
- The full threat model: [`../README.md` → Threat model at a glance](../README.md#-threat-model-at-a-glance).

---

## ✏️ Changing things

| Change | How | Takes effect |
|---|---|---|
| Network rules in `policy.yaml` | `openshell policy set hermes --policy sandbox/hermes/policy.yaml --wait` | Live, no restart |
| Filesystem, Landlock or process parts of `policy.yaml` | `sandbox/scripts/down.sh && sandbox/scripts/up.sh` | Only when the sandbox is re-created |
| `Dockerfile`, `start-hermes.sh`, `config.yaml` | `sandbox/scripts/down.sh && sandbox/scripts/up.sh` (`up.sh` always rebuilds the image) | New sandbox; `config.yaml` only seeds a **new** `hermes-data` volume (except the `model:` block, restored on every start) |
| `hermes.env` | `sandbox/scripts/down.sh && sandbox/scripts/up.sh` | New sandbox |

Before changing `policy.yaml`, run [`../scripts/policy_check.sh`](../scripts/policy_check.sh): it proves the policy stays inside [`../security/boundary.yaml`](../security/boundary.yaml). CI runs it too.

---

## 🧪 Tests and operations

- **Tests:** [`../README.md` → Check that everything works](../README.md#-check-that-everything-works) (`verify.sh`, `verify_https.sh`), [Security tests and DevSecOps](../README.md#-security-tests-and-devsecops) (`policy_check.sh`, `security_compare.sh`, `scan.sh`) and the [guardrail prompts](../demo/README.md#-try-it-yourself-guardrail-prompts). Latest results: [Latest test results](../README.md#-latest-test-results).
- **Health, logs and fixes:** [Health and monitoring signals](../README.md#-health-and-monitoring-signals), [Everyday tasks](../README.md#️-everyday-tasks), [Troubleshooting](../README.md#-troubleshooting).

---

## 📦 Upgrade, rollback and backup

**Disk:** each Hermes image is about 4.3–4.6 GB; an image built `FROM` its pulled base shares its layers. Keep at least **3 GB free** (`df -h /`) before a build; `up.sh` runs `docker builder prune -af` after it.

**1. Back up `hermes-data`** (chats, settings, memories). The volume holds files only `root`/uid `10000` can read, so use a throwaway container, and keep the archive private:

```bash
docker run --rm --network none -v hermes-data:/d:ro -v "$HOME":/out alpine:3.24.2 \
  tar czf /out/hermes-data-backup-YYYYMMDD.tgz -C /d .
docker run --rm --network none -v "$HOME":/out alpine:3.24.2 \
  sh -c "chown $(id -u):$(id -g) /out/hermes-data-backup-YYYYMMDD.tgz && chmod 600 /out/hermes-data-backup-YYYYMMDD.tgz"
```

`tar` reports `socket ignored` for Hermes's runtime sockets; that's expected.

**2. Upgrade.** Read the release notes, then set the new tag in [`Dockerfile`](Dockerfile) (`HERMES_IMAGE`) and [`../scripts/up.sh`](../scripts/up.sh) (`HERMES_IMAGE`, `SANDBOX_IMAGE`), and re-create the sandbox:

```bash
docker pull nousresearch/hermes-agent:<new tag>
docker run --rm --entrypoint ls nousresearch/hermes-agent:<new tag> /opt/hermes/tools   # Python path for policy.yaml
sandbox/scripts/down.sh && sandbox/scripts/up.sh
```

Hermes migrates the saved `config.yaml` on first start (`_config_version`); `hermes doctor` inside the sandbox reports deprecated keys. Then run `verify.sh`, `verify_https.sh`, `policy_check.sh` and the 10 guardrail prompts.

**3. Roll back.** `up.sh` always rebuilds `SANDBOX_IMAGE` from `HERMES_IMAGE`, so a rollback rebuilds from the previous stock image (`docker build` pulls it again if it was pruned):

```bash
sandbox/scripts/down.sh
HERMES_IMAGE=nousresearch/hermes-agent:<previous tag> SANDBOX_IMAGE=hermes-openshell:<previous tag> sandbox/scripts/up.sh
```

**4. Restore the data backup (optional).** Hermes only migrates its config upward, so an older version accepts a config a newer one saved. To restore anyway, run this between `down.sh` and `up.sh`; it replaces everything on the volume, including chats made since the backup:

```bash
docker run --rm --network none -v hermes-data:/d -v "$HOME":/in:ro alpine:3.24.2 \
  sh -c 'find /d -mindepth 1 -delete && tar xzpf /in/hermes-data-backup-YYYYMMDD.tgz -C /d'
```

### What changed in v0.23.0 for this sandbox

| Area | Change | Effect here |
|---|---|---|
| Config | `_config_version` 51 → 52; no keys renamed or removed for our settings | None; `config.yaml` unchanged |
| Policy | Bundled Python path unchanged | None; policy hash unchanged |
| Image | The bundled Python has no `pip` module | Guardrail [B2](../demo/README.md#b2-network-egress-to-a-site-not-in-the-policy)'s `pip install` fails before it reaches the network |
| Approvals | Stricter gate (`curl … \| sudo bash`, hidden credential uploads); a stale approval card can't approve the next request | Stronger defaults, no config change |
| Dashboard | CORS and WebSockets trust only the bound port | Chat through Cloudflare + Traefik still works; sockets stay open when idle (`verify_https.sh` §8–11) |
| Network | Background model-catalogue refresh (`models.dev`) | Denied by the policy, as before; expected `DENIED` lines |

---

## 🧹 Teardown

```bash
sandbox/scripts/down.sh            # delete the sandbox; keeps hermes-data
sandbox/scripts/down.sh --purge    # also stops Traefik, the tunnel and the gateway and removes hermes-data
```

---

## 📌 Pinned versions

| Item | Version | Where |
|---|---|---|
| Base image | `nousresearch/hermes-agent:v0.23.0` | [`Dockerfile`](Dockerfile), [`../scripts/up.sh`](../scripts/up.sh) |
| Built image | `hermes-openshell:v0.23.0` | [`../scripts/up.sh`](../scripts/up.sh) |
| Bundled Python | `python-3.14.9+20261021-linux-x64` | [`policy.yaml`](policy.yaml) |
| NVIDIA OpenShell | `0.1.6` | [`../openshell/docker-compose.yml`](../openshell/docker-compose.yml) |
| Backup helper image | `alpine:3.24.2` | commands above |

## 📚 References

- [Hermes Agent v0.23.0 release notes](https://github.com/NousResearch/hermes-agent/releases/tag/v0.23.0) · [image on Docker Hub](https://hub.docker.com/r/nousresearch/hermes-agent)
- [OpenShell policy schema (v0.1.6)](https://github.com/NVIDIA/OpenShell/blob/v0.1.6/docs/how-it-works/policies/schema.mdx) · [Bring your own container](https://github.com/NVIDIA/OpenShell/tree/v0.1.6/examples/bring-your-own-container)
