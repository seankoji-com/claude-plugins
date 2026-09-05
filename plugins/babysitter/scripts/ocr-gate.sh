#!/usr/bin/env bash
#
# ocr-gate.sh — review the babysitter's own work before it is pushed.
#
# Every fix this plugin makes lands on someone's open PR, where a bad change costs a
# whole extra review round-trip. Running a review over the diff first turns that
# round-trip into a local loop: the agent reads the findings, fixes them, and pushes
# once.
#
# Tool selection, in order:
#   0. codex adversarial-review — tried first when the Codex plugin is installed and
#      usable. A completed verdict (approve or needs-attention) is authoritative and
#      is reported immediately; anything else (not installed, crashed, timed out, no
#      usable verdict) falls through to the chain below without comment — Codex is a
#      best-effort first opinion, not a required one.
#   1. ocr-pre-pr.sh — the user's own wrapper, if installed. Preferred because it
#      writes the HEAD-keyed cache entry their before-PR gate reads, so a babysitter
#      push and a hand-made push are gated by the same record.
#   2. ocr review — the upstream CLI, invoked directly.
#   3. ocr delegate — fallback when either of the above could not reach its LLM. Emits
#      a review spec instead of a review; the calling agent performs the review itself.
#   4. neither    — reports status=skipped and exits 0.
#
# Case 4 is deliberately fail-soft, which is the opposite of this repo's usual
# fail-closed rule, and the reason is the same one that exempts audit-log.sh: `ocr`
# (and now Codex) are optional third-party tools, not bundled dependencies. Hard-failing
# here would make the entire plugin unusable for anyone who has not installed them. What
# is NOT soft is the reporting — status=skipped is stated in the summary line so no agent
# can report a push as "reviewed" when nothing reviewed it.
#
# Case 3 exists because of a specific, observed failure. `ocr` talks to an LLM gateway
# over TLS, and in a sandboxed agent context that connection can fail for reasons that
# have nothing to do with the diff — a proxy whose certificate the Go TLS stack rejects
# (`x509: OSStatus -26276`) took out the gate on nearly every push of a 32-PR sweep.
# Each agent then judged the failure "infrastructure, not a code issue" and pushed
# unreviewed, which is exactly the judgment call a mandated gate exists not to depend
# on. `ocr delegate` needs no LLM at all, so it survives that failure and turns a
# skipped review into one the agent performs itself.
#
# Run this from inside the PR worktree.
#
# Usage:
#   ocr-gate.sh --base <base-ref> [--out <result.json>]
#
# Prints one summary line to stdout:
#   OCR status=<clean|findings|delegate|skipped|error> findings=<n> result=<path|-> tool=<name>
#
# Exit codes (0/1/2 match ocr-pre-pr.sh so the two are interchangeable to a caller):
#   0 — clean, or skipped because ocr is not installed
#   1 — the review produced findings; address them before pushing
#   2 — the review could not run and could not be delegated either
#   3 — the review could not run, but result= holds a delegation spec: review it
#       yourself before pushing. Not a licence to push unreviewed.

set -euo pipefail

# Prints this file's header comment as the help text. Derived from the header
# rather than a hardcoded line range: a `sed -n '2,NNp'` went stale the first time
# this header grew, printing a truncated help message with no other symptom.
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

BASE_REF=""
OUT=""

die() {
  echo "ocr-gate.sh: $1" >&2
  echo "OCR status=error findings=0 result=- tool=-"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
  --base)
    BASE_REF="${2:-}"
    shift 2
    ;;
  --out)
    OUT="${2:-}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "unknown argument: $1"
    ;;
  esac
done

# Lockfiles are regenerated wholesale and review findings on them are always noise.
# Defined up here because both the upstream-CLI path and the delegate fallback pass it.
EXCLUDE="package-lock.json,yarn.lock,pnpm-lock.yaml,bun.lockb,composer.lock,Cargo.lock,Gemfile.lock,poetry.lock,Pipfile.lock"

# Called on every path where a review was supposed to run and could not. Emits the
# summary line and exits — either with a delegation spec the agent can review from
# (exit 3), or with a plain error (exit 2). Never returns.
#
# The TLS hint is printed rather than swallowed because this failure is a property of
# the environment, not of the PR: fifteen agents on fifteen PRs will each hit it and
# each spend a reasoning turn concluding "infrastructure". Naming the cause once, at
# the point of failure, is what stops that.
delegate_or_die() {
  local tool="$1" errfile="$2"

  if [ -s "$errfile" ] && grep -qiE 'x509|certificate|tls|OSStatus' "$errfile" 2>/dev/null; then
    echo "ocr-gate.sh: this looks like a TLS trust failure reaching the review service, not a problem with the diff." >&2
    echo "ocr-gate.sh: a sandbox proxy that re-signs TLS will do this to Go-compiled clients; /sandbox is where that is inspected." >&2
  fi

  if command -v ocr >/dev/null 2>&1; then
    local spec="${OUT}.delegate.json"
    if ocr delegate preview \
      --from "$MERGE_BASE" --to "$HEAD_SHA" \
      --format json --exclude "$EXCLUDE" \
      >"$spec" 2>"${spec}.err" && [ -s "$spec" ]; then
      echo "ocr-gate.sh: ${tool} could not run; emitted a delegation spec instead — review it yourself before pushing" >&2
      echo "OCR status=delegate findings=unknown result=${spec} tool=ocr-delegate"
      exit 3
    fi
    echo "ocr-gate.sh: ocr delegate also failed" >&2
    sed -n '1,10p' "${spec}.err" >&2 || true
  fi

  echo "OCR status=error findings=0 result=- tool=${tool}"
  exit 2
}

# Codex is a separate, independently installed plugin — its script root isn't knowable
# ahead of time, so it's resolved at runtime from Claude Code's own install manifest
# (the same file every plugin is actually recorded in), preferring a user-scope install.
# `/codex:adversarial-review` itself can't be invoked here: its command frontmatter sets
# `disable-model-invocation: true`, which blocks the SlashCommand tool from calling it
# programmatically. This calls the same underlying runtime the slash command wraps
# (`codex-companion.mjs adversarial-review`) directly instead.
#
# Returns 1 (never exits) on anything short of a completed verdict, so the caller falls
# through to the existing ocr-pre-pr.sh / ocr / delegate chain untouched. Exits directly
# (0 clean, 1 findings) only once Codex has actually produced a verdict — that verdict is
# authoritative and is never double-checked by also running OCR.
try_codex() {
  local manifest="${BABYSITTER_CLAUDE_PLUGINS_MANIFEST:-$HOME/.claude/plugins/installed_plugins.json}"
  local codex_root="${BABYSITTER_CODEX_PLUGIN_ROOT:-}"
  if [ -z "$codex_root" ]; then
    [ -f "$manifest" ] || return 1
    codex_root="$(jq -r '
      (.plugins // {}) | to_entries[]
      | select(.key | startswith("codex@"))
      | .value[]? | select(.scope == "user") | .installPath
    ' "$manifest" 2>/dev/null | head -n1)"
    if [ -z "$codex_root" ]; then
      codex_root="$(jq -r '
        (.plugins // {}) | to_entries[]
        | select(.key | startswith("codex@"))
        | .value[0].installPath // empty
      ' "$manifest" 2>/dev/null | head -n1)"
    fi
  fi
  local companion="${codex_root:-}/scripts/codex-companion.mjs"
  [ -n "$codex_root" ] && [ -f "$companion" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  command -v codex >/dev/null 2>&1 || return 1
  command -v perl >/dev/null 2>&1 || return 1

  local result="${OUT}.codex.json" errfile="${OUT}.codex.err"
  set +e
  perl -e '$SIG{ALRM} = sub { exit 124 }; alarm shift @ARGV; exec @ARGV or exit 127' \
    "${BABYSITTER_CODEX_TIMEOUT:-300}" \
    node "$companion" adversarial-review --json --base "origin/${BASE_REF}" --cwd "$(pwd)" \
    >"$result" 2>"$errfile"
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || return 1
  jq -e '(.result != null) and ((.parseError // "") == "")' "$result" >/dev/null 2>&1 || return 1

  local verdict findings
  verdict="$(jq -r '.result.verdict // ""' "$result")"
  findings="$(jq -r '.result.findings | length' "$result" 2>/dev/null || echo unknown)"
  case "$verdict" in
  approve)
    echo "OCR status=clean findings=0 result=${result} tool=codex-adversarial-review"
    exit 0
    ;;
  needs-attention)
    echo "OCR status=findings findings=${findings} result=${result} tool=codex-adversarial-review"
    exit 1
    ;;
  *) return 1 ;;
  esac
}

[ -n "$BASE_REF" ] || die "--base <base-ref> is required"
command -v git >/dev/null 2>&1 || die "git not found on PATH"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git worktree"

# The result lands in the worktree's own git directory rather than a temp file: it
# is guaranteed to exist and be writable wherever the worktree is, it is never
# committed, and it disappears with the worktree. A mktemp default made the script
# die under a restricted TMPDIR before it could print its summary line, which left
# the caller parsing nothing at all.
if [ -z "$OUT" ]; then
  GIT_DIR_PATH="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
  if [ -n "$GIT_DIR_PATH" ] && [ -w "$GIT_DIR_PATH" ]; then
    OUT="${GIT_DIR_PATH}/babysitter-ocr-result.json"
  else
    OUT="$(mktemp -t babysitter-ocr.XXXXXX.json 2>/dev/null || true)"
    [ -n "$OUT" ] || die "cannot create a result file (git dir unwritable, mktemp failed)"
  fi
fi

# ---- nothing to review -------------------------------------------------------
# Checked before tool selection, not inside one branch of it. An empty diff is a
# clean review, and handing "no changed files" to a review CLI makes it exit as an
# error — which would report a perfectly fine push as status=error.
git fetch --quiet origin "$BASE_REF" >/dev/null 2>&1 || true
MERGE_BASE="$(git merge-base "origin/${BASE_REF}" HEAD 2>/dev/null || true)"
[ -n "$MERGE_BASE" ] || die "no merge-base between HEAD and origin/${BASE_REF}"
HEAD_SHA="$(git rev-parse HEAD)"

if [ "$MERGE_BASE" = "$HEAD_SHA" ] || git diff --quiet "$MERGE_BASE" "$HEAD_SHA"; then
  echo "ocr-gate.sh: no changes against origin/${BASE_REF} — nothing to review" >&2
  echo "OCR status=clean findings=0 result=- tool=-"
  exit 0
fi

# ---- Codex first, best-effort --------------------------------------------------
try_codex || true

# ---- no tool installed -------------------------------------------------------
if ! command -v ocr-pre-pr.sh >/dev/null 2>&1 && ! command -v ocr >/dev/null 2>&1; then
  echo "ocr-gate.sh: no ocr CLI on PATH — pre-push review skipped" >&2
  echo "OCR status=skipped findings=0 result=- tool=-"
  exit 0
fi

# ---- the user's own wrapper wins --------------------------------------------
if command -v ocr-pre-pr.sh >/dev/null 2>&1; then
  set +e
  OCR_BASE_REF="$BASE_REF" OCR_RESULT_PATH="$OUT" ocr-pre-pr.sh >"${OUT}.summary" 2>"${OUT}.err"
  rc=$?
  set -e
  case "$rc" in
  0) status="clean" ;;
  1) status="findings" ;;
  *)
    echo "ocr-gate.sh: ocr-pre-pr.sh failed (exit ${rc})" >&2
    sed -n '1,20p' "${OUT}.err" >&2 || true
    delegate_or_die "ocr-pre-pr.sh" "${OUT}.err"
    ;;
  esac
  findings="$(jq -r '.comments | length' "$OUT" 2>/dev/null || true)"
  case "$findings" in
  '' | *[!0-9]*) findings="unknown" ;;
  esac
  # "status=findings findings=0" would tell an agent there is nothing to fix while the
  # exit code says otherwise. When the count cannot be read, say so; the result file is
  # authoritative either way. Written as an if, not an && chain: under `set -e` a
  # trailing `&&` that evaluates false is itself a failing command and ends the script.
  if [ "$status" = "findings" ] && [ "$findings" = "0" ]; then
    findings="unknown"
  fi
  echo "OCR status=${status} findings=${findings} result=${OUT} tool=ocr-pre-pr.sh"
  if [ "$status" = "clean" ]; then
    exit 0
  fi
  exit 1
fi

# ---- upstream CLI ------------------------------------------------------------
set +e
ocr review \
  --from "$MERGE_BASE" --to "$HEAD_SHA" \
  --format json --audience agent \
  --exclude "$EXCLUDE" \
  --effort "${OCR_EFFORT:-low}" \
  >"$OUT" 2>"${OUT}.err"
rc=$?
set -e

if [ "$rc" -ne 0 ] && ! jq -e '.' "$OUT" >/dev/null 2>&1; then
  echo "ocr-gate.sh: ocr review failed (exit ${rc})" >&2
  sed -n '1,20p' "${OUT}.err" >&2 || true
  delegate_or_die "ocr" "${OUT}.err"
fi

# An unreadable count is reported as an error, not as clean. Silently treating a
# malformed result as "nothing found" is the one failure mode that would let this
# gate wave through exactly the pushes it exists to catch.
findings="$(jq -r '.comments | length' "$OUT" 2>/dev/null || true)"
case "$findings" in
'' | *[!0-9]*)
  echo "ocr-gate.sh: could not read a findings count from ${OUT}" >&2
  delegate_or_die "ocr" "${OUT}.err"
  ;;
esac

if [ "$findings" -eq 0 ]; then
  echo "OCR status=clean findings=0 result=${OUT} tool=ocr"
  exit 0
fi

echo "OCR status=findings findings=${findings} result=${OUT} tool=ocr"
exit 1
