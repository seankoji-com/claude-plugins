#!/usr/bin/env bash
# install-agy.sh — install/uninstall this repo's generated Agy plugins
# (dist/agy/<plugin>/) via `agy plugin install`.
#
# Usage:
#   ./install-agy.sh [--ref <branch|tag|sha>]   install (default ref: master)
#   ./install-agy.sh --uninstall                reverse exactly what was installed
#   ./install-agy.sh --self-test                exercise the fail-closed path guard
#   ./install-agy.sh --help
#
# Install records the resolved commit SHA and every path it wrote into a
# manifest so --uninstall can reverse exactly that, and nothing else.
# docs/plans/cross-platform-compat.md is the contract; docs/platform-matrix.md
# (## PR 2 re-verification) is the measured-facts source — see AGY_INSTALL_MODE
# (real copy, not symlink — reinstall-to-update is safe) and the corrected
# install path (~/.gemini/config/plugins/<name>/, not ~/.gemini/antigravity-cli/).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
#
# AGY_INSTALL_TEST_CONFIG_DIR exists only so --self-test can point every path
# at a throwaway mktemp -d prefix instead of the operator's real config dir.
# It is not a supported end-user override.
# ---------------------------------------------------------------------------
AGY_CONFIG_DIR="${AGY_INSTALL_TEST_CONFIG_DIR:-$HOME/.gemini/config}"
AGY_PLUGIN_PREFIX="$AGY_CONFIG_DIR/plugins"
MANIFEST_PATH="$AGY_CONFIG_DIR/.seankoji-agy-manifest"

REF="master"
ACTION="install"

log() {
  printf '%s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
install-agy.sh — install/uninstall this repo's Agy plugins (dist/agy/*/)

  ./install-agy.sh [--ref <branch|tag|sha>]   install at ref (default: master)
  ./install-agy.sh --uninstall                reverse exactly what was installed
  ./install-agy.sh --self-test                exercise the fail-closed path guard
  ./install-agy.sh --help                     show this message

Installs are manifest-tracked at ~/.gemini/config/.seankoji-agy-manifest and
are idempotent: reinstalling overwrites in place (agy's own install is a real
copy, confirmed non-symlink — see docs/platform-matrix.md).
EOF
}

require_agy() {
  if ! command -v agy >/dev/null 2>&1; then
    log "install-agy.sh: 'agy' is not on PATH — install Agy first, then re-run."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Fail-closed path guard
#
# canon_path lexically normalizes a path (resolving "." and ".." components)
# without requiring the path to exist and without touching the filesystem, so
# it works uniformly for paths that exist, don't exist yet, or have already
# been removed. It deliberately does not resolve symlinks.
# ---------------------------------------------------------------------------
canon_path() {
  local p="$1" rest part stack=""
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  rest="$p"
  while [ -n "$rest" ]; do
    if [ "${rest#*/}" = "$rest" ]; then
      part="$rest"
      rest=""
    else
      part="${rest%%/*}"
      rest="${rest#*/}"
    fi
    case "$part" in
      "" | ".") : ;;
      "..") stack="${stack%/*}" ;;
      *) stack="$stack/$part" ;;
    esac
  done
  if [ -z "$stack" ]; then
    printf '/\n'
  else
    printf '%s\n' "$stack"
  fi
}

# path_within_prefix <prefix> <path> — true iff <path> resolves to <prefix>
# itself or something lexically underneath it. Fails closed: any path that
# does not clearly nest under the prefix is rejected.
path_within_prefix() {
  local prefix path
  prefix="$(canon_path "$1")"
  path="$(canon_path "$2")"
  prefix="${prefix%/}"
  [ -z "$prefix" ] && prefix="/"
  case "$path" in
    "$prefix") return 0 ;;
    "$prefix"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# remove_manifest_paths <manifest_file> <prefix>
# Reads "path:<value>" lines and removes each one, refusing (logging, never
# deleting) any path that does not resolve inside <prefix>. Uses
# `while IFS= read -r` and `rm -rf --` throughout so spaces in paths are
# handled correctly and nothing is unquoted-word-split.
remove_manifest_paths() {
  local manifest="$1" prefix="$2" line path refused=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      path:*) path="${line#path:}" ;;
      *) continue ;;
    esac
    [ -z "$path" ] && continue
    if path_within_prefix "$prefix" "$path"; then
      rm -rf -- "$path"
      log "install-agy.sh: removed $path"
    else
      log "install-agy.sh: REFUSING to remove path outside install prefix: $path"
      refused=$((refused + 1))
    fi
  done < "$manifest"
  return "$refused"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
resolve_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || {
    log "install-agy.sh: must be run from inside a git checkout of this repo"
    exit 1
  }
}

# extract_dist_agy <ref> <dest_dir> — checks out dist/agy/ at <ref> into
# <dest_dir> via `git archive`, without touching the caller's working tree.
# Prints the resolved commit SHA on stdout.
extract_dist_agy() {
  local ref="$1" dest="$2" repo_root sha archive_err tar_err
  repo_root="$(resolve_repo_root)"
  sha="$(git -C "$repo_root" rev-parse "$ref" 2>/dev/null)" || {
    log "install-agy.sh: unknown ref: $ref"
    exit 1
  }
  mkdir -p "$dest"
  # stderr from both halves of the pipe is captured (not silenced) so a corrupt
  # git object, a permission error, or a truncated/malformed tar stream is
  # reported as what it is, instead of being collapsed into the generic "no
  # dist/agy/ found" message that also covers the ordinary case (the ref
  # genuinely predates dist/agy/).
  archive_err="$(mktemp "${TMPDIR:-/tmp}/install-agy-archive-err.XXXXXX")"
  tar_err="$(mktemp "${TMPDIR:-/tmp}/install-agy-tar-err.XXXXXX")"
  if ! git -C "$repo_root" archive "$sha" -- dist/agy 2>"$archive_err" | tar -x -C "$dest" 2>"$tar_err"; then
    log "install-agy.sh: no dist/agy/ found at ref $ref ($sha) — nothing to install"
    [ -s "$archive_err" ] && log "install-agy.sh:   git archive: $(cat "$archive_err")"
    [ -s "$tar_err" ] && log "install-agy.sh:   tar: $(cat "$tar_err")"
    rm -f -- "$archive_err" "$tar_err"
    exit 1
  fi
  rm -f -- "$archive_err" "$tar_err"
  printf '%s\n' "$sha"
}

# ---------------------------------------------------------------------------
# __PLUGIN_ROOT__ substitution — the Agy half of the contract in
# docs/plans/cross-platform-compat.md ("no machine paths in the repo or dist/;
# absolute paths are written only by an installer, on the user's machine, at
# install time"). Agy's own `plugin install` is a plain copy, so this runs
# against the INSTALLED tree afterwards.
#
# Literal index/substr replacement, mirroring build/npm/lib/installer.js — not
# sed -- so that a resolved path containing /, &, or \ needs no escaping.
# Idempotent: after a successful pass no placeholder remains, so re-running is
# a no-op. File modes are preserved (cat > in place, not a fresh file) so
# shipped scripts stay executable.
# ---------------------------------------------------------------------------
substitute_plugin_root() {
  local installed_dir="$1" f tmp changed=0
  [ -d "$installed_dir" ] || return 0
  while IFS= read -r f; do
    grep -q '__PLUGIN_ROOT__' "$f" 2>/dev/null || continue
    tmp="$(mktemp)" || return 1
    awk -v root="$installed_dir" '
      {
        n = index($0, "__PLUGIN_ROOT__")
        while (n > 0) {
          $0 = substr($0, 1, n - 1) root substr($0, n + 15)
          n = index($0, "__PLUGIN_ROOT__")
        }
        print
      }
    ' "$f" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    cat "$tmp" > "$f" || { rm -f -- "$tmp"; return 1; }   # preserves $f's mode
    rm -f -- "$tmp"
    changed=$((changed + 1))
  done <<EOF
$(find "$installed_dir" -type f)
EOF
  [ "$changed" -gt 0 ] && log "install-agy.sh:   substituted __PLUGIN_ROOT__ in $changed file(s)"
  return 0
}

# finalize_partial_install <tmp_checkout> <written> <manifest_path> [exit_status] —
# the EXIT trap for install_cmd, invoked with its arguments interpolated into
# the trap string at trap-set time (not read from install_cmd's `local`s,
# which are already torn down by the time `set -e` fires this mid-function —
# see the trap-set call site for why).
#
# Always removes the checkout tmpdir. If $written still exists and recorded at
# least one `path:` line, it is finalized as the real manifest — covering both
# the happy path (a no-op; the success branch below already moved it) and an
# abort partway through the install loop, where some `agy plugin install`
# calls succeeded before one failed: those plugins are now on disk, and
# without this they would have no manifest entry at all (leaving them stuck
# with no record and no clean `--uninstall` path) while the tmp file leaked
# in $AGY_CONFIG_DIR forever. A $written with no `path:` lines (failure before
# anything installed) is just removed, so a real prior manifest is never
# clobbered with an empty one.
finalize_partial_install() {
  local tmp_checkout="$1" written="$2" manifest_path="$3"
  rm -rf -- "$tmp_checkout"
  if [ -f "$written" ]; then
    if grep -q '^path:' "$written" 2>/dev/null; then
      mv -f -- "$written" "$manifest_path"
      log "install-agy.sh: install stopped early — manifest reflects only the plugin(s) installed before the failure; re-run to finish or --uninstall to remove them"
    else
      rm -f -- "$written"
    fi
  fi
}

install_cmd() {
  require_agy

  mkdir -p "$AGY_CONFIG_DIR"

  local tmp_checkout sha written
  tmp_checkout="$(mktemp -d "${TMPDIR:-/tmp}/install-agy.XXXXXX")"
  written="$AGY_CONFIG_DIR/.seankoji-agy-manifest.tmp.$$"
  # Values are interpolated into the trap string now, not read from these
  # `local`s later — bash tears down a function's locals as soon as `set -e`
  # aborts mid-function, so a trap that referenced `$tmp_checkout`/`$written`
  # directly would see them unset by the time it actually runs.
  # shellcheck disable=SC2064
  trap "finalize_partial_install '$tmp_checkout' '$written' '$MANIFEST_PATH'" EXIT

  sha="$(extract_dist_agy "$REF" "$tmp_checkout")"

  if [ ! -d "$tmp_checkout/dist/agy" ]; then
    log "install-agy.sh: no dist/agy/ found at ref $REF — nothing to install"
    exit 1
  fi

  local plugin_dir plugin_name installed_count=0
  {
    printf 'ref=%s\n' "$REF"
    printf 'sha=%s\n' "$sha"
    printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$written"

  for plugin_dir in "$tmp_checkout"/dist/agy/*/; do
    [ -d "$plugin_dir" ] || continue
    plugin_name="$(basename "$plugin_dir")"
    log "install-agy.sh: installing $plugin_name"
    agy plugin install "${plugin_dir%/}"
    substitute_plugin_root "${AGY_PLUGIN_PREFIX%/}/$plugin_name"
    printf 'path:%s\n' "${AGY_PLUGIN_PREFIX%/}/$plugin_name" >> "$written"
    installed_count=$((installed_count + 1))
  done

  if [ "$installed_count" -eq 0 ]; then
    log "install-agy.sh: no plugin directories found under dist/agy/ at ref $REF"
    exit 1
  fi

  mv -f -- "$written" "$MANIFEST_PATH"
  log "install-agy.sh: installed $installed_count plugin(s) at $REF ($sha)"
  log "install-agy.sh: manifest: $MANIFEST_PATH"
}

# ---------------------------------------------------------------------------
# Uninstall — reverses exactly what the manifest records, via
# `agy plugin uninstall`, refusing any recorded path outside the install
# prefix before touching it.
# ---------------------------------------------------------------------------
uninstall_cmd() {
  require_agy

  if [ ! -f "$MANIFEST_PATH" ]; then
    log "install-agy.sh: no manifest at $MANIFEST_PATH — nothing to uninstall"
    exit 1
  fi

  local line written_path name failures=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      path:*) written_path="${line#path:}" ;;
      *) continue ;;
    esac
    [ -z "$written_path" ] && continue
    if ! path_within_prefix "$AGY_PLUGIN_PREFIX" "$written_path"; then
      log "install-agy.sh: REFUSING to uninstall path outside install prefix: $written_path"
      failures=$((failures + 1))
      continue
    fi
    name="$(basename "$written_path")"
    log "install-agy.sh: uninstalling $name"
    if ! agy plugin uninstall "$name"; then
      log "install-agy.sh: agy plugin uninstall failed for $name"
      failures=$((failures + 1))
    fi
  done < "$MANIFEST_PATH"

  if [ "$failures" -eq 0 ]; then
    rm -f -- "$MANIFEST_PATH"
    log "install-agy.sh: uninstall complete"
  else
    log "install-agy.sh: uninstall completed with $failures failure(s); manifest kept at $MANIFEST_PATH"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Self-test — proves the fail-closed path guard, entirely inside a mktemp -d
# prefix it creates and removes itself. Never touches the real install
# prefix and never requires `agy` to be installed.
# ---------------------------------------------------------------------------
self_test() {
  local failures=0 tmp_root

  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/install-agy-selftest.XXXXXX")"

  local prefix="$tmp_root/prefix/plugins"
  mkdir -p "$prefix"

  # Safe: inside the prefix, name contains a space.
  local safe_path="$prefix/spike plugin"
  mkdir -p "$safe_path"
  : > "$safe_path/marker.txt"

  # Unsafe: a sibling tree entirely outside the prefix.
  local unsafe_root="$tmp_root/outside"
  local unsafe_path="$unsafe_root/definitely not installed here"
  mkdir -p "$unsafe_path"
  : > "$unsafe_path/marker.txt"

  local manifest="$tmp_root/manifest"
  {
    printf 'ref=selftest\n'
    printf 'sha=0000000000000000000000000000000000test\n'
    printf 'path:%s\n' "$safe_path"
    printf 'path:%s\n' "$unsafe_path"
  } > "$manifest"

  remove_manifest_paths "$manifest" "$prefix" || true

  if [ -e "$safe_path" ]; then
    log "install-agy.sh --self-test: FAILED — space-containing in-prefix path was not removed: $safe_path"
    failures=$((failures + 1))
  fi
  if [ ! -e "$unsafe_path" ]; then
    log "install-agy.sh --self-test: FAILED — out-of-prefix path was deleted; fail-closed guard did not refuse: $unsafe_path"
    failures=$((failures + 1))
  fi

  # Boundary case: a path that merely starts with the prefix *string* but is
  # actually a sibling (no path-separator boundary) must also be refused.
  local lookalike="${prefix}-not-actually-inside/evil"
  mkdir -p "$(dirname "$lookalike")"
  : > "$lookalike"
  local manifest2="$tmp_root/manifest2"
  printf 'path:%s\n' "$lookalike" > "$manifest2"
  remove_manifest_paths "$manifest2" "$prefix" || true
  if [ ! -e "$lookalike" ]; then
    log "install-agy.sh --self-test: FAILED — prefix-lookalike path was deleted; guard is not boundary-safe: $lookalike"
    failures=$((failures + 1))
  fi

  rm -rf -- "$tmp_root"

  if [ "$failures" -gt 0 ]; then
    log "install-agy.sh --self-test: FAILED ($failures check(s))"
    return 1
  fi
  log "install-agy.sh --self-test: OK"
  return 0
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref)
      [ "$#" -ge 2 ] || { log "install-agy.sh: --ref requires a value"; exit 1; }
      REF="$2"
      shift 2
      ;;
    --uninstall)
      ACTION="uninstall"
      shift
      ;;
    --self-test)
      ACTION="self-test"
      shift
      ;;
    -h | --help)
      ACTION="help"
      shift
      ;;
    *)
      log "install-agy.sh: unrecognized argument: $1"
      exit 1
      ;;
  esac
done

case "$ACTION" in
  help)
    usage
    exit 0
    ;;
  self-test)
    self_test
    exit $?
    ;;
  uninstall)
    uninstall_cmd
    ;;
  install)
    install_cmd
    ;;
esac
