# 🧰 `skills/`: the one skill of the dashboard Hermes

The skill tree for the herdr image layer. It holds exactly one skill, [`herdr-operator`](herdr-operator/), the only external skill the dashboard Hermes loads. Where it sits: see [Architecture (as running)](../../../README.md#️-architecture-as-running), [Components, one line each](../../../README.md#-components-one-line-each) and [herdr in the dashboard](../../../README.md#-herdr-in-the-dashboard).

## 📁 Files

| File | What it does |
|------|--------------|
| [`herdr-operator/`](herdr-operator/) | The skill: `SKILL.md`, which tells Hermes how to run and watch commands in herdr panes inside the sandbox |
| `README.md` | This page (not copied into the image) |

## ⚙️ How it is used

- [`../Dockerfile`](../Dockerfile) copies only `herdr-operator/SKILL.md` to `/opt/hermes-sandbox/skills/herdr-operator/SKILL.md`; no `COPY` or `ADD` takes this folder as a whole, so the README files never reach the image. Afterwards the tree is root-owned, directories 0755, files 0644.
- [`../hermes-managed.yaml`](../hermes-managed.yaml) sets `skills.external_dirs: ["/opt/hermes-sandbox/skills"]`, and [`../start-hermes-herdr.sh`](../start-hermes-herdr.sh) mirrors the `skills` keys into the profile config (`/sandbox/hermes/config.yaml`) at every start.
- A change here needs a new image and a sandbox roll (`STEPS="recreate-sandbox sandbox restore-data tunnel-restart" sandbox/k8s/gke/deploy.sh`).

## 🛡️ Security notes

- Enforces nothing on its own: the skill is guidance. The controls are the `herdr` allowlist and the managed `approvals.deny` globs in [`../hermes-managed.yaml`](../hermes-managed.yaml).
- Skill create/edit is staged for a human (`write_approval: true`, `guard_agent_created: true`, `creation_nudge_interval: 0`), and the installed files are root-owned, so Hermes (uid 10000) cannot change them.
- Must never contain secrets, deployment hostnames, IPs or herdr commands outside the allowlist.

## 🧪 Tests

Results from 2026-11-07 (Hermes Agent v0.23.0, herdr 0.9.5, OpenShell 0.1.6), from [Verify](../../../README.md#-verify):

| Check | Result |
|-------|--------|
| Skill in the dashboard chat | "can you access herdr?" names `herdr-operator`; "run `uname -a` in a new pane" loads the skill and runs it in a new pane |
| Skill is read-only | Writes to the skill as uid 10000 → `Permission denied` |
| Kill guard | [`../test-kill-guard.sh`](../test-kill-guard.sh) 13/13 PASS; operator SIGTERM to herdr → sandbox recreated, herdr back in about 50 s |

⬆️ Back to [`herdr/`](../README.md) · [`k8s/`](../../../README.md)
