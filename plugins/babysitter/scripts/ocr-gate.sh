#!/usr/bin/env bash
#
# ocr-gate.sh — review the babysitter's own work before it is pushed.
#
# Every fix this plugin makes lands on someone's open PR, where a bad change costs a
# whole extra review round-trip. Running OpenCodeReview (`ocr`) over the diff first
# turns that round-trip into a local loop: the agent reads the findings, fixes them,
# and pushes once.
#
# Tool selection, in order:
#   1. ocr-pre-pr.sh — the user's own wrapper, if installed. Preferred because it
#      writes the HEAD-keyed cache entry their before-PR gate reads, so a babysitter
#      push and a hand-made push are gated by the same record.
#   2. ocr review — the upstream CLI, invoked directly.
#   3. neither    — reports status=skipped and exits 0.
#
# Case 3 is deliberately fail-soft, which is the opposite of this repo's usual
# fail-closed rule, and the reason is the same one that exempts audit-log.sh: `ocr`
# is an optional third-party CLI, not a bundled dependency. Hard-failing here would
# make the entire plugin unusable for anyone who has not installed it. What is NOT
# soft is the reporting — status=skipped is stated in the summary line so no agent
# can report a push as "reviewed" when nothing reviewed it.
#
# Run this from inside the PR worktree.
#
# Usage:
#   ocr-gate.sh --base <base-ref> [--out <result.json>]
#
# Prints one summary line to stdout:
#   OCR status=<clean|findings|skipped|error> findings=<n> result=<path|-> tool=<name>
#
# Exit codes (matching ocr-pre-pr.sh so the two are interchangeable to a caller):
#   0 — clean, or skipped because ocr is not installed
#   1 — the review produced findings; address them before pushing
#   2 — the review could not run (no merge-base, credential or CLI error)

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
    echo "OCR status=error findings=0 result=- tool=ocr-pre-pr.sh"
    exit 2
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
# Lockfiles are regenerated wholesale and review findings on them are always noise.
EXCLUDE="package-lock.json,yarn.lock,pnpm-lock.yaml,bun.lockb,composer.lock,Cargo.lock,Gemfile.lock,poetry.lock,Pipfile.lock"

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
  echo "OCR status=error findings=0 result=- tool=ocr"
  exit 2
fi

# An unreadable count is reported as an error, not as clean. Silently treating a
# malformed result as "nothing found" is the one failure mode that would let this
# gate wave through exactly the pushes it exists to catch.
findings="$(jq -r '.comments | length' "$OUT" 2>/dev/null || true)"
case "$findings" in
'' | *[!0-9]*)
  echo "ocr-gate.sh: could not read a findings count from ${OUT}" >&2
  echo "OCR status=error findings=unknown result=${OUT} tool=ocr"
  exit 2
  ;;
esac

if [ "$findings" -eq 0 ]; then
  echo "OCR status=clean findings=0 result=${OUT} tool=ocr"
  exit 0
fi

echo "OCR status=findings findings=${findings} result=${OUT} tool=ocr"
exit 1
