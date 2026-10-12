#!/usr/bin/env bash
# Runs the complete stdlib-unittest Python suite under tests/python/.
# --coverage instruments the same enforcing run. Separate from tests/run.sh,
# which drives the bash-fixture harness for scripts/*.sh — this one is
# Python-only, no pytest, no new dependencies. Exits non-zero on any
# failure so it composes into CI the same way tests/run.sh does.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT" || exit 1
case "${1:-}" in
  '') [ "$#" -eq 0 ] || exit 2; exec python3 "$ROOT/tests/run-python.py" ;;
  --coverage) [ "$#" -eq 1 ] || exit 2; exec python3 -m coverage run "$ROOT/tests/run-python.py" ;;
  *) echo "Usage: tests/run-python.sh [--coverage]" >&2; exit 2 ;;
esac
