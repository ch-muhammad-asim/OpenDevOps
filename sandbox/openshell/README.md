# 🚪 `openshell/`: the OpenShell gateway

The **NVIDIA OpenShell gateway** (`v0.1.6`), the control plane that creates and manages sandboxes through the **Docker** compute driver, holds credentials (the `nvidia` provider) and serves policy and logs to the `openshell` CLI.

> 📘 How OpenShell works and why it's set up this way: [`../README.md`](../README.md) · variables: [`../ENVIRONMENT.md` §7.1](../ENVIRONMENT.md#71-openshell-gateway)

---

## 📁 Files

| File | What it does |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | Runs the gateway (`ghcr.io/nvidia/openshell/gateway:0.1.6`) and a one-off `init` service that writes the sandbox JWT signing keys. Ports `8080` (API) and `8081` (health) are published on **`127.0.0.1` only**. Note: `gateway.toml` binds the health listener to the container's own loopback, so `127.0.0.1:8081` on the host does not answer (checked 2026-11-01). Uses the Docker socket (Docker-outside-of-Docker, no `--privileged`); state lives in `/var/lib/openshell`. Telemetry is off. |
| [`gateway.toml`](gateway.toml) | Gateway settings, mounted read-only: loopback listeners, Docker driver, sandbox and supervisor images **pinned to 0.1.6**, and `allow_driver_config` so the `hermes-data` volume can be attached. TLS and user auth are off: safe only because the gateway is on loopback on a single-user host. |
| [`.env.example`](.env.example) | Optional: `OPENSHELL_VERSION` (default `0.1.6`). No secrets. |

---

## ▶️ How it's used

`sandbox/scripts/up.sh` starts it for you. By hand:

```bash
docker compose -f sandbox/openshell/docker-compose.yml up -d
openshell gateway add http://127.0.0.1:8080 --local --name hermes-gw
openshell status                       # 👉 Connected
```

---

## ⚠️ Notes

- 🔒 **Never expose ports 8080/8081.** The gateway API is unauthenticated here. Before reaching it from anywhere else, turn on mTLS (`disable_tls = false`) and user auth.
- 📌 **Keep versions together.** The gateway image, the sandbox and supervisor images in `gateway.toml`, the `openshell` CLI and the CLI in [`../tunnel/`](../tunnel/) are all `0.1.6`. Upgrade them together and re-run the checks.
- 💾 `/var/lib/openshell` holds the gateway database, including the **credential store** (the NVIDIA key). `scripts/down.sh --purge` stops the gateway and removes `hermes-data` but leaves `/var/lib/openshell` in place (root-owned); wipe it with `sudo rm -rf /var/lib/openshell` only if you mean to start from scratch.
