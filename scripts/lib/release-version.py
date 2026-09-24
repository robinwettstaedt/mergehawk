#!/usr/bin/env python3
"""Select the next 0.1.x version from published stable release tags on stdin."""

import re
import sys


TAG = re.compile(r"v0\.1\.(0|[1-9][0-9]*)-[0-9]{14}\Z")


def main() -> int:
    patches = []
    for line in sys.stdin:
        tag = line.rstrip("\n")
        if not tag:
            continue
        match = TAG.fullmatch(tag)
        if match is None:
            print(f"Unsupported or malformed published release tag: {tag}", file=sys.stderr)
            return 2
        patches.append(int(match.group(1)))

    if not patches:
        print("Cannot establish a 0.1.x baseline: no published stable release tags.", file=sys.stderr)
        return 2

    print(f"0.1.{max(patches) + 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
