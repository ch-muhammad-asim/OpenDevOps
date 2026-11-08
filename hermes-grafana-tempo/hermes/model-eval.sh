#!/usr/bin/env bash
# Compare Workers AI models for Hermes on 5 prompts that force tool calls plus a follow-up answer
# (skills list, skill view, diagnose, PromQL, TraceQL). For each model: store it with deploy.sh, restart the
# pod, ask the 5 prompts one by one through the gateway's API server (kubectl port-forward), and score:
#   clean    no leaked chat-template tokens (<|...|>), no degenerate repetition, non-empty
#   correct  the answer contains the expected real data (skill name, script name, issue names, value, trace ID)
# Usage: CLOUDFLARE_AI_CREDS_FILE=<file> hermes/model-eval.sh @cf/qwen/qwen3.8-27b @cf/meta/llama-4-scout-17b-16e-instruct ...
# Model calls run sequentially (rate limits). The last model listed stays deployed: list the winner last.
set -uo pipefail
cd "$(dirname "$0")"
[[ -n "${CLOUDFLARE_AI_CREDS_FILE:-}" && $# -ge 1 ]] || { echo "usage: CLOUDFLARE_AI_CREDS_FILE=<file> $0 <model>..." >&2; exit 2; }
tmp="$(mktemp -d)"; trap 'kill "$(cat "$tmp/pf" 2>/dev/null)" 2>/dev/null; rm -rf "$tmp"' EXIT; umask 077

PROMPTS=(
  "List all the skills you have."
  "Open (view) your grafana-tempo-observability skill and tell me which script it uses and two of its commands."
  "Diagnose the platform and suggest issues. List the top 5 with evidence."
  "Using your observability skill, query Prometheus for max(hermes_gateway_up) and tell me the value."
  "Using your observability skill, run the TraceQL search { resource.service.name = \"python-inventory\" && status = error } over the last 60 minutes and give me one trace ID."
)
# Expected evidence per prompt (Python regex, case-insensitive)
EXPECT=(
  "grafana-tempo-observability"
  "obs\\.py"
  "(KeyError|timeout|N\\+1|CPU|memory leak).*(KeyError|timeout|N\\+1|CPU|memory leak)"
  "(=|is|:)\\s*\\**\\s*1\\b"
  "\\b[0-9a-f]{32}\\b"
)

ask() {  # $1 question -> reply text on stdout
  Q="$1" python3 -I -c 'import json, os; print(json.dumps({"model": "hermes-agent", "messages": [{"role": "user", "content": os.environ["Q"]}]}))' >"$tmp/body"
  curl -s -K "$tmp/api" -H 'Content-Type: application/json' --max-time 360 --data-binary "@$tmp/body" \
    "http://127.0.0.1:$port/v1/chat/completions" \
    | python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin); print(d["choices"][0]["message"]["content"] or "")
except Exception as e:
    print("ERROR no reply:", e)'
}

score() {  # $1 expected regex, reply on stdin -> "clean correct"
  python3 -I -c 'import re, sys
t = sys.stdin.read(); exp = sys.argv[1]
words = re.findall(r"[A-Za-z]+", t)
rep = any(len(set(words[i:i + 6])) == 1 for i in range(max(0, len(words) - 5)))
uniq = len(set(words)) / max(1, len(words))
clean = bool(t.strip()) and "<|" not in t and not rep and not (len(words) > 60 and uniq < 0.2) and not t.startswith("ERROR")
correct = bool(re.search(exp, t, re.I | re.S))
print(("clean" if clean else "DIRTY"), ("correct" if correct else "WRONG"))' "$1"
}

echo "| Model | P1 skills list | P2 skill view | P3 diagnose | P4 PromQL | P5 TraceQL | clean+correct |"
echo "|---|---|---|---|---|---|---|"
for model in "$@"; do
  HERMES_MODEL="$model" ./deploy.sh >/dev/null 2>&1 || { echo "| $model | deploy failed |"; continue; }
  kubectl -n hermes rollout restart deploy/hermes-gateway >/dev/null
  kubectl -n hermes rollout status deploy/hermes-gateway --timeout=300s >/dev/null
  sleep 15
  pod="$(kubectl -n hermes get pod -l app.kubernetes.io/name=hermes-gateway --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')"
  port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  kubectl -n hermes port-forward "pod/$pod" "$port:8642" >/dev/null 2>&1 & echo $! >"$tmp/pf"
  for _ in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$port/health" && break; sleep 1; done
  printf 'header = "Authorization: Bearer %s"\n' "$(kubectl -n hermes get secret hermes-api-server -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d)" >"$tmp/api"
  row="| \`$model\` |"; ok=0
  for i in "${!PROMPTS[@]}"; do
    t0=$(date +%s)
    reply="$(ask "${PROMPTS[$i]}")"
    s="$(score "${EXPECT[$i]}" <<<"$reply")"
    printf '%s\n' "$reply" >"${EVAL_OUT:-$tmp}/$(echo "$model" | tr '/@' '__')-p$((i + 1)).txt" 2>/dev/null || true
    [[ "$s" == "clean correct" ]] && ok=$((ok + 1))
    row="$row $s ($(( $(date +%s) - t0 ))s) |"
  done
  echo "$row $ok/5 |"
  kill "$(cat "$tmp/pf")" 2>/dev/null
done
