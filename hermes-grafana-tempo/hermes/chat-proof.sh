#!/usr/bin/env bash
# Chat proof: ask Hermes the two demo prompts through its API server and save the answers.
#   1. "List all the skills you have."                      -> must name grafana-tempo-observability
#   2. "Diagnose the platform and suggest issues. ..."      -> must name planted issues and Grafana links
# Usage: hermes/chat-proof.sh [output-dir]        (default: ./chat-proof-<UTC timestamp>)
# Makes exactly 2 chat requests, one after the other (free tiers rate-limit). Run it when the provider's free
# limit has reset. The API key is read from the Secret into a curl config file, never printed or put on argv.
# Exit code = number of prompts whose answer did not contain the expected content.
set -uo pipefail
out="${1:-chat-proof-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out"
tmp="$(mktemp -d)"; trap 'kill "$(cat "$tmp/pf" 2>/dev/null)" 2>/dev/null; rm -rf "$tmp"' EXIT; umask 077

pod="$(kubectl -n hermes get pod -l app.kubernetes.io/name=hermes-gateway --field-selector=status.phase=Running \
       --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
[[ -n "$pod" ]] || { echo "no running hermes-gateway pod" >&2; exit 2; }
port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
kubectl -n hermes port-forward "pod/$pod" "$port:8642" >/dev/null 2>&1 & echo $! >"$tmp/pf"
for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$port/health" && break; sleep 1; done
printf 'header = "Authorization: Bearer %s"\n' \
  "$(kubectl -n hermes get secret hermes-api-server -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d)" >"$tmp/api"
model="$(kubectl -n hermes get secret hermes-model-key -o jsonpath='{.data.HERMES_MODEL}' 2>/dev/null | base64 -d)"

PROMPTS=(
  "List all the skills you have."
  "Diagnose the platform and suggest issues. For each issue give the evidence, the probable root cause, the file to look at, a suggested fix and the Grafana link."
)
# Expected content (Python regex): the skill name; at least 3 planted-issue markers and a Grafana link.
EXPECT=(
  'grafana-tempo-observability'
  '(?s)(?=.*https://grafana-tempo\.saqlainmushtaq\.com/)(?:.*?(KeyError|N\+1|timeout|CPU|memory leak|TypeError|fan-out|supplier)){3}'
)

fails=0
{ echo "# Hermes chat proof, $(date -u +%FT%TZ)"; echo "model: ${model:-unknown} (Secret hermes-model-key)"; } >"$out/summary.txt"
for i in "${!PROMPTS[@]}"; do
  n=$((i + 1)); t0=$(date +%s)
  Q="${PROMPTS[$i]}" python3 -I -c 'import json, os; print(json.dumps({"model": "hermes-agent", "messages": [{"role": "user", "content": os.environ["Q"]}]}))' >"$tmp/body"
  curl -s -K "$tmp/api" -H 'Content-Type: application/json' --max-time 900 --data-binary "@$tmp/body" \
    "http://127.0.0.1:$port/v1/chat/completions" >"$tmp/resp" || true
  python3 -I -c 'import json, sys
try:
    d = json.load(open(sys.argv[1])); sys.stdout.write(d["choices"][0]["message"]["content"] or "")
except Exception as e:
    sys.stdout.write("ERROR: no reply (%s)" % e)' "$tmp/resp" >"$out/answer-$n.md"
  secs=$(( $(date +%s) - t0 ))
  if python3 -I -c 'import re, sys; sys.exit(0 if re.search(sys.argv[1], open(sys.argv[2]).read(), re.I) else 1)' "${EXPECT[$i]}" "$out/answer-$n.md"; then
    verdict=PASS
  else
    verdict=FAIL; fails=$((fails + 1))
  fi
  echo "$verdict  prompt $n (${secs}s): ${PROMPTS[$i]}  -> $out/answer-$n.md" | tee -a "$out/summary.txt"
done

if [[ "$fails" -gt 0 ]] && kubectl -n hermes logs deploy/opencode-bridge -c bridge --since=30m 2>/dev/null | grep -q 'Free usage limit'; then
  echo "note: the OpenCode bridge reported 'Free usage limit reached': retry when the free limit resets" | tee -a "$out/summary.txt"
fi
echo "failures: $fails" | tee -a "$out/summary.txt"
exit "$fails"
