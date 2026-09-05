#!/usr/bin/env bash
# run-code-review.sh — the /imps:imps code-review gate entrypoint.
#
# Tries a Codex adversarial review first (scripts/run-codex-review.sh); falls back to
# OpenCodeReview (scripts/run-ocr.sh) whenever Codex is unavailable, times out, or
# produces no usable verdict. A completed Codex review — approve or needs-attention — is
# authoritative and is never second-guessed by also running OCR: Codex is a genuinely
# different reviewer, not a pre-filter, and running both on a "needs-attention" verdict
# would just be shopping for a clean pass. See references/codex-review.md and
# references/ocr-review.md for the two engines' own contracts and failure modes.
#
# Same CLI surface and output contract as run-ocr.sh, so this is a drop-in replacement
# for it as the /imps:imps gate: {"status":"ok|blocked","verdict":...,"findings":[...],
# "model":...,"provider":...,"session_id":...,"duration_ms":...,"cost_usd":...,"reason":...}
#
# --check must still pass on OCR alone: OCR is the mandatory backstop, Codex is optional.
# A missing Codex install is normal and never fails --check.
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
CODEX_LEG="${IMPS_CODEX_REVIEW_SCRIPT:-$PLUGIN_ROOT/scripts/run-codex-review.sh}"
OCR_LEG="${IMPS_OCR_REVIEW_SCRIPT:-$PLUGIN_ROOT/scripts/run-ocr.sh}"

log() { printf '%s\n' "$*" >&2; }

CHECK_ONLY=0
for arg in "$@"; do
  [ "$arg" = "--check" ] && CHECK_ONLY=1
done

if [ "$CHECK_ONLY" = 1 ]; then
  if [ -x "$CODEX_LEG" ]; then
    "$CODEX_LEG" "$@" >/dev/null 2>&1
    codex_check_rc=$?
    if [ "$codex_check_rc" = 0 ]; then
      log "run-code-review.sh: Codex adversarial review is available and will be tried first"
    else
      log "run-code-review.sh: Codex adversarial review is not available (exit ${codex_check_rc}); OCR will run alone"
    fi
  else
    log "run-code-review.sh: $CODEX_LEG is missing or not executable; OCR will run alone"
  fi
  exec "$OCR_LEG" "$@"
fi

if [ ! -x "$CODEX_LEG" ]; then
  log "run-code-review.sh: $CODEX_LEG is missing or not executable; skipping straight to OCR"
  exec "$OCR_LEG" "$@"
fi

TMP_RESULT="$(mktemp "${TMPDIR:-/tmp}/imps-code-review-result.XXXXXX")" || {
  log "run-code-review.sh: cannot create temporary result file"
  exec "$OCR_LEG" "$@"
}

"$CODEX_LEG" "$@" >"$TMP_RESULT"
codex_rc=$?

# `exec` replaces this process image and never runs an EXIT trap, so every exit path
# below cleans up $TMP_RESULT itself rather than relying on one.
case "$codex_rc" in
  0)
    log "run-code-review.sh: Codex adversarial review completed; using its verdict"
    cat "$TMP_RESULT"
    rm -f "$TMP_RESULT"
    exit 0
    ;;
  1)
    log "run-code-review.sh: Codex adversarial review reported a blocking integrity failure; not falling back to OCR"
    cat "$TMP_RESULT"
    rm -f "$TMP_RESULT"
    exit 1
    ;;
  *)
    reason="$(command -v jq >/dev/null 2>&1 && jq -r '.reason // "unknown"' "$TMP_RESULT" 2>/dev/null)"
    log "run-code-review.sh: Codex adversarial review unavailable (${reason:-exit $codex_rc}); falling back to OCR"
    rm -f "$TMP_RESULT"
    exec "$OCR_LEG" "$@"
    ;;
esac
