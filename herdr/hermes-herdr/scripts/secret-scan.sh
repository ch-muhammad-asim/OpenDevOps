#!/bin/sh
# Runs INSIDE a container (piped in by e2e-redaction.sh test 19 with `sh -s -- ...`). POSIX sh; works with GNU and
# busybox find/grep/xargs/awk. Never prints a matching line, a file's content or a value: only paths, pane ids,
# counts and status words.
#
#   secret-scan.sh [--allow P1,P2,...] PATH...
#       one summary line per PATH:  "<PATH> <count> files=<N> errors=<E> expected=<X> unexpected=<U>"
#                               or  "<PATH> absent"  or  "<PATH> scan-failed" (the pipeline produced no summary)
#       then, for each unexpected error (at most 20), a line "  unexpected-path <path>".
#     count      = lines holding a real-key-shaped NVIDIA key (nvapi- + 20 or more token chars) in the regular files
#                  under PATH (PATH itself when it is a file)
#     files      = files grep read (one count line each): what was scanned
#     errors     = stderr lines of find, xargs and grep (unreadable files or dirs, I/O errors): what was NOT scanned.
#                  Taken from stderr, not exit codes (grep -c also exits 1 when a file simply has no match).
#     expected   = errors whose path (the text between "find: "/"grep: " and the last ": ", quotes removed) is one of
#                  the --allow paths exactly
#     unexpected = every other error line (another path, or a line without such a path)
#     "/" scans the whole filesystem (volumes and tmpfs mounts included) except /proc, /sys and /dev.
#   secret-scan.sh --plant DIR...   writes a fake key-shaped canary (FAKECANARY + 30 random hex chars from
#                                   /dev/urandom) to DIR/.secret-scan-canary.txt: "<DIR> planted" | "<DIR> plant-failed"
#   secret-scan.sh --remove DIR...  deletes DIR/.secret-scan-canary.txt: "<DIR> removed" once it is gone, or
#                                   "<DIR> remove-failed"
#   secret-scan.sh --copy-control FILE...
#       never writes FILE: copies it into a new mktemp dir under /tmp, appends a canary line to the COPY, scans the
#       copy dir with the same scan, deletes the dir and checks it is gone:
#       "<FILE> copy-control <count> files=<N> errors=<E> removed" | "<FILE> absent" | "<FILE> copy-control-failed"
#   secret-scan.sh --cmd-count LABEL CMD...
#       runs CMD and counts the same pattern in its stdout: "<LABEL> <count> lines=<L>"; "<LABEL> read-failed" when
#       CMD exits non-zero, "<LABEL> read-empty" when it prints nothing.
#   secret-scan.sh --pane-control   (work container: herdr + python3)
#       splits a NEW pane (--cwd /work/workspace), types into it a command that prints a canary made in the pane shell
#       (the typed line holds only the printf template, no value), waits for it, counts it with --cmd-count on
#       `herdr pane read <id> --source recent-unwrapped --lines 200`, closes the pane and checks it is gone:
#       "pane-control pane=<id> split=ok run=ok wait=ok count=<n> lines=<L> closed=ok" (a failed step: <step>=failed)
#   secret-scan.sh --panes-count    (work container) --cmd-count on every pane (same read), then
#       "work-panes n=<N> failed=<F> count=<sum>" (failed = list or read failures)
RE='nvapi-[A-Za-z0-9_-]{20,}'
CANARY=.secret-scan-canary.txt
ALLOW=""
LQ="$(printf '\342\200\230')"; RQ="$(printf '\342\200\231')"   # GNU find quotes paths with these (UTF-8 locale)
canary() { r="$(od -An -N15 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"; [ "${#r}" -eq 30 ] && printf 'FAKE_TEST_CANARY=nvapi-FAKECANARY%s\n' "$r"; }

# Classifies stderr lines: prints "U <path>" per unexpected one (at most 20) and "E <errors> <expected> <unexpected>".
# shellcheck disable=SC2016  # awk program, not shell
ERRAWK='BEGIN { n = split(allow, a, ","); for (i = 1; i <= n; i++) ok[a[i]] = 1; q = "\047" }
{ e++; l = $0; p = ""
  if (sub(/^(find|grep): /, "", l)) {
    k = 0; for (i = 1; i < length(l); i++) if (substr(l, i, 2) == ": ") k = i
    if (k > 0) p = substr(l, 1, k - 1)
    gsub(lq, "", p); gsub(rq, "", p)
    if (length(p) >= 2 && substr(p, 1, 1) == q && substr(p, length(p), 1) == q) p = substr(p, 2, length(p) - 2)
  }
  if (p != "" && (p in ok)) x++
  else { u++; if (u <= 20) print "U", (p == "" ? "(no path)" : p) }
}
END { print "E", e + 0, x + 0, u + 0 }'

scan() {  # scan PATH: sets SUM ("<count> files=<N> errors=<E> expected=<X> unexpected=<U>", empty on failure), UNX
  if [ "$1" = / ]; then
    roots=""
    for d in /*; do case "$d" in /proc | /sys | /dev) ;; *) roots="$roots $d" ;; esac; done
  else
    roots="$1"
  fi
  # stderr of find/xargs/grep goes to fd 3 and only into ERRAWK (paths and counts out, never message text).
  # grep -c -h prints one bare count per file it read, so awk sums the matches and counts the files.
  # shellcheck disable=SC2086  # roots is a space-separated list of absolute paths without spaces
  res="$({ { find $roots -type f -print0 2>&3 | xargs -0 -r grep -a -c -h -E "$RE" 2>&3 \
              | awk '{s += $1; f++} END {print "M", s + 0, f + 0}' >&4; } 3>&1 | awk -v allow="$ALLOW" -v lq="$LQ" -v rq="$RQ" "$ERRAWK" >&4; } 4>&1)"
  m="$(printf '%s\n' "$res" | awk '$1 == "M" {print $2, $3}')"
  e="$(printf '%s\n' "$res" | awk '$1 == "E" {print $2 " expected=" $3 " unexpected=" $4}')"
  UNX="$(printf '%s\n' "$res" | sed -n 's/^U /  unexpected-path /p')"
  SUM=""
  if [ -n "$m" ] && [ -n "$e" ]; then SUM="${m% *} files=${m#* } errors=$e"; fi
}

cmdcount() {  # cmdcount LABEL CMD...: see --cmd-count; returns 1 on a failed or empty read
  l="$1"; shift
  if ! out="$("$@" 2>/dev/null)"; then echo "$l read-failed"; return 1; fi
  if [ -z "$out" ]; then echo "$l read-empty"; return 1; fi
  echo "$l $(printf '%s\n' "$out" | grep -c -E "$RE") lines=$(printf '%s\n' "$out" | grep -c '')"
}

paneids() {  # one pane id per line; non-zero when herdr or the JSON parse fails
  j="$(herdr pane list 2>/dev/null)" \
    && printf '%s' "$j" | python3 -c 'import json,sys; [print(p["pane_id"]) for p in json.load(sys.stdin)["result"]["panes"]]' 2>/dev/null
}

case "${1:-}" in
  --plant)
    shift
    for d in "$@"; do
      if [ -d "$d" ] && { canary >"$d/$CANARY"; } 2>/dev/null && [ -s "$d/$CANARY" ]; then
        echo "$d planted"
      else
        echo "$d plant-failed"
      fi
    done
    exit 0 ;;
  --remove)
    shift
    for d in "$@"; do
      { rm -f "$d/$CANARY"; } 2>/dev/null
      if [ -e "$d/$CANARY" ]; then echo "$d remove-failed"; else echo "$d removed"; fi
    done
    exit 0 ;;
  --copy-control)
    shift
    for f in "$@"; do
      if [ ! -e "$f" ]; then echo "$f absent"; continue; fi
      SUM=""
      if t="$(mktemp -d /tmp/.scan-ctl-XXXXXX 2>/dev/null)" && [ -d "$t" ]; then
        if [ -f "$f" ] && cp "$f" "$t/copy" 2>/dev/null && { { echo; canary; } >>"$t/copy"; } 2>/dev/null; then scan "$t"; fi
        rm -rf "$t" 2>/dev/null
        [ ! -e "$t" ] || SUM=""
      fi
      if [ -n "$SUM" ]; then echo "$f copy-control ${SUM% expected=*} removed"; else echo "$f copy-control-failed"; fi
    done
    exit 0 ;;
  --cmd-count)
    shift; cmdcount "$@"; exit 0 ;;
  --pane-control)
    # Typed into the pane shell, it prints FAKE_TEST_CANARY=nvapi-FAKECANARY<30 hex> made there. The typed line itself
    # does not match the pattern (FAKECANARY is followed by %s).
    pcmd="printf 'FAKE_TEST_CANARY=nvapi-FAKECANARY%s\\n' \"\$(od -An -N15 -tx1 /dev/urandom | tr -d ' \\n')\""
    sp=failed; ru=failed; wa=failed; cnt="count=failed lines=0"; cl=failed
    j="$(herdr pane split --direction right --no-focus --cwd /work/workspace 2>/dev/null)" \
      && p="$(printf '%s' "$j" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])' 2>/dev/null)" \
      || p=""
    case "$p" in "" | *[!A-Za-z0-9:]*) p=none ;; *) sp=ok ;; esac
    if [ "$sp" = ok ]; then
      herdr pane run "$p" "$pcmd" >/dev/null 2>&1 && ru=ok
      [ "$ru" = ok ] && herdr pane wait-output "$p" --source recent-unwrapped --regex 'nvapi-FAKECANARY[0-9a-f]{30}' \
        --timeout 30000 >/dev/null 2>&1 && wa=ok
      r="$(cmdcount x herdr pane read "$p" --source recent-unwrapped --lines 200)" && cnt="count=${r#x }"
      herdr pane close "$p" >/dev/null 2>&1
      ids="$(paneids)" && ! printf '%s\n' "$ids" | grep -q -x -F "$p" && cl=ok
    fi
    echo "pane-control pane=$p split=$sp run=$ru wait=$wa $cnt closed=$cl"
    exit 0 ;;
  --panes-count)
    n=0; f=0; s=0
    if ids="$(paneids)"; then
      for p in $ids; do
        n=$((n + 1))
        if r="$(cmdcount "pane:$p" herdr pane read "$p" --source recent-unwrapped --lines 200)"; then
          s=$((s + $(echo "$r" | awk '{print $2}')))
        else f=$((f + 1)); fi
        echo "$r"
      done
    else f=$((f + 1)); fi
    echo "work-panes n=$n failed=$f count=$s"
    exit 0 ;;
  --allow)
    ALLOW="$2"; shift 2 ;;
esac

for p in "$@"; do
  if [ ! -e "$p" ]; then echo "$p absent"; continue; fi
  scan "$p"
  if [ -n "$SUM" ]; then echo "$p $SUM"; [ -z "$UNX" ] || printf '%s\n' "$UNX"; else echo "$p scan-failed"; fi
done
