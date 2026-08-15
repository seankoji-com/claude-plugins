#!/usr/bin/env bash
# Phase 0 helper for /ape:forage — creates the workspace and reports whether a
# fingerprint already exists, as a single preapprovable command (no ad hoc
# compound bash the permission system can't statically analyze).
# fail-fast: partial workspace init is worse than none
set -euo pipefail

slug="$(basename "$(pwd)")"
workspace="$HOME/tmp/repo-research/$slug"

mkdir -p "$workspace/repos" "$workspace/reports"

echo "slug=$slug"
echo "workspace=$workspace"
ls -la "$workspace"

fingerprint="$workspace/fingerprint.md"
if [ -f "$fingerprint" ]; then
  echo "fingerprint=$fingerprint"
  ls -la "$fingerprint"
else
  echo "fingerprint=none"
fi
