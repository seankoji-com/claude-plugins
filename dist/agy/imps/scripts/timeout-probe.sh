#!/usr/bin/env bash
# timeout-probe.sh — test-only entry point for run_with_timeout.
#
# The unit-test harness (tests/run.sh) sources exactly one target file and calls
# exactly one function. run_with_timeout lives in opencode-dispatch.sh (sourced
# below with __SOURCED__=1 so its CLI/dispatch logic does not execute) and takes
# multiple positional args (<seconds> <cmd...>), so this thin wrapper splits one
# positional arg on newlines into an array and passes it through as-is — no
# `eval`, no shell re-parsing of fixture content, each line an opaque argument
# regardless of any spaces or quote characters it contains. Fixture `arg` files
# are one argument per line accordingly (see tests/fixtures/unit/imps/
# opencode-dispatch.sh/run_with_timeout_probe/*/arg).
#
# Split with a newline IFS and `read`, not `mapfile`: `mapfile` is bash 4.0+,
# and stock macOS still ships bash 3.2 (the last GPLv2 release). Since this
# whole harness exists to drive the macOS-only Seatbelt sandbox, "works on the
# system bash" is not optional here — under 3.2 `mapfile` fails with
# `command not found`, leaving args empty and the probe silently measuring
# nothing.
# A here-string (`<<<`, bash 2.05b+) rather than an unquoted heredoc: the
# heredoc form would re-expand `$` and `\` in the fixture content, reopening
# exactly the shell re-parsing the `eval` this replaced was removed for.
# no set -e: a source/parse failure or a bad run_with_timeout call does not abort
# the script — it falls through to `echo "$?"`, so a caller-visible failure shows
# up as a printed exit code (e.g. 127 for a missing function), not as this probe
# itself dying. Callers must check the echoed value, not this script's own status.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
__SOURCED__=1 source "$SCRIPT_DIR/opencode-dispatch.sh"

run_with_timeout_probe() {
  local -a args
  local line
  args=()
  while IFS= read -r line; do
    args[${#args[@]}]="$line"
  done <<<"$1"
  run_with_timeout "${args[@]+"${args[@]}"}"
  echo "$?"
}
