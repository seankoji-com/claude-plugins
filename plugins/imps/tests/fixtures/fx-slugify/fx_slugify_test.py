#!/usr/bin/env python3
"""Oracle for the fx-slugify fixture. Exit 0 == task done."""
import sys

from fx_slugify import slugify

CASES = [
    ("Hello World", "hello-world"),
    ("  Trailing and leading  ", "trailing-and-leading"),
    ("Mixed__Separators--Here", "mixed-separators-here"),
    ("Punctuation! Is? Gone.", "punctuation-is-gone"),
    ("", ""),
]
bad = [(s, want, slugify(s)) for s, want in CASES if slugify(s) != want]
if bad:
    for s, want, got in bad:
        print(f"slugify({s!r}) -> {got!r}, want {want!r}", file=sys.stderr)
    sys.exit(1)
print("ok slugify")
