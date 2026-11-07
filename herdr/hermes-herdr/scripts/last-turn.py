# Runs inside herdr-hermes (stdin to the Hermes venv python), read-only on Hermes's state.db.
#   last-turn.py --max-row   print the highest messages rowid (0 for an empty table); e2e-test.sh ask() stores it as
#                            TURN_ROW before it sends a prompt, so later checks only see rows of that turn
#   last-turn.py N START     print the content of the last N stored assistant answers and tool results with
#                            rowid > START (the current turn only); START must be a non-negative integer
#   last-turn.py [N]         same over the whole history (no turn scope)
# The e2e checks read this next to the pane screen, because a TUI redraw can leave the newest answer out of
# `agent read` for a moment. Lines holding a real-key-shaped nvapi- value are never printed. Any error prints one
# "last-turn error:<type>" line and exits 1, so a check that looks for the turn's output finds nothing to match.
import os
import re
import sqlite3
import sys


def fail(msg):
    print("last-turn error:%s" % msg)
    sys.exit(1)


db = os.path.join(os.environ.get("HERMES_HOME", "/data/hermes"), "state.db")
try:
    con = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    if len(sys.argv) > 1 and sys.argv[1] == "--max-row":
        print(con.execute("SELECT COALESCE(MAX(rowid), 0) FROM messages").fetchone()[0])
        sys.exit(0)
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    sql = "SELECT role, content FROM messages WHERE role IN ('assistant','tool')"
    args = []
    if len(sys.argv) > 2:
        if not re.fullmatch(r"[0-9]+", sys.argv[2]):
            fail("start-row")
        sql += " AND rowid > ?"
        args.append(int(sys.argv[2]))
    rows = con.execute(sql + " ORDER BY rowid DESC LIMIT ?", args + [n]).fetchall()
except (sqlite3.Error, ValueError) as exc:
    fail(type(exc).__name__)
key = re.compile(r"nvapi-[A-Za-z0-9_-]{20,}")
for role, content in reversed(rows):
    for line in str(content or "").splitlines():
        if not key.search(line):
            print("%s: %s" % (role, line))
