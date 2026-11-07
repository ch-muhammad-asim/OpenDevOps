# egress/

The allowlist proxy `hermes-herdr-egress`: the only way out of the POC's internal network. It lets herdr-hermes open
HTTPS tunnels to the NVIDIA model API and refuses everything else. See [Architecture](../README.md#️-architecture)
and [Components](../README.md#-components).

## 📁 Files

| File | What it does |
|---|---|
| `Dockerfile` | Alpine 3.24.2 + tinyproxy (`apk upgrade` at build), copies the config and allowlist, runs as `nobody`, healthcheck: port 8888 open on loopback |
| `tinyproxy.conf` | Port 8888, accepts clients from herdr-hermes's fixed address only, CONNECT to port 443 only, default-deny filter from `allowlist`, no `Via` header, logs connects |
| `allowlist` | Anchored extended regex of allowed hosts: `integrate.api.nvidia.com` only |

## 🚀 How it is run

Built and started with the rest of the stack from the repo root (service `egress`, container `hermes-herdr-egress`):

```bash
docker compose -f herdr/hermes-herdr/docker-compose.yml up -d --build        # builds ./egress with the other three
docker compose -f herdr/hermes-herdr/docker-compose.yml ps egress            # expect Up (healthy)
docker logs hermes-herdr-egress                                              # CONNECTs and "Access denied" lines
```

| Setting | Value (from `docker-compose.yml` and the files above) |
|---|---|
| Image | `hermes-herdr-egress:alpine3.24.2` |
| User | `nobody` (image `USER`) |
| Listens | `:8888` inside the network; no published host port |
| Networks | `internal` (no route out) + `egress` (the outbound side); the only dual-homed container |
| Clients | herdr-hermes, via `HTTPS_PROXY` / `HTTP_PROXY` = `http://hermes-herdr-egress:8888` |
| Mounts | none (config baked into the image) |
| Limits | `mem_limit: 64m`, `cpus: 0.25`, `pids_limit: 64`, `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges` |
| Restart | `unless-stopped` |

To allow another host, add an anchored regex line to `allowlist` and rebuild the service.

## 🛡️ Security notes

| Topic | Detail |
|---|---|
| Enforces | one source (herdr-hermes), one destination (`integrate.api.nvidia.com:443`); all other clients, ports and hosts are refused, including the workbench |
| Trusts | Docker's internal network for the client's source address; DNS for the allowed host name |
| Does not do | filter URL paths or methods, or inspect TLS (see [What is NOT protected](../README.md#what-is-not-protected)) |
| Never put here | secrets, API keys or credentials (the proxy never sees the key; it only tunnels TLS) |

See [Network](../README.md#network) and [Security model](../README.md#️-security-model). If model calls fail
(`000` or timeouts), see [Troubleshooting](../README.md#-troubleshooting).

## 🧪 How it is tested

| # | Test (`scripts/e2e-test.sh`) | What it proves here |
|---|---|---|
| 7 | egress: model API only; workbench offline | herdr-hermes → NVIDIA 200, → example.com refused; the workbench's request through the proxy gets `403` |
| 13 | control from the PC, nothing new listening | 0 published ports; the proxy listens only on `:8888` |

Latest result: tests 1-15 **PASS in three consecutive runs** on Hermes Agent v0.22.5, herdr 0.9.5, Docker 28,
2026-11-07; the re-run on v0.23.0 is in progress. Test 8 (container hardening) checks the other three containers,
not the proxy. Details in [Tests](../README.md#-tests).

## 🛡️ Guardrails

| Guardrail | Official doc | How this folder applies it |
|---|---|---|
| SSRF guard (`security.allow_private_urls`) | [Hermes: SSRF protection](https://hermes-agent.nousresearch.com/docs/user-guide/security#ssrf-protection) | Hermes keeps it `false` and its web tools off; this proxy adds a network-level default deny on top: CONNECT to port 443 only, only hosts in `allowlist` (`tinyproxy.conf`: `ConnectPort 443`, `FilterDefaultDeny Yes`) |
| Website access policy (`security.website_blocklist`) | [Hermes: website access policy](https://hermes-agent.nousresearch.com/docs/user-guide/security#website-access-policy) | Not used in Hermes; egress is limited per host here instead: `integrate.api.nvidia.com` only (`allowlist`) |
| TLS verification (`ssl_verify`) | [Hermes: TLS certificate trust](https://hermes-agent.nousresearch.com/docs/user-guide/security#tls-certificate-trust) | The proxy only tunnels CONNECT and never terminates TLS (`tinyproxy.conf`), so Hermes verifies the model API's certificate end to end |
| herdr remote manifest checks (`[update] manifest_check`) | [herdr: detection manifests](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/agents.mdx?plain=1#L84-L98) | Not turned off (no herdr `config.toml`); herdr.dev is not in `allowlist`, so the proxy refuses the check |
| herdr version check and `herdr update` | [herdr: install and update](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/install.mdx?plain=1#L119-L142) | Same: herdr.dev and GitHub are not in `allowlist`, so update checks and downloads fail closed here |

## 🐞 Known issues

| Issue | Status | Mitigation |
|---|---|---|
| herdr's `[update] version_check` / `manifest_check` default to on; the POC writes no herdr `config.toml` | open (low) | the calls fail closed today (this proxy's `allowlist`); planned: ship a `config.toml` with both off |
| The POC has no OpenShell/Landlock hard sandbox (Docker + SSH + egress proxy only) | by design | use the OpenShell dashboard path for anything beyond a lab |

---

[⬅️ Back to the herdr + Hermes POC](../README.md)
