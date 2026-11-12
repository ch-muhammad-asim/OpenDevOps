#!/usr/bin/env bash
# Offline regression test for the two Grafana settings that made the Tempo UI look broken:
#   1. the Service Topology nodeGraph panel must not use layoutAlgorithm "force" (Grafana 13's
#      force layout never finishes: "Computing layout" forever, every node "hidden"), and the
#      generator must keep producing a rendering layout;
#   2. the Tempo datasource must not shift trace-search time ranges (a shift widens every search
#      beyond the range the user picked, so Explore Traces shows nothing for live services).
# Also checks that apps/loadgen is wired into both kustomize profiles, because an idle stack has
# no service-graph edges to draw. Needs Python 3 only; no cluster, no network.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH="$REPO/helm/grafana/dashboards"
GEN="$DASH/generate-tempo-mixin.py"
VALUES="$REPO/helm/grafana/values.yaml"
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }

# 1. Every generated dashboard: no nodeGraph panel on the "force" layout.
python3 - "$DASH" <<'PY' || fails=$((fails + 1))
import glob, json, os, sys
import yaml
bad = []
panels = 0
for path in sorted(glob.glob(os.path.join(sys.argv[1], "tempo-mixin-*.yaml"))):
    for key, body in (yaml.safe_load(open(path)) or {}).get("data", {}).items():
        dash = json.loads(body)

        def walk(node):
            global panels
            if isinstance(node, dict):
                if node.get("type") == "nodeGraph":
                    panels += 1
                    layout = (node.get("options") or {}).get("layoutAlgorithm")
                    if layout not in ("layered", "grid"):
                        bad.append(f"{os.path.basename(path)}: layoutAlgorithm={layout!r}")
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)

        walk(dash.get("panels", []))
if panels == 0:
    print("FAIL  no nodeGraph panel found in the generated dashboards")
    sys.exit(1)
if bad:
    print("FAIL  nodeGraph layout: " + "; ".join(bad))
    sys.exit(1)
print(f"PASS  {panels} nodeGraph panel(s) use a rendering layout")
PY

# 2. The generator must keep setting that layout (so a regeneration cannot reintroduce "force").
if grep -q 'layoutAlgorithm"] = "layered"' "$GEN"; then
  pass "generate-tempo-mixin.py sets layoutAlgorithm=layered"
else
  fail "generate-tempo-mixin.py no longer sets layoutAlgorithm=layered"
fi

# 3. Tempo datasource: no trace search time shift in any profile.
python3 - "$VALUES" <<'PY' || fails=$((fails + 1))
import sys
import yaml

found = []
bad = []


def walk(node):
    if isinstance(node, dict):
        if node.get("type") == "tempo" and isinstance(node.get("jsonData"), dict):
            trace_query = (node["jsonData"].get("traceQuery") or {})
            found.append(node.get("name") or node.get("uid"))
            if trace_query.get("timeShiftEnabled") is not False:
                bad.append(f"{node.get('name')}: timeShiftEnabled={trace_query.get('timeShiftEnabled')!r}")
            for key in ("spanStartTimeShift", "spanEndTimeShift"):
                if str(trace_query.get(key, "0s")).strip("0smh") != "":
                    bad.append(f"{node.get('name')}: {key}={trace_query.get(key)!r}")
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)


for doc in yaml.safe_load_all(open(sys.argv[1])):
    walk(doc)
if not found:
    print("FAIL  no Tempo datasource found in helm/grafana/values.yaml")
    sys.exit(1)
if bad:
    print("FAIL  trace search time shift still active: " + "; ".join(bad))
    sys.exit(1)
print(f"PASS  Tempo datasource {found} has no trace search time shift")
PY

# 4. Continuous demo traffic is part of both profiles, so the service graph stays populated.
for profile in apps apps/lab; do
  if grep -q 'loadgen/k8s' "$REPO/$profile/kustomization.yaml"; then
    pass "$profile includes the loadgen workload"
  else
    fail "$profile does not include loadgen/k8s"
  fi
done

echo
echo "failures: $fails"
exit "$((fails > 0))"
