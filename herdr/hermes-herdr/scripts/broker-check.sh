#!/usr/bin/env bash
# Runs INSIDE hermes-workbench as the worker uid (piped in by e2e-test.sh test 10): every forbidden herdr form must be
# refused by herdr-broker (exit 126, "denied"), an allowed call must work, and no real herdr binary may exist here.
KEY=(-i /var/lib/workbench/ctl_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes
     -o UserKnownHostsFile=/panekeys/broker_known_hosts -o StrictHostKeyChecking=yes -p 2222)
t() {  # t LABEL CMD...: print "LABEL => rc=N [denied]"
  local label="$1" out rc; shift
  out="$("$@" 2>&1 >/dev/null)"; rc=$?
  echo "${label} => rc=${rc}$(grep -q 'herdr-broker: denied' <<<"$out" && echo ' denied')"
}
t 'herdr server stop' herdr server stop
t 'herdr "agent" send-keys hermes enter' herdr "agent" send-keys hermes enter
t 'h=herdr; $h agent send-keys x enter' sh -c 'h=herdr; $h agent send-keys x enter'
t 'herdr pane close w1:p1' herdr pane close w1:p1
t 'herdr --machine x pane list' herdr --machine x pane list
t 'herdr pane split --env A=B' herdr pane split --env A=B
t 'herdr pane send-keys w1:p1 enter' herdr pane send-keys w1:p1 enter
t 'direct ssh, argv server stop' sh -c 'printf "server\0stop\0" | ssh "$@" herdr@172.31.252.21' _ "${KEY[@]}"
t 'direct ssh, command line' ssh "${KEY[@]}" herdr@172.31.252.21 herdr server stop </dev/null
herdr pane list >/dev/null 2>&1; echo "allowed herdr pane list => rc=$?"
n=0
while IFS= read -r f; do [[ "$(head -c 2 "$f")" == '#!' ]] || n=$((n + 1)); done < <(find / -xdev -name herdr -type f 2>/dev/null)
echo "real herdr binaries: ${n}; client script-only=$(head -c 2 /usr/local/bin/herdr)"
