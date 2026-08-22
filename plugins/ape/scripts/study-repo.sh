#!/usr/bin/env bash
# Resolve and prepare one GitHub repository for /ape:study.
# Accepts a repository URL or a ref plus optional subdirectory:
#   https://github.com/owner/repo
#   https://github.com/owner/repo/tree/main
#   https://github.com/owner/repo/tree/main/path/to/component
set -euo pipefail

parse_target() {
  local raw="${1%/}" suffix="" repo_with_git=""

  if [[ "$raw" =~ [?#] ]]; then
    echo "study-repo: query strings and fragments are not supported" >&2
    return 1
  fi
  if ! [[ "$raw" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(/.*)?$ ]]; then
    echo "study-repo: target must be https://github.com/<owner>/<repo> or /tree/<ref>/<path>" >&2
    return 1
  fi

  owner="${BASH_REMATCH[1]}"
  repo_with_git="${BASH_REMATCH[2]}"
  suffix="${BASH_REMATCH[3]:-}"
  repo="${repo_with_git%.git}"
  tree_spec=""

  if [ -n "$suffix" ]; then
    if ! [[ "$suffix" =~ ^/tree/([A-Za-z0-9_.@%+,:=-]+(/[A-Za-z0-9_.@%+,:=-]+)*)$ ]]; then
      echo "study-repo: tree URLs must use /tree/<ref>[/<safe-path>]" >&2
      return 1
    fi
    tree_spec="${BASH_REMATCH[1]}"
    if [[ "$tree_spec" == -* ]]; then
      echo "study-repo: ref may not start with '-'" >&2
      return 1
    fi
    if [[ "/$tree_spec/" =~ /\.\.?/ ]]; then
      echo "study-repo: tree path may not contain . or .. segments" >&2
      return 1
    fi
  fi

  full_name="$owner/$repo"
  clone_url="https://github.com/$full_name"
  dir_name="${owner}__${repo}"

  printf 'full_name=%s\nclone_url=%s\ntree_spec=%s\n' \
    "$full_name" "$clone_url" "$tree_spec"
}

if [ "${__SOURCED__:-0}" = 1 ]; then
  return 0
fi

if [ "$#" -ne 1 ]; then
  echo "Usage: study-repo.sh https://github.com/<owner>/<repo>[/tree/<ref>[/<path>]]" >&2
  exit 1
fi

parse_target "$1" >/dev/null

if ! project_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
  project_root="$PWD"
fi
host_slug="$(basename "$project_root")"
workspace="$HOME/tmp/repo-research/$host_slug/studies/$dir_name"
repo_path="$workspace/repos/$dir_name"
mkdir -p "$workspace/repos" "$workspace/reports"
repos_root="$(cd "$workspace/repos" && pwd -P)"

if [ -e "$repo_path" ]; then
  if ! repo_real="$(cd "$repo_path" 2>/dev/null && pwd -P)"; then
    echo "study-repo: prepared clone is not a readable directory" >&2
    exit 1
  fi
  case "$repo_real" in
    "$repos_root"/*) ;;
    *)
      echo "study-repo: prepared clone escapes the study workspace" >&2
      exit 1
      ;;
  esac
fi

if [ -d "$repo_path/.git" ]; then
  if ! actual_remote="$(git -C "$repo_path" config --get remote.origin.url)"; then
    echo "study-repo: existing clone has no readable origin" >&2
    exit 1
  fi
  case "$actual_remote" in
    "$clone_url"|"$clone_url.git") ;;
    *)
      echo "study-repo: existing clone has unexpected origin: $actual_remote" >&2
      exit 1
      ;;
  esac
else
  git clone --depth 1 --filter=blob:none "$clone_url" "$repo_path"
fi

if ! repo_real="$(cd "$repo_path" 2>/dev/null && pwd -P)"; then
  echo "study-repo: prepared clone is not a readable directory" >&2
  exit 1
fi
case "$repo_real" in
  "$repos_root"/*) ;;
  *)
    echo "study-repo: prepared clone escapes the study workspace" >&2
    exit 1
    ;;
esac

ref="HEAD"
subdir=""
if [ -n "$tree_spec" ]; then
  candidate="$tree_spec"
  remainder=""
  while :; do
    if git -C "$repo_path" fetch --depth 1 -- origin "$candidate" >/dev/null 2>&1; then
      ref="$candidate"
      subdir="$remainder"
      break
    fi
    if [[ "$candidate" != */* ]]; then
      echo "study-repo: no ref in URL could be fetched: $tree_spec" >&2
      exit 1
    fi
    segment="${candidate##*/}"
    candidate="${candidate%/*}"
    remainder="$segment${remainder:+/$remainder}"
  done
elif ! git -C "$repo_path" fetch --depth 1 -- origin HEAD >/dev/null 2>&1; then
  echo "study-repo: default branch could not be fetched" >&2
  exit 1
fi

if ! git -C "$repo_path" checkout --detach FETCH_HEAD >/dev/null 2>&1; then
  echo "study-repo: checkout failed; the cached clone may contain local changes" >&2
  exit 1
fi

target_path="$repo_real"
if [ -n "$subdir" ]; then
  target_path="$repo_real/$subdir"
fi
if ! target_real="$(cd "$target_path" 2>/dev/null && pwd -P)"; then
  echo "study-repo: requested path does not exist at $ref: ${subdir:-.}" >&2
  exit 1
fi
case "$target_real" in
  "$repo_real"|"$repo_real"/*) ;;
  *)
    echo "study-repo: requested path escapes the cloned repository: ${subdir:-.}" >&2
    exit 1
    ;;
esac
target_path="$target_real"

revision="$(git -C "$repo_path" rev-parse HEAD)"
study_name="$dir_name"
if [ -n "$subdir" ]; then
  study_name="${dir_name}__${subdir//\//__}"
fi
fingerprint_path="$HOME/tmp/repo-research/$host_slug/fingerprint.md"
fingerprint_fresh=false
if [ -f "$fingerprint_path" ] && [ -n "$(find "$fingerprint_path" -type f -mtime -30 -print -quit 2>/dev/null)" ]; then
  fingerprint_fresh=true
fi

printf 'full_name=%s\nworkspace=%s\nrepo_path=%s\nref=%s\nsubdir=%s\ntarget_path=%s\nrevision=%s\nreport_path=%s\nfingerprint_path=%s\nfingerprint_fresh=%s\n' \
  "$full_name" "$workspace" "$repo_real" "$ref" "$subdir" "$target_path" "$revision" \
  "$workspace/reports/$study_name.md" "$fingerprint_path" "$fingerprint_fresh"
