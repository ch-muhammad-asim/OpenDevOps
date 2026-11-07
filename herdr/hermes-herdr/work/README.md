# 🧰 work/

Image for **hermes-herdr-work**: the second herdr server that the herdr-operator skill drives, plus `herdr-broker`
behind a non-root sshd. It is the only place the real work herdr binary exists; the workbench reaches it only through
the broker, and every work pane is an SSH shell back into the workbench. See [Architecture](../README.md#️-architecture)
(component 9) and [Components](../README.md#-components).

## 📁 Files

| File | What it does |
|---|---|
| `Dockerfile` | Alpine 3.24.2 + herdr 0.9.5 (sha256-pinned download), user `herdr` uid 10000, installs the files below |
| `entrypoint.sh` | Creates host and pane keys, publishes them to `/panekeys`, runs a supervised `herdr server` loop, creates workspace `work`, then runs sshd in the foreground |
| `herdr-broker` | sshd `ForceCommand`: reads a NUL-separated herdr argv on stdin, checks it against a fixed allowlist, `execv`s the real herdr (no shell); refusals exit 126 |
| `sshd_config` | sshd on `:2222`, user `herdr` only, pubkey only, no TTY, no forwarding, `ForceCommand /usr/local/libexec/herdr-broker` |
| `workbench-shell` | Shell of every work pane: `ssh -tt` with the pane key to `worker@hermes-workbench`, host key pinned, `cd /work/workspace && exec bash -l` |
| `herdr-close-extra-panes` | Operator/test helper (`docker exec` only, not exposed by the broker): closes every work pane except the first |

## 🚀 How it runs

Built and started by the parent compose file as service `work` (`docker compose -f herdr/hermes-herdr/docker-compose.yml up -d --build`).

| Item | Value |
|---|---|
| Image / container | `hermes-herdr-work:herdr0.9.5-alpine3.24.2` / `hermes-herdr-work` |
| User | `10000:10000` (`herdr`), `cap_drop: ALL`, `no-new-privileges`, read-only rootfs, `init: true` |
| Port | `:2222` (broker sshd) on the internal network only; nothing published |
| Mounts | `hermes-herdr-work-data:/data` (herdr state + socket, pane key, host key); `hermes-pane-keys:/panekeys` (publishes pane `authorized_keys` and `broker_known_hosts`); `hermes-ctl-keys:/ctlkeys:ro` (the workbench's broker key and host key); `/tmp` tmpfs 64m |
| Limits | `mem_limit: 512m`, `cpus: 0.5`, `pids_limit: 256` |
| Health check | `herdr status` shows `status: running` and `sshd` is running |

Allowed by `herdr-broker` (anything else → exit 126, `herdr-broker: denied`):

| Command | Allowed options / arguments |
|---|---|
| `herdr pane list` | `--workspace <wN>` |
| `herdr pane get <PANE_ID>` | none |
| `herdr pane layout` | `--pane <PANE_ID>` |
| `herdr pane read <PANE_ID>` | `--source visible\|recent\|recent-unwrapped`, `--lines 1-1000`, `--format text`, `--raw` |
| `herdr pane wait-output <PANE_ID>` | `--match` or `--regex` (≤ 500 chars, required), `--timeout 1-900000` (required), `--source`, `--lines`, `--raw` |
| `herdr pane split [PANE_ID]` | `--pane`, `--direction right\|down`, `--ratio 0.1-0.9`, `--cwd /work/workspace` only, `--focus`, `--no-focus` |
| `herdr pane run <PANE_ID> '<command>'` | exactly one command string (≤ 8192 chars, not starting with `-`) |
| `herdr pane rename <PANE_ID> [label]` | label `[A-Za-z0-9._-]{1,40}`, or `--clear` |

Pane ids must match `wN:pN` (alphanumeric, e.g. `w1:p2`, `w1:pA`); requests are capped at 64 KiB and must be UTF-8.

## 🛡️ Security notes

| Topic | Detail |
|---|---|
| Enforced | exact argv parsing (no shell, no string matching), `execv` of `/usr/local/bin/herdr`; `SSH_ORIGINAL_COMMAND` ignored; sshd `ForceCommand`, `PermitTTY no`, no forwarding, `AllowUsers herdr` |
| Not enforced | pane ownership: any caller can read or run in any valid work pane, so this is for a **single trusted operator** ([What is NOT protected](../README.md#what-is-not-protected)) |
| Not checked | the command text given to `pane run`; it runs in the workbench like any other Hermes command |
| Trusts | the workbench's broker key in `/ctlkeys/authorized_keys` and its host key in `/ctlkeys/workbench_known_hosts` |
| Never put here | secrets, model keys, real IP addresses; the container has no internet route (internal network only) |
| Scrollback | raw work-pane scrollback is **not redacted**: anything a pane prints stays readable with `pane read` until the pane closes |

More in the parent [Security model](../README.md#️-security-model).

## 🧪 How it is tested

| Test | What it proves for this container |
|---|---|
| `scripts/e2e-test.sh` 6 | 0 NVIDIA variables in the work container |
| `scripts/e2e-test.sh` 8 | uid 10000, CapEff 0, read-only rootfs, NoNewPrivs 1, Seccomp 2 |
| `scripts/e2e-test.sh` 9 | the skill splits a new work pane and runs a command in the workbench through it |
| `scripts/e2e-test.sh` 10 | 9 forbidden forms refused by the broker (`scripts/broker-check.sh`), allowed call works |
| `scripts/e2e-test.sh` 11 | broker refuses `herdr agent list`; work herdr has no agents |
| `scripts/e2e-test.sh` 13 | only `:2222` listens; 0 published ports |
| `scripts/e2e-redaction.sh` 18, 19 | raw work-pane scrollback holds the fake value (by design); no real `nvapi-` key in the work container |

Offline unit test of the allowlist (no containers): `python3 scripts/broker-test.py` (from `herdr/hermes-herdr/`).

Results ([Tests](../README.md#-tests)): tests 1-15 **15/15 PASS in three consecutive runs** on Hermes Agent v0.22.5,
herdr 0.9.5, Docker 28, 2026-11-07; tests 16-19 added after that run, first run pending.

## 🛡️ Guardrails

| Guardrail | Official doc | How this folder applies it |
|---|---|---|
| Socket access (no auth beyond file permissions) | [herdr: socket transport and paths](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/socket-api.mdx?plain=1#L608-L646) | The work herdr socket stays under `/data` (owner `herdr`, mode 0700, `Dockerfile`; `umask 077`, `entrypoint.sh`); from outside, only sshd's `ForceCommand` broker reaches it (`sshd_config`) |
| Remote and SSH access | [herdr: connecting machines](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/connecting-machines.mdx?plain=1#L104-L120) | herdr's own `--remote` / `--machine` is not used (argv must start with `pane`, `herdr-broker`); own sshd: one user, pubkey only, `PermitTTY no`, no forwarding (`sshd_config`); host key pinned by both clients (`workbench-shell`, `../workbench/herdr`) |
| Deny rules are string matches, not a sandbox | [Hermes: user-defined deny rules](https://hermes-agent.nousresearch.com/docs/user-guide/security#user-defined-deny-rules-approvalsdeny) | The control here is the broker: exact argv parsing, no shell, `execv` of the real herdr, `SSH_ORIGINAL_COMMAND` ignored, refusals exit 126 (`herdr-broker`) |
| `pane run` vs `send-text` / `send-keys` | [herdr: CLI reference, pane input](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/cli-reference.mdx?plain=1#L256-L269) | `pane run` allowed with one command string (≤ 8192 chars, no leading `-`), typed into an SSH shell in the workbench (`workbench-shell`); `send-text` / `send-keys` are not in the allowlist (`herdr-broker`) |
| Scrollback (in memory, not redacted) | [herdr: agent automation, reads](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/agent-automation.mdx?plain=1#L86-L92) | `pane read` / `wait-output` `--lines` capped at 1000 (`herdr-broker`); raw text is returned unredacted (see Known issues) |
| Pane screen history on disk | [herdr: pane screen history](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/session-state.mdx?plain=1#L60-L69) | Off: the image ships no herdr `config.toml` (`Dockerfile`) |
| Session state and snapshots are private data | [herdr: session state](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/session-state.mdx?plain=1#L39-L56) | Kept on the `/data` volume, mode 0700 (`Dockerfile`) |
| Server lifecycle | [herdr: persistence](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/persistence-remote.mdx?plain=1#L16) | Supervised restart loop (`entrypoint.sh`); `server stop` is not in the allowlist (`herdr-broker`) |
| Binary integrity | [herdr v0.9.5 release](https://github.com/herdrdev/herdr/releases/tag/v0.9.5) | Download checked with `sha256sum -c` against the pinned digest (`Dockerfile`) |
| Update and manifest checks | [herdr: detection manifests](https://github.com/herdrdev/herdr/blob/master/docs/versions/0.9.5/website/src/content/docs/agents.mdx?plain=1#L84-L98) | Not turned off (no `config.toml`); the container is on the internal network only, so the checks fail; `update` is not in the allowlist (`herdr-broker`) |

## 🐞 Known issues

| Issue | Status | Mitigation |
|---|---|---|
| Raw work-pane scrollback isn't redacted: herdr stores what the shell printed | by design | keep secrets out of the workbench and panes; Hermes masks what it shows and stores (tests 16-18) |
| Tool-call arguments (including `pane run` command text) are stored verbatim in Hermes's session store (`state.db`); upstream removed storage-time argument redaction | open (upstream) | never put a secret on a command line |
| A `password=` value in the middle of a line is not masked by Hermes's redactor | open (upstream) | never put a secret on a command line |
| `approvals.deny` globs are string matches: quoting and indirection (`herdr "agent" …`, `h=herdr; $h …`) pass them | by design | the exact-argv broker is the control (test 10); globs are defence in depth |
| Single trusted operator only: the broker checks argv, not who owns a pane | by design | one work herdr per trust domain |
| herdr's `[update] version_check` / `manifest_check` default to on; the POC writes no herdr `config.toml` | open (low) | the calls fail closed today (internal network only); planned: ship a `config.toml` with both off |
| The POC has no OpenShell/Landlock hard sandbox (Docker + SSH + egress proxy only) | by design | use the OpenShell dashboard path for anything beyond a lab |

[⬅️ Back to the herdr + Hermes POC](../README.md)
