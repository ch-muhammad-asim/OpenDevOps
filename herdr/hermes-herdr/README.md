# 🤖 herdr + Hermes Agent POC

[herdr](https://herdr.dev) runs [Hermes Agent](https://hermes-agent.nousresearch.com/docs/) as a recognised agent
(kind `hermes`) inside hardened containers. You see, prompt, wait for and approve/deny Hermes through herdr from your
PC over SSH + `docker exec`: no published ports, no Docker socket, no herdr socket on the network.
Hermes's own guardrails are on and locked (the container refuses to start if they aren't), its tools run in a
separate offline container, it can drive a second herdr only through an allowlist broker, and its only way out is
an allowlist proxy to the model API.

> ⚠️ This is a proof of concept on a single lab server. There is **no NVIDIA OpenShell** in this design (see
> [What's lost without OpenShell](#-no-openshell-whats-lost)). Running this POC on GKE is sketched, not tested.

**Status:** tested on Hermes Agent v0.22.5 (15/15 end-to-end tests, three consecutive runs); the v0.23.0 upgrade and
benchmark are in progress.

## 🏗️ Architecture

```mermaid
flowchart TB
  PC["1 · Operator PC"]
  subgraph HOST["2 · Server / Docker — no published container ports"]
    subgraph NET["3 · Internal network — no direct route out"]
      subgraph AGENT["4 · herdr-hermes"]
        H["Hermes TUI<br/>herdr pane foreground"]
        S["5 · herdr-operator<br/>Read-only skill"]
        C["6 · Managed config<br/>Read-only"]
        K["7 · Model key<br/>Hermes environment"]
        S -->|guides| H
        C -->|enforces| H
        K -->|key_env| H
      end
      B["8 · hermes-workbench<br/>SSH tools / herdr client"]
      subgraph WORK["9 · hermes-herdr-work"]
        R["10 · herdr-broker<br/>Exact argv allowlist"]
        W["Work herdr server<br/>SSH-backed panes"]
        R -->|execv only| W
      end
      E["11 · hermes-herdr-egress<br/>Allowlist proxy"]
      H -->|SSH tools| B
      B -->|SSH argv| R
      W -->|SSH shells| B
      H -->|HTTPS CONNECT| E
      B -. blocked .-> E
    end
  end
  PC -->|SSH docker-exec| H
  E -->|egress network| API["12 · NVIDIA API<br/>integrate.api.nvidia.com:443"]
  B -. blocked .-> API

  classDef operator fill:#e0f2fe,stroke:#0369a1,color:#0c4a6e,stroke-width:2px;
  classDef agent fill:#ede9fe,stroke:#7c3aed,color:#4c1d95,stroke-width:2px;
  classDef enforcement fill:#fef3c7,stroke:#b45309,color:#78350f,stroke-width:2px;
  classDef isolated fill:#dcfce7,stroke:#15803d,color:#14532d,stroke-width:2px;
  classDef external fill:#fce7f3,stroke:#be185d,color:#831843,stroke-width:2px;
  class PC operator;
  class H,S,K agent;
  class C,R,E enforcement;
  class B,W isolated;
  class API external;
  style HOST fill:#f8fafc,stroke:#64748b,color:#0f172a
  style NET fill:#f1f5f9,stroke:#475569,color:#0f172a,stroke-dasharray:5 5
  style AGENT fill:#faf5ff,stroke:#a78bfa,color:#4c1d95
  style WORK fill:#f0fdf4,stroke:#86efac,color:#14532d
```

| # | Component / boundary | Details and source |
|---|---|---|
| 1 | Operator PC | `scripts/hh` uses host SSH followed by `docker exec herdr-hermes herdr …` to prompt, read, attach and answer approvals. Host SSH remains available; no container port is published. Source: `README.md`. |
| 2 | Server / Docker | Four Compose containers; no Docker socket mount or published ports. Read-only root filesystems, dropped capabilities and `no-new-privileges`; agent, work and workbench run as UID 10000, proxy as `nobody`. Source: `docker-compose.yml`, Dockerfiles. |
| 3 | Internal network | Compose `internal`, `172.31.252.0/24`, `internal: true`; agent `.10`, workbench `.20`, work `.21`, proxy `.2`. Only the proxy also joins Compose `egress`; the API arrow crosses that second network. Internal networking does not isolate these containers from each other; SSH authentication and proxy ACLs enforce the permitted services. Source: `docker-compose.yml`. |
| 4 | herdr-hermes / Hermes TUI | Hosts the control herdr server and Hermes as a pane's foreground process, launched with `--skills herdr-operator`, without `--yolo`. Its local herdr socket is separate from the work server's socket. Terminal and file tools use SSH to `worker@172.31.252.20:2222` with a pinned host key; both environment passthrough lists are empty. Source: `Dockerfile`, `entrypoint.sh`, `hermes-herdr-up.sh`, `config.yaml`. |
| 5 | herdr-operator skill | Root-owned, read-only `/opt/hermes-herdr/skills/herdr-operator/SKILL.md`; guides list → split/reuse → run → wait-output → read → summary. Skill text is instruction, not the broker enforcement boundary. Only operate on the skill's work panes; never answer approvals. Source: skill, `Dockerfile`, `entrypoint.sh`. |
| 6 | Managed config | Root-owned `/etc/hermes/config.yaml` on the read-only image locks manual approvals, deny rules and SSH backend; startup checks fail closed. Flagged commands require a human, timeout is 120 seconds, deny rules reject outright. Safety settings are also mirrored in the profile copied at startup because TUI backend/skill selection uses that profile. Source: `hermes-managed.yaml`, `config.yaml`, `entrypoint.sh`. |
| 7 | Model API key | Supplied through Compose `env_file` only to `herdr-hermes`, consumed via `model.key_env: NVIDIA_API_KEY`; never supplied to workbench or work. Precisely: entrypoint stages it in mode-0600 `/tmp/.hermes-herdr/model.key` on tmpfs, unsets it before starting herdr, and `hermes-shim` restores it to the Hermes process environment. Thus “env only” describes injection/model configuration, not exclusive storage: the tmpfs copy and Docker container metadata remain. No key is baked into the image or written to YAML. Source: Compose, entrypoint, shim, README caveats. |
| 8 | hermes-workbench | Key-only sshd on `:2222`; executes terminal/file tools and work-pane shell commands. `/work` is read-only except the `/work/workspace` volume; `/var/lib/workbench` and `/tmp` are also writable for state/runtime needs. No model key or real herdr binary; `/usr/local/bin/herdr` serializes argv with NUL separators over SSH to the broker. Direct internet has no route; proxy rejects this source IP. Source: `workbench/`, Compose, proxy config. |
| 9 | hermes-herdr-work / work herdr | Separate, supervised herdr server with state/socket in `/data/home`. Each pane runs `workbench-shell`, which SSHes back to `worker@172.31.252.20:2222` with a PTY and starts Bash in `/work/workspace`. The actual job executes in the workbench, not in this container. Source: `work/entrypoint.sh`, `work/workbench-shell`. |
| 10 | herdr-broker | Work sshd `:2222` forces this command: no login shell, PTY or forwarding. Parses NUL-delimited UTF-8 argv (64 KiB limit), ignores `SSH_ORIGINAL_COMMAND`, validates then `os.execv`s real herdr; rejection exits 126. Exact operation allowlist: `pane list`, `get`, `layout`, `read`, `wait-output`, `split`, `run`, `rename`; options/values are checked, split cwd can only be `/work/workspace`, wait requires a timeout (1–900000 ms) and match/regex. `run` accepts a pane ID and one nonempty command string up to 8192 characters, not starting with `-`. “No shell” applies to broker dispatch; that command string intentionally runs in the workbench pane's shell. Source: `work/herdr-broker`, `work/sshd_config`. |
| 11 | hermes-herdr-egress | Tinyproxy `:8888`, dual-homed on `internal` and `egress`. Accepts only `.10/32`; default-deny host filter `^integrate\.api\.nvidia\.com$` and CONNECT port 443. Workbench and work are refused. This is host/CONNECT-port filtering, not TLS inspection or API path/method filtering. Source: Compose, `egress/allowlist`, `egress/tinyproxy.conf`. |
| 12 | NVIDIA model API | Configured base URL `https://integrate.api.nvidia.com/v1`, model `nvidia/nemotron-3.5-super-vl-120b-a12b`; the sole configured external model destination allowed through the proxy. The dotted workbench → API edge denotes blocked direct internet access; it is not an extra network service. Source: `config.yaml`, egress config. |


## 🧩 Components

- `herdr-hermes`: herdr 0.9.5 server with Hermes Agent's TUI as the foreground process of pane `w1:p1`, agent name `hermes`.
- `hermes-workbench`: Alpine container where every Hermes terminal/file tool call runs; `/work` read-only except `/work/workspace`.
- `hermes-herdr-work`: the herdr server for the skill's work panes and the only place its real binary exists; panes are SSH shells into the workbench.
- `work/herdr-broker`: sshd ForceCommand that takes a herdr argv (NUL-separated, no shell), allows only `pane list/get/layout/split/run/read/wait-output/rename` and execs herdr.
- `workbench/herdr`: the workbench's `herdr`, a client that sends its argv to the broker.
- `hermes-herdr-egress`: tinyproxy that only lets `172.31.252.10` CONNECT to `integrate.api.nvidia.com:443`.
- `hermes-managed.yaml` → `/etc/hermes/config.yaml`: Hermes managed scope; locks the safety keys ("managed by your administrator").
- `config.yaml`: Hermes profile config, replaced from the image on every start; model settings plus a mirror of the safety keys (see [Caveats](#-caveats)).
- `skills/herdr-operator/SKILL.md`: the one skill, root-owned and read-only in the image.
- `herdr-agent-detection/hermes.toml`: herdr detection override so the Hermes TUI's turns show as `working`.
- `entrypoint.sh`, `hermes-herdr-up.sh`, `hermes-shim`: fail-closed guardrail check, key handling, start herdr and the `hermes` agent (idempotent).
- `scripts/hh`: `herdr` wrapper (`docker exec`, over SSH when `HERMES_HERDR_SSH` is set).
- `scripts/e2e-test.sh` (+ `broker-check.sh`, `deny-steps.py`): 15 end-to-end tests; `scripts/bench.sh`: efficiency benchmark.

## ✅ Prerequisites

- Linux server with Docker Engine + Compose v2, ~6 GB free disk (see [Disk](#-disk)), 2 vCPU / 4 GB RAM spare.
- An NVIDIA API key (build.nvidia.com) for the model `nvidia/nemotron-3.5-super-vl-120b-a12b`.
- On your PC: `ssh` key access to the server, `python3`, `bash`.

## 🚀 Run it

```bash
# on the server
mkdir -p ~/.config/hermes-herdr && chmod 700 ~/.config/hermes-herdr
cp herdr/hermes-herdr/hermes-herdr.env.example ~/.config/hermes-herdr/hermes-herdr.env
chmod 600 ~/.config/hermes-herdr/hermes-herdr.env      # then put your key after NVIDIA_API_KEY=
docker compose -f herdr/hermes-herdr/docker-compose.yml up -d --build
docker exec herdr-hermes herdr agent list               # hermes ... idle

# from your PC
export HERMES_HERDR_SSH=user@server
herdr/hermes-herdr/scripts/hh agent prompt hermes "Run uname -sr and reply with the output" --wait
herdr/hermes-herdr/scripts/hh agent read hermes --source recent-unwrapped --lines 20
herdr/hermes-herdr/scripts/e2e-test.sh                  # 15 tests, evidence in ./hermes-herdr-e2e.log
```

Approvals: when Hermes asks, herdr shows the agent as `blocked`. Read the panel with `hh agent read hermes`, move
to **4. Deny** with `hh agent send-keys hermes down down down` and confirm with `hh agent send-keys hermes enter`
(`scripts/deny-steps.py` finds the Deny row from the panel text), or attach and choose (`hh agent attach hermes`).

## 🧪 Tests

`scripts/e2e-test.sh` runs from your PC; every approval it meets is answered **Deny**. Evidence goes to `$EVIDENCE`
(lines that look like an NVIDIA key are filtered out).

| # | Test | How it is proven | Result |
|---|------|------------------|--------|
| 1 | herdr recognises Hermes, idle → working → idle | `agent get` kind `hermes`; `agent wait --until working` / `--until idle` return; `state_change_seq` +≥2 | PASS: kind `hermes`; wait working + idle ok; seq 1→2→3 |
| 2 | prompt `--wait` + `agent read`; runs in the workbench | output `hostname` = workbench, ≠ herdr-hermes; `$SSH_CONNECTION` = `172.31.252.10 … 172.31.252.20 2222` (the sshd login count may not move: `ssh_persistent` reuses one ControlMaster connection) | PASS: hostname = workbench; `via=172.31.252.10 … 172.31.252.20 2222` |
| 3 | dangerous command → herdr `blocked` → Deny → not run | `chmod -R 777` raises the approval panel, herdr state `blocked`, Deny selected from the panel text, file mode unchanged | PASS: state `blocked`; denied 1×; mode 644→644 |
| 4 | `approvals.deny`: privilege escalation refused without a prompt | runtime: `sudo ls /root` → `BLOCKED … deny rule`, 0 prompts; matcher: 12 forms (`sudo`, `/usr/bin/sudo`, `env sudo`, `bash -c "sudo …"`, `s\udo`, `su`, `doas`, `pkexec` …) → `user-deny` | PASS: runtime BLOCKED, 0 prompts; matcher 12/12 |
| 5 | writes outside `/work/workspace` refused (tool **and OS**) | `write_file` returns "outside HERMES_WRITE_SAFE_ROOT"; as the worker uid a shell write to `/work` and a write through a symlink to `/` fail with "Read-only file system" | PASS: write_file denied; shell + symlink writes: Read-only file system |
| 6 | NVIDIA key never visible to commands or output | 0 NVIDIA vars in the workbench and the work container; no `nvapi-` in output | PASS: 0 NVIDIA vars in workbench and work; no `nvapi-` |
| 7 | egress: model API only; workbench offline | herdr-hermes → NVIDIA 200, → example.com refused; workbench direct fails, workbench → proxy answered `403` | PASS: NVIDIA 200, example.com 000; workbench direct fails, proxy 403 |
| 8 | container hardening (herdr-hermes, workbench, work) | uid 10000, CapEff 0, read-only rootfs, NoNewPrivs 1, Seccomp 2, no ports, no Docker socket | PASS: all 3: uid 10000, CapEff 0, ro, NoNewPrivs 1, Seccomp 2 |
| 9 | skill herdr-operator drives the work herdr | work herdr reset to 1 pane; afterwards a **new** pane holds the skill's marker command (`…; echo EXIT_$?_…`) and the answer equals the workbench's real `uname -sr` | PASS: panes 1→2; marker in new pane; answer = real `uname -sr` |
| 10 | forbidden herdr commands refused | **OS layer (the control):** as the worker uid, 9 forbidden forms through herdr-broker → exit 126 "denied", incl. the quoting tricks that pass the globs (`herdr "agent" send-keys`, `h=herdr; $h agent …`) and a direct ssh to the broker; `herdr pane list` allowed; no real herdr binary in the workbench. **Glob layer (defence in depth):** `hermes approvals test` → `user-deny` for 5 forms, `allow` for `herdr pane list`; runtime `!echo <forbidden string> <nonce>` → `BLOCKED`, nonce never printed; glob limits recorded in the evidence | PASS: broker 9/9 refused, allowed call ok; globs 5/5, runtime 2/2 |
| 11 | Hermes cannot reach its own pane (no self-approval) | workbench: 0 herdr sockets, `herdr agent list` refused by the broker; work herdr has no agents | PASS: 0 herdr sockets; agent list refused; work agents `[]` |
| 12 | skills can't be created/edited; guardrail config unchanged | skill tree hash and `/etc/hermes/config.yaml` sha256 equal before/after (both on a read-only rootfs, which is the control); no `evil-skill` | PASS: skill + config sha256 equal before/after |
| 13 | control from the PC, nothing new listening | `hh agent list` over SSH; no host socket owned by herdr; 0 published ports; inside: workbench and work `:2222`, egress `:8888`, herdr-hermes loopback only | PASS: 0 published ports; only :2222 ×2, :8888, loopback |
| 14 | restart recovery | `docker restart herdr-hermes` → agent back `idle`, workspace file kept | PASS: back `idle`; workspace file kept |
| 15 | existing stack untouched | dashboard `/login` 200; its containers still up | PASS: `/login` 200; 5 containers up |

Result on Hermes Agent v0.22.5 (herdr 0.9.5): **15/15 PASS in three consecutive runs** (2026-11-07). The table shows
the last run; the evidence logs contain no `nvapi-` string. Earlier failures while building the suite were test bugs
(sampling, panel parsing, stdin) and one real finding (`sudo` without arguments, `su`, `doas`, `pkexec` were not in the
deny rules; added), all fixed before these runs.

## 🛡️ Hermes guardrails

Set in `hermes-managed.yaml` (managed scope, the user can't override it) and mirrored in `config.yaml`. Every key
was checked against the Hermes code (`hermes_cli/config_defaults.py` and the code that reads it) in v0.22.5 and again in v0.23.0 (same keys, same defaults; `_config_version` 51 → 52).

| Setting | Value | Protects against | Docs | Verified by |
|---|---|---|---|---|
| `approvals.mode` | `manual` (not the default `smart`) | a model auto-approving flagged commands | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | test 3 |
| `approvals.timeout` | `120` | an unanswered prompt running anyway (no answer = deny) | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | config |
| `approvals.cron_mode` / `single_query_mode` / `unattended_mode` | `deny` | auto-approval in cron, `hermes -q` and API runs | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | config |
| `approvals.denial_breaker_threshold` | `3` | retry loops after denials | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | config |
| `approvals.deny` | `rm -rf /`, `sudo` (also bare), `su`, `doas`, `pkexec`, `curl\|sh`, `wget\|sh`, `git push`, `docker`, plus the herdr globs below | these commands, even under `--yolo`. String globs: they catch wrappers, paths, case and quoting of the command word, not quoting of later words, so the real limits are the containers | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | tests 4, 10 |
| `command_allowlist` | `[]` | stored "always allow" answers | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | config |
| no `--yolo` | Hermes starts as `hermes --skills herdr-operator` | bypassing approvals (`--yolo` can't be disabled by config; `approvals.deny` still applies under it) | [CLI](https://hermes-agent.nousresearch.com/docs/user-guide/cli) | `hermes-herdr-up.sh` |
| `terminal.backend: ssh` → workbench, `env_passthrough: []` | commands and file tools run in `hermes-workbench` | commands touching herdr-hermes (its herdr socket, key, config) | [Tools](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools) | tests 2, 6, 11 |
| `HERMES_WRITE_SAFE_ROOT` | `/work/workspace` | file-tool writes outside the workspace (path check only; the OS boundary is the workbench's read-only `/work`) | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | test 5 |
| `platform_toolsets.cli` | `terminal, file, todo, clarify` | everything else (web, browser, code execution, delegation, MCP, memory, skills tools …) | [Tools](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools) | config |
| `agent.disabled_toolsets` | web, search, browser, code_execution, delegation, cronjob, memory, session_search, connections, skills, computer_use, vision, image_gen, tts, kanban, x_search, video, video_gen, stt | same, second layer | [Tools](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools) | config |
| `agent.max_turns` / `run_budget_seconds` | `30` / `1800` | runaway loops and cost | [Configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration) | config |
| `security.redact_secrets` | `true` | secrets in tool output, logs, prompts | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | test 6 |
| `security.allow_private_urls` / `allow_lazy_installs` | `false` / `false` | SSRF; automatic package installs | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | config |
| `security.protected_instruction_files` | `true` | silent edits to AGENTS.md / SOUL.md / Hermes config | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | config |
| `security.approval.transport_fallback` | `deny` | an approval path failing open | [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security) | config |
| secrets via env only (`model.key_env: NVIDIA_API_KEY`) | env file mode 600 outside the repo | keys in config files or the image | [Secrets](https://hermes-agent.nousresearch.com/docs/user-guide/secrets) | test 6 |
| `tools.connectors`, `mcp_servers`, `memory`, `curator`, `auxiliary.background_review` | off / `{}` | extra tool surfaces and background "save memory / patch skill" runs | [Memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory), [Curator](https://hermes-agent.nousresearch.com/docs/user-guide/features/curator) | config |
| `delegation.subagent_auto_approve` / `max_spawn_depth` | `false` / `1` | sub-agents approving their own commands | [Delegation](https://hermes-agent.nousresearch.com/docs/user-guide/features/delegation) | config |
| `code_execution.mode`, `hooks_auto_accept`, `plugins.auto_apply`, `updates.check` | `strict`, `false`, `false`, `false` | unreviewed code, hooks, plugin updates | [Configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration) | config |
| managed scope `/etc/hermes/config.yaml` | root-owned, read-only image | the agent or user relaxing any key above | [Managed Scope](https://hermes-agent.nousresearch.com/docs/user-guide/managed-scope) | test 12 |
| fail closed at start | `entrypoint.sh`: the managed file must parse and pin manual approvals, the ssh backend and the deny rules, and `hermes approvals test -- sudo ls` must return `user-deny`; otherwise the container exits | Hermes silently ignoring a managed file it can't parse | [Managed Scope](https://hermes-agent.nousresearch.com/docs/user-guide/managed-scope) | start-up |
| no bundled skills | `HERMES_BUNDLED_SKILLS` → empty dir; seeded copies removed at start | unused skills in the prompt's skill index | [Skills](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills) | start-up |

## 🧰 Hermes skill: herdr-operator

One skill lets Hermes use a **second, separate herdr** (in `hermes-herdr-work`) to run long commands in panes, wait
for completion markers and read only the lines it needs. Work panes are SSH shells into the workbench, so those
commands run next to Hermes's other commands. Hermes can't see or control the herdr server that runs Hermes itself.

| Control | How | Verified by |
|---|---|---|
| Skill is fixed | in the image at `/opt/hermes-herdr/skills`, root-owned, mode 0644; loaded via `skills.external_dirs` | test 12 |
| No skill create/edit | `skills` toolset disabled (no `skill_manage`), `write_approval`, `guard_agent_created`, curator off | test 12 |
| herdr allowlist (OS-enforced) | the workbench has no herdr binary; its `herdr` sends argv to `herdr-broker`, which allows only `pane list/get/layout/split/run/read/wait-output/rename` with checked options (pane ids `wN:pN`, `--cwd /work/workspace` only, `wait-output` needs `--timeout`) and execs herdr without a shell | test 10 |
| Forbidden herdr commands (second layer) | `approvals.deny` globs: `*herdr server stop*`, `*herdr * close*`, `*herdr --machine*`, `*herdr --remote*`, `*herdr --session*`, `*herdr update*`, `*herdr integration*`, `*herdr config*`, `*herdr agent send-keys*`, `*herdr agent prompt*`, `*herdr agent start*`, `*herdr machine*` | test 10 |
| No self-approval | Hermes's commands run in the workbench; its own pane and approval prompt live in herdr-hermes's herdr, which neither the workbench nor the work herdr can reach | test 11 |
| Work herdr stays up | supervised restart loop in `hermes-herdr-work`; the broker never allows `server stop` | test 10 |
| Everything else still asks | non-herdr dangerous commands still go to the manual approval prompt | test 3 |
| Skill text | never bypass approvals or use `--yolo`, never touch secrets, only allowed herdr commands, stop after 2 failures | `SKILL.md` |

### 🔁 How Hermes runs a command through herdr

```mermaid
sequenceDiagram
  title Hermes uses herdr-operator to run a command
  actor U as Operator
  participant H as Hermes TUI
  participant C as Workbench client
  participant B as Broker
  participant W as Work herdr
  participant P as Workbench shell

  U->>H: User prompt via SSH + docker exec
  Note over H: herdr-operator guides pane workflow
  Note over H: Deny rules reject, approval applies when flagged
  opt Command flagged for approval
    H-->>U: Approval prompt (agent blocked)
    U->>H: Human decision
    break Denied or timed out
      H-->>U: Not executed
    end
  end
  Note over H,W: List panes first, split if needed (same broker path)
  H->>C: SSH terminal: herdr pane run ID command
  C->>B: SSH: NUL-separated herdr argv
  B->>B: Validate exact argv, reject invalid requests
  B->>W: execv herdr pane run
  W->>P: Type command + Enter over pane SSH
  P-->>W: Output + computed exit marker
  W-->>B: Run acknowledgement
  B-->>C: Return result
  C-->>H: Tool result
  loop wait-output, then read
    H->>C: herdr pane wait-output / read
    C->>B: SSH argv
    B->>W: Validate and execv
    W-->>B: Marker matched / captured output
    B-->>C: Return result
    C-->>H: Tool result
  end
  H-->>U: Exit code + concise summary
  Note over H,P: wait-output uses timeout + computed marker, read defaults to 40 lines in skill
```


## 🚫 No OpenShell: what's lost

This POC uses **no NVIDIA OpenShell**. Isolation comes from Docker hardening, a separate workbench container,
an internal network and an allowlist proxy.

| OpenShell feature | Here instead | Gap |
|---|---|---|
| Landlock filesystem policy inside the sandbox | read-only rootfs (only `/work/workspace` writable in the workbench), non-root, separate containers, `HERMES_WRITE_SAFE_ROOT` | no per-path kernel policy inside a container |
| L7 network policy (per host/path/method) | tinyproxy CONNECT allowlist (host + port 443) | no path/method filtering, no TLS inspection |
| Credential placeholders (the agent never holds the real key) | key only in the Hermes process tree (moved out of the container env at start); workbench and work container have none; redaction on | the Hermes processes hold the real key |

## ⚠️ Caveats

- **Profile config matters:** Hermes's TUI session builds its terminal backend and skill dirs from the *profile*
  `config.yaml`, not only the managed file, so the safety keys are mirrored there and the file is replaced from the
  image on every start. Keep both files in sync in the repo.
- **Detection override:** herdr's bundled Hermes manifest doesn't match the TUI's working line; the override in
  `herdr-agent-detection/hermes.toml` is copied to `~/.config/herdr/agent-detection/` and only loads at server start.
- **Don't run `herdr integration install hermes`:** it appends to `config.yaml` in a way that breaks flow-style YAML
  (`TerminalPolicyUnavailable`). It only reports session identity; not needed.
- **The `!` shell:** whoever can `herdr agent prompt` this pane can type `!cmd`, which runs in herdr-hermes (through
  the same deny/approval guard, with provider keys filtered from its environment). That is operator access, the same
  as `docker exec`; Hermes itself can't reach it. From there `/proc/<hermes pid>/environ` still shows the key.
- **Where the key still is:** the entrypoint moves it from the container environment into a 0600 file on the tmpfs
  and unsets it, so the herdr server and pane shells start without it; `hermes-shim` loads it for Hermes only. It
  remains in PID 1's environment, in Hermes's own processes and in `docker inspect` (it comes from an env file).

## 📊 Hermes v0.22.5 vs v0.23.0

In progress. Baseline measured on v0.22.5 so far: image 4348 MB, startup to `idle` 22.6 s, idle CPU 1.3 %, idle RAM
386 MiB, approval guardrail 3/3. Task timings and the v0.23.0 comparison follow once both benchmarks are complete
(`scripts/bench.sh`, same model and prompts, 3 runs, median).

## 💾 Disk

| Image | Size | Note |
|---|---|---|
| `herdr-hermes:herdr0.9.5-hermesv0.22.5` | 4.35 GB | built `FROM nousresearch/hermes-agent:v0.22.5` (4.31 GB), layers shared |
| `hermes-workbench` | 85 MB | |
| `hermes-herdr-egress` | 24 MB | |

- Keep **>= 3 GB free** on `/`; check `df -h /` before every build. Build a new Hermes version `FROM` its pulled
  base image so only the small top layers are new, and remove the version you don't keep once the other is verified.
- Each build leaves about 4 GB of BuildKit cache: run `docker builder prune -af` after **every** build.
- Cleanup: `docker builder prune -af`, `docker image prune -f`, `docker rmi <superseded tag>`,
  `sudo journalctl --vacuum-size=50M`, `sudo apt-get clean`.
- Container logs rotate at 10 MB x 3 (`/etc/docker/daemon.json`) for containers created after that file was installed.
- 20 GB is tight for two Hermes versions side by side; use a 30-40 GB root volume for a new server.

## ☸️ Run on GKE later (sketch, not tested)

- **Workload:** one StatefulSet per container (herdr-hermes, workbench) with a PVC each for `/data` and `/work`, a
  shared Secret-mounted key pair instead of the `keys` volume, and a Deployment for the egress proxy.
- **Pod security:** `runAsNonRoot`, `runAsUser: 10000`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, resource limits as in the compose file.
- **Secret:** `NVIDIA_API_KEY` from a Kubernetes Secret (or Secret Manager CSI), mounted as env only in herdr-hermes.
- **NetworkPolicy:** default deny; herdr-hermes → workbench:2222 and → egress:8888; egress → 0.0.0.0/0:443 (the
  allowlist lives in tinyproxy); nothing else, no Service exposed outside the namespace.
- **Control:** `kubectl exec herdr-hermes-0 -- herdr …` replaces `docker exec` (set `scripts/hh` accordingly).

## 🧹 Teardown

```bash
docker compose -f herdr/hermes-herdr/docker-compose.yml down        # keep volumes
docker compose -f herdr/hermes-herdr/docker-compose.yml down -v     # also delete Hermes state and the workspace
```

## 📌 Pinned versions

| Component | Version |
|---|---|
| herdr | 0.9.5 (`herdr-linux-x86_64`, sha256 `14d9e8bc…929d`, checked at build) |
| Hermes Agent | `nousresearch/hermes-agent:v0.22.5` (tested); `HERMES_VERSION` selects the base image |
| Alpine (workbench, work, egress) | 3.24.2 |
| tinyproxy | from Alpine 3.24.2 |
| Model | `nvidia/nemotron-3.5-super-vl-120b-a12b` via `integrate.api.nvidia.com` |
