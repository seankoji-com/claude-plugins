#!/usr/bin/env bash
# Oracle for the fx-sum fixture. Exit 0 == task done.
set -uo pipefail

fails=0
check() { # check <expected> <input lines...>
  local want="$1" got
  shift
  got="$(printf '%s\n' "$@" | bash ./fx-sum.sh)"
  if [ "$got" != "$want" ]; then
    echo "fx-sum.sh <<< '$*' -> '$got', want '$want'" >&2
    fails=$((fails + 1))
  fi
}

check 6 1 2 3
check 0 0
check -1 5 -6
check 100 100

[ "$fails" -eq 0 ] || exit 1
echo "ok fx-sum"
