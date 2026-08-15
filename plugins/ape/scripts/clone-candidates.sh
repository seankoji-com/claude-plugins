#!/usr/bin/env bash
# Gate-phase helper for /ape:forage — clones the selected candidates in the
# background and reports the tail of a log, as a single preapprovable command.
#
# Usage: clone-candidates.sh <workspace-dir> <url> <name> <sparse:0|1> [<url> <name> <sparse:0|1> ...]
#
# Two passes:
#   1. Validate every (url, name, sparse) triple up front. Validation is
#      all-or-nothing: if any triple is invalid, exit 1 immediately without
#      touching the filesystem — no directory is created, no clone is
#      launched, the workspace is left exactly as it was.
#   2. Only once every triple has validated does any `git clone` run. From
#      here on it's fail-soft: every clone is attempted regardless of
#      whether earlier ones failed, and results are aggregated into a single
#      exit status after all clones finish, with the log tail printed
#      regardless.
set -uo pipefail

workspace="$1"
shift
args=("$@")

# keep in sync with: FULL_NAME_PATTERN / GITHUB_URL_PATTERN in ape-forage.workflow.js
# Allowlist: only a plain https://github.com/<owner>/<repo>[.git] URL may
# reach `git clone`. url/name are model-filled from untrusted third-party
# repo content (README text, search results) — reject anything else before
# it gets anywhere near git, rather than trust upstream quoting/schema
# constraints alone.
url_re='^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?$'
name_re='^[A-Za-z0-9_.-]+$'

# --- Pass 1: validate every triple before touching the filesystem ---------
# bash-3.2-safe: plain array indexing ("${args[$i]}"), no ${!i}-style
# indirection (that needs bash 4.3+).
if [ "$#" -eq 0 ] || [ $(($# % 3)) -ne 0 ]; then
  echo "clone-candidates: arguments must come in (url, name, sparse) triples" >&2
  exit 1
fi

i=0
while [ "$i" -lt "${#args[@]}" ]; do
  url="${args[$i]}"
  name="${args[$((i + 1))]}"
  sparse="${args[$((i + 2))]}"

  if ! [[ "$url" =~ $url_re ]]; then
    echo "clone-candidates: invalid repository URL '$url' (must be https://github.com/<owner>/<repo>[.git])" >&2
    exit 1
  fi
  if ! [[ "$name" =~ $name_re ]]; then
    echo "clone-candidates: invalid repository name '$name' (must match ^[A-Za-z0-9_.-]+\$)" >&2
    exit 1
  fi
  if [ "$sparse" != "0" ] && [ "$sparse" != "1" ]; then
    echo "clone-candidates: invalid sparse flag '$sparse' for '$name' (must be 0 or 1)" >&2
    exit 1
  fi

  i=$((i + 3))
done

# --- Pass 2: every triple validated — safe to start cloning ---------------
mkdir -p "$workspace/repos"
log="$workspace/repos/clone.log"
: >"$log"
pids=()

i=0
while [ "$i" -lt "${#args[@]}" ]; do
  url="${args[$i]}"
  name="${args[$((i + 1))]}"
  sparse="${args[$((i + 2))]}"

  if [ "$sparse" = "1" ]; then
    git clone --depth 1 --filter=blob:none --sparse "$url" "$workspace/repos/$name" >>"$log" 2>&1 &
  else
    git clone --depth 1 --filter=blob:none "$url" "$workspace/repos/$name" >>"$log" 2>&1 &
  fi
  pids[${#pids[@]}]=$!

  i=$((i + 3))
done

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done
echo "--- clone.log (tail) ---"
tail -n 40 "$log"
exit "$status"
