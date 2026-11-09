#!/usr/bin/env bash
# Run a real inference request against every currently advertised free bridge model.
# Usage: hermes/model-smoke.sh [model-id ...]  (no arguments: the complete live catalogue)
# Runs sequentially to respect free-provider quotas. No credentials or reply text are printed.
set -euo pipefail
kubectl -n hermes exec -i deploy/hermes-gateway -c gateway -- python3 - "$@" <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

base = "http://opencode-bridge.hermes:18282/v1"
headers = {"Authorization": "Bearer " + os.environ["HERMES_MODEL_API_KEY"],
           "Content-Type": "application/json"}

def request(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, headers=headers)
    return json.load(urllib.request.urlopen(req, timeout=660))

available = {m["id"] for m in request("/models")["data"]}
models = sys.argv[1:] or sorted(available)
if not models or set(models) - available:
    raise SystemExit("No models available, or requested model is absent from the free catalogue")
failures = 0
for model in models:
    start = time.monotonic()
    result = {"model": model}
    try:
        reply = request("/chat/completions", {"model": model, "messages": [
            {"role": "user", "content": "Reply with exactly MODEL-SMOKE-OK. Do not use tools."}]})
        text = reply["choices"][0]["message"].get("content") or ""
        result["passed"] = "MODEL-SMOKE-OK" in text and "<|" not in text
        if not result["passed"]:
            result["error"] = "Missing expected marker or malformed model output"
    except urllib.error.HTTPError as exc:
        result.update(passed=False, error="HTTP " + str(exc.code))
    except Exception as exc:
        result.update(passed=False, error=type(exc).__name__)
    result["seconds"] = round(time.monotonic() - start, 1)
    failures += not result["passed"]
    print(json.dumps(result), flush=True)
print(json.dumps({"tested": len(models), "passed": len(models) - failures, "failed": failures}), flush=True)
sys.exit(bool(failures))
PY
