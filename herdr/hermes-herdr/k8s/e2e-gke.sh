#!/usr/bin/env bash
# Run the POC's own end-to-end suite (scripts/e2e-test.sh, unchanged) against the GKE deployment:
#   herdr/hermes-herdr/k8s/e2e-gke.sh            # evidence: ./hermes-herdr-e2e-gke.log
# The `docker` shim in k8s/bin maps the suite's docker exec/logs/restart/inspect/port/ps to kubectl.
#   EGRESS_WB_EXPECT=blocked  the NetworkPolicy drops the workbench's packets before tinyproxy (no 403 to read)
#   HOST_HERDR_CHECK=0        the machine running the tests may run its own herdr; nothing of the POC runs there
#   EXISTING_*                the existing hermes-gke stack must stay up (its /login and its workloads)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$HERE/bin:$PATH"
export EGRESS_WB_EXPECT="${EGRESS_WB_EXPECT:-blocked}" HOST_HERDR_CHECK="${HOST_HERDR_CHECK:-0}"
export EXISTING_URL="${EXISTING_URL:-https://hermes-gke.saqlainmushtaq.com/login}"
export EXISTING_CMD="${EXISTING_CMD:-kubectl get pods -A --field-selector=status.phase=Running --no-headers | grep -c -E '^(openshell|hermes-edge|traefik) '}"
export EVIDENCE="${EVIDENCE:-./hermes-herdr-e2e-gke.log}"
# herdr reports Hermes idle a moment before its TUI accepts input; wait for interactive_ready, then let it settle.
for _ in $(seq 120); do
  "$HERE/../scripts/hh" agent get "${HERMES_AGENT_NAME:-hermes}" 2>/dev/null \
    | python3 -c 'import json,sys; a=json.load(sys.stdin)["result"]["agent"]; sys.exit(0 if a["agent_status"] == "idle" and a.get("interactive_ready") else 1)' \
    2>/dev/null && break
  sleep 2
done
sleep 10
exec "$HERE/../scripts/e2e-test.sh" "$@"
