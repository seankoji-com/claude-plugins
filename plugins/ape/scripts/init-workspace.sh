#!/usr/bin/env bash
# Phase 0 helper for /ape:forage — creates the workspace and reports whether a
# fingerprint already exists, as a single preapprovable command (no ad hoc
# compound bash the permission system can't statically analyze).
set -euo pipefail

# Derive a disambiguated slug from remote origin + basename to avoid
# collisions between identically-named repos at different paths.
repo_basename="$(basename "$(pwd)")"
slug="$repo_basename"
if remote_url=$(git remote get-url origin 2>/dev/null); then
  # Normalize remote URL to extract owner/repo.
  # Supports https://, git@, ssh:// formats.
  owner_repo=$(echo "$remote_url" |
    sed -E \
      -e 's|^https?://[^/]+/||' \
      -e 's|^git@[^:]+:||' \
      -e 's|^ssh://[^/]+/[^/]+/||' \
      -e 's|\.git$||' \
      -e 's|/$||' |
    tr '/' '_')
  if [ -n "$owner_repo" ] && [ "$owner_repo" != "$repo_basename" ]; then
    slug="${owner_repo}__${repo_basename}"
  fi
fi
workspace="$HOME/tmp/repo-research/$slug"

# -- Migration: rename old-format workspace if it exists --
old_workspace="$HOME/tmp/repo-research/$repo_basename"
if [ "$old_workspace" != "$workspace" ] && [ -d "$old_workspace" ] && [ ! -d "$workspace" ]; then
  mkdir -p "$(dirname "$workspace")"
  mv "$old_workspace" "$workspace"
fi
# -- end migration --

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
