#!/usr/bin/env bash
# Gate-phase helper for /ape:forage — clones the selected candidates in the
# background and reports the tail of a log, as a single preapprovable command.
#
# Usage: clone-candidates.sh <workspace-dir> <url> <name> <sparse:0|1> [<url> <name> <sparse:0|1> ...]
# fail-soft: report every clone result, aggregate errors — continue to log tail even if some clones failed
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
  # Allowlist: only a plain https://github.com/<owner>/<repo>[.git] URL may
  # reach `git clone`. url/name are model-filled from untrusted third-party
  # repo content (README text, search results) — reject anything else before
  # it gets anywhere near git, rather than trust upstream quoting/schema
  # constraints alone.
  case "$url" in
  https://github.com/*) ;;
  *)
    echo "clone-candidates: invalid repository URL '$url' (must be https://github.com/<owner>/<repo>[.git])" >&2
    exit 1
    ;;
  esac
  if ! [[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$ ]]; then
    echo "clone-candidates: invalid repository URL '$url' (must be https://github.com/<owner>/<repo>[.git])" >&2
    exit 1
  fi
  case "$name" in
  '' | . | .. | */*)
    echo "clone-candidates: invalid repository name '$name'" >&2
    exit 1
    ;;
  esac
  if ! [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "clone-candidates: invalid repository name '$name' (must match ^[A-Za-z0-9_.-]+\$)" >&2
    exit 1
  fi
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
