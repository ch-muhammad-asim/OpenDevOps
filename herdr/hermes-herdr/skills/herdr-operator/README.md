# 🧰 `herdr-operator`: Hermes skill for herdr panes

Tells Hermes how to run and watch commands in panes of the separate **work** herdr server (`hermes-herdr-work`): split a pane, run a command with a computed completion marker, wait for it, read only the lines it needs, and summarize. Where it sits: see [Architecture](../../README.md#️-architecture) and [How Hermes runs a command through herdr](../../README.md#-how-hermes-runs-a-command-through-herdr).

## 📁 Files

| File | What it does |
|------|--------------|
| [`SKILL.md`](SKILL.md) | The skill: frontmatter (name, description, version 1.0.0, needs `herdr` and `jq`), the rules and the allowed herdr commands |
| `README.md` | This page (not copied into the image, see [`../README.md`](../README.md)) |

## ⚙️ How it is used

- Installed read-only at `/opt/hermes-herdr/skills/herdr-operator/SKILL.md` and preloaded by [`../../hermes-herdr-up.sh`](../../hermes-herdr-up.sh) (`--skills herdr-operator`).
- Hermes's commands run in the workbench as uid 10000. Its `herdr` there is a client that sends the argv to `herdr-broker` in `hermes-herdr-work` over SSH on port 2222. Work panes run in `/work/workspace`.
- Commands it uses: `herdr pane list`, `pane split --direction right --no-focus --cwd /work/workspace`, `pane run`, `pane wait-output --regex 'EXIT_[0-9]+_42' --timeout …`, `pane read --source recent-unwrapped --lines 40` and `pane rename`.

## 🛡️ Security notes

- The skill is guidance, not the control. `herdr-broker` enforces the exact-argv allowlist (test 10), and the `approvals.deny` globs in [`../../hermes-managed.yaml`](../../hermes-managed.yaml) are a second layer.
- Its rules tell Hermes never to bypass or answer approvals, never to touch secrets, never to stop the herdr server, use `--machine`/`--remote`, change herdr config or send keys or prompts to an agent, and to stop after 2 failed attempts at the same step.
- Locked with `hermes curator lock` (Hermes v0.23.0+); skill create/edit tools are disabled.
- Must never contain secrets, hostnames or IPs.

## 🧪 Tests

| # | What it proves |
|---|----------------|
| 9 | The skill workflow runs: a new work pane, `uname -sr` typed there, answer = the workbench's real `uname -sr` |
| 10 | Forbidden herdr commands are refused by `herdr-broker` (exit 126) whatever the skill says |
| 12 | Hermes can't create skills or edit this one: the skill tree sha256 is unchanged, the curator lock is in place (v0.23.0+) |
| 18 | Output read back with `pane read` is masked in Hermes's pane, logs and `state.db` |

Last full run: 15/15 PASS on Hermes Agent v0.22.5 and herdr 0.9.5 (2026-11-07, [`../../scripts/e2e-test.sh`](../../scripts/e2e-test.sh)); tests 16-19 are in [`../../scripts/e2e-redaction.sh`](../../scripts/e2e-redaction.sh), and the v0.23.0 re-run is in progress ([Tests](../../README.md#-tests)).

⬆️ Back to [`skills/`](../README.md) · [herdr + Hermes Agent POC](../../README.md)
