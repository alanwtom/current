#!/usr/bin/env python3
"""Stamp the download page from the release artifact before site staging."""
import hashlib
import re
import sys
from pathlib import Path


def replace_one(html, pattern, replacement):
    updated, count = re.subn(pattern, lambda _: replacement, html)
    if count != 1:
        raise ValueError(f"expected one download field: {pattern}")
    return updated


def stamp(page, archive, version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("release version must use MAJOR.MINOR.PATCH")
    data = archive.read_bytes()
    checksum = hashlib.sha256(data).hexdigest()
    size = f"{len(data) / 1_000_000:.1f}"
    html = page.read_text()
    html = replace_one(html, r'<span class="dl-name">[^<]*</span>',
                       f'<span class="dl-name">Current {version}</span>')
    html = replace_one(html, r'<span class="dl-size">[^<]*</span>',
                       f'<span class="dl-size">{size}&nbsp;MB</span>')
    html = replace_one(html, r'<code id="sha-value">[^<]*</code>',
                       f'<code id="sha-value">{checksum}</code>')
    page.write_text(html)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("usage: stamp-download-page.py PAGE.html ARCHIVE.dmg VERSION")
        stamp(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
    except (ValueError, OSError) as error:
        sys.exit(str(error))
