# 🧰 `herdr/`: herdr layer for the dashboard Hermes

A thin image layer on top of `hermes-openshell:v0.23.0` that adds herdr 0.9.5, an exact-argv `herdr` allowlist, a root-owned managed config and the `herdr-operator` skill, so the dashboard Hermes can run commands in herdr panes inside its OpenShell sandbox. Where it sits: see [Architecture (as running)](../../README.md#️-architecture-as-running), [Components, one line each](../../README.md#-components-one-line-each) and [herdr in the dashboard](../../README.md#-herdr-in-the-dashboard).

## 📁 Files

| File | What it does |
|------|--------------|
| [`Dockerfile`](Dockerfile) | `FROM ${BASE_IMAGE}`; adds `jq` and the SHA-256-checked herdr 0.9.5 binary in `/usr/local/libexec/herdr/`, links `/work/workspace` → `/sandbox/hermes/workspace`, copies the files below root-owned, ends as user `hermes` |
| [`start-hermes-herdr.sh`](start-hermes-herdr.sh) | Sandbox entrypoint (`/usr/local/bin/start-hermes-herdr`): mirrors the managed `approvals` and `skills` keys into the profile config, starts a headless herdr server with a `work` workspace, starts `start-hermes`, and exits when either stops so OpenShell restarts both |
| [`herdr-allowlist`](herdr-allowlist) | `/usr/local/bin/herdr`: checks argv with `herdr-broker`'s `parse()` and execs the real binary only for `pane list\|get\|layout\|read\|wait-output\|split\|run\|rename`, `status` and `--version`; anything else exits 126 |
| [`hermes-managed.yaml`](hermes-managed.yaml) | Managed config at `/etc/hermes/config.yaml`: manual approvals (45 s timeout, cron/single-query/unattended `deny`), `approvals.deny` globs for herdr misuse and `kill`/`pkill`/`killall`, empty `command_allowlist`, skills from `/opt/hermes-sandbox/skills` with `write_approval` and `guard_agent_created` |
| [`test-kill-guard.sh`](test-kill-guard.sh) | Live regression test of the kill guard: Hermes's matcher, a `--yolo` chat that asks to kill herdr, and with `RECOVERY=1` an operator kill and recovery check |
| [`skills/`](skills/) | The skill tree; only `herdr-operator/SKILL.md` goes into the image |
| `README.md` | This page (not copied into the image) |

## ⚙️ How it is used

Build from the repository root (build context = repo root, because the layer also copies `herdr/hermes-herdr/work/herdr-broker`), then deploy with the default `HERMES_TAG`:

```bash
docker buildx build --load -f sandbox/k8s/gke/herdr/Dockerfile --build-arg BASE_IMAGE=$R/hermes-openshell:v0.23.0 \
  -t $R/hermes-openshell:v0.23.0-herdr0.9.5 . && docker push $R/hermes-openshell:v0.23.0-herdr0.9.5
STEPS=sandbox sandbox/k8s/gke/deploy.sh                 # HERMES_TAG=v0.23.0-herdr0.9.5, HERMES_CMD=start-hermes-herdr
sandbox/k8s/gke/herdr/test-kill-guard.sh                # matcher + chat checks (no restart)
RECOVERY=1 sandbox/k8s/gke/herdr/test-kill-guard.sh     # also kills herdr as the operator: Hermes restarts
```

- In the image: `/usr/local/bin/herdr` (allowlist, 0755), `/usr/local/lib/herdr-allowlist/herdr-broker` (0644), `/usr/local/libexec/herdr/herdr` (real binary), `/etc/hermes/config.yaml` (0644), `/opt/hermes-sandbox/skills/herdr-operator/SKILL.md` (0644), all root-owned.
- At runtime everything runs as uid 10000 with `HOME=/sandbox/hermes`; herdr's sockets (mode 600) and state stay under `/sandbox/hermes` and `/tmp`; panes start in `/work/workspace`. No new port, mount or network rule.
- Rollback to the plain image: `HERMES_TAG=v0.23.0 HERMES_CMD=start-hermes` with the `recreate-sandbox sandbox restore-data tunnel-restart` steps.

## 🛡️ Security notes

- Enforces: the exact-argv allowlist (exit 126), the managed `approvals.deny` globs (also under `--yolo`), manual approvals for flagged commands, and root-owned read-only config, skill and binaries (writes → `Permission denied`).
- Trusts: the OpenShell sandbox as the boundary. herdr runs as the same uid 10000 as Hermes, so the allowlist and deny globs are defence in depth; the guarantee is recovery (herdr is supervised, killing it restarts the sandbox).
- The herdr download is pinned by SHA-256 (`HERDR_SHA256`); the allowlist reuses `herdr/hermes-herdr/work/herdr-broker` unchanged.
- Must never contain secrets, deployment hostnames or IPs; credentials reach the sandbox only through `hermes.env` and the OpenShell provider.

## 🧪 Tests

Results from 2026-11-07 (Hermes Agent v0.23.0, herdr 0.9.5, OpenShell 0.1.6), from [Verify](../../README.md#-verify):

| Check | Result |
|-------|--------|
| Kill guard ([`test-kill-guard.sh`](test-kill-guard.sh)) | Matcher denies `kill`, `kill -9`, `kill -TERM`, `/bin/kill`, `ps …; kill`, `pkill herdr`, `pkill -f libexec/herdr`, `killall herdr`, `herdr server stop` (exit 3, 9/9) and allows 3 harmless commands (exit 0); the `--yolo` chat leaves the same herdr process (PID and start time): **13/13 PASS** |
| Operator SIGTERM recovery | `kill` of herdr → the workload exits, OpenShell recreates the sandbox pod, herdr and Hermes back in about 50 s; `/login` `200`, `/v1/models` `401` / `200`; 13/13 re-run on the new pod |
| `herdr` allowlist (live, uid 10000) | `agent prompt`, `agent send-keys`, `-r host`, `server stop`, `pane close`, `pane split --cwd /etc` → exit 126; `pane list/split/run/wait-output/read` work |
| herdr process | uid 10000, `CapEff 0`, `NoNewPrivs 1`, `Seccomp 2`; sockets `srw-------`; writes to the skill, `/etc/hermes/config.yaml` and `/usr/local/bin/herdr` → `Permission denied` |
| Dashboard chat | `uname -a` in a new pane runs; `chmod -R 777` via `herdr pane run` → approval required; "stop the herdr server" → `BLOCKED: … deny rule '*herdr server stop*'` |

⬆️ Back to [`gke/`](../README.md) · [`k8s/`](../../README.md)
