#!/usr/bin/env python3
"""Prints one version's section from CHANGELOG.md.

Used by Scripts/release.sh so a release's notes and the changelog can never
disagree — there is one place release notes are written, and it is the file a
reader of the repository sees.

    Scripts/changelog-section.py 1.1.0

Exits non-zero if there is no section for that version, which stops a release
going out with no notes.
"""
import re
import sys
from pathlib import Path

def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <version>", file=sys.stderr)
        return 2
    wanted = sys.argv[1].lstrip("v")

    path = Path(__file__).resolve().parent.parent / "CHANGELOG.md"
    if not path.exists():
        print("no CHANGELOG.md", file=sys.stderr)
        return 1

    lines = path.read_text().splitlines()
    # Headings look like:  ## [1.1.0] — 2026-09-06   or   ## [Unreleased]
    heading = re.compile(r"^##\s+\[([^\]]+)\]")

    start = None
    for i, line in enumerate(lines):
        m = heading.match(line)
        if m and m.group(1).lstrip("v") == wanted:
            start = i + 1
            break
    if start is None:
        print(f"no section for {wanted} in CHANGELOG.md", file=sys.stderr)
        return 1

    end = len(lines)
    for i in range(start, len(lines)):
        if heading.match(lines[i]):
            end = i
            break

    body = "\n".join(lines[start:end]).strip()
    if not body:
        print(f"the section for {wanted} is empty", file=sys.stderr)
        return 1
    print(body)
    return 0

if __name__ == "__main__":
    sys.exit(main())
