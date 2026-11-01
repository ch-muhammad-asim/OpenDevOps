#!/usr/bin/env bash
# Keep the server's disk from filling up. Safe to run any time: it removes
# only things Docker or these scripts can recreate.
#
#   sandbox/scripts/housekeeping.sh                 # run once
#   sandbox/scripts/housekeeping.sh --install-cron  # also run daily at 04:17
#
# Removes: Docker build cache, dangling (untagged) images, demo/test logs in
# /tmp older than a day. Never touches tagged images, volumes or containers.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${HOUSEKEEPING_LOG:-$HOME/.local/state/hermes-housekeeping.log}"
WARN_FREE_MIB="${WARN_FREE_MIB:-4096}"

if [ "${1:-}" = "--install-cron" ]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  line="17 4 * * * $HERE/housekeeping.sh >> $LOG_FILE 2>&1"
  { crontab -l 2>/dev/null | grep -v -F "$HERE/housekeeping.sh"; echo "$line"; } | crontab -
  echo "Installed daily cron job: $line"
fi

# Keep our own log small.
if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -gt 1048576 ]; then
  tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

echo "== housekeeping $(date -u +%FT%TZ)"
echo "before: $(df -Pm / | awk 'NR == 2 {print $4 " MiB free (" $5 " used)"}')"
docker builder prune -af 2>/dev/null | tail -n 1
docker image prune -f 2>/dev/null | tail -n 1
find /tmp -maxdepth 1 \( -name 'demo-run-all.*.log' -o -name 'hermes-up*.log' -o -name 'hermes-down*.log' \) \
  -user "$(id -u)" -mtime +1 -delete 2>/dev/null
free_mib="$(df -Pm / | awk 'NR == 2 {print $4}')"
echo "after:  $free_mib MiB free"
if [ "$free_mib" -lt "$WARN_FREE_MIB" ]; then
  echo "WARNING: less than $WARN_FREE_MIB MiB free. Hermes shows its 'disk is filling up' banner at >= 85% used." >&2
  echo "         Check 'docker system df' and 'du -xsh ~/*'; consider growing the EBS volume." >&2
  exit 1
fi
