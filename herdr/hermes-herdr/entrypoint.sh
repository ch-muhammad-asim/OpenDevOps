#!/bin/sh
# herdr-hermes entrypoint: move the model key out of the environment, install Hermes's profile config, refuse to start
# unless the managed guardrails are in force (fail closed), pin herdr's detection rules, create the ssh key for the
# workbench, open the Hermes pane in the background, then run the herdr server as the main process (its sockets
# stay inside this container, mode 600).
set -eu
die() { echo "[herdr-hermes] FATAL: $*" >&2; exit 1; }

# Model key: from the env file into a 0600 file on the tmpfs; the herdr server, the up-script and the pane shells
# start without it. Only the Hermes process tree loads it (/opt/hermes-herdr/bin/hermes).
umask 077
mkdir -p /tmp/.hermes-herdr
[ -n "${NVIDIA_API_KEY:-}" ] && printf '%s' "$NVIDIA_API_KEY" >/tmp/.hermes-herdr/model.key
unset NVIDIA_API_KEY
umask 022

mkdir -p "$HOME/.config/herdr/agent-detection" "$HOME/.ssh" "$HERMES_HOME/ssh" "$HERMES_HOME/skills"
chmod 0700 "$HOME" "$HERMES_HOME" "$HOME/.ssh" "$HERMES_HOME/ssh"
# Replace the profile config from the image on every start, so its mirrored guardrails never drift from the
# managed copy (/etc/hermes/config.yaml, root-owned). Edit config.yaml in the repo, not on the volume.
# The NVIDIA key is never written here: Hermes reads it from the environment via key_env.
cp /opt/hermes-herdr/config.yaml "$HERMES_HOME/config.yaml"
# No bundled skills (HERMES_BUNDLED_SKILLS is empty); remove any seeded by an earlier start. The one skill lives
# read-only in /opt/hermes-herdr/skills.
find "$HERMES_HOME/skills" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

# Fail closed: Hermes ignores a managed file it can't parse (with only a log warning). Refuse to run unless the
# managed scope parses and pins the key guardrails, and Hermes's own matcher denies a known-forbidden command.
/opt/hermes/.venv/bin/python - <<'EOF' || die "managed config /etc/hermes/config.yaml missing, invalid or incomplete"
import sys
from hermes_cli.managed_scope import load_managed_config
c = load_managed_config()
a, t = c.get("approvals", {}), c.get("terminal", {})
ok = (a.get("mode") == "manual" and "*sudo *" in (a.get("deny") or []) and "*herdr server stop*" in (a.get("deny") or [])
      and t.get("backend") == "ssh" and t.get("ssh_host") == "172.31.252.20" and t.get("env_passthrough") == [])
sys.exit(0 if ok else 1)
EOF
set +e; hermes approvals test --env-type ssh -- sudo ls >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 3 ] || die "approvals.deny is not enforced (hermes approvals test -- sudo ls exited $rc, expected 3)"

# Always re-pin the detection override from the image.
cp /opt/hermes-herdr/herdr-agent-detection/hermes.toml "$HOME/.config/herdr/agent-detection/hermes.toml"

# Pin the workbench's host key (published by hermes-workbench) instead of trusting it on first use; rewritten on
# every start so a re-keyed workbench never leaves a stale entry, and a different key is always refused.
for _ in $(seq 60); do [ -s /workbench-pub/workbench_known_hosts ] && break; sleep 1; done
[ -s /workbench-pub/workbench_known_hosts ] || die "workbench host key not published (/workbench-pub/workbench_known_hosts)"
cp /workbench-pub/workbench_known_hosts "$HOME/.ssh/known_hosts"
chmod 0644 "$HOME/.ssh/known_hosts"

# Key for Hermes's ssh terminal backend. Only the public key leaves this container (shared keys volume, read-only
# in the workbench); `restrict` turns off forwarding, agent, X11 and PTY for this key.
[ -f "$HERMES_HOME/ssh/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C hermes-herdr -f "$HERMES_HOME/ssh/id_ed25519"
printf 'restrict %s\n' "$(cat "$HERMES_HOME/ssh/id_ed25519.pub")" >/keys/authorized_keys.tmp
chmod 0644 /keys/authorized_keys.tmp
mv /keys/authorized_keys.tmp /keys/authorized_keys

hermes-herdr-up &
exec herdr server
