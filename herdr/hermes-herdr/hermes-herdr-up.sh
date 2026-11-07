#!/bin/sh
# Idempotent: make sure herdr has a workspace "hermes" whose pane runs the Hermes CLI as agent "hermes".
# Runs at container start (after a restart herdr restores the workspace; this starts Hermes in it again)
# and can be run by hand: docker exec herdr-hermes hermes-herdr-up
set -u
AGENT="${HERMES_AGENT_NAME:-hermes}"
LABEL="${HERMES_WORKSPACE_LABEL:-hermes}"
log() { echo "[hermes-herdr-up] $*" >&2; }

# Small JSON readers (python from the Hermes venv; no eval, labels passed as arguments).
workspace_id() {  # workspace_id LABEL < workspace list JSON
  python -c 'import json,sys
for w in json.load(sys.stdin)["result"]["workspaces"]:
    if w.get("label") == sys.argv[1]:
        print(w["workspace_id"]); break' "$1"
}
first_pane() {  # first_pane < pane list JSON
  python -c 'import json,sys
p = json.load(sys.stdin)["result"]["panes"]
print(p[0]["pane_id"] if p else "")'
}
root_pane() {  # root_pane < workspace create JSON
  python -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])'
}

for _ in $(seq 60); do
  herdr status 2>/dev/null | grep -q 'status: running' && break
  sleep 1
done

if herdr agent get "$AGENT" >/dev/null 2>&1; then
  log "agent $AGENT already running"
  exit 0
fi

# Reuse the (restored) workspace's first pane, or create the workspace.
ws="$(herdr workspace list | workspace_id "$LABEL")"
if [ -n "$ws" ]; then
  pane="$(herdr pane list --workspace "$ws" | first_pane)"
else
  pane="$(herdr workspace create --label "$LABEL" --cwd "$HERMES_WRITE_SAFE_ROOT" --no-focus | root_pane)"
fi
[ -n "$pane" ] || { log "no pane for workspace $LABEL"; exit 1; }

# herdr starts the canonical `hermes` executable in the pane and returns once it is detected and ready.
# Fixed launch command: never --yolo (dangerous commands must stop at Hermes's approval prompt); the one
# installed skill is preloaded read-only with --skills, so the skill-management toolset can stay disabled.
for attempt in 1 2 3; do
  if herdr agent start "$AGENT" --kind hermes --pane "$pane" --timeout 120000 -- --skills herdr-operator >/dev/null; then
    log "agent $AGENT started in pane $pane"
    exit 0
  fi
  log "agent start attempt $attempt failed; retrying"
  sleep 5
done
exit 1
