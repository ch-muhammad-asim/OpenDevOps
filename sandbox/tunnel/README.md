# 🔌 `tunnel/`: hermes-tunnel

A tiny container with only the **OpenShell CLI**. It holds the two port forwards into the Hermes sandbox, so Traefik can reach Hermes's dashboard (`:9119`) and API (`:8642`). There's no web server in it; Traefik talks to the forwarded ports directly.

> 📘 Traffic path and design: [`../README.md`](../README.md) · variables: [`../ENVIRONMENT.md` §7.2](../ENVIRONMENT.md#72-hermes-tunnel)

---

## 🗺️ Where it sits

Traefik → (HTTP over `hermes_edge`, `172.31.250.0/24`) → **hermes-tunnel** `172.31.250.10:9119` / `:8642` → (SSH forward over gRPC `ForwardTcp` to `gateway:8080` on `openshell_default`) → OpenShell gateway → relay over the supervisor's session → supervisor → sandbox runtime → Hermes `:9119` / `:8642`.

The full, verified diagram is [sandbox/README.md → Architecture at a glance](../README.md#architecture-at-a-glance).

Traefik can reach the tunnel, but **not** the gateway: they share no Docker network (`hermes_edge` vs `openshell_default`, both ordinary bridge networks with restricted membership, not Docker `internal`). The tunnel publishes no ports on the host.

---

## 📁 Files

| File | What it does |
|---|---|
| [`Dockerfile`](Dockerfile) | `alpine:3.24.2` + the OpenShell CLI `0.1.6` (downloaded, **checksum-verified**), `openssh-client` (the CLI's forwards use SSH), the real `lsof` (BusyBox's ignores its arguments, so `openshell forward` thought every port was taken) and `curl` for health probes. Runs as uid `10001`. |
| [`entrypoint.sh`](entrypoint.sh) | Keeps both forwards alive on `BIND_ADDRESS` only. **Self-healing:** a forward is restarted when it exits, and every `HEALTH_INTERVAL` s a health loop checks the dashboard (a real WebSocket upgrade request) and the API (`/health`); after 3 failures in a row it kills the forward and any stale listener and starts a new one. |
| [`docker-compose.yml`](docker-compose.yml) | Joins `openshell_default` (to reach the gateway) and creates `hermes_edge` (shared with Traefik only). Hardened: non-root, no capabilities, `no-new-privileges`, read-only root, 128 MB, 64 PIDs, rotated logs. |
| [`.env.example`](.env.example) | Optional overrides: `SANDBOX_NAME`, `DASHBOARD_PORT`, `API_PORT`, `HEALTH_INTERVAL`. No secrets. |

---

## ▶️ How it's used

`sandbox/scripts/https_up.sh` starts it. By hand:

```bash
docker compose -f sandbox/tunnel/docker-compose.yml up -d --build
docker logs --tail 20 hermes-tunnel        # 👉 "✓ Forwarding port 9119 to sandbox hermes" (and 8642),
                                           #    no "[hermes-tunnel] health: … did not answer" lines
```

> ⚠️ Restarting or re-creating `hermes-tunnel` disconnects every open chat; users reload the page.
