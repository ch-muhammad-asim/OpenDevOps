#!/bin/sh
# Runs INSIDE herdr-hermes (piped in by e2e-test.sh test 12): prints whether herdr-operator carries Hermes's user skill
# lock (`hermes curator lock`, v0.23.0+). Prints no-lock-support on Hermes versions without the command.
hermes curator lock --help >/dev/null 2>&1 || { echo no-lock-support; exit 0; }
/opt/hermes/.venv/bin/python - <<'EOF'
import json
try:
    usage = json.load(open("/data/hermes/skills/.usage.json"))
except (OSError, ValueError):
    usage = {}
print("locked" if usage.get("herdr-operator", {}).get("locked") is True else "unlocked")
EOF
