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
# A review that ran but did not cover everything is not clean either. `ocr` publishes
# partial results and exits 0 when only some files failed (a gateway 5xx on one request,
# an exhausted token budget), with a well-formed `comments` array that says nothing about
# the files it never reviewed. The files it could not review are listed under
# `manifest.coverage.failed`, so a "clean" verdict is only issued when that list is empty;
# otherwise the run is handled exactly like one that could not run (case 3, then exit 2).
#
# There is no flag that waives a failed gate: every failure above exits non-zero. The
# only switches tighten it. BABYSITTER_REVIEW_REQUIRED=1 turns case 4 from skipped
# (exit 0) into blocked (exit 2) for hosts that must not push without a review tool, and
# BABYSITTER_REVIEW_TIMEOUT (default 300s) bounds each external tool call; a call that
# times out is a failed call, not a clean one.
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
#   2 — the review could not run (or was incomplete) and could not be delegated either;
#       also case 4 when BABYSITTER_REVIEW_REQUIRED=1
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
  echo "OCR status=error findings=0 result=- tool=- head=${HEAD_SHA:-unknown} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE:-unknown}"
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

REVIEW_HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
bounded() { python3 "$REVIEW_HELPERS/run-bounded.py" "${BABYSITTER_REVIEW_TIMEOUT:-300}" "$@"; }
assert_revision() {
  [ "$(git rev-parse HEAD)" = "$HEAD_SHA" ] && [ "$(git status --porcelain=v1)" = "$SOURCE_STATUS" ] || die "reviewed checkout changed during review"
}

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
    if bounded ocr delegate preview \
      --from "$MERGE_BASE" --to "$HEAD_SHA" \
      --format json --exclude "$EXCLUDE" \
      >"$spec" 2>"${spec}.err" && [ -s "$spec" ]; then
      echo "ocr-gate.sh: ${tool} could not run; emitted a delegation spec instead — review it yourself before pushing" >&2
      echo "OCR status=delegate findings=unknown result=${spec} tool=ocr-delegate head=${HEAD_SHA:-unknown} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE:-unknown}"
      exit 3
    fi
    echo "ocr-gate.sh: ocr delegate also failed" >&2
    sed -n '1,10p' "${spec}.err" >&2 || true
  fi

  echo "OCR status=error findings=0 result=- tool=${tool} head=${HEAD_SHA:-unknown} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE:-unknown}"
  exit 2
}

# Called before a result is reported clean. A result can be well-formed, exit 0, and still
# describe a review that did not cover the diff (see the header): such a result goes down
# the same path as a review that could not run. Never returns when coverage is incomplete
# or cannot be read, and when the coverage field is present but not an array (malformed
# data is not evidence of completeness). A field that is absent altogether (an older ocr, a
# wrapper that writes its own format) counts as complete: nothing contradicts the verdict.
require_full_coverage() {
  local tool="$1" result="$2" errfile="$3" reason
  if ! reason="$(jq -r '
      if (.status // "") == "failed" or (.manifest.terminal_state // "") == "failed" then "the run reported failure"
      else .manifest.coverage.failed as $f
        | if $f == null then empty
          elif ($f | type) != "array" then "coverage data is malformed"
          elif ($f | length) > 0 then "\($f | length) file(s) not reviewed"
          else empty end
      end' "$result" 2>/dev/null)"; then
    reason="coverage could not be read from the result"
  fi
  if [ -n "$reason" ]; then
    echo "ocr-gate.sh: ${tool} produced an incomplete review (${reason}); a partial review is not a clean review" >&2
    delegate_or_die "$tool" "$errfile"
  fi
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
  local root goal result rc
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  goal="$(pwd)/GOAL.md"
  if [ ! -f "$goal" ]; then
    goal="${OUT}.goal.md"
    printf '%s\n' 'Review the changed code for concrete correctness and security defects, against the repository conventions. Report unavailable acceptance context; never infer that product requirements passed.' > "$goal"
  fi
  result="${OUT}.codex.json"
  set +e
  IMPS_CODEX_TIMEOUT="${BABYSITTER_CODEX_TIMEOUT:-300}" \
    "$root/run-codex-review.sh" --repo "$(pwd)" --base "$MERGE_BASE" --head "$HEAD_SHA" --goal "$goal" > "$result"
  rc=$?
  set -e
  if [ "$rc" -eq 1 ]; then
    echo "OCR status=error findings=unknown result=${result} tool=codex-adversarial-review head=${HEAD_SHA} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE}"
    exit 2
  fi
  [ "$rc" -eq 0 ] || return 1
  case "$(jq -r '.verdict' "$result")" in
    APPROVE) echo "OCR status=clean findings=0 result=${result} tool=codex-adversarial-review head=${HEAD_SHA} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE}"; exit 0 ;;
    CHANGES_REQUESTED) echo "OCR status=findings findings=$(jq '.findings | length' "$result") result=${result} tool=codex-adversarial-review head=${HEAD_SHA} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE}"; exit 1 ;;
    *) return 1 ;;
  esac
}

[ -n "$BASE_REF" ] || die "--base <base-ref> is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required for bounded review timeouts"
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
BASE_FRESH=true
if ! bounded git fetch --quiet origin "$BASE_REF" >/dev/null 2>&1; then
  BASE_FRESH=false
  echo "ocr-gate.sh: cannot refresh base; reviewing the cached base revision only" >&2
fi
MERGE_BASE="$(git merge-base "origin/${BASE_REF}" HEAD 2>/dev/null || true)"
[ -n "$MERGE_BASE" ] || die "no merge-base between HEAD and origin/${BASE_REF}"
HEAD_SHA="$(git rev-parse HEAD)"
SOURCE_STATUS="$(git status --porcelain=v1)"

if [ "$MERGE_BASE" = "$HEAD_SHA" ] || git diff --quiet "$MERGE_BASE" "$HEAD_SHA"; then
  echo "ocr-gate.sh: no changes against origin/${BASE_REF} — nothing to review" >&2
  echo "OCR status=clean findings=0 result=- tool=- head=${HEAD_SHA:-unknown} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE:-unknown}"
  exit 0
fi

# ---- Codex first, best-effort --------------------------------------------------
try_codex || true

# ---- no tool installed -------------------------------------------------------
if ! command -v ocr-pre-pr.sh >/dev/null 2>&1 && ! command -v ocr >/dev/null 2>&1; then
  echo "ocr-gate.sh: no ocr CLI on PATH — pre-push review skipped" >&2
  echo "OCR status=skipped findings=0 result=- tool=- head=${HEAD_SHA:-unknown} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE:-unknown}"
  [ "${BABYSITTER_REVIEW_REQUIRED:-0}" = 1 ] && exit 2
  exit 0
fi

# ---- the user's own wrapper wins --------------------------------------------
if command -v ocr-pre-pr.sh >/dev/null 2>&1; then
  set +e
  OCR_BASE_REF="$BASE_REF" OCR_RESULT_PATH="$OUT" bounded ocr-pre-pr.sh >"${OUT}.summary" 2>"${OUT}.err"
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
  assert_revision
  if [ "$status" = clean ] && ! jq -e '.comments | type == "array"' "$OUT" >/dev/null 2>&1; then
    echo "ocr-gate.sh: ocr-pre-pr.sh returned success without a valid findings array" >&2
    delegate_or_die "ocr-pre-pr.sh" "${OUT}.err"
  fi
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
  if [ "$status" = clean ] && [ "$findings" != 0 ]; then status=findings; fi
  if [ "$status" = clean ]; then require_full_coverage "ocr-pre-pr.sh" "$OUT" "${OUT}.err"; fi
  echo "OCR status=${status} findings=${findings} result=${OUT} tool=ocr-pre-pr.sh head=${HEAD_SHA:-unknown} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE:-unknown}"
  if [ "$status" = "clean" ]; then
    exit 0
  fi
  exit 1
fi

# ---- upstream CLI ------------------------------------------------------------
set +e
bounded ocr review \
  --from "$MERGE_BASE" --to "$HEAD_SHA" \
  --format json --audience agent \
  --exclude "$EXCLUDE" \
  --effort "${OCR_EFFORT:-low}" \
  >"$OUT" 2>"${OUT}.err"
rc=$?
set -e

assert_revision
if [ "$rc" -ne 0 ] || ! jq -e '.comments | type == "array"' "$OUT" >/dev/null 2>&1; then
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
  require_full_coverage "ocr" "$OUT" "${OUT}.err"
  echo "OCR status=clean findings=0 result=${OUT} tool=ocr head=${HEAD_SHA:-unknown} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE:-unknown}"
  exit 0
fi

echo "OCR status=findings findings=${findings} result=${OUT} tool=ocr head=${HEAD_SHA:-unknown} base_fresh=${BASE_FRESH:-false} base=${MERGE_BASE:-unknown}"
exit 1
