# workbench/

The `hermes-workbench` container: where Hermes's terminal and file tools run (Hermes `terminal.backend: ssh`) and
where the work panes' shells land. A non-root, key-only sshd with no secrets, no internet and no real herdr. See
[Architecture](../README.md#️-architecture) and [Components](../README.md#-components).

## 📁 Files

| File | What it does |
|---|---|
| `Dockerfile` | Alpine 3.24.2 + OpenSSH and shell tools; user `worker` (uid 10000, home `/work`); root-owned `/work`, writable `/work/workspace` and `/var/lib/workbench`; healthcheck `pgrep -x sshd` |
| `entrypoint.sh` | Creates the persistent sshd host key and the broker client key, publishes the pinned host key and the `restrict`ed broker key to `/ctlkeys`, then runs sshd in the foreground |
| `sshd_config` | sshd on `:2222`, user `worker` only, public keys only (`/keys` and `/panekeys`), no forwarding, tunnels, X11 or user environment |
| `herdr` | Client only: sends its argv NUL-separated over SSH to herdr-broker in hermes-herdr-work, pinned host key, no shell |

## 🚀 How it is run

Built and started with the rest of the stack from the repo root (service `workbench`, container `hermes-workbench`):

```bash
docker compose -f herdr/hermes-herdr/docker-compose.yml up -d --build        # builds ./workbench with the other three
docker compose -f herdr/hermes-herdr/docker-compose.yml ps workbench         # expect Up (healthy)
docker logs hermes-workbench                                                 # sshd logins
```

| Setting | Value (from `docker-compose.yml` and the files above) |
|---|---|
| Image | `hermes-workbench:alpine3.24.2` |
| User | `10000:10000` (`worker`) |
| Listens | sshd `:2222` on the `internal` network; no published host port |
| Logins | Hermes's SSH backend from herdr-hermes (key in `/keys`); work pane shells from hermes-herdr-work (key in `/panekeys`) |
| Outbound | SSH to herdr-broker (`herdr@hermes-herdr-work:2222`) only through `herdr`; no internet |
| `hermes-workbench-workspace` → `/work/workspace` | the only writable work dir |
| `hermes-workbench-state` → `/var/lib/workbench` | sshd host key, broker client key |
| `hermes-workbench-keys` → `/keys:ro` | authorized key from herdr-hermes |
| `hermes-pane-keys` → `/panekeys:ro` | authorized key from hermes-herdr-work + broker host key |
| `hermes-ctl-keys` → `/ctlkeys` | publishes this sshd's host key and the broker client key |
| Limits | `mem_limit: 1g`, `cpus: 1.0`, `pids_limit: 256`, `read_only: true`, `/tmp` tmpfs 256m, `cap_drop: [ALL]`, `no-new-privileges` |

## 🛡️ Security notes

| Topic | Detail |
|---|---|
| Enforces | read-only rootfs (only `/work/workspace` writable); key-only SSH for `worker`; no forwarding; no real herdr binary or socket, so Hermes can't reach its own pane or approval prompt |
| Trusts | the public keys published by herdr-hermes and hermes-herdr-work; herdr-broker to decide which herdr calls run |
| Network | `internal` only; the egress proxy refuses this container (see [Network](../README.md#network)) |
| Never put here | the model key, any other secret or credential: raw work-pane scrollback is not redacted (see [What is NOT protected](../README.md#what-is-not-protected)) |

`Host key verification failed` after a volume was recreated: see [Troubleshooting](../README.md#-troubleshooting).

## 🧪 How it is tested

| # | Test | What it proves here |
|---|---|---|
| 2 | prompt `--wait` + `agent read` | Hermes's command runs here (hostname = workbench, SSH connection to `:2222`) |
| 5 | writes outside `/work/workspace` refused | shell and symlink writes fail with "Read-only file system" |
| 6 | NVIDIA key never visible | 0 NVIDIA variables in this container's environment |
| 7 | egress | direct connections fail; the proxy answers `403` |
| 8 | container hardening | uid 10000, CapEff 0, read-only rootfs, NoNewPrivs 1, Seccomp 2 |
| 9 | skill herdr-operator | a new work pane shows the workbench's real `uname -sr` |
| 10 | forbidden herdr commands | as `worker`, 9 forbidden forms refused by herdr-broker (exit 126); no real herdr binary here |
| 11 | no self-approval | 0 herdr sockets; `herdr agent list` refused |
| 13 | nothing new listening | only `:2222`, 0 published ports |
| 19 | real key absent (`scripts/e2e-redaction.sh`) | 0 real-key-shaped values in the workbench `/` |

Latest result: tests 1-15 **PASS in three consecutive runs** on Hermes Agent v0.22.5, herdr 0.9.5, Docker 28,
2026-11-07; the re-run on v0.23.0 is in progress. Test 19: added, first run pending. Details in
[Tests](../README.md#-tests).

## 🛡️ Guardrails

| Guardrail | Official doc | How this folder applies it |
|---|---|---|
| Terminal backend isolation (`terminal.backend`) | [Hermes: terminal backend security](https://hermes-agent.nousresearch.com/docs/user-guide/security#terminal-backend-security-comparison) | Hermes's terminal and file tools run here over SSH, not next to Hermes; key-only sshd for user `worker`, no forwarding or tunnels (`sshd_config`); non-root uid 10000 (`Dockerfile`) |
| What triggers approval | [Hermes: what triggers approval](https://hermes-agent.nousresearch.com/docs/user-guide/security#what-triggers-approval) | With the `ssh` backend Hermes's dangerous-command approvals stay on (they are skipped only on the container backends), so commands that run here still ask a human |
| `HERMES_WRITE_SAFE_ROOT` | [Hermes: write safe root](https://hermes-agent.nousresearch.com/docs/user-guide/security#hermes_write_safe_root-optional-sandbox) | Hermes limits its file tools to `/work/workspace` (set in the parent `Dockerfile`); here the OS enforces it too: `/work` is root-owned on the read-only rootfs, only the `/work/workspace` and `/var/lib/workbench` volumes are writable (`Dockerfile`) |
| Environment passthrough | [Hermes: environment variable passthrough](https://hermes-agent.nousresearch.com/docs/user-guide/security#environment-variable-passthrough) | Nothing is forwarded into SSH sessions: `PermitUserEnvironment no` and no `AcceptEnv` (`sshd_config`) |
| herdr pane environment (`HERDR_SOCKET_PATH`) | [herdr: socket API](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/socket-api.mdx?plain=1#L253-L257) | Work-pane shells land here over SSH, which carries none of herdr's pane variables (`sshd_config`); there is no herdr socket or real binary here, only the broker client (`herdr`) |
| `blocked` / `idle` is not authorization | [herdr: blocked state](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/agents.mdx?plain=1#L74-L78) | Hermes's own approval prompt lives in herdr-hermes; from here the `herdr` client reaches only the broker's `pane` commands on the work herdr, so a command run here cannot answer it |

## 🐞 Known issues

| Issue | Status | Mitigation |
|---|---|---|
| Raw work-pane scrollback isn't redacted: herdr stores what the shell printed | by design | keep secrets out of the workbench and panes; Hermes masks what it shows and stores (tests 16-18) |
| Hermes declines to echo a secret-like value typed into the prompt (e.g. `TEST_API_KEY=sk-…`) | by design (guardrail) | the redaction tests put the fake value in a fixture file in `/work/workspace` and the prompt names only the file (`scripts/e2e-redaction.sh`, tests 17-18) |
| The POC has no OpenShell/Landlock hard sandbox (Docker + SSH + egress proxy only) | by design | use the OpenShell dashboard path for anything beyond a lab |

---

[⬅️ Back to the herdr + Hermes POC](../README.md)
