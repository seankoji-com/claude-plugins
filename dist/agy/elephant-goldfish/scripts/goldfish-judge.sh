#!/usr/bin/env bash
#
# goldfish-judge.sh — ONE cold "goldfish" comprehension pass over a bootstrap doc.
#
# Runs the judge(s) on DIFFERENT-LINEAGE models so they do not share the Claude author's
# priors — that is what stops the loop from certifying its own guesses. The primary judge
# is the `gemini` CLI. An optional second opinion is available via `ollama` (set
# OLLAMA_MODEL). Both judges get the doc INLINED into the prompt — never handed file
# access — so no sandbox flags or workspace setup are needed to isolate them.
#
# This is the COMPREHENSION test (can a cold reader bootstrap the project from this doc
# ALONE?), not a truth test. It judges sufficiency, not accuracy. No-repo-access is
# deliberate: if the doc omits something, a true zero-context reader does not know it
# either, so giving the judge the code would let the doc cheat its gaps. A confidently
# WRONG doc can still pass this gate — that's not a bug, it's the shape of the test. Pair
# this with a separate factual-accuracy pass (see elephant.md's `check` mode) if subtle
# correctness matters as much as bootstrap-sufficiency.
#
# Exit codes:
#   0  = READY         (all run judges agree: READY)
#   10 = NOT READY     (at least one judge says NOT READY; report has the gaps)
#   2  = judge error   (empty output / no VERDICT line / requested CLI missing)
#   1  = usage
#
#   The 0/10/2 contract is preserved for callers regardless of how many judges run.
#   Consensus is fail-closed AND: READY only when every judge that ran says READY.
#   Worst case is always a false NOT-READY, never a false READY.
#
# VERIFY AGAINST YOUR `gemini` CLI ──────────────────────────────────────────────────────
#   CLI flags move between releases. Run `gemini --help` and confirm the two marked flags
#   below (model selector, one-shot prompt flag) still match. Do NOT point GEMINI_MODEL at
#   a Claude model — that reintroduces the clone problem this script exists to avoid.

set -euo pipefail

DOC="${1:-elephant.md}"
REPORT_OUT="${REPORT_OUT:-}"                 # optional: also write the combined report here
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-pro}"  # VERIFY: any Gemini model name
OLLAMA_MODEL="${OLLAMA_MODEL:-}"             # optional: any model name accepted by `ollama run`
                                             # honors OLLAMA_HOST for a remote instance
OLLAMA_NO_THINK="${OLLAMA_NO_THINK:-true}"  # prepend /no_think to suppress the <think> block on
                                             # qwen3 and other thinking models so VERDICT: is the
                                             # first output line; set false for non-thinking models
JUDGE_TIMEOUT="${JUDGE_TIMEOUT:-180}"       # seconds; guards gemini/ollama against hanging forever
                                             # (auth prompt, network stall, model load)

# Portable timeout wrapper: prefers GNU coreutils `timeout`, falls back to `gtimeout`
# (Homebrew coreutils on macOS). If neither is on PATH, judge calls run unguarded — a warning
# is printed rather than refusing to run, since the fail-closed VERDICT-line check below still
# catches a hang's empty/partial output as ERROR once the process is eventually killed some
# other way; this only loses the bounded-wait guarantee, not the fail-closed correctness.
TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout "$JUDGE_TIMEOUT")
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(gtimeout "$JUDGE_TIMEOUT")
else
  echo "goldfish-judge: no 'timeout'/'gtimeout' on PATH — judge calls are NOT time-bounded." >&2
fi

# Classify a report. Echoes one of: READY | NOT_READY | ERROR
# grep -m1 finds the first VERDICT line anywhere in the output, tolerant of any preamble
# a CLI prints before it.
classify() {
  local report="$1" verdict
  if [ -z "${report//[[:space:]]/}" ]; then echo ERROR; return; fi
  verdict="$(printf '%s\n' "$report" | grep -m1 -iE 'VERDICT:[[:space:]]*(NOT[[:space:]]+)?READY' || true)"
  if [ -z "$verdict" ]; then echo ERROR; return; fi
  if   printf '%s' "$verdict" | grep -qiE 'NOT[[:space:]]+READY'; then echo NOT_READY
  elif printf '%s' "$verdict" | grep -qiE 'READY';                then echo READY
  else echo ERROR; fi
}

# tests/run.sh sources this file with __SOURCED__=1 to unit-test classify() without
# running the judges below. Everything past this line is the "do the thing" tail.
${__SOURCED__:+false} : || return 0

[ -f "$DOC" ] || { echo "goldfish-judge: doc not found: $DOC" >&2; exit 1; }
command -v gemini >/dev/null 2>&1 || { echo "goldfish-judge: 'gemini' not on PATH" >&2; exit 2; }

# Cold-read isolation: run from an EMPTY scratch dir so `gemini` doesn't pick up this
# repo's own GEMINI.md/context files from cwd (some CLIs auto-load a context file at
# workspace root). Nothing is copied into it — the doc is inlined into the prompt text
# below, so the judge needs no file access at all.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/goldfish.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# Shared judging criteria + prompt framing used by all judges (doc inlined, no file access).
JUDGE_SPEC="$(cat <<'SPEC_EOF'
Decide whether this document ALONE lets a zero-context reader bootstrap the project —
understand what it is and why, how it is architected and how the components relate,
and where in the code each major component lives.

OUTPUT FORMAT — follow exactly:
- The VERY FIRST LINE must be exactly:  VERDICT: READY   or   VERDICT: NOT READY
- READY means that from THIS DOCUMENT ALONE you can (a) explain what the project does and
  why, (b) describe its architecture and how the components relate, and (c) know which file
  or directory owns each component because the document names specific paths. You are judging
  whether the doc TELLS you where to look — you cannot and need not open those paths. Give a
  3-5 sentence summary that demonstrates (a), (b), and (c).
- NOT READY means it failed one of those. List each failure as a numbered, specific gap:
  what you could not determine, the exact section or claim involved, why a cold reader is
  blocked, and what the document must add or correct.
- Judge sufficiency for bootstrapping, not writing quality. Do not propose redesigns. A
  near-universal convention a competent engineer already knows is not a gap. A component
  whose owning path the doc names is navigable even though you cannot open it.
SPEC_EOF
)"

DOC_CONTENTS="$(cat "$DOC")"
PROMPT="$(cat <<PROMPT_EOF
You are a brand-new engineer with zero prior knowledge of this project. The ONLY
information you have is the design document pasted below — you have NO access to the
source repository or any other file. If the document does not tell you something, you do
not know it — do not assume, infer from convention, or imagine code you cannot see.

$JUDGE_SPEC

----- BEGIN DOCUMENT -----
$DOC_CONTENTS
----- END DOCUMENT -----
PROMPT_EOF
)"

# ── Judge 1: gemini (inline prompt, no file access, no sandbox flags needed) ────────────
gemini_raw="$(cd "$SCRATCH" && "${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"}" gemini -m "$GEMINI_MODEL" -p "$PROMPT" 2>&1 || true)"
gemini_class="$(classify "$gemini_raw")"
[ "$gemini_class" = ERROR ] && echo "goldfish-judge: gemini judge produced no usable verdict. NOT a pass." >&2

combined="===== JUDGE 1: gemini / $GEMINI_MODEL =====
$gemini_raw"

# ── Judge 2: ollama (optional, sequential) ───────────────────────────────────────────────
ollama_class="READY"   # neutral default when Ollama is disabled; doesn't affect consensus
if [ -n "$OLLAMA_MODEL" ]; then
  if command -v ollama >/dev/null 2>&1; then
    ollama_err="$(mktemp "${TMPDIR:-/tmp}/goldfish-ollama-err.XXXXXX")"
    _prefix=""
    # /no_think prefix tells qwen3 and compatible models to skip their <think> block so the
    # very first output token is VERDICT:, matching the format spec. Ignored by other models.
    [ "$OLLAMA_NO_THINK" = "true" ] && _prefix="/no_think
"
    ollama_raw="$("${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"}" ollama run "$OLLAMA_MODEL" "${_prefix}${PROMPT}" 2>"$ollama_err" || true)"
    ollama_class="$(classify "$ollama_raw")"
    if [ "$ollama_class" = ERROR ]; then
      echo "goldfish-judge: ollama judge produced no usable verdict. NOT a pass." >&2
      tail -5 "$ollama_err" >&2
    fi
    rm -f "$ollama_err"
    combined="$combined

===== JUDGE 2: ollama / $OLLAMA_MODEL =====
$ollama_raw"
  else
    echo "goldfish-judge: OLLAMA_MODEL set but 'ollama' not on PATH. NOT a pass." >&2
    ollama_class="ERROR"
  fi
fi

[ -n "$REPORT_OUT" ] && printf '%s\n' "$combined" > "$REPORT_OUT"
printf '%s\n' "$combined"

# ── Fail-closed AND consensus ─────────────────────────────────────────────────────────────
if [ "$gemini_class" = ERROR ] || [ "$ollama_class" = ERROR ]; then
  echo "goldfish-judge: a judge errored / produced no verdict. NOT a pass. See report." >&2
  exit 2
fi
if [ "$gemini_class" = NOT_READY ] || [ "$ollama_class" = NOT_READY ]; then exit 10; fi
exit 0
