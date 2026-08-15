#!/usr/bin/env bash
# Phase 1 helper for gibbon-scout — runs one or more gh search queries as a
# single preapprovable command instead of a multi-line compound bash block.
#
# Usage: search-repos.sh "<query 1>" ["<query 2>" ...]
set -uo pipefail

# Track query exit codes. Policy: exit non-zero only if ALL queries fail.
# Partial results (some queries succeed, some fail) still provide value and exit 0.
# This keeps the script resilient to transient failures while catching cascading
# auth/network issues where every query fails.
failed_queries=0
total_queries=$#

for q in "$@"; do
  echo "=== $q ==="
  gh search repos "$q" --limit 15 --json fullName,description,stargazersCount,updatedAt,license,url 2>&1 || failed_queries=$((failed_queries + 1))
done

# Exit non-zero only if every query failed
if [ "$total_queries" -gt 0 ] && [ "$failed_queries" -eq "$total_queries" ]; then
  exit 1
fi
