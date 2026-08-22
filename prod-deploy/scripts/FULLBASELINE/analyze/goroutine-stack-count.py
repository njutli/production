#!/usr/bin/env python3
"""Count selected goroutine-stack signatures in Go debug=2 dumps.

Usage:
    python3 goroutine-stack-count.py pprof-goroutine-*.txt

Counts are per goroutine block, not raw line occurrences. Categories may overlap;
the output is evidence about queueing population, not a partition of all stacks.
"""
from __future__ import annotations

import hashlib
import pathlib
import re
import sys


PATTERNS = {
    "file_wait": "(*fileReader).waitForIO",
    "data_wait": "(*dataReader).Read",
    "rados_read": "_Cfunc_rados_read",
    "rados_stat": "_Cfunc_rados_stat",
}


def split_blocks(text: str) -> list[str]:
    return [b for b in re.split(r"(?m)(?=^goroutine \d+ \[)", text) if b.startswith("goroutine ")]


def count(path: pathlib.Path) -> list[str]:
    raw = path.read_bytes()
    blocks = split_blocks(raw.decode(errors="replace"))
    values = [str(sum(signature in block for block in blocks)) for signature in PATTERNS.values()]
    return [path.name, hashlib.md5(raw).hexdigest(), str(len(blocks)), *values]


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    print("file\tmd5\ttotal\t" + "\t".join(PATTERNS))
    for name in argv:
        path = pathlib.Path(name)
        if not path.is_file():
            print(f"MISSING: {path}", file=sys.stderr)
            return 2
        print("\t".join(count(path)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
