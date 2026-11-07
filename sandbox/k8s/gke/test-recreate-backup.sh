#!/usr/bin/env bash
# Offline test of deploy.sh's `recreate-sandbox` step: it must FAIL CLOSED (never delete the sandbox, which also
# deletes its workspace PVC) unless the backup of /sandbox/hermes is a readable archive containing
# hermes/config.yaml. Runs the real step with stub docker/kubectl/gcloud on PATH; touches no cluster.
#   sandbox/k8s/gke/test-recreate-backup.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/secrets" "$T/src/hermes"
echo 'model: {}' > "$T/src/hermes/config.yaml"; echo note > "$T/src/hermes/USER.md"
tar -C "$T/src" -czf "$T/good.tgz" hermes
tar -C "$T/src" -czf "$T/noconfig.tgz" hermes/USER.md

cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *" sandbox exec "*)   echo exec >> "$CALLS"
    case "$MODE" in
      exec-fails) exit 255 ;;
      empty)      exit 0 ;;
      corrupt)    printf 'not a tarball'; exit 0 ;;
      noconfig)   cat "$FIXTURES/noconfig.tgz"; exit 0 ;;
      changed)    cat "$FIXTURES/good.tgz"; exit 1 ;;   # GNU tar: "file changed as we read it"
      good)       cat "$FIXTURES/good.tgz"; exit 0 ;;
    esac ;;
  *" sandbox delete "*) echo delete >> "$CALLS"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *port-forward*) exec python3 -I -c 'import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("127.0.0.1",18080));s.listen();time.sleep(60)' ;;
  *"get secret"*) printf eA== ;;
  *"get pod"*) exit 1 ;;
esac
exit 0
STUB
printf '#!/bin/sh\necho test-project\n' > "$T/bin/gcloud"
chmod +x "$T/bin/"*

pass=0 fail=0
check() {  # mode, expected exit (0|1), expected delete (yes|no)
  : > "$T/calls"; rm -f "$T/secrets"/hermes-data-backup-*
  PATH="$T/bin:$PATH" MODE="$1" CALLS="$T/calls" FIXTURES="$T" GKE_SECRETS="$T/secrets" STEPS=recreate-sandbox \
    bash "$HERE/deploy.sh" >"$T/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || rc=1
  del=no; grep -q delete "$T/calls" && del=yes
  files=$(find "$T/secrets" -name 'hermes-data-backup-*.tgz' | wc -l)
  if [ "$rc" = "$2" ] && [ "$del" = "$3" ]; then pass=$((pass+1)); r=PASS; else fail=$((fail+1)); r=FAIL; fi
  printf '%-4s %-11s exit=%s delete=%s backups=%s  %s\n' "$r" "$1" "$rc" "$del" "$files" "$(grep -E 'backup (ok|failed)|nothing deleted' "$T/out" | head -1 | sed "s#$T#<tmp>#g")"
}
check exec-fails 1 no
check empty      1 no
check corrupt    1 no
check noconfig   1 no
check changed    0 yes
check good       0 yes
echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
