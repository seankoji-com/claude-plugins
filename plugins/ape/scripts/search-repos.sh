#!/usr/bin/env bash
# Phase 1 helper for gibbon-scout — runs one or more gh search queries as a
# single preapprovable command instead of a multi-line compound bash block.
#
# Usage: search-repos.sh "<query 1>" ["<query 2>" ...]
# fail-soft: run every query even if some fail; exit 0 if any succeed, 1 only if all fail
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: search-repos.sh \"<query 1>\" [\"<query 2>\" ...]" >&2
  exit 2
fi

# Track query exit codes. Policy: exit non-zero only if ALL queries fail.
# Partial results (some queries succeed, some fail) still provide value and exit 0.
# This keeps the script resilient to transient failures while catching cascading
# auth/network issues where every query fails.
failed_queries=0
total_queries=$#

for q in "$@"; do
  output="$(gh search repos "$q" --limit 15 --json fullName,description,stargazersCount,updatedAt,license,url 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    echo "=== $q ==="
  else
    # Header carries a machine-checkable marker so a downstream parser can
    # skip this query's block instead of misreading the error text as data.
    echo "=== $q === (FAILED)"
    failed_queries=$((failed_queries + 1))
  fi
  printf '%s\n' "$output"
done

if [ "$failed_queries" -gt 0 ]; then
  echo "search-repos: $failed_queries of $total_queries queries failed" >&2
fi

# Exit non-zero only if every query failed
if [ "$total_queries" -gt 0 ] && [ "$failed_queries" -eq "$total_queries" ]; then
  exit 1
fi
