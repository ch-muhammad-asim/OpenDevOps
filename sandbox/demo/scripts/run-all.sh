#!/usr/bin/env bash
# Full dry run: reset -> verify 01..08 -> reset -> verify 01..08 -> health.
# The second round proves the demo is repeatable; any difference fails it.
#
#   sandbox/demo/scripts/run-all.sh [--with-llm]
#
# --with-llm also sends each DEMO-NN prompt through the Hermes API; those
# steps report SKIP while the model quota is exhausted. The full output is
# also written to a log file (path printed at the end).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

args=()
[ "$WITH_LLM" -eq 1 ] && args+=(--with-llm)
LOG="$(mktemp "${TMPDIR:-/tmp}/demo-run-all.XXXXXX.log")"
declare -A res cnt
steps=(reset verify-01 verify-02 verify-03 verify-04 verify-05 verify-06 verify-07 verify-08)

run_step() {  # round, step
  local round="$1" step="$2" out rc counts
  printf '\n######## round %s: %s ########\n' "$round" "$step" | tee -a "$LOG"
  out="$(bash "$DEMO_SCRIPTS/$step.sh" "${args[@]}" 2>&1)"; rc=$?
  printf '%s\n' "$out" | tee -a "$LOG"
  counts="$(printf '%s\n' "$out" | sed -n 's/^Result: \([0-9]*\) passed, \([0-9]*\) failed, \([0-9]*\) skipped$/\1\/\2\/\3/p' | tail -1)"
  if [ "$rc" -eq 0 ]; then res[$round,$step]=PASS; else res[$round,$step]=FAIL; fi
  cnt[$round,$step]="${counts:-?/?/?}"
}

start=$(date +%s)
# One shared real-model budget for the whole run (see LLM_BUDGET in lib.sh).
LLM_BUDGET_FILE="$(mktemp /tmp/demo-llm-budget.XXXXXX)"; export LLM_BUDGET_FILE
echo 0 > "$LLM_BUDGET_FILE"
trap 'rm -f "$LLM_BUDGET_FILE"' EXIT
sandbox_before="$(live_sandbox_id)"
for round in 1 2; do
  for step in "${steps[@]}"; do run_step "$round" "$step"; done
done
printf '\n######## final health ########\n' | tee -a "$LOG"
health_out="$(health_checks)"
printf '%s\n' "$health_out" | tee -a "$LOG"
sandbox_after="$(live_sandbox_id)"
if [ -n "$sandbox_before" ] && [ "$sandbox_before" = "$sandbox_after" ]; then
  health_out+=$'\n'"  PASS  live sandbox was not re-created or restarted during the demo"
else
  health_out+=$'\n'"  FAIL  live sandbox changed during the demo (before: ${sandbox_before:-none}, after: ${sandbox_after:-none})"
fi
printf '%s\n' "$health_out" | tail -1 | tee -a "$LOG"
case "$health_out" in *"  FAIL  "*) health=FAIL ;; *) health=PASS ;; esac

overall=0
[ "$health" = PASS ] || overall=1
rows=""
for step in "${steps[@]}"; do
  same=yes
  # With --with-llm the shared LLM_BUDGET makes prompt-path counts differ
  # between rounds by design, so compare only the PASS/FAIL result then.
  if [ "$WITH_LLM" -eq 1 ]; then
    [ "${res[1,$step]}" = "${res[2,$step]}" ] || same=NO
  else
    { [ "${res[1,$step]}" = "${res[2,$step]}" ] && [ "${cnt[1,$step]}" = "${cnt[2,$step]}" ]; } || same=NO
  fi
  { [ "${res[1,$step]}" = PASS ] && [ "${res[2,$step]}" = PASS ] && [ "$same" = yes ]; } || overall=1
  rows+="$(printf '%-10s  %-4s %-11s  %-4s %-11s  %s' "$step" "${res[1,$step]}" "${cnt[1,$step]}" "${res[2,$step]}" "${cnt[2,$step]}" "$same")"$'\n'
done
{
  printf '\n==================== SUMMARY ====================\n'
  printf '%-10s  %-16s  %-16s  %s\n' "step" "round 1 (p/f/s)" "round 2 (p/f/s)" "repeatable"
  printf '%s' "$rows"
  printf '%-10s  %s\n' "health" "$health"
  printf 'duration: %ss   llm prompts: %s   log: %s\n' "$(( $(date +%s) - start ))" \
    "$([ "$WITH_LLM" -eq 1 ] && echo on || echo off)" "$LOG"
  if [ "$overall" -eq 0 ]; then echo "OVERALL: PASS"; else echo "OVERALL: FAIL"; fi
} | tee -a "$LOG"
exit "$overall"
