#!/usr/bin/env python3
"""Select the next MAJOR.MINOR.PATCH version from published stable release tags on stdin."""

import re
import sys


TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
BUMPS = ("patch", "minor", "major")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in BUMPS:
        print("Usage: release-version.py <patch|minor|major>", file=sys.stderr)
        return 2
    bump = sys.argv[1]

    versions = []
    for line in sys.stdin:
        tag = line.rstrip("\n")
        if not tag:
            continue
        match = TAG.fullmatch(tag)
        if match is None:
            print(f"Unsupported or malformed published release tag: {tag}", file=sys.stderr)
            return 2
        versions.append(tuple(int(part) for part in match.groups()))

    if not versions:
        print("1.0.0")
        return 0

    major, minor, patch = max(versions)
    if bump == "patch":
        patch += 1
    elif bump == "minor":
        minor, patch = minor + 1, 0
    else:
        major, minor, patch = major + 1, 0, 0
    print(f"{major}.{minor}.{patch}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
