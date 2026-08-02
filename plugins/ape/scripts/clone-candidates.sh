#!/usr/bin/env bash
# Gate-phase helper for /ape:forage — clones the selected candidates in the
# background and reports the tail of a log, as a single preapprovable command.
#
# Usage: clone-candidates.sh <workspace-dir> <url> <name> <sparse:0|1> [<url> <name> <sparse:0|1> ...]
set -uo pipefail

workspace="$1"
shift

mkdir -p "$workspace/repos"
log="$workspace/repos/clone.log"
: >"$log"
pids=()

while [ "$#" -ge 3 ]; do
  url="$1"
  name="$2"
  sparse="$3"
  shift 3
  case "$name" in
  '' | . | .. | */*)
    echo "clone-candidates: invalid repository name '$name'" >&2
    exit 1
    ;;
  esac
  if [ "$sparse" = "1" ]; then
    git clone --depth 1 --filter=blob:none --sparse "$url" "$workspace/repos/$name" >>"$log" 2>&1 &
  else
    git clone --depth 1 --filter=blob:none "$url" "$workspace/repos/$name" >>"$log" 2>&1 &
  fi
  pids[${#pids[@]}]=$!
done

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done
echo "--- clone.log (tail) ---"
tail -n 40 "$log"
exit "$status"
