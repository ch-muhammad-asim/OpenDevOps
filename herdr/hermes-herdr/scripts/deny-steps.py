#!/usr/bin/env python3
"""Read a Hermes approval panel (herdr `agent read` output) on stdin and print how many Down presses move the
selection from the current row to the row labelled exactly "Deny". Prints -1 if no panel/Deny row is found.
Works on the classic CLI panel ("❯ 1. Allow once ... 4. Deny") and on panels with extra rows such as
"No, and tell Hermes what to do instead", because it matches the label, not a fixed position."""
import re
import sys

LABELS = ("allow once", "allow for this session", "allow this session", "add to permanent allowlist",
          "always allow", "deny", "no, and tell hermes")
ROW = re.compile(r"^[\s│|]*(?P<sel>[❯›▸>])?\s*(?:\d+\.\s*)?(?P<label>[^│|]+?)\s*[│|]?\s*$")

lines = sys.stdin.read().splitlines()
# use the last panel on screen: scan backwards from the end to the last "Allow once" block
rows = []
for line in lines:
    m = ROW.match(line)
    if not m:
        continue
    label = m.group("label").strip().lower()
    if label.startswith(LABELS):
        if label.startswith("allow once"):
            rows = []                       # a new panel starts; keep only the latest one
        rows.append((bool(m.group("sel")), label))
sel = next((i for i, (s, _) in enumerate(rows) if s), None)
deny = next((i for i, (_, label) in enumerate(rows) if label == "deny"), None)
print(deny - sel if sel is not None and deny is not None and deny >= sel else -1)
