# shellcheck shell=bash
# Secret-redaction tests 16-19 for the herdr + Hermes POC. Not run on its own: e2e-test.sh sources it after test 15,
# before the summary, and it uses that script's helpers and variables (vm, vmin, hh, ask, screen, wfile, ev, result,
# A, B, W, HERE, AGENT). Fake values only, made from $RANDOM per run; output and evidence hold counts and yes/no only.
# Tests 17/18 never put the fake in the prompt: the harness writes it into a workbench fixture file and Hermes `cat`s it,
# so the value first appears in tool output (what the redactor must mask). The prompt names only the file.
# shellcheck disable=SC2154  # A, B, W, HERE, AGENT, DENIED come from e2e-test.sh

fakebody() { local s=""; while ((${#s} < 30)); do s+="$(printf '%04x' "$RANDOM")"; done; printf '%s' "${s:0:30}"; }
rcount() { grep -c -F -- "$1" 2>/dev/null; }   # stdin: text; prints the number of lines holding $1, nothing else
logcount() {  # logcount FAKE: lines holding FAKE in the files under /data/hermes/logs; prints a number, or "error"
  # when find, a file read or grep fails (no pipe: grep reads each file itself; its exit 1 = no match, >1 = error)
  local o
  o="$(vm "docker exec ${A} find /data/hermes/logs -type f -exec sh -c 'f=\$1; shift; grep -c -h -F -- \"\$f\" \"\$@\"; [ \$? -le 1 ]' sh $1 {} + && echo LOGS_OK" 2>/dev/null)"
  if [[ "$(tail -n 1 <<<"$o")" != LOGS_OK ]] || sed '$d' <<<"$o" | grep -q -v -x -E '[0-9]+'; then echo error; return; fi
  sed '$d' <<<"$o" | awk '{ s += $1 } END { print s + 0 }'
}
statecount() { vmin "docker exec -i ${A} /opt/hermes/.venv/bin/python - $1" "${HERE}/state-count.py" 2>&1; }
num() { sed -n "s/.*\b$1=\([0-9]*\).*/\1/p" <<<"$2"; }   # num KEY "k=v k=v": the value of KEY (empty if absent)
# hscreen N: the Hermes pane's last N lines; fails (returns 1, prints nothing) when the reader exits non-zero or
# prints nothing, so a partial read followed by an error is an evidence error, never a clean count.
hscreen() { local out rc; out="$(screen "$1")"; rc=$?; [[ "$rc" == 0 && -n "$out" ]] || return 1; printf '%s\n' "$out"; }

# 16. Offline, no model: Hermes's own redactor (agent.redact.redact_sensitive_text, unforced so it follows
#     security.redact_secrets) masks fake sk-test-, nvapi-, ghp_, password= and Bearer values; the effective
#     config (managed overlay included) has security.redact_secrets true.
r16="$(vmin "docker exec -i ${A} /opt/hermes/.venv/bin/python -" "${HERE}/redact-check.py" 2>&1)"
printf '%s\n' "$r16" | ev "16 redaction offline (Hermes redact_sensitive_text on fake values)"
if [[ "$r16" == *"masked 5/5"* && "$r16" == *"security.redact_secrets=True"* ]]; then
  result PASS "16 redactor masks fake sk-/nvapi-/ghp_/password/Bearer" "5/5 masked; security.redact_secrets=True"
else result FAIL "16 redactor masks fake sk-/nvapi-/ghp_/password/Bearer" "$(grep -E '^masked|redact_secrets' <<<"$r16" | tr '\n' ' ')"; fi

isnum() { [[ "$1" =~ ^[0-9]+$ ]]; }
mkmark() { printf 'MARK_%05d%05d' "$RANDOM" "$RANDOM"; }   # run-unique, NOT secret: may be printed and stored
writefix() {  # writefix FILE MARKER FAKE: write "MARKER TEST_API_KEY=FAKE" into the workbench fixture; prints ok|fail
  local c; c="$(vm "docker exec ${B} sh -c 'echo $2 TEST_API_KEY=$3 > /work/workspace/$1 && grep -c -x -F -e \"$2 TEST_API_KEY=$3\" /work/workspace/$1'" 2>/dev/null)"
  if [[ "$c" == 1 ]]; then echo ok; else echo fail; fi
}
turncount() { vmin "docker exec -i ${A} /opt/hermes/.venv/bin/python - $1 ${TURN_ROW:-error} $2 $3 $4" "${HERE}/state-count.py" 2>&1; }  # FAKE MARKER FIXTURE cat|pane

# 17. Tool output path: the harness writes "MARK_<nonce> TEST_API_KEY=<fake>" into a workbench file and Hermes `cat`s
#     it with its terminal tool (Hermes refuses to echo a secret-looking value typed in a prompt, so the value must
#     first appear in tool output). The fixture write is checked (the line must read back). Required control
#     (state-count.py MODE cat, qualifying >= 1): the turn is the one state.db user row after TURN_ROW naming the
#     run-unique fixture file (zero or several = FAIL), in that row's session, up to its next user row; in it a
#     terminal call whose command is exactly `cat /work/workspace/<fixture>` has a linked tool result with exit_code
#     present and int 0, whose output holds the marker and the fixture line as Hermes's own redactor masks it (forced,
#     so it doesn't depend on config), and no raw fake. Zero counts, global: the fake may not appear in the Hermes
#     pane, its logs, or state.db tool-result / answer content of any session. Any collection error (empty pane read,
#     log find/read/grep failure, state-count error) fails the test. Evidence holds counts and the marker only.
b17="$(fakebody)"; F17="sk-test-${b17}"; M17="$(mkmark)"
X17="fixture17-${b17:0:8}.txt"   # the prompt names only the file; the fake first appears in tool output
w17="$(writefix "$X17" "$M17" "$F17")"
if [[ "$w17" == ok ]]; then   # no model call for a turn that can't pass
  ask "Use the terminal tool to run exactly: cat /work/workspace/${X17}  -- then report the exact tool output."
fi
if scr17="$(hscreen 200)"; then s17="$(rcount "$F17" <<<"$scr17")"; else s17="error"; fi
l17="$(logcount "$F17")"; d17="$(turncount "$F17" "$M17" "$X17" cat)"
vm "docker exec ${B} rm -f /work/workspace/${X17}" >/dev/null 2>&1
t17="$(num tool_content "$d17")"; a17="$(num assistant_content "$d17")"; m17="$(num qualifying "$d17")"
printf 'fixture write=%s; marker=%s; turn start rowid=%s\nfake sk-test-<30 chars> occurrences: hermes pane=%s; /data/hermes/logs=%s; state.db: %s\ncontrol: exact `cat <fixture>` results this turn, exit_code 0, marker + masked line, no raw fake (qualifying)=%s\n' \
  "$w17" "$M17" "${TURN_ROW:-?}" "${s17:-?}" "${l17:-?}" "$d17" "${m17:-?}" | ev "17 redaction: terminal tool output (counts only)"
if [[ "$w17" == ok ]] && isnum "$m17" && ((m17 >= 1)) && [[ "$s17" == 0 && "$l17" == 0 && "$t17" == 0 && "$a17" == 0 ]]; then
  result PASS "17 tool output: fake key masked in pane, logs, state.db" "masked tool result with marker this turn=${m17}; pane 0, logs 0, tool/answer content 0"
else result FAIL "17 tool output: fake key masked in pane, logs, state.db" "fixture=${w17} masked+marker=${m17:-?} pane=${s17:-?} logs=${l17:-?} tool=${t17:-?} answer=${a17:-?}"; fi

# 18. herdr-operator wrapped path: Hermes `cat`s a fixture file holding "MARK_<nonce> TEST_API_KEY=<fake>" in a NEW
#     work pane and gets its output back with `herdr pane read` / `wait-output` via the terminal tool. Checked: (a) the
#     fixture write reads back; (b) info only: the raw work-pane scrollback (NOT redacted: herdr keeps what the shell
#     printed) count of the fake, recorded but not required (the skill may close its pane after reading it); its pane
#     list / read failures are evidence errors; (c) the required control (state-count.py MODE pane, qualifying >= 1):
#     the turn is the one state.db user row after TURN_ROW naming the run-unique fixture file (zero or several = FAIL),
#     in that row's session, up to its next user row; in it a terminal call `herdr pane run <id> '...cat
#     /work/workspace/<fixture>...'` and, at or after it, a terminal call `herdr pane read|wait-output <id> ...` for the
#     SAME pane id, with no fixture name, no `cat `, no shell chaining or substitution, whose linked tool result has
#     exit_code present and int 0, output holding the marker and the fixture line as Hermes's own redactor masks it,
#     and no raw fake; (d) zero counts, global, for the fake of every attempt: Hermes pane, its logs, state.db
#     tool-result / answer content. Evidence errors (fixture write failure, pane list or read failure, log
#     find/read/grep failure, non-numeric count, state-count error) accumulate over both attempts; any one fails the
#     test. One logged retry when an attempt had no error and no qualifying result.
vm "docker exec ${W} herdr-close-extra-panes" >/dev/null 2>&1
rawcount() {  # rawcount FAKE: prints "<lines> <panes> <errors>": lines holding FAKE across all work-pane scrollbacks
  # Each reader's exit status is checked on its own (no pipe on the remote side): a failed list or read is an error.
  local ids lst rd p n=0 np=0 ne=0
  if ! lst="$(wfile "herdr pane list")" \
     || ! ids="$(python3 -c 'import json,sys; [print(p["pane_id"]) for p in json.load(sys.stdin)["result"]["panes"]]' <<<"$lst" 2>/dev/null)"; then
    echo "0 0 1"; return
  fi
  for p in $ids; do
    np=$((np + 1))
    if rd="$(wfile "herdr pane read ${p} --lines 200")"; then n=$((n + $(rcount "$1" <<<"$rd"))); else ne=$((ne + 1)); fi
  done
  ((np > 0)) || ne=$((ne + 1))
  echo "$n $np $ne"
}
try18=0; F18S=(); err18=0; ne18t=0
while :; do
  try18=$((try18 + 1)); b18="$(fakebody)"; F18="sk-test-${b18}"; M18="$(mkmark)"; F18S+=("$F18")
  X18="fixture18-${b18:0:8}.txt"; w18="$(writefix "$X18" "$M18" "$F18")"; e=0
  if [[ "$w18" == ok ]]; then
    ask "Use the herdr-operator skill: split a NEW herdr pane, run exactly cat /work/workspace/${X18} in it and wait for it to finish, then read the pane back and report the exact output."
    hh agent wait "${AGENT}" --until idle --timeout 120000 >/dev/null 2>&1
  else e=$((e + 1)); fi
  read -r raw18 np18 ne18 <<<"$(rawcount "$F18")"
  d18="$(turncount "$F18" "$M18" "$X18" pane)"; p18="$(num qualifying "$d18")"
  for v in "$raw18" "$np18" "$ne18" "$p18"; do isnum "$v" || e=$((e + 1)); done
  isnum "$ne18" && ne18t=$((ne18t + ne18)); err18=$((err18 + e))
  printf 'attempt %s: fixture write=%s; marker=%s; turn start rowid=%s; raw work-pane lines=%s panes=%s pane-read errors=%s; attempt evidence errors=%s\nstate.db: %s\n' \
    "$try18" "$w18" "$M18" "${TURN_ROW:-?}" "${raw18:-?}" "${np18:-?}" "${ne18:-?}" "$e" "$d18" | ev "18 attempt ${try18} (counts only)"
  if isnum "$p18" && ((p18 >= 1)); then break; fi
  ((try18 >= 2 || e > 0 || ne18t > 0)) && break   # an evidence error already fails the test: no retry
  echo "attempt ${try18}: qualifying Hermes pane-read results=${p18:-?} (raw work-pane lines=${raw18:-?}, info); retrying once" | ev "18 retry"
done
vm "docker exec ${B} sh -c 'rm -f /work/workspace/fixture18-*.txt'" >/dev/null 2>&1
# Global zero counts for every attempt's fake; the last attempt's state.db read is redone after the turn settled.
d18="$(turncount "$F18" "$M18" "$X18" pane)"; p18="$(num qualifying "$d18")"
s18=0; l18=0; t18=0; a18=0; scr18="$(hscreen 200)" || { scr18=""; err18=$((err18 + 1)); }
for f in "${F18S[@]}"; do
  if [[ "$f" == "$F18" ]]; then df="$d18"; else df="$(statecount "$f")"; fi
  c1="$(rcount "$f" <<<"$scr18")"; c2="$(logcount "$f")"; c3="$(num tool_content "$df")"; c4="$(num assistant_content "$df")"
  for v in "$c1" "$c2" "$c3" "$c4"; do isnum "$v" || err18=$((err18 + 1)); done
  isnum "$c1" && s18=$((s18 + c1)); isnum "$c2" && l18=$((l18 + c2)); isnum "$c3" && t18=$((t18 + c3)); isnum "$c4" && a18=$((a18 + c4))
done
isnum "$p18" || err18=$((err18 + 1))
printf 'fixture write=%s; marker=%s; attempts=%s; evidence errors (all attempts)=%s\nfake sk-test-<30 chars> occurrences (sum over %s attempt fakes): hermes pane=%s; /data/hermes/logs=%s; state.db tool_content=%s assistant_content=%s\nlast attempt state.db: %s\ninfo: raw work-pane scrollback (NOT redacted by design; not required) last attempt lines=%s panes=%s; pane-read errors (all attempts)=%s\ncontrol (required): same-pane `herdr pane read|wait-output` results this turn, exit_code 0, marker + masked line, no raw fake (qualifying)=%s\n' \
  "$w18" "$M18" "$try18" "$err18" "${#F18S[@]}" "$s18" "$l18" "$t18" "$a18" "$d18" "${raw18:-?}" "${np18:-?}" "$ne18t" "${p18:-?}" \
  | ev "18 redaction: herdr-operator pane run + pane read (counts only)"
if [[ "$w18" == ok && "$err18" == 0 && "$ne18t" == 0 ]] && ((p18 >= 1 && s18 == 0 && l18 == 0 && t18 == 0 && a18 == 0)); then
  result PASS "18 herdr-operator path: Hermes shows/stores fake masked" "Hermes read the pane: marker + masked fake in its same-pane read result (${p18}); pane 0, logs 0, tool/answer 0; raw work scrollback=${raw18} (info); attempts ${try18}"
else result FAIL "18 herdr-operator path: Hermes shows/stores fake masked" "fixture=${w18} pane-read qualifying=${p18:-?} pane=${s18} logs=${l18} tool=${t18} answer=${a18}; raw work scrollback=${raw18:-?} panes=${np18:-?} pane-read errors=${ne18t} evidence errors=${err18}; attempts ${try18}"; fi

# 19. Real key absent. secret-scan.sh (run inside each container, see its header) counts lines holding a
#     real-key-shaped nvapi- value (nvapi- + 20 or more token chars); it never prints a line, file content or value.
#     Filesystem scan per path: count, files read, errors (stderr lines of find/xargs/grep = what was not read), and
#     how many errors name an allowed path (expected) or not (unexpected). Locations: herdr-hermes /data/hermes/logs,
#     /data/hermes/sessions, /data/hermes/state.db (+ -wal, -shm), /data/home and all of /data (no allow list: every
#     error is unexpected); the whole workbench and work-container filesystems except /proc, /sys, /dev, with the allow
#     list ALLOW19 = the root-only paths uid 10000 without capabilities cannot read there (busybox: "find: /root:
#     Permission denied", "grep: /etc/shadow: Permission denied", ...).
#     Required: every path exists except state.db-wal and state.db-shm (SQLite creates them only while a connection
#     has the database open in WAL mode); logs, state.db, /data/home and /data have >= 1 file read, sessions >= 0,
#     each "/" >= 100; unexpected=0 for every path.
#     Controls (all must pass before the real scan counts):
#      - directories: --plant writes a fake key-shaped canary (FAKECANARY + 30 random hex chars made in the container,
#        never printed) into herdr-hermes /data/hermes/logs, /data/hermes/sessions, /data/home, /data; workbench
#        /work/workspace, /tmp; work /tmp, /data (8). The same scan must count at least the canaries at or below each
#        path.
#      - state.db, -wal, -shm (the live files are never written): --copy-control copies each existing one into a new
#        mktemp dir under /tmp in herdr-hermes, appends a canary line to the copy, scans the copy (count >= 1,
#        files=1, errors=0), deletes the dir and checks it is gone. state.db must exist; -wal/-shm absent = no control.
#      - panes: --pane-control in the work container splits a NEW pane (--cwd /work/workspace), types a printf that
#        prints a canary made in the pane shell (the typed line holds no value), waits for it (pane wait-output),
#        counts it in `herdr pane read <id> --source recent-unwrapped --lines 200` (count >= 1), closes the pane and
#        checks it is gone from `herdr pane list`.
#     Then every planted canary is removed (8/8 confirmed) and the real scan runs: count 0 for every path, the Hermes
#     pane (`herdr agent read <agent> --source recent-unwrapped --lines 1000` in herdr-hermes, the read hh does) and
#     every remaining work pane (same read as the control). A pane read that exits non-zero or prints nothing fails.
#     FAIL on any missing or malformed scanner line, required path absent, too few files, unexpected error, failed
#     plant/copy/remove/pane step, control count below its minimum, or real-key-shaped count above 0.
SC19="${HERE}/secret-scan.sh"
ALLOW19="/root,/etc/crontabs/root,/etc/shadow,/etc/shadow-,/lib/apk/db/lock"
DB19="/data/hermes/state.db /data/hermes/state.db-wal /data/hermes/state.db-shm"
sc19() { vmin "docker exec -i $1 sh -s -- $2" "$SC19" 2>&1 | sed "s|^|$1:|"; }   # sc19 CONTAINER "ARGS"
scan19() {  # identical for the control and the real scan
  sc19 "$A" "/data/hermes/logs /data/hermes/sessions ${DB19} /data/home /data"
  sc19 "$B" "--allow ${ALLOW19} /"
  sc19 "$W" "--allow ${ALLOW19} /"
}
canary19() {  # canary19 --plant|--remove
  sc19 "$A" "$1 /data/hermes/logs /data/hermes/sessions /data/home /data"
  sc19 "$B" "$1 /work/workspace /tmp"
  sc19 "$W" "$1 /tmp /data"
}
# location                need      min files  canaries at or below it (- = no planted canary)
spec19="${A}:/data/hermes/logs required 1 1
${A}:/data/hermes/sessions required 0 1
${A}:/data/hermes/state.db required 1 -
${A}:/data/hermes/state.db-wal optional 1 -
${A}:/data/hermes/state.db-shm optional 1 -
${A}:/data/home required 1 1
${A}:/data required 1 4
${B}:/ required 100 2
${W}:/ required 100 2"
chk19() {  # chk19 control|real ROWS: one problem per line, nothing when every location is fine
  local key need minf ctl row cnt f u re='^[^ ]+ ([0-9]+) files=([0-9]+) errors=[0-9]+ expected=[0-9]+ unexpected=([0-9]+)$'
  while read -r key need minf ctl; do
    row="$(awk -v k="$key" '$1 == k' <<<"$2" | head -1)"
    if [[ "$row" == "${key} absent" ]]; then [[ "$need" == optional ]] || echo "${key} required-but-absent"; continue; fi
    if [[ ! "$row" =~ $re ]]; then echo "${key} scanner-failed"; continue; fi
    cnt="${BASH_REMATCH[1]}"; f="${BASH_REMATCH[2]}"; u="${BASH_REMATCH[3]}"
    ((f >= minf)) || echo "${key} files=${f}<${minf}"
    ((u == 0)) || echo "${key} unexpected-errors=${u}"
    if [[ "$1" == control ]]; then [[ "$ctl" == - ]] || ((cnt >= ctl)) || echo "${key} canary-count=${cnt}<${ctl}"
    else ((cnt == 0)) || echo "${key} real-key-shaped=${cnt}"; fi
  done <<<"$spec19"
}
chkdb19() {  # chkdb19 ROWS: copy-control problems, one per line
  local p key row re='^[^ ]+ copy-control ([0-9]+) files=([0-9]+) errors=([0-9]+) removed$'
  for p in $DB19; do
    key="${A}:${p}"; row="$(awk -v k="$key" '$1 == k' <<<"$1" | head -1)"
    if [[ "$row" == "${key} absent" ]]; then [[ "$p" != */state.db ]] || echo "${key} required-but-absent"; continue; fi
    if [[ ! "$row" =~ $re ]]; then echo "${key} copy-control-failed"; continue; fi
    ((BASH_REMATCH[1] >= 1 && BASH_REMATCH[2] == 1 && BASH_REMATCH[3] == 0)) || echo "${key} copy-control-count/files/errors"
  done
}
# Controls: plant, copy-control, control scan, pane control.
p19="$(canary19 --plant)"; np19="$(grep -c ' planted$' <<<"$p19")"
db19="$(sc19 "$A" "--copy-control ${DB19}")"; dbad19="$(chkdb19 "$db19")"
ctl19="$(scan19)"; cbad19="$(chk19 control "$ctl19")"
pc19="$(sc19 "$W" --pane-control)"; pok19=no
re19='^[^ ]+ pane=[A-Za-z0-9:]+ split=ok run=ok wait=ok count=([0-9]+) lines=[0-9]+ closed=ok$'
[[ "$pc19" =~ $re19 ]] && ((BASH_REMATCH[1] >= 1)) && pok19=yes
# Removal (always, even after a failed plant), then the real scan.
r19="$(canary19 --remove)"; nr19="$(grep -c ' removed$' <<<"$r19")"
real19="$(scan19)"; rbad19="$(chk19 real "$real19")"
hp19="$(sc19 "$A" "--cmd-count hermes-pane herdr agent read ${AGENT} --source recent-unwrapped --lines 1000")"; hok19=no
re19='^[^ ]+:hermes-pane 0 lines=[1-9][0-9]*$'; [[ "$hp19" =~ $re19 ]] && hok19=yes
wp19="$(sc19 "$W" --panes-count)"; wok19=no
re19='^[^ ]+:work-panes n=[1-9][0-9]* failed=0 count=0$'; [[ "$(tail -n 1 <<<"$wp19")" =~ $re19 ]] && wok19=yes
{
  echo "directory canaries (fake, made in each container, value never printed): ${np19}/8 planted"
  printf '%s\n' "$p19"
  echo "state.db/-wal/-shm copy controls (canary appended to a copy under /tmp, copy scanned then deleted; live files untouched):"
  printf '%s\n' "$db19"
  echo "copy-control problems: $(tr '\n' ' ' <<<"${dbad19:-none}")"
  echo "control scan (count must be >= the canaries at or below the path; unexpected=0; allowed unreadable paths in ${B} and ${W}: ${ALLOW19}):"
  printf '%s\n' "$ctl19"
  echo "control problems: $(tr '\n' ' ' <<<"${cbad19:-none}")"
  echo "pane control (new work pane, canary printed by its shell, read count >= 1, pane closed and gone): ok=${pok19}"
  printf '%s\n' "$pc19"
  echo "canary removal: ${nr19}/8 removed"
  printf '%s\n' "$r19"
  echo "real-key scan after removal (count must be 0, unexpected=0):"
  printf '%s\n' "$real19"
  echo "real-scan problems: $(tr '\n' ' ' <<<"${rbad19:-none}")"
  echo "Hermes pane (last 1000 lines; count 0, lines >= 1): ok=${hok19}"
  printf '%s\n' "$hp19"
  echo "remaining work panes (each read ok, count 0): ok=${wok19}"
  printf '%s\n' "$wp19"
} | ev "19 real NVIDIA key absent (controls + scan, counts only)"
if [[ "$np19" == 8 && -z "$dbad19" && -z "$cbad19" && "$pok19" == yes && "$nr19" == 8 && -z "$rbad19" && "$hok19" == yes && "$wok19" == yes ]]; then
  result PASS "19 real NVIDIA key absent from data, containers, scrollback" "controls: 8/8 dir canaries, state.db copies, new work pane counted; all removed; real scan 0 in every path + Hermes pane + work panes; unexpected errors 0"
else result FAIL "19 real NVIDIA key absent from data, containers, scrollback" "planted ${np19}/8 removed ${nr19}/8 pane-control=${pok19} hermes-pane=${hok19} work-panes=${wok19}; $(tr '\n' ' ' <<<"${dbad19}${dbad19:+ }${cbad19}${cbad19:+ }${rbad19}")"; fi
