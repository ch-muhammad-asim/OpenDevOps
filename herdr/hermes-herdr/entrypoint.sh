#!/bin/sh
# herdr-hermes entrypoint: check the model key file, install Hermes's profile config, refuse to start
# unless the managed guardrails are in force (fail closed), pin herdr's detection rules, create the ssh key for the
# workbench, open the Hermes pane in the background, then run the herdr server as the main process (its sockets
# stay inside this container, mode 600).
set -eu
die() { echo "[herdr-hermes] FATAL: $*" >&2; exit 1; }

# Model key: a read-only file mount, loaded only by the Hermes process tree (/opt/hermes-herdr/bin/hermes). Refuse to
# start without it rather than run a Hermes that can't reach its model; it must never come in through the environment.
[ -r /run/secrets/nvidia_api_key ] && [ -s /run/secrets/nvidia_api_key ] || die "model key file /run/secrets/nvidia_api_key missing or unreadable"
[ -z "${NVIDIA_API_KEY:-}" ] || die "NVIDIA_API_KEY must not be set in the container environment (use the key file mount)"

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
      and t.get("backend") == "ssh" and t.get("ssh_host") == "hermes-workbench" and t.get("env_passthrough") == []
      and c.get("display", {}).get("show_reasoning") is False)
sys.exit(0 if ok else 1)
EOF
set +e; hermes approvals test --env-type ssh -- sudo ls >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 3 ] || die "approvals.deny is not enforced (hermes approvals test -- sudo ls exited $rc, expected 3)"

# Lock the one skill (Hermes v0.23.0+ `hermes curator lock`): skill_manage, write_file, patch and terminal refuse to
# change it, even under --yolo. Its files are also root-owned on the read-only rootfs. Re-applied on every start
# because the skills dir (which holds the lock record) is cleaned above. Fail closed: no lock, no start.
hermes curator lock --help >/dev/null 2>&1 || die "hermes curator lock unsupported (needs Hermes v0.23.0+); refusing to start"
hermes curator lock herdr-operator >/dev/null 2>&1 || die "could not lock skill herdr-operator; refusing to start"

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
