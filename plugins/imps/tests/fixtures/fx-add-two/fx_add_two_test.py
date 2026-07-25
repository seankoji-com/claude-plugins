#!/usr/bin/env python3
"""Oracle for the fx-add-two fixture. Exit 0 == task done."""
import sys

from fx_add_two import add_two

CASES = [(0, 2), (1, 3), (-5, -3), (40, 42)]
bad = [(n, want, add_two(n)) for n, want in CASES if add_two(n) != want]
if bad:
    for n, want, got in bad:
        print(f"add_two({n}) -> {got}, want {want}", file=sys.stderr)
    sys.exit(1)
print("ok add_two")
