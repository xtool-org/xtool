#!/usr/bin/env python3
"""Rename generated Swift `Client` symbols to `DeveloperAPIClient`.

This replaces standalone occurrences of the identifier `Client` with
`DeveloperAPIClient` to avoid name clashes with other client types.  The
previous implementation relied on `sed -i ''`, which only works on macOS.
Using Python keeps the regeneration pipeline working on Linux systems such as
Ubuntu.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


PATTERN = re.compile(r"\bClient\b")


def rewrite_file(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    updated = PATTERN.sub("DeveloperAPIClient", original)
    if updated != original:
        path.write_text(updated, encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: rename-generated-client.py <swift-file> [<swift-file> ...]", file=sys.stderr)
        return 1

    for name in argv[1:]:
        rewrite_file(Path(name))

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
