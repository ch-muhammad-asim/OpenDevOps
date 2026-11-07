#!/usr/bin/env bash
# Switch the VM's Hermes sandbox between the plain image and the herdr image (sandbox/k8s/gke/herdr/), keeping
# hermes-data. Run on the server from the repository checkout.
#
#   sandbox/scripts/herdr-roll.sh build      # build hermes-openshell:v0.23.0-herdr0.9.5 only (sandbox untouched)
#   sandbox/scripts/herdr-roll.sh backup     # private, timestamped tar of the hermes-data volume (fails closed)
#   sandbox/scripts/herdr-roll.sh roll       # backup, then re-create the sandbox from the herdr image
#   sandbox/scripts/herdr-roll.sh rollback   # backup, then re-create the sandbox from the plain image
#   sandbox/scripts/herdr-roll.sh lock       # (re-)apply the curator lock on herdr-operator in the running sandbox
#
# hermes-data is a Docker volume, so deleting the sandbox keeps chats, settings and memory; the backup is the safety
# net. Never restarts Docker or the OpenShell gateway.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSHELL="${OPENSHELL:-openshell}"
SANDBOX_NAME="${SANDBOX_NAME:-hermes}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-hermes-openshell:v0.23.0}"
HERDR_IMAGE="${HERDR_IMAGE:-${SANDBOX_IMAGE}-herdr0.9.5}"
DATA_VOLUME="${DATA_VOLUME:-hermes-data}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/hermes-backups}"
MIN_FREE_KB="${MIN_FREE_KB:-3145728}"   # 3 GB free on / before and after a build
PUBLIC_URL="${PUBLIC_URL:-}"            # optional, e.g. https://hermes.example.com/ : checked after a roll

log() { printf '\n==> %s\n' "$*"; }
free_kb() { df -Pk / | awk 'NR==2{print $4}'; }
need_disk() {
  local f; f="$(free_kb)"
  [ "$f" -ge "$MIN_FREE_KB" ] || { echo "only $((f / 1024)) MB free on /, need $((MIN_FREE_KB / 1024)) MB; stopping" >&2; exit 1; }
  echo "disk: $((f / 1024)) MB free on /"
}

build() {
  docker image inspect "$SANDBOX_IMAGE" >/dev/null || { echo "base image $SANDBOX_IMAGE missing (run up.sh first)" >&2; exit 1; }
  [ -f "$HERE/../herdr/hermes-herdr/work/herdr-broker" ] || { echo "missing herdr/hermes-herdr/work/herdr-broker" >&2; exit 1; }
  need_disk
  log "Building $HERDR_IMAGE from $SANDBOX_IMAGE"
  docker build -q -f "$HERE/k8s/gke/herdr/Dockerfile" --build-arg "BASE_IMAGE=$SANDBOX_IMAGE" -t "$HERDR_IMAGE" "$HERE/.."
  docker builder prune -af >/dev/null 2>&1 || true   # drop the build cache right away
  docker image inspect "$HERDR_IMAGE" --format 'built {{.Id}} {{.Size}} bytes'
  need_disk
}

backup() {   # prints the backup path on stdout; exits 1 before anything is deleted on failure
  local f rc=0 n
  docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1 || { echo "backup failed: no volume $DATA_VOLUME; nothing changed" >&2; exit 1; }
  mkdir -p "$BACKUP_DIR" && chmod 0700 "$BACKUP_DIR"
  f="$BACKUP_DIR/hermes-data-backup-$(date -u +%Y%m%dT%H%M%SZ).tgz"
  # Read-only mount, no network; Hermes keeps running, so tar exit 1 ("file changed as we read it") is accepted.
  ( umask 077
    docker run --rm --network none --user 0:0 --entrypoint tar -v "$DATA_VOLUME:/sandbox/hermes:ro" "$SANDBOX_IMAGE" \
      -C /sandbox --warning=no-file-changed --exclude='*.sock' -czf - hermes > "$f.tmp" ) || rc=$?
  if [ "$rc" -gt 1 ]; then echo "backup failed: tar exited $rc; nothing changed" >&2; rm -f "$f.tmp"; exit 1; fi
  n="$(tar -tzf "$f.tmp" 2>/dev/null | grep -c '^hermes/' || true)"
  if [ "${n:-0}" -lt 1 ] || ! tar -tzf "$f.tmp" hermes/config.yaml >/dev/null 2>&1; then
    echo "backup failed: archive empty, unreadable or without hermes/config.yaml; nothing changed" >&2; rm -f "$f.tmp"; exit 1
  fi
  mv "$f.tmp" "$f"
  echo "backup ok: $f ($n entries, $(du -h "$f" | cut -f1))" >&2
  printf '%s\n' "$f"
}

# openshell sandbox exec starts with HOME=/sandbox and no HERMES_HOME: point Hermes at its real profile.
hx() { "$OPENSHELL" sandbox exec -n "$SANDBOX_NAME" --no-tty -- env HOME=/sandbox/hermes HERMES_HOME=/sandbox/hermes "$@"; }

lock() {   # user lock on the one skill (Hermes v0.23.0+): the agent cannot change it; kept on hermes-data. Re-runnable.
  for _ in $(seq 1 24); do hx hermes curator lock herdr-operator >/dev/null 2>&1 && break; sleep 5; done
  hx python3 -I -c 'import json,sys; sys.exit(0 if json.load(open("/sandbox/hermes/skills/.usage.json")).get("herdr-operator", {}).get("locked") is True else 1)' \
    || { echo "skill herdr-operator is NOT locked; run: $0 lock (or $0 rollback)" >&2; exit 1; }
  echo "skill herdr-operator locked"
}

recreate() {   # $1 = HERDR value for up.sh (1 = herdr image, 0 = plain image)
  local img; [ "$1" = 1 ] && img="$HERDR_IMAGE" || img="$SANDBOX_IMAGE"
  docker image inspect "$img" >/dev/null || { echo "image $img missing (run: $0 build)" >&2; exit 1; }
  need_disk
  local b; b="$(backup)" || exit 1
  [ -s "$b" ] || { echo "no backup file; nothing changed" >&2; exit 1; }
  log "Deleting sandbox $SANDBOX_NAME (volume $DATA_VOLUME is kept)"
  "$OPENSHELL" sandbox delete "$SANDBOX_NAME" || true
  for _ in $(seq 1 60); do "$OPENSHELL" sandbox get "$SANDBOX_NAME" >/dev/null 2>&1 || break; sleep 2; done
  log "Re-creating sandbox from $img"
  HERDR="$1" SANDBOX_IMAGE="$SANDBOX_IMAGE" HERDR_IMAGE="$HERDR_IMAGE" "$HERE/scripts/up.sh"
  for _ in $(seq 1 60); do "$OPENSHELL" sandbox get "$SANDBOX_NAME" 2>/dev/null | grep -q Ready && break; sleep 5; done
  "$HERE/scripts/forwards.sh"
  [ "$1" = 1 ] && lock
  for _ in $(seq 1 36); do curl -fsS -o /dev/null http://127.0.0.1:9119/ && break; sleep 5; done
  curl -sS -o /dev/null -w 'dashboard 127.0.0.1:9119 -> %{http_code}\n' http://127.0.0.1:9119/
  if [ -n "$PUBLIC_URL" ]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' "$PUBLIC_URL" || true)"
    if [ "$code" != 200 ]; then   # the tunnel container only: never the gateway or Docker
      log "Public URL returned $code; restarting hermes-tunnel"
      docker compose -f "$HERE/tunnel/docker-compose.yml" restart
      sleep 10; code="$(curl -sS -o /dev/null -w '%{http_code}' "$PUBLIC_URL" || true)"
    fi
    echo "public $PUBLIC_URL -> $code"
  fi
  echo "rollback data: $b"
}

case "${1:-}" in
  build) build ;;
  backup) backup >/dev/null ;;
  roll) recreate 1 ;;
  rollback) recreate 0 ;;
  lock) lock ;;
  *) sed -n '5,9p' "$0" >&2; exit 2 ;;
esac
