#!/usr/bin/env bash
# Helper for /ape:clean — safely deletes ape's cloned repos or the full workspace.
# Usage: clean-ape-workspace.sh <workspace-dir> [--all] --confirm
#
# Without --all: deletes only the repos/ subdirectory.
# With --all:    deletes the entire workspace directory.
# --confirm is required as a safety gate.
set -euo pipefail

confirm=false
all=false
workspace=""

for arg in "$@"; do
  case "$arg" in
  --confirm) confirm=true ;;
  --all) all=true ;;
  *) workspace="$arg" ;;
  esac
done

if [ -z "$workspace" ]; then
  echo "ERROR: workspace directory required" >&2
  echo "Usage: $0 <workspace-dir> [--all] --confirm" >&2
  exit 1
fi

if [ "$confirm" != true ]; then
  echo "ERROR: --confirm flag required as safety gate" >&2
  echo "Usage: $0 <workspace-dir> [--all] --confirm" >&2
  exit 1
fi

# Canonicalize the workspace path for comparison
workspace_real="$(cd "$workspace" 2>/dev/null && pwd -P || true)"
allowed_real="$(cd "$HOME/tmp/repo-research" 2>/dev/null && pwd -P || true)"

if [ -z "$workspace_real" ] || [ -z "$allowed_real" ]; then
  echo "ERROR: cannot resolve workspace or allowed base directory" >&2
  exit 1
fi

# Path traversal guard: workspace must be a subdirectory of $HOME/tmp/repo-research/
case "$workspace_real" in
"$allowed_real" | "$allowed_real/"*) ;;
*)
  echo "ERROR: workspace must be under $HOME/tmp/repo-research/" >&2
  echo "  got: $workspace_real" >&2
  exit 1
  ;;
esac

# Minimum: workspace must contain at least one char after the allowed base (not the root itself)
if [ "$workspace_real" = "$allowed_real" ]; then
  echo "ERROR: refusing to operate on $HOME/tmp/repo-research/ itself (must be a project subdirectory)" >&2
  exit 1
fi

if [ "$all" = true ]; then
  echo "Removing entire workspace: $workspace_real"
  rm -rf "$workspace_real"
  echo "Done. Workspace removed."
else
  repos_dir="$workspace_real/repos"
  if [ ! -d "$repos_dir" ]; then
    echo "No repos/ directory at $workspace_real — nothing to clean."
    exit 0
  fi
  echo "Removing repos/ from: $workspace_real"
  rm -rf "$repos_dir"
  echo "Done. repos/ removed."
fi
