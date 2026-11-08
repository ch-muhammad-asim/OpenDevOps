#!/usr/bin/env python3
"""Lightweight, network-free repository documentation quality gate."""

from pathlib import Path
import re
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]
REQUIRED = ("README.md", "LICENSE", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md")
LOCAL_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")


def main() -> int:
    errors: list[str] = []
    for filename in REQUIRED:
        if not (ROOT / filename).is_file():
            errors.append(f"Missing required root file: {filename}")

    files = [ROOT / filename for filename in ("README.md", "CONTRIBUTING.md", "SECURITY.md")]
    for path in files:
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8")
        for match in LOCAL_LINK.finditer(text):
            raw = match.group(1).strip().split()[0].strip("<>")
            if raw.startswith(("http:", "https:", "mailto:", "#", "data:")):
                continue
            dest = unquote(raw.split("#", 1)[0].split("?", 1)[0])
            if not dest:
                continue
            target = path.parent / dest
            if not target.exists():
                errors.append(f"{path.relative_to(ROOT)}: broken local link -> {raw}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("PASS: root OSS docs present and local links in root docs resolve")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
