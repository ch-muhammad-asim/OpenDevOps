# 🚦 `traefik/`: the public HTTPS entry point

**Traefik `v3.7.15`** is the only public door to Hermes. It answers on host ports **80/443**, accepts requests **only from Cloudflare's IP ranges**, and forwards them over a private network to [`hermes-tunnel`](../tunnel/): `/v1/…` to Hermes's API, everything else (including WebSockets) to the dashboard.

> 📘 HTTPS setup (Step 6) and Cloudflare SSL modes: [`../README.md`](../README.md) · variables: [`../ENVIRONMENT.md` §7.3](../ENVIRONMENT.md#73-traefik)

---

## 🗺️ Traffic path

Browser → Cloudflare (HTTPS :443) → **Traefik** (host `:80`→`:8000`, `:443`→`:8443`, Cloudflare IPs only; `/v1` and `/v1/*` → `:8642`, everything else → `:9119`) → `hermes-tunnel` over `hermes_edge` → OpenShell gateway → supervisor → sandbox runtime → Hermes.

The full, verified diagram is [sandbox/README.md → Architecture at a glance](../README.md#architecture-at-a-glance).

---

## 📁 Files

| File | What it does |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | Publishes `80→8000` and `443→8443`, joins only `hermes_edge`. Hardened: non-root (`TRAEFIK_UID`/`GID`), no capabilities, `no-new-privileges`, read-only root, 256 MB, 128 PIDs, **no Docker socket**, health check. Mounts the optional origin-certificate folder read-only. |
| [`traefik.yml`](traefik.yml) | Static config: entry points, trusted Cloudflare IPs for `X-Forwarded-*`, JSON logs and an access log that **drops request headers** (no cookies or `Authorization` in logs). No Let's Encrypt, no API tokens. |
| [`dynamic/`](dynamic/) | Routes, middlewares and TLS options (file provider, hot-reloaded). See [`dynamic/README.md`](dynamic/README.md). |
| [`tls-origin.yml.tmpl`](tls-origin.yml.tmpl) | Template that `https_up.sh` turns into `dynamic/tls-origin.yml` when a **Cloudflare Origin Certificate** exists, enabling SSL mode *Full (strict)*. |
| [`.env.example`](.env.example) | `TRAEFIK_UID`, `TRAEFIK_GID`, `TRAEFIK_TLS_DIR`. `https_up.sh` sets them for you. No secrets. |
| [`.gitignore`](.gitignore) | Keeps the generated `dynamic/tls-origin.yml` and a local `.env` out of git. |

---

## ▶️ How it's used

```bash
sandbox/scripts/https_up.sh      # preferred: starts the tunnel, checks, writes tls-origin.yml if a cert exists, starts Traefik
# or by hand (start the tunnel first: it creates the hermes_edge network)
docker compose -f sandbox/traefik/docker-compose.yml up -d
```

---

## ⚠️ Notes

- 🧱 Ports published by Docker **bypass UFW**, which is why Traefik itself refuses non-Cloudflare clients (`403`). The AWS security group must allow TCP 80/443.
- 🔐 Optional origin certificate: `~/.config/hermes-sandbox/tls/origin.pem` (`644`) and `origin.key` (`600`; `https_up.sh` refuses anything looser). Without them Traefik serves its self-signed certificate, which works with Cloudflare SSL mode *Full*.
- ✅ Checks: `verify.sh` section 7 (on the server) and `verify_https.sh` (from your laptop).
