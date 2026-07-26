#!/usr/bin/env bash
# sandbox-wrap-shape.sh — proves sandbox-wrap.sh's own PURE logic (SBPL
# render, ENV_PASS/sh_args construction, SANDBOX_MODE/bypass dispatch,
# metachar rejection) without requiring macOS or a real `safehouse` backend.
#
# This is deliberately NOT a duplicate of sandbox-smoke.sh: that suite proves
# the rendered profile's real *effects* under a genuine Seatbelt sandbox on
# Darwin. This suite never applies a real sandbox — it stubs `uname` (to
# report Darwin so the safehouse arm's OS gate passes) and `safehouse` itself
# (to just echo the argv it was invoked with) so sandbox-wrap.sh's own
# branching, string-building, and die() messages can be exercised and
# asserted on any platform, including ubuntu-latest CI.
#
# Every negative-path assertion here checks the SPECIFIC stderr message
# die() emitted (exact string, not exit code alone) — an exit-2-only
# assertion can't tell "died for the reason I meant" from "died for an
# unrelated reason", which is exactly how a test silently tests nothing.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
WRAP="$PLUGIN_ROOT/scripts/sandbox-wrap.sh"
# Absolute path, not a bare `bash`: some tests below deliberately run with a
# minimal PATH that doesn't include bash itself (to keep a real ambient
# `safehouse` off PATH), and `env ... bash ...` resolves its own command
# through that same PATH.
BASH_BIN="$(command -v bash)"

fails=0
assert() { # assert <name> <ok:0|1> [detail]
  if [ "$2" = 1 ]; then
    printf 'ok   sandbox-wrap-shape/%s\n' "$1"
  else
    printf 'FAIL sandbox-wrap-shape/%s\n' "$1"
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

# Scratch space OUTSIDE this git repo (mandatory — see below). If it lands
# inside a git working tree, sandbox-wrap.sh's `git rev-parse --git-dir`
# self-resolve fallback (used whenever --real-gitdir is omitted) can actually
# resolve to a real gitdir and hit the containment check for the wrong
# reason, derailing the very branches this suite targets.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-wrap-shape.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT HUP INT TERM
# Canonicalize immediately: on macOS, $TMPDIR is under a /tmp -> /private/tmp
# symlink, and sandbox-wrap.sh's own canon() (cd + pwd -P) resolves the
# physical path. Doing the same here up front keeps every fixture path below
# byte-identical to what the script under test will itself produce, instead
# of comparing a symlinked path against its resolved form.
SCRATCH="$(cd "$SCRATCH" && pwd -P)"

# --- Stubs ------------------------------------------------------------------
STUB_BIN="$SCRATCH/stub-bin"
mkdir -p "$STUB_BIN"

cat >"$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "-s" ]; then
  echo "Darwin"
else
  # Exec the REAL binary by absolute path — a bare `uname "$@"` would
  # re-resolve through this same stub-first PATH and recurse forever.
  exec /usr/bin/uname "$@"
fi
EOF
chmod +x "$STUB_BIN/uname"

cat >"$STUB_BIN/safehouse" <<'EOF'
#!/usr/bin/env bash
# Echo every argv element received, one per line, so the caller can inspect
# the exact command line sandbox-wrap.sh built, then succeed.
for a in "$@"; do printf '%s\n' "$a"; done
exit 0
EOF
chmod +x "$STUB_BIN/safehouse"

# A stub-bin with `uname` but deliberately NO `safehouse` — used by the
# resolve_safehouse-precedence tests to prove the plain "not found" path.
STUB_BIN_NO_SAFEHOUSE="$SCRATCH/stub-bin-no-safehouse"
mkdir -p "$STUB_BIN_NO_SAFEHOUSE"
cp "$STUB_BIN/uname" "$STUB_BIN_NO_SAFEHOUSE/uname"
chmod +x "$STUB_BIN_NO_SAFEHOUSE/uname"

# --- run_wrap: the single invocation point, with mandatory env hygiene -----
# sandbox-wrap.sh reads six ambient env vars that would otherwise make these
# golden-value assertions environment-dependent: CLAUDE_PLUGIN_ROOT (resolves
# DENY_TEMPLATE), IMPS_SANDBOX_EXPLAIN, IMPS_SAFEHOUSE_BIN, SANDBOX_MODE,
# IMPS_SANDBOX_DANGEROUSLY_DISABLE, and HOME. Every invocation pins
# CLAUDE_PLUGIN_ROOT to THIS repo's plugins/imps, explicitly unsets the other
# four bypass/mode vars (callers that deliberately test one pass it via
# EXTRA_ENV, which is applied AFTER the -u unsets so it wins), and takes HOME
# and PATH as explicit arguments rather than ever inheriting the ambient
# values.
#
# Sets globals: RC, OUT, ERR.
EXTRA_ENV=()
run_wrap() { # run_wrap <HOME_DIR> <PATH_VALUE> -- <args to sandbox-wrap.sh...>
  local home_dir="$1" path_val="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  local out_f err_f
  out_f="$(mktemp)"
  err_f="$(mktemp)"
  env -u IMPS_SANDBOX_EXPLAIN -u IMPS_SAFEHOUSE_BIN -u SANDBOX_MODE -u IMPS_SANDBOX_DANGEROUSLY_DISABLE \
      CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" HOME="$home_dir" PATH="$path_val" \
      "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
      "$BASH_BIN" "$WRAP" "$@" >"$out_f" 2>"$err_f"
  RC=$?
  OUT="$(cat "$out_f")"
  ERR="$(cat "$err_f")"
  rm -f "$out_f" "$err_f"
}

# --- Shared fixtures ---------------------------------------------------------
HOME_EMPTY="$SCRATCH/home-empty"
mkdir -p "$HOME_EMPTY"

HOME_FULL="$SCRATCH/home-full"
mkdir -p "$HOME_FULL/.opencode/bin"
: >"$HOME_FULL/.gitconfig"
: >"$HOME_FULL/.gitignore_global"

# Plain (non-git) worktree/gitmeta/datadir — the "unresolved gitdir" shape:
# WORKTREE isn't a git repo at all, so the self-resolve fallback's `git
# rev-parse --git-dir` fails silently, and GITMETA has no worktrees/
# subdirectory, so the fail-closed die doesn't fire either — the script
# proceeds to the /dev/null/unresolved-real-gitdir placeholder.
WT_PLAIN="$SCRATCH/wt-plain"
GITMETA_PLAIN="$SCRATCH/gitmeta-plain"
DATADIR_PLAIN="$SCRATCH/datadir-plain"
mkdir -p "$WT_PLAIN" "$GITMETA_PLAIN" "$DATADIR_PLAIN"

# ==============================================================================
# Item 1 — `&`-in-HOME rejection, exact message (not a substring shared with
# the separate --gitmeta metachar guard).
# ==============================================================================
HOME_AMP="$SCRATCH/ho&me"
mkdir -p "$HOME_AMP"
run_wrap "$HOME_AMP" "$STUB_BIN:$PATH" -- \
  --worktree "$WT_PLAIN" --gitmeta "$GITMETA_PLAIN" --datadir "$DATADIR_PLAIN" -- true
assert_eq "home-amp-rejected/exit" "$RC" "2" "stderr=$ERR"
assert_eq "home-amp-rejected/message" "$ERR" \
  "sandbox-wrap: HOME contains a quote, backslash, ampersand, or colon — cannot build a safe sandbox profile"

# ==============================================================================
# Item 2 — SBPL render fidelity.
# ==============================================================================

# 2a. Unresolved-gitdir case: drive a full successful run through the plain
# fixture above (real HOME, no ambient bypass), read the rendered profile
# left behind in DATADIR (the script deliberately never cleans it up), and
# assert: no residual @[A-Z_]*@ token, HOME/GITMETA substitutions landed, and
# the REAL_GITDIR placeholder is the literal /dev/null path.
render_dir_a="$SCRATCH/render-a-datadir"
mkdir -p "$render_dir_a"
run_wrap "$HOME_EMPTY" "$STUB_BIN:$PATH" -- \
  --worktree "$WT_PLAIN" --gitmeta "$GITMETA_PLAIN" --datadir "$render_dir_a" -- true
assert_eq "render-unresolved/exit" "$RC" "0" "stderr=$ERR"
profile_a="$(find "$render_dir_a" -maxdepth 1 -name 'imps-deny-profile.*' -print -quit 2>/dev/null)"
if [ -z "$profile_a" ]; then
  assert "render-unresolved/profile-exists" 0 "no imps-deny-profile.* file found under $render_dir_a; stderr=$ERR"
else
  assert "render-unresolved/profile-exists" 1
  no_token=1
  residual_hit="$(grep -E '@[A-Z_]+@' "$profile_a" 2>/dev/null || true)"
  [ -z "$residual_hit" ] || no_token=0
  assert "render-unresolved/no-residual-token" "$no_token" "residual token(s):
$residual_hit"
  home_ok=1
  grep -qF "$HOME_EMPTY/.claude/.credentials.json" "$profile_a" 2>/dev/null || home_ok=0
  assert "render-unresolved/home-substituted" "$home_ok" "expected literal \"$HOME_EMPTY/.claude/.credentials.json\" in $profile_a"
  gitmeta_ok=1
  grep -qF "$GITMETA_PLAIN/hooks" "$profile_a" 2>/dev/null || gitmeta_ok=0
  assert "render-unresolved/gitmeta-substituted" "$gitmeta_ok" "expected \"$GITMETA_PLAIN/hooks\" in $profile_a"
  placeholder_ok=1
  grep -qF '(allow file-write* (subpath "/dev/null/unresolved-real-gitdir"))' "$profile_a" 2>/dev/null || placeholder_ok=0
  assert "render-unresolved/real-gitdir-placeholder" "$placeholder_ok" "expected the unresolved placeholder rule in $profile_a"
fi

# 2b. Self-resolve success: a GENUINE linked worktree, so REAL_GITDIR is
# resolved via the self-resolve fallback (no --real-gitdir given) rather than
# an explicit arg, passes the worktrees/*/ containment check, and its real
# gitdir path lands in the rendered profile.
base_repo="$SCRATCH/base-repo"
git init -q "$base_repo"
git -C "$base_repo" -c user.email=a@b -c user.name=a -c commit.gpgsign=false commit -q --allow-empty -m init
linked_wt="$SCRATCH/linked-wt"
git -C "$base_repo" worktree add -q "$linked_wt" -b sandbox-wrap-shape-linked >/dev/null 2>&1
gitmeta_base="$(cd "$base_repo/.git" && pwd -P)"
# The per-worktree gitdir's basename is derived from $linked_wt's own
# basename by `git worktree add`, NOT the -b branch name — ask git itself
# (same self-resolve command sandbox-wrap.sh runs) rather than assume.
real_gitdir_b="$(cd "$(git -C "$linked_wt" rev-parse --git-dir)" && pwd -P)"
render_dir_b="$SCRATCH/render-b-datadir"
mkdir -p "$render_dir_b"
run_wrap "$HOME_EMPTY" "$STUB_BIN:$PATH" -- \
  --worktree "$linked_wt" --gitmeta "$gitmeta_base" --datadir "$render_dir_b" -- true
assert_eq "render-self-resolve/exit" "$RC" "0" "stderr=$ERR"
if [ "$RC" -eq 0 ]; then
  profile_b="$(find "$render_dir_b" -maxdepth 1 -name 'imps-deny-profile.*' -print -quit 2>/dev/null)"
  self_resolve_ok=1
  grep -qF "$real_gitdir_b" "$profile_b" 2>/dev/null || self_resolve_ok=0
  assert "render-self-resolve/real-gitdir-substituted" "$self_resolve_ok" \
    "expected \"$real_gitdir_b\" in $profile_b"
fi

# ==============================================================================
# Item 3 — ENV_PASS exact golden, via the captured stub-safehouse argv.
# ==============================================================================
EXPECTED_ENV_PASS="TERM,TMPDIR,OPENCODE_DISABLE_LSP_DOWNLOAD,OPENCODE_DISABLE_MODELS_FETCH,OPENCODE_DISABLE_AUTOCOMPACT,OPENCODE_DISABLE_PRUNE,OPENCODE_DISABLE_DEFAULT_PLUGINS,OPENCODE_DISABLE_SHARE,OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER,XDG_DATA_HOME,XDG_STATE_HOME,XDG_CONFIG_HOME,XDG_CACHE_HOME"

argv_value_after() { # argv_value_after <flag> <<< "$OUT"
  # Reads the stub-safehouse's one-arg-per-line stdout from stdin, prints the
  # value immediately following the given flag (empty/no output if absent).
  local flag="$1" line prev=""
  while IFS= read -r line; do
    if [ "$prev" = "$flag" ]; then
      printf '%s' "$line"
      return 0
    fi
    prev="$line"
  done
  return 1
}

run_wrap "$HOME_EMPTY" "$STUB_BIN:$PATH" -- \
  --worktree "$WT_PLAIN" --gitmeta "$GITMETA_PLAIN" --datadir "$DATADIR_PLAIN" -- true
assert_eq "env-pass-golden/exit" "$RC" "0" "stderr=$ERR"
got_env_pass="$(argv_value_after '--env-pass' <<<"$OUT")"
assert_eq "env-pass-golden/value" "$got_env_pass" "$EXPECTED_ENV_PASS"

# ==============================================================================
# Item 4 — sh_args/argv golden via the stub safehouse.
# ==============================================================================

# 4a. RO_PATHS empty (no dotfiles in HOME) — --add-dirs-ro must be absent.
run_wrap "$HOME_EMPTY" "$STUB_BIN:$PATH" -- \
  --worktree "$WT_PLAIN" --gitmeta "$GITMETA_PLAIN" --datadir "$DATADIR_PLAIN" -- true
assert_eq "argv-golden/exit-empty-home" "$RC" "0" "stderr=$ERR"
got_workdir="$(argv_value_after '--workdir' <<<"$OUT")"
assert_eq "argv-golden/workdir" "$got_workdir" "$WT_PLAIN"
got_add_dirs="$(argv_value_after '--add-dirs' <<<"$OUT")"
assert_eq "argv-golden/add-dirs" "$got_add_dirs" "$GITMETA_PLAIN:$DATADIR_PLAIN"
got_append_profile="$(argv_value_after '--append-profile' <<<"$OUT")"
append_profile_ok=1
case "$got_append_profile" in
  "$DATADIR_PLAIN"/imps-deny-profile.*) ;;
  *) append_profile_ok=0 ;;
esac
assert "argv-golden/append-profile" "$append_profile_ok" "got: [$got_append_profile] want under $DATADIR_PLAIN/imps-deny-profile.*"
has_ro=0
grep -qxF -- '--add-dirs-ro' <<<"$OUT" && has_ro=1
assert_eq "argv-golden/add-dirs-ro-absent-when-empty" "$has_ro" "0" "argv=$OUT"
has_wide_read=0
grep -qF -- '--enable=wide-read' <<<"$OUT" && has_wide_read=1
assert_eq "argv-golden/no-wide-read-empty-home" "$has_wide_read" "0" "argv=$OUT"

# 4b. RO_PATHS non-empty (dotfiles present) — --add-dirs-ro must appear with
# the exact colon-joined value, and --enable=wide-read must still never
# appear.
run_wrap "$HOME_FULL" "$STUB_BIN:$PATH" -- \
  --worktree "$WT_PLAIN" --gitmeta "$GITMETA_PLAIN" --datadir "$DATADIR_PLAIN" -- true
assert_eq "argv-golden/exit-full-home" "$RC" "0" "stderr=$ERR"
got_ro_paths="$(argv_value_after '--add-dirs-ro' <<<"$OUT")"
assert_eq "argv-golden/add-dirs-ro-value" "$got_ro_paths" \
  "$HOME_FULL/.gitconfig:$HOME_FULL/.gitignore_global:$HOME_FULL/.opencode/bin"
has_wide_read2=0
grep -qF -- '--enable=wide-read' <<<"$OUT" && has_wide_read2=1
assert_eq "argv-golden/no-wide-read-full-home" "$has_wide_read2" "0" "argv=$OUT"

# ==============================================================================
# Item 5 — REAL_GITDIR normalization/containment state machine.
# ==============================================================================

# 5a. Explicit --real-gitdir arg, pointing at a genuine worktrees/<name>
# gitdir under GITMETA — passes containment via the explicit-arg branch
# (distinct code path from the self-resolve fallback exercised in 2b).
explicit_render="$SCRATCH/render-explicit-datadir"
mkdir -p "$explicit_render"
run_wrap "$HOME_EMPTY" "$STUB_BIN:$PATH" -- \
  --worktree "$linked_wt" --gitmeta "$gitmeta_base" --real-gitdir "$real_gitdir_b" \
  --datadir "$explicit_render" -- true
assert_eq "real-gitdir-explicit-arg/exit" "$RC" "0" "stderr=$ERR"
if [ "$RC" -eq 0 ]; then
  profile_explicit="$(find "$explicit_render" -maxdepth 1 -name 'imps-deny-profile.*' -print -quit 2>/dev/null)"
  explicit_ok=1
  grep -qF "$real_gitdir_b" "$profile_explicit" 2>/dev/null || explicit_ok=0
  assert "real-gitdir-explicit-arg/substituted" "$explicit_ok" "expected \"$real_gitdir_b\" in $profile_explicit"
fi

# 5b. --real-gitdir equal to --gitmeta exactly — collapses to the inert
# placeholder rather than reallowing $GITMETA wholesale. Needs a GITMETA with
# NO worktrees/ subtree (placement gotcha), else the fail-closed check in 5c
# fires first instead.
collapse_gitmeta="$SCRATCH/collapse-gitmeta"
git init -q --bare "$collapse_gitmeta" >/dev/null 2>&1
collapse_render="$SCRATCH/render-collapse-datadir"
mkdir -p "$collapse_render"
run_wrap "$HOME_EMPTY" "$STUB_BIN:$PATH" -- \
  --worktree "$WT_PLAIN" --gitmeta "$collapse_gitmeta" --real-gitdir "$collapse_gitmeta" \
  --datadir "$collapse_render" -- true
assert_eq "real-gitdir-equals-gitmeta-collapses/exit" "$RC" "0" "stderr=$ERR"
if [ "$RC" -eq 0 ]; then
  profile_collapse="$(find "$collapse_render" -maxdepth 1 -name 'imps-deny-profile.*' -print -quit 2>/dev/null)"
  collapse_ok=1
  grep -qF '(allow file-write* (subpath "/dev/null/unresolved-real-gitdir"))' "$profile_collapse" 2>/dev/null || collapse_ok=0
  assert "real-gitdir-equals-gitmeta-collapses/placeholder" "$collapse_ok" \
    "expected the unresolved placeholder rule in $profile_collapse"
fi

# 5c. worktrees/-exists fail-closed: GITMETA has a worktrees/ subtree but
# REAL_GITDIR is unresolved (no --real-gitdir, non-git WORKTREE) — must
# refuse rather than silently deny the whole subtree with nothing reallowed.
failclosed_gitmeta="$SCRATCH/failclosed-gitmeta"
mkdir -p "$failclosed_gitmeta/worktrees"
run_wrap "$HOME_EMPTY" "$STUB_BIN:$PATH" -- \
  --worktree "$WT_PLAIN" --gitmeta "$failclosed_gitmeta" --datadir "$DATADIR_PLAIN" -- true
assert_eq "worktrees-exists-fail-closed/exit" "$RC" "2" "stderr=$ERR"
assert_eq "worktrees-exists-fail-closed/message" "$ERR" \
  "sandbox-wrap: cannot resolve the worktree's gitdir, but $failclosed_gitmeta/worktrees exists — refusing to run with the whole linked-worktree subtree denied"

# 5d. Containment-reject: explicit --real-gitdir points at a real directory
# that is NOT under $GITMETA/worktrees.
outside_gitdir="$SCRATCH/outside-real-gitdir"
mkdir -p "$outside_gitdir"
run_wrap "$HOME_EMPTY" "$STUB_BIN:$PATH" -- \
  --worktree "$WT_PLAIN" --gitmeta "$GITMETA_PLAIN" --real-gitdir "$outside_gitdir" \
  --datadir "$DATADIR_PLAIN" -- true
assert_eq "real-gitdir-containment-reject/exit" "$RC" "2" "stderr=$ERR"
assert_eq "real-gitdir-containment-reject/message" "$ERR" \
  "sandbox-wrap: resolved gitdir is not under $GITMETA_PLAIN/worktrees: $outside_gitdir"

# ==============================================================================
# Item 6 — SANDBOX_MODE dispatch. Both arms are siblings of the `safehouse`
# arm in the same `case "$MODE"`, and neither touches `uname` — assertable
# without the uname stub in place.
# ==============================================================================
EXTRA_ENV=(SANDBOX_MODE=sbpl)
run_wrap "$HOME_EMPTY" "$PATH" --
EXTRA_ENV=()
assert_eq "sandbox-mode-sbpl/exit" "$RC" "2" "stderr=$ERR"
assert_eq "sandbox-mode-sbpl/message" "$ERR" \
  "sandbox-wrap: SANDBOX_MODE=sbpl is reserved but not implemented in v1 — see references/opencode-harness.md"

EXTRA_ENV=(SANDBOX_MODE=bogus-mode)
run_wrap "$HOME_EMPTY" "$PATH" --
EXTRA_ENV=()
assert_eq "sandbox-mode-unrecognised/exit" "$RC" "2" "stderr=$ERR"
assert_eq "sandbox-mode-unrecognised/message" "$ERR" \
  "sandbox-wrap: unrecognised SANDBOX_MODE: 'bogus-mode' (expected safehouse or sbpl)"

# ==============================================================================
# Item 7 — IMPS_SANDBOX_DANGEROUSLY_DISABLE bypass block.
# ==============================================================================

# 7a. Wrong value.
EXTRA_ENV=(IMPS_SANDBOX_DANGEROUSLY_DISABLE=nope)
run_wrap "$HOME_EMPTY" "$PATH" -- --check
EXTRA_ENV=()
assert_eq "bypass-wrong-value/exit" "$RC" "2" "stderr=$ERR"
assert_eq "bypass-wrong-value/message" "$ERR" \
  "sandbox-wrap: IMPS_SANDBOX_DANGEROUSLY_DISABLE is set to something other than 'i-accept-full-privilege' — refusing"

# 7b. Right value + no command — the message here must be EXACTLY
# "sandbox-wrap: no command given" (no trailing parenthetical); a substring
# assertion cannot distinguish this from the unrelated, later
# "no command given (use -- before the command)" required-arg check.
EXTRA_ENV=(IMPS_SANDBOX_DANGEROUSLY_DISABLE=i-accept-full-privilege)
run_wrap "$HOME_EMPTY" "$PATH" --
EXTRA_ENV=()
assert_eq "bypass-no-command/exit" "$RC" "2" "stderr=$ERR"
assert_eq "bypass-no-command/message" "$ERR" "sandbox-wrap: no command given"

# 7c. Right value + --check — exit 0, above the uname gate (no stub needed).
EXTRA_ENV=(IMPS_SANDBOX_DANGEROUSLY_DISABLE=i-accept-full-privilege)
run_wrap "$HOME_EMPTY" "$PATH" -- --check
EXTRA_ENV=()
assert_eq "bypass-check-only/exit" "$RC" "0" "stderr=$ERR"

# 7d. Right value + a real command — execs, warns on stderr (assert the
# warning text itself, not just non-empty stderr), and the command's own
# stdout must actually appear (proving it really exec'd).
EXTRA_ENV=(IMPS_SANDBOX_DANGEROUSLY_DISABLE=i-accept-full-privilege)
run_wrap "$HOME_EMPTY" "$PATH" -- echo bypass-marker-9f3a
EXTRA_ENV=()
assert_eq "bypass-runs-command/exit" "$RC" "0" "stderr=$ERR"
assert_eq "bypass-runs-command/stdout" "$OUT" "bypass-marker-9f3a"
assert_eq "bypass-runs-command/warning" "$ERR" \
  "sandbox-wrap: *** SANDBOX DISABLED (IMPS_SANDBOX_DANGEROUSLY_DISABLE) — running with full privilege ***"

# ==============================================================================
# Item 8 — resolve_safehouse precedence: IMPS_SAFEHOUSE_BIN set to a
# non-executable path fails outright, with NO PATH fallthrough (exclusivity,
# not just priority) — distinguished from the plain "not found" case, which
# shares the same message/exit code in this implementation.
# ==============================================================================
nonexec_safehouse="$SCRATCH/nonexec-safehouse"
: >"$nonexec_safehouse"
chmod -x "$nonexec_safehouse"

# 8a. IMPS_SAFEHOUSE_BIN non-executable, but a WORKING safehouse stub is on
# PATH and every other arg is fully valid: if the code fell through to PATH
# despite the explicit override being invalid, this would succeed (exit 0)
# instead of dying — the assertion below is genuinely distinguishing.
EXTRA_ENV=(IMPS_SAFEHOUSE_BIN="$nonexec_safehouse")
run_wrap "$HOME_EMPTY" "$STUB_BIN:$PATH" -- \
  --worktree "$WT_PLAIN" --gitmeta "$GITMETA_PLAIN" --datadir "$DATADIR_PLAIN" -- true
EXTRA_ENV=()
assert_eq "safehouse-bin-nonexec-no-fallthrough/exit" "$RC" "2" "stderr=$ERR"
assert_eq "safehouse-bin-nonexec-no-fallthrough/message" "$ERR" \
  "sandbox-wrap: safehouse not found (brew install agent-safehouse, or set IMPS_SAFEHOUSE_BIN)"

# 8b. Plain "not found": no IMPS_SAFEHOUSE_BIN override, and no `safehouse`
# anywhere on PATH (uname stub present so we still clear the Darwin gate).
# PATH is the stub dir plus plain /usr/bin:/bin ONLY — not the ambient
# $PATH — resolve_safehouse's `command -v safehouse` needs no external tool
# before this die, but the stub `uname`'s own `#!/usr/bin/env bash` shebang
# does need `bash` reachable, hence the bare system dirs. On a maintainer's
# own dev machine (unlike ubuntu-latest CI) a real `agent-safehouse` may well
# sit on the ambient PATH via Homebrew (/opt/homebrew/bin), which would
# silently find it and pass for the wrong reason if the ambient $PATH leaked
# in here. HOMEBREW_PREFIX is also overridden to a nonexistent path so
# resolve_safehouse's own hardcoded Homebrew-keg-only fallback locations
# can't find a real install either, for the same reason.
# HOMEBREW_PREFIX only neutralizes resolve_safehouse's two ${HOMEBREW_PREFIX}-
# relative fallbacks (sandbox-wrap.sh:105-106) — its THIRD fallback,
# /usr/local/opt/agent-safehouse/bin/safehouse, is a separate hardcoded
# literal (sandbox-wrap.sh:107) with no env override at all. On an Intel Mac
# that actually has agent-safehouse installed there, resolve_safehouse
# succeeds via that literal path regardless of HOMEBREW_PREFIX, and both
# assertions below would fail for the wrong reason (a real backend was
# found, not "sandbox-wrap.sh has a bug"). Skip rather than assert in that
# case — this is a real, uncontrollable host fact, not something the test's
# own env-pinning can neutralize.
if [ -x /usr/local/opt/agent-safehouse/bin/safehouse ]; then
  echo "skip safehouse-plain-not-found: real agent-safehouse present at the hardcoded Intel fallback path"
else
  EXTRA_ENV=(HOMEBREW_PREFIX="$SCRATCH/no-homebrew")
  run_wrap "$HOME_EMPTY" "$STUB_BIN_NO_SAFEHOUSE:/usr/bin:/bin" -- \
    --worktree "$WT_PLAIN" --gitmeta "$GITMETA_PLAIN" --datadir "$DATADIR_PLAIN" -- true
  EXTRA_ENV=()
  assert_eq "safehouse-plain-not-found/exit" "$RC" "2" "stderr=$ERR"
  assert_eq "safehouse-plain-not-found/message" "$ERR" \
    "sandbox-wrap: safehouse not found (brew install agent-safehouse, or set IMPS_SAFEHOUSE_BIN)"
fi

# ==============================================================================
echo "---"
if [ "$fails" -ne 0 ]; then
  echo "sandbox-wrap-shape: $fails assertion(s) failed" >&2
  exit 1
fi
echo "sandbox-wrap-shape: all assertions passed"
