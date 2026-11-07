#!/bin/sh
# hermes-workbench entrypoint: persistent host key, the key for herdr-broker, then sshd in the foreground (PID 1:
# if it dies the container exits and Docker restarts it).
set -eu
umask 077
[ -f /var/lib/workbench/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /var/lib/workbench/ssh_host_ed25519_key
[ -f /var/lib/workbench/ctl_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C hermes-workbench-ctl -f /var/lib/workbench/ctl_ed25519

# Publish this sshd's host key so its clients pin it (StrictHostKeyChecking, no trust-on-first-use).
printf '[172.31.252.20]:2222 %s\n' "$(cut -d' ' -f1,2 /var/lib/workbench/ssh_host_ed25519_key.pub)" >/ctlkeys/workbench_known_hosts.tmp
mv /ctlkeys/workbench_known_hosts.tmp /ctlkeys/workbench_known_hosts

# hermes-herdr-work accepts this key only for herdr-broker (ForceCommand there); `restrict` turns off the rest.
umask 022
printf 'restrict %s\n' "$(cat /var/lib/workbench/ctl_ed25519.pub)" >/ctlkeys/authorized_keys.tmp
mv /ctlkeys/authorized_keys.tmp /ctlkeys/authorized_keys

# Logins: Hermes's terminal backend (key from herdr-hermes, /keys) and the work panes (key from hermes-herdr-work,
# /panekeys). sshd reads both files on every login, so nothing has to wait for them here.
exec /usr/sbin/sshd -D -e -f /etc/workbench/sshd_config
