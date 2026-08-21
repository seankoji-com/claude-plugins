#!/usr/bin/env bash
# sandbox-smoke-shape.sh — proves sandbox-smoke.sh's OWN assertion/counting/
# exit-code logic, not real sandbox containment (only the Darwin+SANDBOX_MODE
# inline run in tests/run.sh proves that — this file deliberately does not
# replace it). It runs sandbox-smoke.sh as a REAL subprocess against a
# STUBBED sandbox-wrap.sh, selected via CLAUDE_PLUGIN_ROOT — sandbox-smoke.sh
# already resolves $WRAP through that var (`WRAP="$PLUGIN_ROOT/scripts/
# sandbox-wrap.sh"`), so nothing in the script under test needed to change to
# make it stubbable, the same way sandbox-wrap-shape.sh stubs `safehouse` on
# PATH without touching sandbox-wrap.sh itself.
#
# Three stub personalities, one per scenario below:
#
#   1. backend-unavailable: `--check` always fails. sandbox-smoke.sh must
#      report exit 2 with its specific stderr message, before touching $HOME
#      at all.
#   2. cannot-nest: `--check` succeeds, but the FIRST wrapped call (the
#      nesting probe, `/usr/bin/true`) fails. sandbox-smoke.sh must report
#      exit 77, again before any real assertion runs.
#   3. leaky (never isolates anything — just execs the wrapped command
#      directly, no Seatbelt, no denial): this is the exact failure mode the
#      underlying issue is about — a sandbox backend that silently stopped
#      denying anything. Proves sandbox-smoke.sh's assert()/counting/exit-code
#      logic actually turns that into named FAIL lines and a non-zero exit,
#      on any platform, without a real macOS sandbox.
#
# Scenario 3 does not attempt to fully emulate the real Seatbelt profile (that
# would just be reimplementing sandbox-wrap.sh) — it only proves sandbox-smoke.sh
# NOTICES when the thing it exists to notice (an allow that should have been a
# deny) actually happens. A curated subset of assertion names is checked, not
# the full set: sandbox-smoke.sh gaining or losing an assertion should not by
# itself break this file.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
SMOKE="$PLUGIN_ROOT/scripts/sandbox-smoke.sh"
BASH_BIN="$(command -v bash)"

fails=0
assert() { # assert <name> <ok:0|1> [detail]
  if [ "$2" = 1 ]; then
    printf 'ok   sandbox-smoke-shape/%s\n' "$1"
  else
    printf 'FAIL sandbox-smoke-shape/%s\n' "$1"
    [ -n "${3:-}" ] && printf '%s\n' "$3" | sed 's/^/     /' | tail -n 12
    fails=$((fails + 1))
  fi
}
assert_eq() { # assert_eq <name> <actual> <want> [context]
  if [ "$2" = "$3" ]; then
    assert "$1" 1
  else
    assert "$1" 0 "got:  [$2]
want: [$3]${4:+
$4}"
  fi
}
assert_line() { # assert_line <name> <haystack> <exact_line>
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then
    assert "$1" 1
  else
    assert "$1" 0 "expected exact line not found: [$3]"
  fi
}
assert_line_match() { # assert_line_match <name> <haystack> <grep -E pattern>
  if printf '%s\n' "$2" | grep -qE -- "$3"; then
    assert "$1" 1
  else
    assert "$1" 0 "expected a line matching: [$3]"
  fi
}

[ -x "$SMOKE" ] || { echo "sandbox-smoke-shape: missing $SMOKE" >&2; exit 2; }

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-smoke-shape.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT HUP INT TERM
# Canonicalize immediately (see sandbox-wrap-shape.sh's identical comment):
# macOS's $TMPDIR is a symlink, and sandbox-smoke.sh's own canon() (cd + pwd
# -P) resolves the physical path — matching up front keeps every path this
# file compares byte-identical to what the script under test itself produces.
SCRATCH="$(cd "$SCRATCH" && pwd -P)"

# Isolate every real `git` call sandbox-smoke.sh makes (init, commit, worktree
# add) from the operator's own global/system git config — same trap
# dispatch-guards.sh and worktree-shape.sh document: a signing key or a
# core.excludesFile entry on the host reads green in isolation and red only on
# a real dev machine.
GIT_BIN="$(command -v git)" || { echo "sandbox-smoke-shape: git is required" >&2; exit 2; }
export GIT_CONFIG_GLOBAL="$SCRATCH/gitconfig-global"
: >"$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_SYSTEM="$SCRATCH/gitconfig-system"
: >"$GIT_CONFIG_SYSTEM"
SAFE_PATH="$(dirname "$GIT_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"

# run_smoke: the single invocation point. env -i so no ambient var (a
# maintainer's real HOME, a CI runner's own TMPDIR, an inherited
# SANDBOX_MODE) can leak into what's meant to be a fully pinned run.
# Sets globals: RC, OUT, ERR.
run_smoke() { # run_smoke <fake_plugin_root> <home_dir>
  local fake_root="$1" home_dir="$2"
  local out_f err_f
  out_f="$(mktemp)"
  err_f="$(mktemp)"
  env -i HOME="$home_dir" PATH="$SAFE_PATH" TMPDIR="$SCRATCH" \
      GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_SYSTEM="$GIT_CONFIG_SYSTEM" \
      CLAUDE_PLUGIN_ROOT="$fake_root" \
      "$BASH_BIN" "$SMOKE" >"$out_f" 2>"$err_f"
  RC=$?
  OUT="$(cat "$out_f")"
  ERR="$(cat "$err_f")"
  rm -f "$out_f" "$err_f"
}

make_stub() { # make_stub <fake_root> <stub body...via stdin>
  local fake_root="$1"
  mkdir -p "$fake_root/scripts"
  cat >"$fake_root/scripts/sandbox-wrap.sh"
  chmod +x "$fake_root/scripts/sandbox-wrap.sh"
}

# ==============================================================================
# Scenario 1 — backend unavailable: `--check` always fails.
# ==============================================================================
ROOT_UNAVAILABLE="$SCRATCH/root-unavailable"
make_stub "$ROOT_UNAVAILABLE" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

HOME_UNAVAILABLE="$SCRATCH/home-unavailable"
mkdir -p "$HOME_UNAVAILABLE"
run_smoke "$ROOT_UNAVAILABLE" "$HOME_UNAVAILABLE"
assert_eq "backend-unavailable/exit" "$RC" "2" "stdout=$OUT
stderr=$ERR"
assert_eq "backend-unavailable/message" "$ERR" \
  "sandbox-smoke: sandbox backend unavailable (SANDBOX_MODE=safehouse)"

# ==============================================================================
# Scenario 2 — cannot nest: `--check` succeeds, but the nesting probe
# (the FIRST wrapped call) fails.
# ==============================================================================
ROOT_NESTED="$SCRATCH/root-nested"
make_stub "$ROOT_NESTED" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--check" ] && exit 0
exit 1
EOF

HOME_NESTED="$SCRATCH/home-nested"
mkdir -p "$HOME_NESTED"
run_smoke "$ROOT_NESTED" "$HOME_NESTED"
assert_eq "cannot-nest/exit" "$RC" "77" "stdout=$OUT
stderr=$ERR"
assert_eq "cannot-nest/message" "$ERR" \
  "sandbox-smoke: cannot apply the sandbox here — Seatbelt does not nest.
sandbox-smoke: re-run outside Claude Code's Bash sandbox (see references/opencode-harness.md)."

# ==============================================================================
# Scenario 3 — leaky wrapper: `--check` succeeds, and every wrapped call just
# execs the command directly with NO isolation at all (the exact regression
# this issue is about: a backend that silently stopped denying anything).
# ==============================================================================
ROOT_LEAKY="$SCRATCH/root-leaky"
make_stub "$ROOT_LEAKY" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--check" ] && exit 0
while [ $# -gt 0 ]; do
  if [ "$1" = "--" ]; then
    shift
    exec "$@"
  fi
  shift
done
exit 2
EOF

HOME_LEAKY="$SCRATCH/home-leaky"
mkdir -p "$HOME_LEAKY"
run_smoke "$ROOT_LEAKY" "$HOME_LEAKY"
assert_eq "leaky/exit" "$RC" "1" "stdout=$OUT
stderr=$ERR"

# Denies that the leaky wrapper turned into silent allows must be reported as
# FAIL, by exact assertion name — this is the core security property: a
# broken backend must never read as a pass. This includes
# gitmeta-own-worktree-commit-still-allowed: with NOTHING denied, the earlier
# gitmeta-commondir-write-denied / gitmeta-gitdir-write-denied probes actually
# succeed against the real $WT repo (unlike under a real sandbox, where they're
# denied and never touch it), which corrupts commondir resolution and makes
# the later `git worktree add` setup itself fail — every assertion that setup
# would have driven, including this one, reports FAIL via the "could not set
# up linked worktrees" path rather than silently passing. That cascade is
# itself a real property worth asserting: a leaky wrapper must never produce a
# clean run, not even by accident.
for name in \
  home-write-denied \
  home-read-denied \
  gitmeta-hooks-write-denied \
  gitmeta-config-write-denied \
  gitmeta-modules-write-denied \
  gitmeta-commondir-write-denied \
  gitmeta-gitdir-write-denied \
  gitmeta-linked-worktree-config-denied \
  gitmeta-sibling-worktree-config-denied \
  gitmeta-own-gitdir-modules-denied \
  gitmeta-dotgit-redirect-does-not-grant-target \
  gitmeta-own-worktree-commit-still-allowed \
; do
  assert_line "leaky/FAIL-$name" "$OUT" "FAIL $name"
done

# Genuine allows that don't depend on the (now-corrupted) $WT repo staying
# usable must stay allows even against the leaky (passthrough) stub — these
# were never denied by design, so this stub cannot turn them red, and a real
# regression here would mean sandbox-smoke.sh itself, not the wrapper, is
# broken.
for name in \
  worktree-write-allowed \
  gitmeta-write-allowed \
  devnull-write-allowed \
  git-status-ok \
; do
  assert_line "leaky/ok-$name" "$OUT" "ok   $name"
done

# ~/.config/gh is created by sandbox-smoke.sh itself when absent (so this
# assertion is never vacuously skipped — see the script's own header comment)
# and must therefore actually run against the leaky stub, not be skipped.
assert_line "leaky/FAIL-gh-config-denied" "$OUT" "FAIL gh-config-denied"

# Credential paths that are genuinely absent on this scratch $HOME must be
# skipped, not silently counted as a pass either way.
for name in auth-json-denied ssh-denied aws-denied claude-creds-denied; do
  assert_line_match "leaky/skip-$name" "$OUT" "^note $name: .*absent on this host — skipped, NOT counted as a pass$"
done

assert_line_match "leaky/summary" "$ERR" "^sandbox-smoke: [0-9]+ assertion\(s\) failed$"

# ==============================================================================
echo "---"
if [ "$fails" -ne 0 ]; then
  echo "sandbox-smoke-shape: $fails assertion(s) failed" >&2
  exit 1
fi
echo "sandbox-smoke-shape: all assertions passed"
