#!/usr/bin/env bash
# dist-lint.sh — the only mechanical gate on generated output (dist/).
#
# Contract: docs/plans/cross-platform-compat.md, item 9. The reviewer diff and the
# persona panel both exclude `dist/` (imps-run.workflow.js hardcodes
# `git diff … -- ':!*lock*' ':!dist'`), so nothing else in this repo's review path ever
# looks at what generate.py produced. This script is the substitute: it re-asserts every
# invariant build/generate.py is supposed to guarantee, independently, against the
# committed tree — plus three invariants ("out-of-prefix uninstall path", "frozen Claude
# sources", "README marker vs. generation-manifest agreement") that get NO enforcement
# anywhere else in this run. "frozen Claude sources" is opt-in (--check-frozen-sources),
# not part of the default lint CI runs on every push/PR — see that flag's --help text.
#
# Usage:
#   build/dist-lint.sh                 # lint the whole committed dist/ + repo state
#   build/dist-lint.sh --scope <name>  # lint one plugin's slice of dist/ (+ its README)
#   build/dist-lint.sh --self-test     # prove each invariant fails on a broken fixture
#                                       # and passes on a correct one (no repo mutation)
#
# The README-marker check only fails a README that HAS a `<!-- PLATFORM-SUPPORT: -->`
# marker and disagrees with build/generation-manifest.json. A missing marker is not this
# script's failure (that's a separate acceptance item, owned by whichever task adds the
# markers) — see check_readme_marker below. The out-of-prefix-uninstall-path check is
# equally lenient when no uninstaller script exists yet in this worktree: with nothing to
# scan, there is nothing to fail. Both are exercised for real by --self-test regardless of
# what does or doesn't exist in the working tree, via synthetic fixtures under mktemp.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: build/dist-lint.sh [--scope <plugin>] [--check-frozen-sources] [--self-test]

  (no flags)               lint the committed dist/ and repo state, whole-tree
  --scope <plugin>         lint just that plugin's slice of dist/ (+ its README marker)
  --check-frozen-sources   also diff plugins/*/{commands,agents,scripts} (or, with
                            --scope, just that plugin's slice) against origin/master and
                            fail on anything beyond the named exceptions. Opt-in and NOT
                            part of the default lint: it compares against a moving base
                            ref, so wired into every push/PR it would reject any future,
                            unrelated change to a command/agent/script file. Use it once,
                            e.g. right before merging a change that must prove it left
                            Claude sources untouched.
  --self-test              prove each of the 10 invariants below fails on a broken fixture
                            and passes on a correct one; touches nothing under $ROOT
  -h, --help               this text

Invariants checked: regen-diff, unsubstituted-ref, absolute-path, manifest, budget,
mirrored-block, gate-stripped, uninstall-prefix, frozen-sources, readme-marker.
EOF
}

# --------------------------------------------------------------------------- utilities

# LC_ALL=C so filesystem-enumeration order never depends on locale — mirrors
# generate.py's own determinism contract ("every filesystem enumeration in sorted()").
sorted() { LC_ALL=C sort; }

resolve_base_ref() {
  # Prefer origin/master (what the contract's own Verify: lines compare against); fall
  # back to a local master branch for a repo with no configured remote (self-test
  # fixtures are exactly that case). Never invents a ref beyond these two.
  local root="$1"
  if (cd "$root" && git rev-parse --verify origin/master >/dev/null 2>&1); then
    echo "origin/master"
    return 0
  fi
  if (cd "$root" && git rev-parse --verify master >/dev/null 2>&1); then
    echo "master"
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------ 1. regen-diff
#
# dist/ must be exactly what a fresh `python3 build/generate.py` produces from the
# current plugins/ + build/ sources. Runs the generator in an isolated mktemp copy of the
# generator's inputs (never the real dist/ — task 2 does not own dist/'s content; see
# AGENTS.md's Global Constraints) and diffs its output against the dist/ under test.

check_regen_diff() {
  local repo_root="$1" dist_under_test="$2" scope="${3:-}"
  local tmp
  tmp="$(mktemp -d)" || {
    echo "regen-diff: mktemp -d failed — could not create a scratch dir to regenerate into" >&2
    return 1
  }
  mkdir -p "$tmp/build" "$tmp/plugins"
  # Check the actual exit status ($? from the command substitution below, not "is
  # stderr non-empty") -- a warning-with-exit-0 `cp` (macOS occasionally writes one for
  # xattr/ACL metadata it can't fully preserve) must not fail this lint, and a silent
  # non-zero `cp` with no stderr output must not slip past it.
  local cp_err cp_status
  cp_err="$(cp -R "$repo_root/build/." "$tmp/build/" 2>&1 1>/dev/null)"
  cp_status=$?
  if [ "$cp_status" -ne 0 ]; then
    echo "regen-diff: cp -R $repo_root/build/. failed (exit $cp_status):" >&2
    [ -n "$cp_err" ] && echo "$cp_err" >&2
    rm -rf "$tmp"
    return 1
  fi
  cp_err="$(cp -R "$repo_root/plugins/." "$tmp/plugins/" 2>&1 1>/dev/null)"
  cp_status=$?
  if [ "$cp_status" -ne 0 ]; then
    echo "regen-diff: cp -R $repo_root/plugins/. failed (exit $cp_status):" >&2
    [ -n "$cp_err" ] && echo "$cp_err" >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp/dist"

  local gen_out status=0
  if [ -n "$scope" ]; then
    gen_out="$(cd "$tmp" && python3 build/generate.py --only "$scope" 2>&1)"
  else
    gen_out="$(cd "$tmp" && python3 build/generate.py 2>&1)"
  fi
  if [ $? -ne 0 ]; then
    echo "regen-diff: generate.py failed:" >&2
    echo "$gen_out" >&2
    rm -rf "$tmp"
    return 1
  fi
  if [ ! -d "$tmp/dist" ]; then
    echo "regen-diff: generate.py produced no dist/" >&2
    rm -rf "$tmp"
    return 1
  fi

  local f rel
  while IFS= read -r f; do
    rel="${f#"$tmp"/dist/}"
    if ! diff -q "$f" "$dist_under_test/$rel" >/dev/null 2>&1; then
      echo "regen-diff: dist/$rel differs from (or is missing from) a fresh regeneration" >&2
      status=1
    fi
  done < <(find "$tmp/dist" -type f 2>/dev/null | sorted)

  if [ -z "$scope" ] && [ -d "$dist_under_test" ]; then
    while IFS= read -r f; do
      rel="${f#"$dist_under_test"/}"
      if [ ! -f "$tmp/dist/$rel" ]; then
        echo "regen-diff: dist/$rel exists but a fresh generate.py does not produce it" >&2
        status=1
      fi
    done < <(find "$dist_under_test" -type f 2>/dev/null | sorted)
  fi

  rm -rf "$tmp"
  return $status
}

# ------------------------------------------------------------- 2. unsubstituted-ref
#
# The Claude-side env var name must never leak into dist/ — every bundled-script path
# reference must already be the __PLUGIN_ROOT__ placeholder (contract: 'Machine paths').

check_unsubstituted_ref() {
  local dist="$1"
  local hits
  hits="$(grep -rl 'CLAUDE_PLUGIN_ROOT' "$dist" 2>/dev/null | sorted || true)"
  if [ -n "$hits" ]; then
    echo "unsubstituted-ref: CLAUDE_PLUGIN_ROOT leaked into dist/ in:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- 3. absolute-path
#
# No absolute machine path and no $HOME reference anywhere in dist/ — resolution happens
# only at install time, on the user's machine (contract: 'Machine paths — the invariant').

check_absolute_path() {
  local dist="$1"
  local hits
  hits="$(grep -rlE '(^|[^_[:alnum:]])/(Users|home|opt|usr/local)/|[$]HOME' "$dist" 2>/dev/null | sorted || true)"
  if [ -n "$hits" ]; then
    echo "absolute-path: absolute machine path or \$HOME leaked into dist/ in:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
  return 0
}

# --------------------------------------------------------------------- 4. manifest
#
# Every dist/agy/<plugin>/plugin.json carries name + description and never version
# (contract: 'Versioning' — version-bump.yml must never be able to desync dist/).

check_manifest() {
  local dist="$1" f err status=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! err="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("name"), "missing name"
assert d.get("description"), "missing description"
assert "version" not in d, "carries a version field"
' "$f" 2>&1)"; then
      echo "manifest: $f: $err" >&2
      status=1
    fi
  done < <(find "$dist" -path '*/agy/*/plugin.json' 2>/dev/null | sorted)
  return $status
}

# ----------------------------------------------------------------------- 5. budget
#
# CLAUDE.md <= 200 lines, AGENTS.md <= 300, GEMINI.md <= 50 (dist/, build/ exempt —
# contract: 'Audit log' section's budget paragraph).

check_budget() {
  local root="$1" status=0
  local claude="$root/CLAUDE.md" agents="$root/AGENTS.md" gemini="$root/GEMINI.md"
  local n
  if [ -f "$claude" ]; then
    n="$(wc -l < "$claude" | tr -d ' ')"
    if [ "$n" -gt 200 ]; then
      echo "budget: CLAUDE.md has $n lines, budget is 200" >&2
      status=1
    fi
  fi
  if [ -f "$agents" ]; then
    n="$(wc -l < "$agents" | tr -d ' ')"
    if [ "$n" -gt 300 ]; then
      echo "budget: AGENTS.md has $n lines, budget is 300" >&2
      status=1
    fi
  fi
  if [ -f "$gemini" ]; then
    n="$(wc -l < "$gemini" | tr -d ' ')"
    if [ "$n" -gt 50 ]; then
      echo "budget: GEMINI.md has $n lines, budget is 50" >&2
      status=1
    fi
  fi
  return $status
}

# ------------------------------------------------------------- 6. mirrored-block
#
# CLAUDE.md and AGENTS.md must carry a byte-identical SHARED-MAINTAINER-BLOCK (contract:
# 'Maintainer invariants stay auto-loaded'). Neither file carrying the block yet is not
# this check's failure — that's task 10/31's job; only a *mismatch* is.

check_mirrored_block() {
  local root="$1" status=0
  local claude="$root/CLAUDE.md" agents="$root/AGENTS.md"
  local c_has=0 a_has=0
  [ -f "$claude" ] && grep -q 'BEGIN SHARED-MAINTAINER-BLOCK' "$claude" 2>/dev/null && c_has=1
  [ -f "$agents" ] && grep -q 'BEGIN SHARED-MAINTAINER-BLOCK' "$agents" 2>/dev/null && a_has=1
  if [ "$c_has" = 0 ] && [ "$a_has" = 0 ]; then
    return 0
  fi
  if [ "$c_has" != "$a_has" ]; then
    echo "mirrored-block: SHARED-MAINTAINER-BLOCK present in only one of CLAUDE.md/AGENTS.md" >&2
    return 1
  fi
  if ! diff -u \
      <(sed -n '/BEGIN SHARED-MAINTAINER-BLOCK/,/END SHARED-MAINTAINER-BLOCK/p' "$claude") \
      <(sed -n '/BEGIN SHARED-MAINTAINER-BLOCK/,/END SHARED-MAINTAINER-BLOCK/p' "$agents") \
      >&2; then
    echo "mirrored-block: SHARED-MAINTAINER-BLOCK differs between CLAUDE.md and AGENTS.md" >&2
    status=1
  fi
  return $status
}

# ------------------------------------------------------------- 7. gate-stripped
#
# Claude Workflow dispatch mechanics (the `agent()` call, the `isolation: 'worktree'`
# option) must never appear in generated output — dispatch prose there comes from
# build/overrides/ instead (contract, Phase C).

check_gate_stripped() {
  local dist="$1"
  local hits
  hits="$(grep -rlE "agent\(\)|isolation: 'worktree'" "$dist" 2>/dev/null | sorted || true)"
  if [ -n "$hits" ]; then
    echo "gate-stripped: Claude Workflow gate mechanics leaked into generated output:" >&2
    printf '%s\n' "$hits" >&2
    return 1
  fi
  return 0
}

# ------------------------------------------------------- 8. out-of-prefix uninstall path
#
# "Uninstallers fail closed on paths" (AGENTS.md Global Constraints): every manifest-
# driven removal must reject a path outside its install prefix before deleting, and use
# `rm -f --` / `rm -rf --` (never a bare `rm -f $var`, which lets a leading '-' or a
# hostile filename be parsed as a flag). This is a static/textual heuristic, not a
# behavioral test of any particular script — install-agy.sh (task 6) and the npm bin CLI
# (task 7) get their own behavioral --self-test for the real thing; this is the lint-time
# backstop that a removal-capable script was written with the fail-closed shape at all.
#
# A script only gets scanned if it actually contains an `rm -f`/`rm -rf` call — a script
# with nothing to remove has nothing for this invariant to enforce, so real-repo scanning
# is naturally lenient about scripts that don't exist yet in a worktree that precedes the
# task that adds them (mirrors the README-marker check's leniency, item 9's own text).

_unsafe_rm_lines() {
  # rm -f/-rf invoked without a literal `--` end-of-options marker immediately after the
  # flag. Deliberately NOT `grep -v -- '--'` on the whole line -- that excludes a line
  # from "unsafe" if `--` appears ANYWHERE on it, including inside an unrelated trailing
  # comment (e.g. `rm -f "$path"  # see --help`), which is a false negative: the `rm`
  # invocation itself still has no end-of-options marker. Match the exact
  # flag-then-`--`-marker shape instead (mirrors the positive check a few lines below).
  # A whole-line `#` comment (e.g. `# ... via \`rm -rf --\`` in a doc comment) is prose,
  # not an invocation, and is excluded the same way the JS/Python frozen-sources filters
  # above exclude comment-only diff lines -- grep -n's own "N:" prefix is stripped first
  # so the `^[[:space:]]*#` anchor lines up against the real line content.
  grep -nE '(^|[^A-Za-z0-9_])rm[[:space:]]+-[A-Za-z]*f[A-Za-z]*([[:space:]]|$)' "$1" 2>/dev/null \
    | grep -vE '(^|[^A-Za-z0-9_])rm[[:space:]]+-[A-Za-z]*f[A-Za-z]*[[:space:]]+--([[:space:]]|$)' \
    | grep -vE '^[0-9]+:[[:space:]]*#'
}

_has_prefix_guard() {
  # A case block with an arm matching "$<...PREFIX...>"* (prefix-membership test) whose
  # wildcard arm rejects (exit/return non-zero) — the fail-closed shape.
  awk '
    /case[ \t]+.*in[ \t]*$/ { in_case=1; has_prefix_arm=0; has_reject=0; in_wild=0 }
    in_case && /"\$[A-Za-z0-9_]*[Pp][Rr][Ee][Ff][Ii][Xx][A-Za-z0-9_]*"\/?\*\)/ { has_prefix_arm=1 }
    in_case && /^[ \t]*\*\)/ { in_wild=1 }
    in_case && in_wild && /(exit|return)[ \t]+[1-9]/ { has_reject=1 }
    in_case && /esac/ {
      if (has_prefix_arm && has_reject) { found=1 }
      in_case=0; in_wild=0
    }
    END { exit(found ? 0 : 1) }
  ' "$1" 2>/dev/null
}

check_uninstall_prefix_file() {
  local file="$1"
  local unsafe
  unsafe="$(_unsafe_rm_lines "$file" || true)"
  if [ -n "$unsafe" ]; then
    echo "uninstall-prefix: $file: rm -f/-rf without a literal -- end-of-options marker:" >&2
    printf '%s\n' "$unsafe" >&2
    return 1
  fi
  if ! grep -qE '(^|[^A-Za-z0-9_])rm[[:space:]]+-[A-Za-z]*f[A-Za-z]*[[:space:]]+--' "$file" 2>/dev/null; then
    return 0  # no manifest-driven removal in this file — nothing to enforce
  fi
  if ! _has_prefix_guard "$file"; then
    echo "uninstall-prefix: $file: removes paths but has no case-based prefix guard (a \"\$..PREFIX..\"*) arm with a rejecting wildcard arm)" >&2
    return 1
  fi
  return 0
}

# The JS equivalent of check_uninstall_prefix_file, for the npm channel: the file that
# actually performs the removal (fs.rmSync) is build/npm/lib/installer.js, not the thin
# bin/cli.js it's called from, and the shell-oriented check above (rm -f/-rf, a
# case-statement guard) cannot recognize either JS construct at all — it would silently
# treat any JS file as "no manifest-driven removal here, nothing to enforce". Same
# structural-heuristic spirit as the shell check, not a control-flow proof that every
# fs.rmSync call site is actually preceded by the guard at runtime: a file that removes
# paths via fs.rmSync with no startsWith(...)-based guard and no throw naming the
# out-of-prefix case at all has certainly never asserted the invariant anywhere, which is
# exactly the class of regression this exists to catch.
check_uninstall_prefix_js_file() {
  local file="$1"
  grep -qE 'fs\.rmSync\(' "$file" 2>/dev/null || return 0  # no removal here — nothing to enforce
  if ! grep -qE '\.startsWith\(' "$file" 2>/dev/null \
    || ! grep -qE 'throw[[:space:]]+new[[:space:]]+Error' "$file" 2>/dev/null \
    || ! grep -qiE 'outside' "$file" 2>/dev/null; then
    echo "uninstall-prefix: $file: calls fs.rmSync but is missing a .startsWith(...) prefix guard, a throw new Error refusal, or wording naming the out-of-prefix case" >&2
    return 1
  fi
  return 0
}

check_uninstall_prefix_repo() {
  local root="$1"
  local -a candidates=()
  [ -f "$root/install-agy.sh" ] && candidates+=("$root/install-agy.sh")
  if [ -d "$root/build/npm/bin" ]; then
    local f
    while IFS= read -r f; do candidates+=("$f"); done \
      < <(find "$root/build/npm/bin" -maxdepth 1 -type f 2>/dev/null | sorted)
  fi
  [ -f "$root/build/npm/lib/installer.js" ] && candidates+=("$root/build/npm/lib/installer.js")
  if [ ${#candidates[@]} -eq 0 ]; then
    return 0  # no uninstaller script exists yet in this worktree
  fi
  local status=0 c
  for c in "${candidates[@]}"; do
    case "$c" in
      *.js) check_uninstall_prefix_js_file "$c" || status=1 ;;
      *) check_uninstall_prefix_file "$c" || status=1 ;;
    esac
  done
  return $status
}

# ---------------------------------------------------------------- 9. frozen-sources
#
# plugins/*/commands, plugins/*/agents, plugins/*/scripts stay byte-identical to the
# comparison base except three narrowly-scoped exceptions, each checked line-by-line so
# the exception can never smuggle in a real behavior change:
#   1-2. comment-only platform-assumption headers in the two named workflow scripts
#        (contract, Architecture + Phase D).
#   3.   the `SERVER_VERSION = "..."` line in any plugins/*/scripts/*.py, rewritten by
#        .github/workflows/version-bump.yml on every PR that bumps that plugin's
#        version (a pre-existing, intentional CI mechanism added in #161 to keep
#        SERVER_VERSION from drifting from plugin.json — see AGENTS.md's "Cross-plugin
#        audit log" section). Without this exception, that bot commit trips this check
#        on every future PR touching such a plugin, on a diff the PR author neither
#        introduced nor controls.
# The only enforcement this invariant gets anywhere in this run — and it must stay
# opt-in (run_lint only calls it when --check-frozen-sources is passed; see main()).
# The comparison base (origin/master, or master with no remote) moves with every merge,
# so wired into the default lint that CI runs on every push/PR, this would reject any
# later, unrelated PR that legitimately edits a command/agent/script file — there is no
# way for such a PR to ever satisfy "byte-identical to the base ref" once this migration
# itself has merged and become part of that base ref. There is no unfreeze procedure
# because there is no permanent freeze: this check verifies one specific thing, this
# migration's own diff, and is meant to be run explicitly for that purpose, not forever.

check_frozen_sources() {
  local root="$1" scope="${2:-}" base status=0
  base="$(resolve_base_ref "$root")" || {
    echo "frozen-sources: no comparison base ref (origin/master or master) found" >&2
    return 1
  }

  # Git pathspecs, not bash globs: a bash array assignment like
  # `paths=(plugins/*/commands ...)` expands against the CALLER's cwd at the moment this
  # function runs, not against $root — call this from any other directory (a foreign cwd
  # that happens to contain a plugins/ dir, or none at all) and the glob silently expands
  # to something else, or to nothing, and the check fails open. `:(glob)` pathspec magic
  # is expanded by git itself, scoped to the repo at $root by the `cd "$root"` below, so
  # the caller's cwd can never change what gets compared.
  local -a paths
  if [ -n "$scope" ]; then
    paths=("plugins/$scope/commands" "plugins/$scope/agents" "plugins/$scope/scripts")
  else
    paths=(':(glob)plugins/*/commands/**' ':(glob)plugins/*/agents/**' ':(glob)plugins/*/scripts/**')
  fi

  local changed
  changed="$(cd "$root" && git diff "$base" --name-only -- "${paths[@]}" 2>/dev/null)"

  local f fdiff
  local -a bad=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */imps-run.workflow.js|*/ape-forage.workflow.js)
        # `^[+-]` picks every added/removed content line; excluding only the diff's own
        # `+++ `/`--- ` file-header lines (note the trailing space, part of git's literal
        # header format) — NOT the broader `^[+-][^+-]`, which also silently swallows any
        # real changed line whose own content happens to start with + or - (e.g. a line
        # added reading `++globalCounter;` diffs as `+++globalCounter;`, matching neither
        # `^[+-][^+-]` nor a real header, and would slip through undetected as "just a
        # header line"). Matches the same fix in
        # tests/python/test_override_platform_drift.py's diff filter.
        fdiff="$(cd "$root" && git diff "$base" -- "$f" 2>/dev/null \
          | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' \
          | grep -vE '^[+-][[:space:]]*(//|/\*|\*)' || true)"
        [ -n "$fdiff" ] && bad+=("$f (non-comment change)")
        ;;
      plugins/*/scripts/*.py)
        fdiff="$(cd "$root" && git diff "$base" -- "$f" 2>/dev/null \
          | grep -E '^[+-]' | grep -vE '^(\+\+\+|---) ' \
          | grep -vE '^[+-]SERVER_VERSION = "[^"]*"$' || true)"
        [ -n "$fdiff" ] && bad+=("$f (change beyond SERVER_VERSION)")
        ;;
      *)
        bad+=("$f")
        ;;
    esac
  done <<EOF
$changed
EOF

  if [ "${#bad[@]}" -gt 0 ]; then
    echo "frozen-sources: changed outside the named exceptions (base=$base):" >&2
    printf '%s\n' "${bad[@]}" >&2
    status=1
  fi
  return $status
}

# ------------------------------------------------------------------ 10. readme-marker
#
# Where a plugins/*/README.md carries a `<!-- PLATFORM-SUPPORT: opencode=<status>
# agy=<status> -->` marker, its status per platform must agree with
# build/generation-manifest.json. A README with NO marker is skipped, not failed — a
# missing marker is item 32's failure, not this script's, so the lint stays green in
# worktrees that precede it (contract, item 9's own text). The only enforcement this
# invariant gets anywhere in this run.

check_readme_marker() {
  local root="$1" scope="${2:-}" status=0
  local manifest="$root/build/generation-manifest.json"
  [ -f "$manifest" ] || {
    echo "readme-marker: missing $manifest" >&2
    return 1
  }
  local dir
  for dir in "$root"/plugins/*/; do
    local plugin
    plugin="$(basename "$dir")"
    if [ -n "$scope" ] && [ "$plugin" != "$scope" ]; then continue; fi
    local readme="${dir%/}/README.md"
    [ -f "$readme" ] || continue
    local marker
    marker="$(grep -m1 '^<!-- PLATFORM-SUPPORT:' "$readme" 2>/dev/null || true)"
    [ -z "$marker" ] && continue

    local expect_all
    if ! expect_all="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
p = d.get(sys.argv[2])
if p is None:
    sys.exit(1)
print(p.get("opencode", ""))
print(p.get("agy", ""))
' "$manifest" "$plugin" 2>/dev/null)"; then
      echo "readme-marker: $plugin not found in build/generation-manifest.json" >&2
      status=1
      continue
    fi
    local expect_opencode expect_agy
    expect_opencode="$(printf '%s\n' "$expect_all" | sed -n 1p)"
    expect_agy="$(printf '%s\n' "$expect_all" | sed -n 2p)"

    local platform expect actual
    for platform in opencode agy; do
      if [ "$platform" = opencode ]; then expect="$expect_opencode"; else expect="$expect_agy"; fi
      actual="$(printf '%s' "$marker" | grep -oE "${platform}=[A-Za-z-]+" | head -1 | cut -d= -f2)"
      if [ "$actual" != "$expect" ]; then
        echo "readme-marker: $readme: marker says $platform=${actual:-<missing>} but generation-manifest.json says $platform=$expect" >&2
        status=1
      fi
    done
  done
  return $status
}

# --------------------------------------------------------------------------- self-test

st_pass=0
st_fail=0

st_report() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = 1 ]; then
    echo "ok   $name"
    st_pass=$((st_pass + 1))
  else
    echo "FAIL $name${detail:+ — $detail}"
    st_fail=$((st_fail + 1))
  fi
}

# Runs $2 against the broken fixture (must fail, i.e. exit != 0) and $3 against the
# correct fixture (must pass, i.e. exit 0). $2/$3 are full shell command strings (eval'd)
# so callers can pass extra args per fixture.
st_case() {
  local name="$1" broken_cmd="$2" correct_cmd="$3"
  if eval "$broken_cmd" >/dev/null 2>&1; then
    st_report "$name (catches broken fixture)" 0 "check passed on a fixture that violates the invariant"
  else
    st_report "$name (catches broken fixture)" 1
  fi
  if eval "$correct_cmd" >/dev/null 2>&1; then
    st_report "$name (accepts correct fixture)" 1
  else
    st_report "$name (accepts correct fixture)" 0 "check failed on a fixture that satisfies the invariant"
  fi
}

self_test() {
  local tmp
  tmp="$(mktemp -d)" || { echo "self-test: mktemp -d failed" >&2; return 1; }
  trap 'rm -rf "$tmp"' RETURN

  # 1. regen-diff — uses the REAL repo's build/+plugins/ (read-only copy) as the
  #    generator input for BOTH fixtures: the "correct" one is a fresh generate.py run
  #    of that same input, not a copy of the real committed $ROOT/dist. Using the
  #    committed dist/ here would make this case's "accepts correct fixture" half
  #    depend on dist/ already matching a fresh regeneration — the exact thing regen-diff
  #    itself checks — so a stale committed dist/ would fail self-test for a reason
  #    unrelated to the invariant's own logic, muddying two independent signals into
  #    one. Generating the fixture keeps this case self-contained and correct
  #    regardless of whether $ROOT/dist happens to be stale right now.
  mkdir -p "$tmp/regen/correct" "$tmp/regen/broken" \
    "$tmp/regen/gen_src/build" "$tmp/regen/gen_src/plugins"
  cp -R "$ROOT/build/." "$tmp/regen/gen_src/build/" 2>/dev/null
  cp -R "$ROOT/plugins/." "$tmp/regen/gen_src/plugins/" 2>/dev/null
  if ! (cd "$tmp/regen/gen_src" && python3 build/generate.py >/dev/null 2>&1); then
    echo "self-test: could not generate the regen-diff fixture" >&2
    rm -rf "$tmp"
    return 1
  fi
  cp -R "$tmp/regen/gen_src/dist/." "$tmp/regen/correct/" 2>/dev/null
  cp -R "$tmp/regen/gen_src/dist/." "$tmp/regen/broken/" 2>/dev/null
  local corrupt_target
  corrupt_target="$(find "$tmp/regen/broken" -type f | sorted | head -1)"
  if [ -n "$corrupt_target" ]; then
    printf '\n<!-- dist-lint self-test corruption -->\n' >> "$corrupt_target"
  else
    mkdir -p "$tmp/regen/broken/opencode"
    printf 'dist-lint self-test corruption\n' > "$tmp/regen/broken/opencode/__selftest_extra_file.md"
  fi
  st_case "regen-diff" \
    "check_regen_diff '$ROOT' '$tmp/regen/broken'" \
    "check_regen_diff '$ROOT' '$tmp/regen/correct'"

  # 2. unsubstituted-ref
  mkdir -p "$tmp/ref/correct" "$tmp/ref/broken"
  printf 'run "%s/scripts/foo.sh"\n' '__PLUGIN_ROOT__' > "$tmp/ref/correct/a.md"
  printf 'run "%s/scripts/foo.sh"\n' '$CLAUDE_PLUGIN_ROOT' > "$tmp/ref/broken/a.md"
  st_case "unsubstituted-ref" \
    "check_unsubstituted_ref '$tmp/ref/broken'" \
    "check_unsubstituted_ref '$tmp/ref/correct'"

  # 3. absolute-path
  mkdir -p "$tmp/abs/correct" "$tmp/abs/broken"
  printf 'state at ~/.config/opencode/state.json\n' > "$tmp/abs/correct/a.md"
  printf 'state at /Users/example/.config/opencode/state.json\n' > "$tmp/abs/broken/a.md"
  st_case "absolute-path" \
    "check_absolute_path '$tmp/abs/broken'" \
    "check_absolute_path '$tmp/abs/correct'"

  # 4. manifest
  mkdir -p "$tmp/manifest/correct/agy/foo" "$tmp/manifest/broken/agy/foo"
  printf '{\n  "description": "d",\n  "name": "foo"\n}\n' > "$tmp/manifest/correct/agy/foo/plugin.json"
  printf '{\n  "description": "d",\n  "name": "foo",\n  "version": "0.1.0"\n}\n' > "$tmp/manifest/broken/agy/foo/plugin.json"
  st_case "manifest" \
    "check_manifest '$tmp/manifest/broken'" \
    "check_manifest '$tmp/manifest/correct'"

  # 5. budget
  mkdir -p "$tmp/budget/correct" "$tmp/budget/broken"
  yes "line" | head -5 > "$tmp/budget/correct/CLAUDE.md"
  yes "line" | head -201 > "$tmp/budget/broken/CLAUDE.md"
  st_case "budget" \
    "check_budget '$tmp/budget/broken'" \
    "check_budget '$tmp/budget/correct'"

  # 6. mirrored-block
  mkdir -p "$tmp/block/correct" "$tmp/block/broken"
  {
    echo "# CLAUDE.md"
    echo "<!-- BEGIN SHARED-MAINTAINER-BLOCK -->"
    echo "shared content"
    echo "<!-- END SHARED-MAINTAINER-BLOCK -->"
  } > "$tmp/block/correct/CLAUDE.md"
  cp "$tmp/block/correct/CLAUDE.md" "$tmp/block/correct/AGENTS.md"
  cp "$tmp/block/correct/CLAUDE.md" "$tmp/block/broken/CLAUDE.md" 2>/dev/null || { mkdir -p "$tmp/block/broken"; cp "$tmp/block/correct/CLAUDE.md" "$tmp/block/broken/CLAUDE.md"; }
  {
    echo "# AGENTS.md"
    echo "<!-- BEGIN SHARED-MAINTAINER-BLOCK -->"
    echo "DIFFERENT content"
    echo "<!-- END SHARED-MAINTAINER-BLOCK -->"
  } > "$tmp/block/broken/AGENTS.md"
  st_case "mirrored-block" \
    "check_mirrored_block '$tmp/block/broken'" \
    "check_mirrored_block '$tmp/block/correct'"

  # 7. gate-stripped
  mkdir -p "$tmp/gate/correct" "$tmp/gate/broken"
  printf 'On Claude Code this uses the Workflow oracle loop.\n' > "$tmp/gate/correct/a.md"
  printf 'call agent() with isolation: '"'"'worktree'"'"'\n' > "$tmp/gate/broken/a.md"
  st_case "gate-stripped" \
    "check_gate_stripped '$tmp/gate/broken'" \
    "check_gate_stripped '$tmp/gate/correct'"

  # 8. out-of-prefix uninstall path (synthetic scripts, not the real install-agy.sh).
  # correct.sh also carries a doc comment that mentions `rm -rf --` in prose, and a
  # trailing `# see --help`-style comment on its real `rm -f --` call, to prove
  # _unsafe_rm_lines' `--` check is anchored to the actual invocation, not "does `--`
  # appear anywhere on the line" (a whole-line `grep -v -- '--'` would have let a truly
  # unsafe `rm -f $path  # see --help` line in broken2.sh below slip through undetected).
  mkdir -p "$tmp/uninstall"
  cat > "$tmp/uninstall/correct.sh" <<'FIXTURE'
#!/usr/bin/env bash
# remove_path_guarded <prefix> <path> — removes a single path (via `rm -rf --`)
while IFS= read -r path; do
  case "$path" in
    "$PREFIX"/*) ;;
    *) echo "refusing to remove path outside prefix: $path" >&2; exit 1 ;;
  esac
  rm -f -- "$path"  # see --help for flag details
done < manifest.txt
FIXTURE
  cat > "$tmp/uninstall/broken.sh" <<'FIXTURE'
#!/usr/bin/env bash
while IFS= read -r path; do
  rm -f $path
done < manifest.txt
FIXTURE
  cat > "$tmp/uninstall/broken2.sh" <<'FIXTURE'
#!/usr/bin/env bash
while IFS= read -r path; do
  rm -f "$path"  # see --help
done < manifest.txt
FIXTURE
  st_case "uninstall-prefix" \
    "check_uninstall_prefix_file '$tmp/uninstall/broken.sh'" \
    "check_uninstall_prefix_file '$tmp/uninstall/correct.sh'"
  st_case "uninstall-prefix-trailing-comment-dashes" \
    "check_uninstall_prefix_file '$tmp/uninstall/broken2.sh'" \
    "check_uninstall_prefix_file '$tmp/uninstall/correct.sh'"

  # 8b. out-of-prefix uninstall path, JS variant (synthetic files, not the real
  # build/npm/lib/installer.js) — the shell check above cannot recognize fs.rmSync or a
  # JS guard at all, so this is a separate function over a separate fixture pair.
  cat > "$tmp/uninstall/correct.js" <<'FIXTURE'
const fs = require("fs");
const path = require("path");
function uninstall(files, prefix) {
  const prefixResolved = path.resolve(prefix) + path.sep;
  for (const file of files) {
    const resolved = path.resolve(file);
    if (!(resolved + path.sep).startsWith(prefixResolved)) {
      throw new Error(`refusing — path is outside install prefix ${prefix}`);
    }
  }
  for (const file of files) {
    fs.rmSync(file, { force: true });
  }
}
FIXTURE
  cat > "$tmp/uninstall/broken.js" <<'FIXTURE'
const fs = require("fs");
function uninstall(files) {
  for (const file of files) {
    fs.rmSync(file, { force: true });
  }
}
FIXTURE
  st_case "uninstall-prefix-js" \
    "check_uninstall_prefix_js_file '$tmp/uninstall/broken.js'" \
    "check_uninstall_prefix_js_file '$tmp/uninstall/correct.js'"

  # 9. frozen-sources — synthetic git repos (never $ROOT's own history)
  local fz_correct="$tmp/frozen/correct" fz_broken="$tmp/frozen/broken"
  local d
  for d in "$fz_correct" "$fz_broken"; do
    mkdir -p "$d/plugins/imps/commands" "$d/plugins/imps/agents" "$d/plugins/imps/scripts" \
             "$d/plugins/ape/scripts"
    printf 'a command\n' > "$d/plugins/imps/commands/imps.md"
    printf '#!/usr/bin/env node\n// platform: darwin-only dispatch backend\nconsole.log(1)\n' \
      > "$d/plugins/imps/scripts/imps-run.workflow.js"
    printf '#!/usr/bin/env node\n// platform: darwin-only dispatch backend\nconsole.log(1)\n' \
      > "$d/plugins/ape/scripts/ape-forage.workflow.js"
    (cd "$d" && git init -q -b master && git -c user.email=t@example.com -c user.name=t \
       add -A && git -c user.email=t@example.com -c user.name=t commit -q -m init)
  done
  # correct: comment-only edit to an allowed exception file
  sed -i.bak 's#// platform: darwin-only dispatch backend#// platform: darwin-only dispatch backend (opencode)#' \
    "$fz_correct/plugins/imps/scripts/imps-run.workflow.js" && rm -f "$fz_correct/plugins/imps/scripts/imps-run.workflow.js.bak"
  # broken: non-comment edit to a non-exception command file
  printf 'a command, mutated\n' > "$fz_broken/plugins/imps/commands/imps.md"
  st_case "frozen-sources" \
    "check_frozen_sources '$fz_broken'" \
    "check_frozen_sources '$fz_correct'"

  # 9b. frozen-sources / SERVER_VERSION exception — the version-bump.yml lockstep
  # (AGENTS.md "Cross-plugin audit log") rewrites only the SERVER_VERSION line; any
  # other simultaneous change to the same file must still fail.
  local fz_sv_correct="$tmp/frozen-sv/correct" fz_sv_broken="$tmp/frozen-sv/broken"
  for d in "$fz_sv_correct" "$fz_sv_broken"; do
    mkdir -p "$d/plugins/offload-sidecar/scripts"
    printf '#!/usr/bin/env python3\nSERVER_VERSION = "0.3.4"\nprint("ok")\n' \
      > "$d/plugins/offload-sidecar/scripts/offload_sidecar.py"
    (cd "$d" && git init -q -b master && git -c user.email=t@example.com -c user.name=t \
       add -A && git -c user.email=t@example.com -c user.name=t commit -q -m init)
  done
  # correct: SERVER_VERSION-only bump, exactly what version-bump.yml writes
  sed -i.bak 's/SERVER_VERSION = "0.3.4"/SERVER_VERSION = "0.3.5"/' \
    "$fz_sv_correct/plugins/offload-sidecar/scripts/offload_sidecar.py" \
    && rm -f "$fz_sv_correct/plugins/offload-sidecar/scripts/offload_sidecar.py.bak"
  # broken: SERVER_VERSION bump smuggling in a second, unrelated line change
  sed -i.bak -e 's/SERVER_VERSION = "0.3.4"/SERVER_VERSION = "0.3.5"/' \
    -e 's/print("ok")/print("mutated")/' \
    "$fz_sv_broken/plugins/offload-sidecar/scripts/offload_sidecar.py" \
    && rm -f "$fz_sv_broken/plugins/offload-sidecar/scripts/offload_sidecar.py.bak"
  st_case "frozen-sources-server-version" \
    "check_frozen_sources '$fz_sv_broken'" \
    "check_frozen_sources '$fz_sv_correct'"

  # 10. readme-marker
  mkdir -p "$tmp/marker/correct/build" "$tmp/marker/correct/plugins/foo" \
           "$tmp/marker/broken/build" "$tmp/marker/broken/plugins/foo"
  printf '{"foo": {"opencode": "full", "agy": "excluded", "reason": "x"}}\n' \
    > "$tmp/marker/correct/build/generation-manifest.json"
  cp "$tmp/marker/correct/build/generation-manifest.json" "$tmp/marker/broken/build/generation-manifest.json"
  printf '<!-- PLATFORM-SUPPORT: opencode=full agy=excluded -->\n# foo\n' \
    > "$tmp/marker/correct/plugins/foo/README.md"
  printf '<!-- PLATFORM-SUPPORT: opencode=full agy=full -->\n# foo\n' \
    > "$tmp/marker/broken/plugins/foo/README.md"
  st_case "readme-marker" \
    "check_readme_marker '$tmp/marker/broken'" \
    "check_readme_marker '$tmp/marker/correct'"

  echo
  echo "$st_pass ok, $st_fail failed (of $((st_pass + st_fail)))"
  [ "$st_fail" -eq 0 ]
}

# ------------------------------------------------------------------------------ run_lint

run_lint() {
  local scope="$1" check_frozen="${2:-0}" status=0 dist="$ROOT/dist"

  if [ -n "$scope" ] && [ ! -d "$ROOT/plugins/$scope" ]; then
    echo "dist-lint: --scope $scope: no such plugin directory plugins/$scope" >&2
    return 1
  fi

  echo "== dist-lint${scope:+ --scope $scope} =="

  check_regen_diff "$ROOT" "$dist" "$scope" && echo "ok   regen-diff" || { echo "FAIL regen-diff"; status=1; }
  check_unsubstituted_ref "$dist" && echo "ok   unsubstituted-ref" || { echo "FAIL unsubstituted-ref"; status=1; }
  check_absolute_path "$dist" && echo "ok   absolute-path" || { echo "FAIL absolute-path"; status=1; }
  check_manifest "$dist" && echo "ok   manifest" || { echo "FAIL manifest"; status=1; }
  check_budget "$ROOT" && echo "ok   budget" || { echo "FAIL budget"; status=1; }
  check_mirrored_block "$ROOT" && echo "ok   mirrored-block" || { echo "FAIL mirrored-block"; status=1; }
  check_gate_stripped "$dist" && echo "ok   gate-stripped" || { echo "FAIL gate-stripped"; status=1; }
  check_uninstall_prefix_repo "$ROOT" && echo "ok   uninstall-prefix" || { echo "FAIL uninstall-prefix"; status=1; }
  # frozen-sources is opt-in (--check-frozen-sources), NOT part of the default lint that
  # CI's push/pull_request gate runs on every commit. It diffs plugins/*/{commands,agents,
  # scripts} against origin/master — fine as a one-time check of *this migration's* diff,
  # but origin/master keeps moving, so wired into a permanent gate it would reject any
  # future, unrelated PR that legitimately edits a command/agent/script file. Run it
  # explicitly (e.g. once, before merging this migration) with --check-frozen-sources.
  if [ "$check_frozen" = "1" ]; then
    check_frozen_sources "$ROOT" "$scope" && echo "ok   frozen-sources" || { echo "FAIL frozen-sources"; status=1; }
  else
    echo "skip frozen-sources (opt-in: --check-frozen-sources)"
  fi
  check_readme_marker "$ROOT" "$scope" && echo "ok   readme-marker" || { echo "FAIL readme-marker"; status=1; }

  return $status
}

# --------------------------------------------------------------------------------- main

scope=""
mode="lint"
check_frozen=0
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) mode="self-test"; shift ;;
    --check-frozen-sources) check_frozen=1; shift ;;
    --scope)
      if [ $# -lt 2 ]; then
        echo "dist-lint: --scope requires a value" >&2
        usage >&2
        exit 1
      fi
      scope="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "dist-lint: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$mode" = "self-test" ]; then
  self_test
  exit $?
else
  run_lint "$scope" "$check_frozen"
  exit $?
fi
