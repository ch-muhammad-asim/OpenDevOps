# 🧰 `herdr-operator`: Hermes skill for herdr panes in the sandbox

Tells the dashboard Hermes how to run and watch commands in panes of the herdr server inside its own OpenShell sandbox: split a pane, run a command with a computed completion marker, wait for it, read only the lines it needs, and summarize. Where it sits: see [Architecture (as running)](../../../../README.md#️-architecture-as-running), [Components, one line each](../../../../README.md#-components-one-line-each) and [herdr in the dashboard](../../../../README.md#-herdr-in-the-dashboard).

## 📁 Files

| File | What it does |
|------|--------------|
| [`SKILL.md`](SKILL.md) | The skill: frontmatter (name, description, version 1.0.0, needs `herdr` and `jq`), the rules and the allowed herdr commands |
| `README.md` | This page; **not copied into the image** (the Dockerfile copies only `SKILL.md`, because Hermes can read any other file in a skill folder as skill content) |

## ⚙️ How it is used

- Installed read-only at `/opt/hermes-sandbox/skills/herdr-operator/SKILL.md` by [`../../Dockerfile`](../../Dockerfile) and found through `skills.external_dirs` in [`../../hermes-managed.yaml`](../../hermes-managed.yaml).
- Hermes's commands and the herdr panes run in the same sandbox as uid 10000 (Landlock, seccomp, no capabilities, network only through the OpenShell policy). `herdr` on PATH is the allowlist [`../../herdr-allowlist`](../../herdr-allowlist); panes start in `/work/workspace` (→ `/sandbox/hermes/workspace`).
- Commands it uses: `herdr pane list`, `pane split --direction right --no-focus --cwd /work/workspace`, `pane run`, `pane wait-output --regex 'EXIT_[0-9]+_42' --timeout …`, `pane read --source recent-unwrapped --lines 40` and `pane rename`.

## 🛡️ Security notes

- The skill is guidance, not the control: the `herdr` allowlist refuses everything else (exit 126), and the `approvals.deny` globs in [`../../hermes-managed.yaml`](../../hermes-managed.yaml) are a second layer.
- Its rules tell Hermes never to bypass or answer approvals or use `--yolo`, never to touch secrets, never to stop the herdr server, use `--machine`/`--remote`, change herdr config or send keys or prompts to an agent, and to stop after 2 failed attempts at the same step.
- Root-owned and read-only in the image; skill create/edit is staged for a human (`write_approval`, `guard_agent_created`).
- Must never contain secrets, deployment hostnames or IPs.

## 🧪 Tests

Results from 2026-11-07 (Hermes Agent v0.23.0, herdr 0.9.5, OpenShell 0.1.6), from [Verify](../../../../README.md#-verify):

| Check | Result |
|-------|--------|
| Dashboard chat | "run `uname -a` in a new pane" → skill loaded, new pane, `Linux default--hermes …`; `chmod -R 777` via `herdr pane run` → approval required; "stop the herdr server" → `BLOCKED: … deny rule '*herdr server stop*'`, server still running |
| Forbidden herdr commands | `agent prompt`, `agent send-keys`, `-r host`, `server stop`, `pane close`, `pane split --cwd /etc` → exit 126 whatever the skill says |
| Kill guard | [`../../test-kill-guard.sh`](../../test-kill-guard.sh) 13/13 PASS; operator SIGTERM to herdr → sandbox recreated, herdr back in about 50 s |
| Read-only skill | Writes to the skill as uid 10000 → `Permission denied` |

⬆️ Back to [`skills/`](../README.md) · [`herdr/`](../../README.md) · [`k8s/`](../../../../README.md)
