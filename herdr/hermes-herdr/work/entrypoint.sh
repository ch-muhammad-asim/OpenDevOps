#!/bin/sh
# hermes-herdr-work entrypoint: keys, a supervised work herdr server (panes are SSH shells into the workbench), then
# the broker sshd in the foreground.
set -eu
umask 077
mkdir -p /data/home /data/ssh /data/hostkey
[ -f /data/hostkey/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /data/hostkey/ssh_host_ed25519_key
[ -f /data/ssh/pane_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C hermes-herdr-pane -f /data/ssh/pane_ed25519

# The workbench accepts the pane key for PTY shells only (shared volume, read-only in the workbench).
umask 022
printf 'restrict,pty %s\n' "$(cat /data/ssh/pane_ed25519.pub)" >/panekeys/authorized_keys.tmp
mv /panekeys/authorized_keys.tmp /panekeys/authorized_keys
# Publish the broker's host key so the workbench client pins it.
printf '[hermes-herdr-work]:2222 %s\n' "$(cut -d' ' -f1,2 /data/hostkey/ssh_host_ed25519_key.pub)" >/panekeys/broker_known_hosts.tmp
mv /panekeys/broker_known_hosts.tmp /panekeys/broker_known_hosts

# Supervised: if the herdr server ever exits, it is started again (state is restored from /data/home).
(
  while :; do
    SHELL=/usr/local/bin/workbench-shell herdr server >/dev/null 2>&1 || true
    sleep 2
  done
) &
# One workspace ("work", first pane in /work/workspace) so `herdr pane split` has a pane to split. Restored
# from state after a restart; created only if missing.
(
  for _ in $(seq 60); do herdr status 2>/dev/null | grep -q 'status: running' && break; sleep 1; done
  herdr workspace list 2>/dev/null | python3 -c 'import json,sys
sys.exit(0 if any(w.get("label") == "work" for w in json.load(sys.stdin)["result"]["workspaces"]) else 1)' \
    || herdr workspace create --label work --cwd /work/workspace --no-focus >/dev/null 2>&1 || true
) &
exec /usr/sbin/sshd -D -e -f /etc/herdr-work/sshd_config
