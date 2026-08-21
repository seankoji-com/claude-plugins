#!/usr/bin/env bash
# Phase 1 helper for gibbon-scout — triages finalist repos with `gh repo view`
# as a single preapprovable command instead of a shell for-loop the
# permission system can't statically analyze.
#
# Usage: triage-repos.sh "<owner/repo 1>" ["<owner/repo 2>" ...]
# fail-soft: run every repo check even if some fail, report all results
set -uo pipefail

failed=0

for r in "$@"; do
  echo "=== $r ==="
  gh repo view "$r" --json isArchived,pushedAt,diskUsage,licenseInfo,description 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: gh repo view failed (exit $rc) for: $r" >&2
    failed=$((failed + 1))
  fi
done

if [ "$failed" -gt 0 ]; then
  exit 1
fi
