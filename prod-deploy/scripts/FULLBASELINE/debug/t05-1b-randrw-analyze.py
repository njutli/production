#!/usr/bin/env python3
"""Offline 05-1b analyzer entry point.

The accepted 05-1 analyzer is the single implementation of the timing and
weighted-log rules.  This small adapter keeps 05-1b on that implementation;
it never runs a command or contacts an environment.  Volume BlockSize and
mount identity remain executor evidence, not a bandwidth-derived inference.
"""
from __future__ import annotations

import importlib.util
import pathlib
import sys

BASE_PATH = pathlib.Path(__file__).with_name("t05-1-randrw-analyze.py")
SPEC = importlib.util.spec_from_file_location("t051_randrw_analyzer", BASE_PATH)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("base analyzer unavailable")
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)


def main() -> None:
    # Preserve the base CLI (self-test/cell/batch) so historical 05-1
    # archives can be replayed byte-for-byte under the same rules.
    BASE.main()


if __name__ == "__main__":
    main()
