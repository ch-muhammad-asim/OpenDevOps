# Runs INSIDE herdr-hermes (piped in by e2e-redaction.sh tests 17/18 to the Hermes venv python), read-only on
# Hermes's state.db (WAL included). Prints counts only: never a fake value, nor its masked form.
#   state-count.py FAKE                               global counts only
#   state-count.py FAKE START MARKER FIXTURE MODE     global counts + the turn's qualifying results
# Global counts (whole db, every session): messages whose column contains FAKE.
#   failing:  tool_content, assistant_content (what Hermes stores as tool results and answers)
#   info:     tool_calls (tool-call arguments may hold it, known upstream behaviour), user_content, api_content,
#             reasoning (the model's reasoning is stored unredacted: it may hold a value the model worked out)
# Turn scope (exact): the turn is the ONE user row with rowid > START (the max rowid before the prompt) whose content
# holds FIXTURE (the run-unique fixture file name the prompt names). Zero or several such rows = "scope error".
# Turn rows = rows of that row's session_id with rowid > that row and < the next user row of that session (if any).
# A qualifying result is a tool row in the turn linked (tool_call_id / tool_call_uid) to a "terminal" tool call
# of an assistant row in the turn, whose content is the terminal JSON result with "exit_code" present, an int
# (not bool) and 0, whose "output" holds MARKER and a Hermes-masked form of the fixture line, and whose content
# does not hold FAKE. Masked forms come from Hermes's own redactor, forced so they don't depend on config:
# agent.redact.redact_sensitive_text(line, force=True) with code_file False and True, plus
# agent.redact.redact_terminal_output(line, <the call's command>, force=True); a form counts only if it holds
# MARKER and not FAKE. The linked call's command (stripped) must be:
#   MODE cat:   exactly "cat /work/workspace/FIXTURE"
#   MODE pane:  "herdr pane read <id> ..." or "herdr pane wait-output <id> ..." with no FIXTURE, no "/work/workspace/",
#               no "cat ", no shell chaining or substitution (; & | ` $( newline), and <id> (quotes optional, letters,
#               digits and _:.- only) equal to the <id> of a "herdr pane run <id> '...'" terminal call in the turn,
#               at or before the read, whose payload holds "cat /work/workspace/FIXTURE"
# Prints "turn: ... qualifying=N"; any argument, db, schema, redactor or scope error prints "turn error:<what>" or
# "scope error:<what>" instead, without qualifying=, and exits 1, so the caller's check fails.
import json
import os
import re
import sqlite3
import sys

fake = sys.argv[1] if len(sys.argv) > 1 else ""
db = os.path.join(os.environ.get("HERMES_HOME", "/data/hermes"), "state.db")
if not fake:
    print("args error:fake")
    sys.exit(1)
try:
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    cols = {r[1] for r in con.execute("PRAGMA table_info(messages)")}
    if not cols:
        raise sqlite3.OperationalError("no messages table")
except sqlite3.Error as exc:
    print("state.db error:%s" % type(exc).__name__)
    sys.exit(1)


def count(col, role=None):
    if col not in cols:
        return "n/a"
    sql = "SELECT COUNT(*) FROM messages WHERE instr(CAST(%s AS TEXT), ?) > 0" % col
    args = [fake]
    if role:
        sql += " AND role = ?"
        args.append(role)
    return con.execute(sql, args).fetchone()[0]


try:
    out = ("tool_content=%s assistant_content=%s info: tool_calls=%s user_content=%s api_content=%s reasoning=%s"
           % (count("content", "tool"), count("content", "assistant"), count("tool_calls"),
              count("content", "user"), count("api_content"), count("reasoning_content")))
except sqlite3.Error as exc:
    print("state.db error:%s" % type(exc).__name__)
    sys.exit(1)
if len(sys.argv) == 2:
    print(out)
    sys.exit(0)


def fail(msg, kind="turn"):
    print("%s %s error:%s" % (out, kind, msg))
    sys.exit(1)


if len(sys.argv) != 6:
    fail("args")
start, marker, fixture, mode = sys.argv[2:6]
if not re.fullmatch(r"[0-9]+", start):
    fail("start")
if (not re.fullmatch(r"MARK_[0-9]+", marker) or not re.fullmatch(r"[A-Za-z0-9._-]+", fixture)
        or mode not in ("cat", "pane")):
    fail("args")
start = int(start)
path = "/work/workspace/" + fixture
line = "%s TEST_API_KEY=%s" % (marker, fake)


def valid(form):
    return isinstance(form, str) and marker in form and fake not in form


try:
    sys.path.append("/opt/hermes")
    from agent.redact import redact_sensitive_text, redact_terminal_output
    base_forms = {f for f in (redact_sensitive_text(line, force=True),
                              redact_sensitive_text(line, force=True, code_file=True)) if valid(f)}
except Exception as exc:  # noqa: BLE001 - any import/call failure must fail the check
    fail("redactor:%s" % type(exc).__name__)
if not base_forms:
    fail("redactor:nothing-masked")

if not {"role", "content", "session_id", "tool_call_id", "tool_calls"} <= cols:
    fail("schema")
try:
    users = con.execute("SELECT rowid, session_id FROM messages WHERE role = 'user' AND rowid > ? "
                        "AND instr(CAST(content AS TEXT), ?) > 0", (start, fixture)).fetchall()
    if len(users) != 1:
        fail("user-rows=%d" % len(users), "scope")
    urow, sess = users[0]
    if sess is None:
        fail("session", "scope")
    nxt = con.execute("SELECT MIN(rowid) FROM messages WHERE role = 'user' AND session_id = ? AND rowid > ?",
                      (sess, urow)).fetchone()[0]
    sel = ["rowid", "role", "content", "tool_call_id", "tool_calls"]
    sel += [c if c in cols else "NULL" for c in ("tool_call_uid", "tool_call_uids")]
    sql = "SELECT %s FROM messages WHERE session_id = ? AND rowid > ?" % ", ".join(sel)
    args = [sess, urow]
    if nxt is not None:
        sql += " AND rowid < ?"
        args.append(nxt)
    rows = con.execute(sql + " ORDER BY rowid", args).fetchall()
except sqlite3.Error as exc:
    fail(type(exc).__name__)


def norm_id(v):
    return v.split("|", 1)[0].strip() if isinstance(v, str) else v


def jload(v, default):
    if isinstance(v, (list, dict)):
        return v
    try:
        return json.loads(v) if v else default
    except (TypeError, ValueError):
        return default


PANE_ID = r"""(?:"([A-Za-z0-9_:.-]+)"|'([A-Za-z0-9_:.-]+)'|([A-Za-z0-9_:.-]+))"""
RUN_RE = re.compile(r"herdr pane run\s+" + PANE_ID + r"\s+(.*)", re.S)
READ_RE = re.compile(r"herdr pane (?:read|wait-output)\s+" + PANE_ID + r"(?:\s|\Z)")
CHAIN = (";", "&", "|", "`", "$(", "\n", "\r")


def pane_id(m):
    return next(g for g in m.groups()[:3] if g)


calls, uid_to_id = {}, {}  # provider call id -> (rowid, command) of a terminal call; tool_call_uid -> call id
run_panes = []  # (rowid, pane id) of `herdr pane run <id> '...cat /work/workspace/FIXTURE...'` terminal calls
for rid, role, _c, _tcid, tool_calls, _tuid, tool_call_uids in rows:
    if role != "assistant" or not tool_calls:
        continue
    for tc in jload(tool_calls, []) or []:
        if not isinstance(tc, dict):
            continue
        fn = tc.get("function") if isinstance(tc.get("function"), dict) else {}
        if (fn.get("name") or tc.get("name")) != "terminal":
            continue
        args = jload(fn.get("arguments", tc.get("arguments")), {})
        cmd = args.get("command") if isinstance(args, dict) else None
        if not isinstance(cmd, str):
            continue
        cmd = cmd.strip()
        for key in (tc.get("call_id"), tc.get("id"), tc.get("response_item_id"),
                    norm_id(tc.get("call_id")), norm_id(tc.get("id"))):
            if key:
                calls[key] = (rid, cmd)
        m = RUN_RE.fullmatch(cmd)
        if m and ("cat " + path) in m.group(4):
            run_panes.append((rid, pane_id(m)))
    uids = jload(tool_call_uids, {})
    for cid, uid in (uids.items() if isinstance(uids, dict) else ()):
        uid_to_id[uid] = cid


def call_ok(rid, cmd):
    if mode == "cat":
        return cmd == "cat " + path
    m = READ_RE.match(cmd)
    if not m or fixture in cmd or "/work/workspace/" in cmd or "cat " in cmd or any(c in cmd for c in CHAIN):
        return False
    return any(r <= rid and p == pane_id(m) for r, p in run_panes)


n = {k: 0 for k in ("tools", "linked", "call", "exit0", "qualifying", "raw")}
for _rid, role, content, tcid, _tc, tool_call_uid, _u in rows:
    if role != "tool":
        continue
    n["tools"] += 1
    content = "" if content is None else str(content)
    raw = fake in content
    n["raw"] += raw
    entry = calls.get(tcid) or calls.get(norm_id(tcid)) or calls.get(uid_to_id.get(tool_call_uid))
    if entry is None:
        continue
    n["linked"] += 1
    if not call_ok(*entry):
        continue
    n["call"] += 1
    data = jload(content, None)
    if not isinstance(data, dict) or type(data.get("exit_code")) is not int or data["exit_code"] != 0:
        continue
    n["exit0"] += 1
    text = data.get("output")
    if raw or not isinstance(text, str) or marker not in text:
        continue
    forms = set(base_forms)
    f = redact_terminal_output(line, entry[1], force=True)
    if valid(f):
        forms.add(f)
    n["qualifying"] += any(f in text for f in forms)

print(out + " turn: mode=%s start=%d user_row=%d turn_rows=%d pane_runs=%d turn_tools=%d turn_linked=%d turn_call=%d"
      " turn_exit0=%d turn_raw=%d masked_forms=%d redactor=ok qualifying=%d"
      % (mode, start, urow, len(rows), len(run_panes), n["tools"], n["linked"], n["call"], n["exit0"], n["raw"],
         len(base_forms), n["qualifying"]))
