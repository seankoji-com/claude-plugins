#!/usr/bin/env bash
# Resolve and prepare one GitHub repository for /ape:study.
# Accepts a repository URL or a single-segment ref plus subdirectory:
#   https://github.com/owner/repo
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
  ref=""
  subdir=""

  if [ -n "$suffix" ]; then
    if ! [[ "$suffix" =~ ^/tree/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.@%+,:=-]+(/[A-Za-z0-9_.@%+,:=-]+)*)$ ]]; then
      echo "study-repo: subdirectory URLs must use /tree/<single-segment-ref>/<safe-path>" >&2
      return 1
    fi
    ref="${BASH_REMATCH[1]}"
    subdir="${BASH_REMATCH[2]}"
    if [[ "/$subdir/" =~ /\.\.?/ ]]; then
      echo "study-repo: subdirectory may not contain . or .. path segments" >&2
      return 1
    fi
  fi

  full_name="$owner/$repo"
  clone_url="https://github.com/$full_name"
  dir_name="${owner}__${repo}"

  printf 'full_name=%s\nclone_url=%s\nref=%s\nsubdir=%s\n' \
    "$full_name" "$clone_url" "$ref" "$subdir"
}

if [ "${__SOURCED__:-0}" = 1 ]; then
  return 0
fi

if [ "$#" -ne 1 ]; then
  echo "Usage: study-repo.sh https://github.com/<owner>/<repo>[/tree/<ref>/<path>]" >&2
  exit 1
fi

parse_target "$1"

host_slug="$(basename "$(pwd)")"
workspace="$HOME/tmp/repo-research/$host_slug/studies/$dir_name"
repo_path="$workspace/repos/$dir_name"
mkdir -p "$workspace/repos" "$workspace/reports"

if [ -d "$repo_path/.git" ]; then
  actual_remote="$(git -C "$repo_path" config --get remote.origin.url)"
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

git -C "$repo_path" fetch --depth 1 origin "${ref:-HEAD}"
git -C "$repo_path" checkout --detach FETCH_HEAD

target_path="$repo_path"
if [ -n "$subdir" ]; then
  target_path="$repo_path/$subdir"
fi
if [ ! -d "$target_path" ]; then
  echo "study-repo: requested path does not exist at ${ref:-default branch}: ${subdir:-.}" >&2
  exit 1
fi

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

printf 'workspace=%s\nrepo_path=%s\ntarget_path=%s\nrevision=%s\nreport_path=%s\nfingerprint_path=%s\nfingerprint_fresh=%s\n' \
  "$workspace" "$repo_path" "$target_path" "$revision" \
  "$workspace/reports/$study_name.md" "$fingerprint_path" "$fingerprint_fresh"
