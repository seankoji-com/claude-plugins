#!/usr/bin/env bash
# run-codex-review.sh — isolated, read-only Codex adversarial-review attempt for /imps.
#
# The final stdout line is always this JSON contract. All diagnostics stay on stderr:
# {"status":"ok|blocked|skip","verdict":"APPROVE|CHANGES_REQUESTED|null","findings":[],
#  "model":"…","provider":"codex|null","session_id":"…|null","duration_ms":0,
#  "cost_usd":null,"reason":"…|null"}
#
# This is not a standalone gate: `scripts/run-code-review.sh` calls this first and falls
# back to `scripts/run-ocr.sh` on `status: "skip"`. Every failure mode short of an actual
# source mutation is a skip, not a block — Codex is a best-effort first opinion, and OCR
# remains the fail-closed backstop. Exit codes carry that distinction because the caller
# needs it before it can even parse JSON:
#   0 — status ok (Codex produced a verdict; authoritative, do not also run OCR)
#   1 — status blocked (source_mutated only — a real integrity failure, do not fall back)
#   2 — status skip (Codex unavailable, timed out, or produced no usable verdict — fall
#       back to OCR)
#
# `/codex:adversarial-review` cannot be invoked here: its command frontmatter sets
# `disable-model-invocation: true`, which blocks the SlashCommand tool from calling it
# programmatically — only a human typing it in chat can. This script instead calls the
# same underlying runtime the slash command wraps
# (`scripts/codex-companion.mjs adversarial-review`) directly, exactly as run-ocr.sh calls
# the `ocr` CLI directly instead of going through `/open-code-review:review`.
#
# Codex is a separate, independently installed plugin, so its script path isn't knowable
# at authoring time. It's resolved at runtime from Claude Code's own
# `~/.gemini/config/plugins/installed_plugins.json` (the same file the harness consults to know
# where any plugin is actually installed on this machine) — not hardcoded, and not
# guessed from a directory layout.
set -uo pipefail

exec 3>&1
exec 1>&2

NODE_BIN="${IMPS_CODEX_NODE_BIN:-node}"
CODEX_BIN="${IMPS_CODEX_BIN:-codex}"
PLUGINS_MANIFEST="${IMPS_CLAUDE_PLUGINS_MANIFEST:-~/.gemini/config/plugins/installed_plugins.json}"

REPO=""
BASE=""
HEAD="HEAD"
GOAL=""
MODEL="${IMPS_CODEX_MODEL:-}"
TIMEOUT_SECONDS="${IMPS_CODEX_TIMEOUT:-300}"
CHECK_ONLY=0

STATUS="skip"
VERDICT=""
FINDINGS="[]"
SESSION_ID=""
COST_USD=""
REASON="unknown"
EMITTED=0
REVIEW_PID=""
TMP_ROOT=""
START_NS="$(date +%s000000000 2>/dev/null || echo 0)"

log() { printf '%s\n' "$*" >&2; }

duration_ms() {
  local now
  now="$(date +%s000000000 2>/dev/null || echo 0)"
  if [ "$START_NS" = 0 ] || [ "$now" = 0 ]; then printf '0'; else printf '%s' $(( (now - START_NS) / 1000000 )); fi
}

json_number() {
  case "${1:-}" in
    ''|*[!0-9.]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

emit_contract() {
  [ "$EMITTED" = 0 ] || return
  EMITTED=1
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"status":"skip","verdict":null,"findings":[],"model":null,"provider":null,"session_id":null,"duration_ms":0,"cost_usd":null,"reason":"jq_missing"}\n' >&3
    return
  fi
  jq -nc \
    --arg status "$STATUS" \
    --arg verdict "$VERDICT" \
    --argjson findings "$FINDINGS" \
    --arg model "$MODEL" \
    --arg provider "codex" \
    --arg session_id "$SESSION_ID" \
    --arg reason "$REASON" \
    --argjson duration_ms "$(duration_ms)" \
    --argjson cost_usd "$(json_number "$COST_USD")" \
    '{status:$status, verdict:(if $verdict == "" then null else $verdict end), findings:$findings, model:(if $model == "" then null else $model end), provider:$provider, session_id:(if $session_id == "" then null else $session_id end), duration_ms:$duration_ms, cost_usd:$cost_usd, reason:(if $reason == "" then null else $reason end)}' >&3
}

cleanup() { [ -z "$TMP_ROOT" ] || rm -rf "$TMP_ROOT"; }
on_exit() { cleanup; emit_contract; }
trap on_exit EXIT
trap '[ -z "$REVIEW_PID" ] || kill -TERM "$REVIEW_PID" 2>/dev/null; exit 129' HUP
trap '[ -z "$REVIEW_PID" ] || kill -TERM "$REVIEW_PID" 2>/dev/null; exit 130' INT
trap '[ -z "$REVIEW_PID" ] || kill -TERM "$REVIEW_PID" 2>/dev/null; exit 143' TERM

# Distinct from `skip`: a real integrity failure. Never falls back to OCR.
blocked() {
  STATUS="blocked"
  REASON="$1"
  [ -n "${2:-}" ] && log "$2"
  exit 1
}

# Codex unavailable, timed out, crashed, or produced no usable verdict. The caller falls
# back to OCR — this is the expected, common outcome on a machine without Codex set up.
skip() {
  STATUS="skip"
  REASON="$1"
  [ -n "${2:-}" ] && log "$2"
  exit 2
}

bad_arguments() {
  STATUS="blocked"
  REASON="bad_arguments"
  [ -n "${1:-}" ] && log "$1"
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage: run-codex-review.sh --repo <path> --base <sha-or-ref> --goal <GOAL.md>
                            [--head <sha-or-ref>] [--model <model-id>]
                            [--timeout <seconds>] [--concurrency <n>] [--check]
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --head) HEAD="${2:-}"; shift 2 ;;
    --goal) GOAL="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --concurrency) shift 2 ;; # accepted for arg-forwarding parity with run-ocr.sh; unused
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; STATUS="skip"; REASON="help"; exit 0 ;;
    *) usage; bad_arguments "unknown argument: $1" ;;
  esac
done

case "$TIMEOUT_SECONDS" in ''|0|*[!0-9]*) bad_arguments "--timeout must be a positive integer" ;; esac

command -v jq >/dev/null 2>&1 || { STATUS="skip"; REASON="jq_missing"; exit 2; }
command -v git >/dev/null 2>&1 || { STATUS="skip"; REASON="git_missing"; exit 2; }
command -v perl >/dev/null 2>&1 || skip timeout_unsupported 'perl is required for the portable timeout guard'

# ---- Locate the installed Codex plugin ---------------------------------------------
# Codex is optional and lives in a separate, independently-installed plugin. Resolve its
# script root at runtime rather than assuming a path: prefer an explicit override, then
# ask Claude Code's own install manifest, preferring a user-scope install.
resolve_codex_root() {
  if [ -n "${IMPS_CODEX_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$IMPS_CODEX_PLUGIN_ROOT"
    return 0
  fi
  [ -f "$PLUGINS_MANIFEST" ] || return 1
  local root
  root="$(jq -r '
    (.plugins // {}) | to_entries[]
    | select(.key | startswith("codex@"))
    | .value[]?
    | select(.scope == "user")
    | .installPath
  ' "$PLUGINS_MANIFEST" 2>/dev/null | head -n1)"
  if [ -z "$root" ]; then
    root="$(jq -r '
      (.plugins // {}) | to_entries[]
      | select(.key | startswith("codex@"))
      | .value[0].installPath // empty
    ' "$PLUGINS_MANIFEST" 2>/dev/null | head -n1)"
  fi
  [ -n "$root" ] || return 1
  printf '%s' "$root"
}

CODEX_ROOT="$(resolve_codex_root)" || CODEX_ROOT=""
COMPANION_SCRIPT="$CODEX_ROOT/scripts/codex-companion.mjs"

if [ "$CHECK_ONLY" = 1 ]; then
  # Best-effort and informational only: Codex not being set up is a normal, expected
  # outcome, not a failure of this preflight. `run-code-review.sh` never fails its own
  # --check on this script's exit code — only on run-ocr.sh's.
  if [ -z "$CODEX_ROOT" ] || [ ! -f "$COMPANION_SCRIPT" ]; then
    skip codex_plugin_not_installed "no codex@* entry with a readable script root in $PLUGINS_MANIFEST"
  fi
  command -v "$NODE_BIN" >/dev/null 2>&1 || skip node_missing "$NODE_BIN is not on PATH"
  command -v "$CODEX_BIN" >/dev/null 2>&1 || skip codex_cli_missing "$CODEX_BIN is not on PATH"
  STATUS="ok"; REASON=""
  exit 0
fi

[ -n "$REPO" ] && [ -n "$BASE" ] && [ -n "$GOAL" ] || { usage; bad_arguments '--repo, --base, and --goal are required unless using --check'; }
REPO="$(cd "$REPO" 2>/dev/null && pwd -P)" || bad_arguments '--repo is not a directory'
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || bad_arguments '--repo is not a git worktree'
git -C "$REPO" rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || bad_arguments '--base is not a commit'
git -C "$REPO" rev-parse --verify "$HEAD^{commit}" >/dev/null 2>&1 || bad_arguments '--head is not a commit'
[ -f "$GOAL" ] || bad_arguments '--goal is not a readable file'

if [ -z "$CODEX_ROOT" ] || [ ! -f "$COMPANION_SCRIPT" ]; then
  skip codex_plugin_not_installed "no codex@* entry with a readable script root in $PLUGINS_MANIFEST"
fi
command -v "$NODE_BIN" >/dev/null 2>&1 || skip node_missing "$NODE_BIN is not on PATH"
command -v "$CODEX_BIN" >/dev/null 2>&1 || skip codex_cli_missing "$CODEX_BIN is not on PATH"

SOURCE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
SOURCE_STATUS="$(git -C "$REPO" status --porcelain=v1)"
MERGE_BASE="$(git -C "$REPO" merge-base "$BASE" "$HEAD" 2>/dev/null)" || bad_arguments 'cannot compute merge-base'
[ -n "$MERGE_BASE" ] || bad_arguments 'cannot compute merge-base'

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/imps-codex-review.XXXXXX")" || { STATUS="skip"; REASON="tmpdir_failed"; exit 2; }

# ---- Focus text: the acceptance criteria the diff is judged against ---------------
# `/codex:adversarial-review` takes free-text focus after its flags (no --background-file
# of its own, unlike OCR); GOAL.md is the Definition of Done plus Global Constraints, so
# pass it the same way run-ocr.sh passes its background — capped for the same reason.
FOCUS_FILE="$TMP_ROOT/focus.md"
{
  printf '%s\n' 'This diff is judged against the acceptance criteria below. A finding must name a'
  printf '%s\n\n' 'concrete breaking scenario and a concrete fix. Do not manufacture findings.'
  cat "$GOAL"
} > "$FOCUS_FILE" || { STATUS="skip"; REASON="snapshot_failed"; exit 2; }
FOCUS_CHARS="$(wc -c < "$FOCUS_FILE" | tr -d ' ')"
if [ "$FOCUS_CHARS" -gt 7800 ]; then
  log "focus text is ${FOCUS_CHARS} chars; truncating to 7500"
  head -c 7500 "$FOCUS_FILE" > "$FOCUS_FILE.trunc" \
    && printf '\n...(truncated)\n' >> "$FOCUS_FILE.trunc" \
    && mv "$FOCUS_FILE.trunc" "$FOCUS_FILE"
fi
FOCUS_TEXT="$(cat "$FOCUS_FILE")"

RESULT_PATH="$TMP_ROOT/result.json"
CODEX_ARGS=(adversarial-review --json --base "$MERGE_BASE")
[ -n "$MODEL" ] && CODEX_ARGS+=(--model "$MODEL")
CODEX_ARGS+=(--cwd "$REPO" "$FOCUS_TEXT")

run_with_timeout() {
  # `exec` means Perl becomes the node process, so the alarm kills the reviewed process
  # itself and cannot leave a watchdog child behind. macOS ships Perl; see the preflight.
  perl -e '$SIG{ALRM} = sub { exit 124 }; alarm shift @ARGV; exec @ARGV or exit 127' \
    "$TIMEOUT_SECONDS" "$@" >"$RESULT_PATH" 2>"$TMP_ROOT/codex.err" &
  REVIEW_PID=$!
  wait "$REVIEW_PID"
  local rc=$?
  REVIEW_PID=""
  return "$rc"
}

run_with_timeout "$NODE_BIN" "$COMPANION_SCRIPT" "${CODEX_ARGS[@]}"
RUN_RC=$?
# `exec` resets Perl's signal handler but keeps its alarm on macOS, so an alarm can
# surface as SIGALRM's 142 exit status instead of Perl's requested 124.
if [ "$RUN_RC" -eq 124 ] || [ "$RUN_RC" -eq 142 ]; then
  skip timeout 'Codex adversarial review timed out'
fi
if [ "$RUN_RC" -ne 0 ]; then
  log "$(tail -n 20 "$TMP_ROOT/codex.err" 2>/dev/null)"
  skip codex_run_failed "codex-companion.mjs exited ${RUN_RC}"
fi

# ---- Map Codex output onto the imps review contract --------------------------------
jq -e 'type == "object"' "$RESULT_PATH" >/dev/null 2>&1 \
  || { log "$(head -c 400 "$RESULT_PATH" 2>/dev/null)"; skip malformed_payload 'Codex did not emit a JSON object'; }

if ! jq -e '(.result != null) and ((.parseError // "") == "")' "$RESULT_PATH" >/dev/null 2>&1; then
  PARSE_ERROR="$(jq -r '.parseError // "no structured result"' "$RESULT_PATH" 2>/dev/null)"
  skip codex_parse_error "Codex produced no usable structured verdict: ${PARSE_ERROR}"
fi

RAW_VERDICT="$(jq -r '.result.verdict // ""' "$RESULT_PATH")"
case "$RAW_VERDICT" in
  approve) VERDICT="APPROVE" ;;
  needs-attention) VERDICT="CHANGES_REQUESTED" ;;
  *) skip codex_unexpected_verdict "unexpected verdict: ${RAW_VERDICT}" ;;
esac

FINDINGS="$(jq -c '
  def sev($s): ($s | ascii_downcase
    | if . == "critical" then "blocker"
      elif . == "high" then "major"
      elif . == "medium" then "minor"
      else "nit" end);
  [ .result.findings[]?
    | { severity: sev(.severity // "low"),
        path: (.file // ""),
        line: (((.line_start // .line_end // 1) | if type == "number" then . else 1 end)
               | if . < 1 then 1 else . end),
        message: (
          ([(.title // ""), (.body // "")] | map(select(length > 0)) | join(": ")) as $base
          | (.recommendation // "") as $rec
          | if ($rec | length) > 0 then ($base + " Fix: " + $rec) else $base end
        )
      }
    | select(.path != "" and .message != "")
  ]' "$RESULT_PATH" 2>/dev/null)" || FINDINGS="[]"

printf '%s' "$FINDINGS" | jq -e '
  type == "array" and all(.[];
    type == "object" and
    (.severity | IN("blocker","major","minor","nit")) and
    (.path | type == "string") and (.line | type == "number") and (.line >= 1) and
    (.message | type == "string") and (.message | length > 0))
' >/dev/null 2>&1 || skip malformed_payload 'mapped findings did not satisfy the review contract'

SESSION_ID="$(jq -r '.threadId // ""' "$RESULT_PATH")"
[ -n "$MODEL" ] || MODEL="codex-default"

AFTER_HEAD="$(git -C "$REPO" rev-parse HEAD)"
AFTER_STATUS="$(git -C "$REPO" status --porcelain=v1)"
[ "$SOURCE_HEAD" = "$AFTER_HEAD" ] && [ "$SOURCE_STATUS" = "$AFTER_STATUS" ] || blocked source_mutated 'the source checkout changed during review'

STATUS="ok"; REASON=""
exit 0
