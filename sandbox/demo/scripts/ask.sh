#!/usr/bin/env bash
# Send one prompt to Hermes's OpenAI-compatible API and print the reply: the
# same agent, tools and model as the web chat. Each call is a new session.
#
#   sandbox/demo/scripts/ask.sh < prompt.txt        # safest: no shell quoting issues
#   sandbox/demo/scripts/ask.sh 'a simple prompt'
#
# Run it on the server. The API key is read from hermes.env and never printed
# or put on a command line. Commands Hermes flags as risky are cleared by its
# automatic approver or fail closed after 45 s (nobody can click Approve over
# the API); use the web chat or the CLI with --yolo to see the sandbox's answer.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,/^set -uo/p' "$0" | sed -n 's/^# \{0,1\}//p'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
if [ $# -eq 0 ] && [ -t 0 ]; then usage >&2; exit 2; fi
prompt="${1:-$(cat)}"
[ -n "$prompt" ] || { echo "usage: $0 'prompt'  (or the prompt on stdin)" >&2; exit 2; }
set --   # lib.sh parses "$@"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
[ -r "$HERMES_ENV_FILE" ] && [ -n "$(envval API_SERVER_KEY)" ] \
  || { echo "ask.sh: no API_SERVER_KEY in $HERMES_ENV_FILE (run this on the server)" >&2; exit 2; }
reply="$(llm_chat "$prompt")"; rc=$?
printf '%s\n' "$reply"
case "$reply" in "[no reply]"*) exit 1 ;; esac
exit "$rc"
