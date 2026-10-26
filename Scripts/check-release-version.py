#!/usr/bin/env python3
"""Reject a release that existing installs would treat as old. No network I/O."""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def version_parts(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        raise ValueError(f"version must contain only numbers and dots: {value}")
    parts = [int(part) for part in value.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def item_value(item, name):
    element = item.find(f"{{{SPARKLE}}}{name}")
    if element is not None:
        return element.text or ""
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("feed item has no enclosure")
    return enclosure.get(f"{{{SPARKLE}}}{name}", "")


def check(version, build, feed):
    if not re.fullmatch(r"[0-9]+", build) or int(build) < 1:
        raise ValueError("build must be a positive integer")
    items = ET.parse(feed).findall("./channel/item")
    if not items:
        raise ValueError("live feed has no releases")
    for item in items:
        old_build = item_value(item, "version")
        old_version = item_value(item, "shortVersionString")
        if version_parts(build) <= version_parts(old_build):
            raise ValueError(f"build {build} must exceed live build {old_build}; set CURRENT_BUILD_VERSION")
        if version_parts(version) <= version_parts(old_version):
            raise ValueError(f"version {version} must exceed live version {old_version}")


def main():
    if len(sys.argv) != 4:
        raise ValueError(f"usage: {Path(sys.argv[0]).name} VERSION BUILD FEED.xml")
    check(*sys.argv[1:])
    print("Release version and build exceed the live feed.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, ET.ParseError, OSError) as error:
        sys.exit(str(error))
