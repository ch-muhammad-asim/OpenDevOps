#!/bin/bash
# Sandbox entrypoint for the dashboard Hermes with herdr: mirror the managed approval/skill keys into the profile
# config (Hermes's chat session reads skill dirs and approval settings from it), keep a headless herdr server
# running inside the sandbox, then hand over to start-hermes (dashboard + gateway).
set -euo pipefail
export HOME="${HERMES_HOME:-/sandbox/hermes}"
mkdir -p "$HOME/workspace"
[ -f "$HOME/config.yaml" ] || cp /opt/hermes-sandbox/config.yaml "$HOME/config.yaml"
/opt/hermes/.venv/bin/python - "$HOME/config.yaml" /etc/hermes/config.yaml <<'PY'
import sys
from ruamel.yaml import YAML
y = YAML()  # round-trip: keeps the comments of the seeded config
prof, managed = sys.argv[1], sys.argv[2]
p = y.load(open(prof)) or {}
m = y.load(open(managed)) or {}
for k in ("approvals", "skills"):
    p.setdefault(k, {}).update(m.get(k, {}))
p["command_allowlist"] = []
with open(prof, "w") as f:
    y.dump(p, f)
PY
# herdr's socket and state stay under the sandbox's writable paths ($HOME, /tmp). This script stays the workload's
# main process and supervises both herdr and start-hermes (dashboard + gateway): if either exits or is killed (or this
# script is), the workload exits and OpenShell's on-failure restart brings Hermes and herdr back together. A process of
# the same uid can always signal another, so recovery, not prevention, is the guarantee; `kill` is also denied in the
# managed config for the naive forms.
cd "$HOME/workspace"
/usr/local/libexec/herdr/herdr server >/dev/null 2>&1 &
herdr_pid=$!
# A headless server starts with no panes, so open one workspace ("work", in /work/workspace) for the skill to split.
for _ in $(seq 1 30); do herdr pane list >/dev/null 2>&1 && break; sleep 1; done
[ "$(herdr pane list 2>/dev/null | jq '.result.panes | length')" != 0 ] ||
  /usr/local/libexec/herdr/herdr workspace create --cwd /work/workspace --label work --focus >/dev/null 2>&1 || true
start-hermes &
hermes_pid=$!
trap 'kill "$herdr_pid" "$hermes_pid" 2>/dev/null || true' EXIT INT TERM
status=0
wait -n "$herdr_pid" "$hermes_pid" || status=$?
echo "[start-hermes-herdr] herdr or Hermes exited (status $status); stopping the other so the sandbox restarts" >&2
exit $(( status == 0 ? 1 : status ))
