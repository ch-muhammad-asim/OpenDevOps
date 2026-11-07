"""Unit test for work/herdr-broker (no containers needed): feeds NUL-separated argv on stdin with the real herdr
replaced by /bin/echo; allowed calls must exit 0, refused ones 126.  Run: python3 scripts/broker-test.py"""
import subprocess, sys
import os
BROKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "work", "herdr-broker")
src = open(BROKER).read().replace('REAL = "/usr/local/bin/herdr"', 'REAL = "/bin/echo"')
import tempfile
T = os.path.join(tempfile.mkdtemp(), "broker-under-test.py")
open(T, "w").write(src)

def run(argv, raw=None):
    data = raw if raw is not None else b"".join(a.encode() + b"\0" for a in argv)
    p = subprocess.run([sys.executable, "-I", T], input=data, capture_output=True)
    return p.returncode

ALLOW = [
    ["pane", "list"], ["pane", "list", "--workspace", "w1"], ["pane", "get", "w1:p2"], ["pane", "layout"],
    ["pane", "split", "--direction", "right", "--no-focus", "--cwd", "/work/workspace"],
    ["pane", "split", "w1:p1", "--direction", "down"],
    ["pane", "run", "w1:p3", "make test; echo EXIT_$?_$((20+22))"],
    ["pane", "wait-output", "w1:p3", "--regex", "EXIT_[0-9]+_42", "--timeout", "300000"],
    ["pane", "read", "w1:p3", "--source", "recent-unwrapped", "--lines", "40"],
    ["pane", "rename", "w1:p3", "tests"],
    ["pane", "run", "w1:pF", "echo hi; echo EXIT_$?_$((20+22))"], ["pane", "read", "w1:pM", "--lines", "20"],
    ["pane", "get", "wA:p1Z"], ["pane", "list", "--workspace", "wB"],
]
DENY = [
    [], ["server", "stop"], ["agent", "send-keys", "hermes", "enter"], ["--machine", "x", "pane", "list"],
    ["--remote", "h", "pane", "list"], ["pane", "close", "w1:p1"], ["pane", "send-keys", "w1:p1", "enter"],
    ["pane", "send-text", "w1:p1", "x"], ["pane", "split", "--env", "A=B"], ["pane", "split", "--cwd", "/"],
    ["pane", "split", "--right-click", "x"], ["pane", "run", "w1:p1"], ["pane", "run", "w1:p1", "a", "b"],
    ["pane", "run", "--help", "x"], ["pane", "run", "w1:p1", "--foo"], ["pane", "get", "../x"],
    ["pane", "read", "w1:p1", "--format", "ansi"], ["pane", "wait-output", "w1:p1", "--regex", "x"],
    ["pane", "list", "--workspace=w1"], ["pane", "rename", "w1:p1", "a b;c"], ["pane", "report-agent", "w1:p1"],
    ["integration", "install", "hermes"], ["update"], ["config"], ["pane", "zoom", "w1:p1"],
    ["pane", "get", "w1:p-1"], ["pane", "get", "w1:p1;x"], ["pane", "get", "w1:pABCDEFG"], ["pane", "get", "x1:p1"],
    ["pane", "run", "w1:pF", "--help"], ["pane", "list", "--workspace", "w1:p1"],
]
bad = 0
for a in ALLOW:
    rc = run(a)
    if rc != 0: bad += 1; print("SHOULD ALLOW", rc, a)
for a in DENY:
    rc = run(a)
    if rc != 126: bad += 1; print("SHOULD DENY", rc, a)
for raw in [b"pane\0list", b"\xff\xfe\0", b"pane\0list\0" + b"x" * 70000 + b"\0"]:
    rc = run(None, raw)
    if rc != 126: bad += 1; print("SHOULD DENY raw", rc, raw[:20])
print(f"allow {len(ALLOW)}, deny {len(DENY)} + 3 malformed; failures: {bad}")
sys.exit(1 if bad else 0)
