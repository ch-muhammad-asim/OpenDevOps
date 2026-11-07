# 🤖 `hermes/`: Hermes Agent made sandbox-ready

Everything needed to run the stock **Hermes Agent `v0.23.0`** image (`nousresearch/hermes-agent`) as an **NVIDIA OpenShell** sandbox workload: the image changes, the start script, Hermes's first-start config, the sandbox policy and the template for Hermes's secrets.

> 📘 Setup and background: [`../README.md`](../README.md) · every variable: [`../ENVIRONMENT.md` §6](../ENVIRONMENT.md#-6-hermes-inside-the-sandbox) · security: [`../SECURITY.md`](../SECURITY.md)

---

## 📁 Files

| File | What it does |
|---|---|
| [`Dockerfile`](Dockerfile) | Builds `hermes-openshell:v0.23.0` from the stock image. OpenShell refuses root and replaces the image's `ENTRYPOINT` (s6-overlay), so it runs as the image's `hermes` user (uid/gid `10000`), moves `HERMES_HOME` to `/sandbox/hermes` (the `hermes-data` volume) and adds `start-hermes`. No credentials are baked in. |
| [`start-hermes.sh`](start-hermes.sh) | The sandbox's main process (installed as `/usr/local/bin/start-hermes`). Runs the two jobs s6 normally supervises, the **dashboard** (`:9119`) and the **gateway/API** (`:8642`); if either exits, both stop and OpenShell restarts them. On every start it also: sets `TERM=xterm-256color`/`COLORTERM=truecolor`/`LANG=C.UTF-8` (OpenShell starts it with `TERM=dumb`, which turned the chat terminal plain); seeds `config.yaml` once; restores the NVIDIA default model block. |
| [`config.yaml`](config.yaml) | Seed config, copied to `/sandbox/hermes/config.yaml` only if none exists: default model `nvidia/nemotron-3.5-super-vl-120b-a12b`, two fallbacks (`openai/gpt-oss-20b`, `meta/muse-glimmer-30b`, chosen by [`../benchmarks/`](../benchmarks/)), the optional `opencode-bridge` provider, a 45 s approval timeout and the WebSocket keepalive tuned for Cloudflare. |
| [`policy.yaml`](policy.yaml) | The **OpenShell policy**: Landlock filesystem allow-list (fail closed), uid `10000`, and deny-by-default egress with one rule (`opencode_bridge`: three REST routes, Hermes's bundled Python only). The NVIDIA rule comes from the provider ([`../providers/`](../providers/)). |
| [`hermes.env.example`](hermes.env.example) | Template for Hermes's own secrets: dashboard login (username, scrypt hash, session secret) and `API_SERVER_KEY`. Copy to `~/.config/hermes-sandbox/hermes.env` (`600`); never commit the real file. |

---

## ▶️ How it's used

```bash
install -d -m 700 ~/.config/hermes-sandbox
install -m 600 sandbox/hermes/hermes.env.example ~/.config/hermes-sandbox/hermes.env   # fill in REPLACE
sandbox/scripts/up.sh          # builds the image, creates the sandbox with policy.yaml, runs start-hermes
```

`up.sh` builds the image (`docker build --build-arg HERMES_IMAGE=…`), creates the sandbox with `--policy hermes/policy.yaml`, passes `hermes.env` with `--env-from` (never as arguments) and starts `start-hermes`.

---

## ✏️ Changing things

| Change | How | Takes effect |
|---|---|---|
| Network rules in `policy.yaml` | `openshell policy set hermes --policy sandbox/hermes/policy.yaml --wait` | Live, no restart |
| Filesystem, Landlock or process parts of `policy.yaml` | `sandbox/scripts/down.sh && sandbox/scripts/up.sh` | Only when the sandbox is re-created |
| `Dockerfile`, `start-hermes.sh`, `config.yaml` | `sandbox/scripts/down.sh && sandbox/scripts/up.sh` (`up.sh` always rebuilds the image) | New sandbox; `config.yaml` only seeds a **new** `hermes-data` volume (except the `model:` block, restored on every start) |
| `hermes.env` | `sandbox/scripts/down.sh && sandbox/scripts/up.sh` | New sandbox |

Before changing `policy.yaml`, run [`../scripts/policy_check.sh`](../scripts/policy_check.sh): it proves the policy stays inside [`../security/boundary.yaml`](../security/boundary.yaml). CI runs it too.

> ⚠️ The Python path in `policy.yaml` (`/opt/hermes/tools/python-3.14.9+20261021-linux-x64/bin/python3.14`) belongs to this exact image. After a Hermes upgrade, check it still exists, or Hermes loses access to its models.

---

## ⬆️ Hermes v0.23.0 (upgraded 2026-11-07)

[Release notes](https://github.com/NousResearch/hermes-agent/releases/tag/v0.23.0) (rolls up v0.22.6 and v0.22.7). What changed for us:

- **Config:** none needed. `hermes doctor` on v0.23.0 reports no deprecated keys in `config.yaml`; Hermes migrates the saved config from `_config_version` 51 to 52 on first start. `hermes-data` (chats, settings, memories) is kept.
- **Policy:** unchanged (same hash); the bundled Python path in `policy.yaml` is the same in v0.23.0.
- **Image:** the stock Python no longer ships `pip`, so guardrail B2's `pip install` now fails before it reaches the network.
- **Upstream security changes we inherit:** stricter approval gate (`curl … | sudo bash`, hidden credential uploads), stale approval cards can no longer approve the next request, wider secret masking, dashboard CORS/WebSocket trust limited to its own bound port (checked: chat over Cloudflare + Traefik still works, sockets stay open idle).

**Approvals:** the sandbox runs Hermes's default `approvals.mode: smart` (our `config.yaml` sets only `approvals.timeout: 45`), so Hermes's auxiliary model, not a human, clears most commands it flags as risky. OpenShell's policy is the enforced control; don't describe Hermes's approvals as a human gate. Changing the mode is the owner's decision.

**Backup before an upgrade** (root-owned files inside, so read them through a throwaway container; keep the archive private):

```bash
docker run --rm --network none -v hermes-data:/d:ro -v "$HOME":/out alpine:3.24.2 \
  tar czf /out/hermes-data-backup-YYYYMMDD.tgz -C /d .
docker run --rm --network none -v "$HOME":/out alpine:3.24.2 \
  sh -c "chown $(id -u):$(id -g) /out/hermes-data-backup-YYYYMMDD.tgz && chmod 600 /out/hermes-data-backup-YYYYMMDD.tgz"
```

**Rollback to v0.22.5.** `up.sh` always rebuilds `SANDBOX_IMAGE` from `HERMES_IMAGE`, so rollback means rebuilding from the stock v0.22.5 image (`docker build` pulls it again if it was pruned; ~4.3 GB). `hermes-openshell:rollback-v0.22.5` is only a reference copy of the image that ran before the upgrade.

```bash
sandbox/scripts/down.sh
HERMES_IMAGE=nousresearch/hermes-agent:v0.22.5 SANDBOX_IMAGE=hermes-openshell:v0.22.5 sandbox/scripts/up.sh
```

Restoring the data backup is optional: v0.22.5 only migrates config upward and accepts the v0.23.0 config (`_config_version: 52`). To restore it anyway, run this between `down.sh` and `up.sh` (it replaces everything on the volume, including chats made since the backup):

```bash
docker run --rm --network none -v hermes-data:/d -v "$HOME":/in:ro alpine:3.24.2 \
  sh -c 'find /d -mindepth 1 -delete && tar xzpf /in/hermes-data-backup-YYYYMMDD.tgz -C /d'
```
