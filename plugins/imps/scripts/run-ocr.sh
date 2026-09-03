#!/usr/bin/env bash
# run-ocr.sh — isolated, read-only OpenCodeReview (OCR) diff review for /imps.
#
# The final stdout line is always this JSON contract. All diagnostics stay on stderr:
# {"status":"ok|blocked","verdict":"APPROVE|CHANGES_REQUESTED|null","findings":[],
#  "model":"…","provider":"…","session_id":"…|null","duration_ms":0,
#  "cost_usd":0|null,"reason":"…|null"}
#
# Engine: `@alibaba-group/open-code-review` (the `ocr` CLI), NOT the OpenCode agent.
# Those are unrelated tools with confusingly similar names; this file used to run the
# latter and was named for it.
#
# Why the swap: OpenCode issued one completion covering the entire diff, which reliably
# timed out against a self-hosted OpenAI-compatible endpoint once a diff got large — a
# 2,752-line diff killed it twice, at 99s and at 120s (exit 143), producing no verdict.
# A review that cannot return is a gate that cannot pass. OCR is a purpose-built diff
# reviewer: it chunks per file and fans out with --concurrency, so review cost scales
# with the widest file rather than with the whole changeset.
#
# OCR reviews `--from <base> --to <head>` against the real repository and has no tool
# surface that can mutate it, so this does not build the deny-everything snapshot the
# OpenCode implementation needed. The source-mutation assertion is kept anyway: it is
# two git calls, and it is the check that would catch an engine that started writing.
set -uo pipefail

exec 3>&1
exec 1>&2

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
OCR_BIN="${IMPS_OCR_BIN:-ocr}"
OCR_PIN_VERSION="${IMPS_OCR_VERSION:-1.10.1}"
OPENCODE_CONFIG_PATH="${IMPS_OPENCODE_CONFIG_PATH:-$HOME/.config/opencode/opencode.json}"
RULE_PATH="${IMPS_OCR_RULE:-$PLUGIN_ROOT/references/ocr-review-rule.json}"

REPO=""
BASE=""
HEAD="HEAD"
GOAL=""
MODEL="${IMPS_OCR_MODEL:-deepseek-v4-flash}"
PROVIDER="litellm"
CONCURRENCY="${IMPS_OCR_CONCURRENCY:-4}"
TIMEOUT_SECONDS="${IMPS_OCR_TIMEOUT:-900}"
CHECK_ONLY=0

STATUS="blocked"
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
    printf '{"status":"blocked","verdict":null,"findings":[],"model":null,"provider":null,"session_id":null,"duration_ms":0,"cost_usd":null,"reason":"jq_missing"}\n' >&3
    return
  fi
  jq -nc \
    --arg status "$STATUS" \
    --arg verdict "$VERDICT" \
    --argjson findings "$FINDINGS" \
    --arg model "$MODEL" \
    --arg provider "$PROVIDER" \
    --arg session_id "$SESSION_ID" \
    --arg reason "$REASON" \
    --argjson duration_ms "$(duration_ms)" \
    --argjson cost_usd "$(json_number "$COST_USD")" \
    '{status:$status, verdict:(if $verdict == "" then null else $verdict end), findings:$findings, model:$model, provider:(if $provider == "" then null else $provider end), session_id:(if $session_id == "" then null else $session_id end), duration_ms:$duration_ms, cost_usd:$cost_usd, reason:(if $reason == "" then null else $reason end)}' >&3
}

cleanup() { [ -z "$TMP_ROOT" ] || rm -rf "$TMP_ROOT"; }
on_exit() { cleanup; emit_contract; }
trap on_exit EXIT
trap '[ -z "$REVIEW_PID" ] || kill -TERM "$REVIEW_PID" 2>/dev/null; exit 129' HUP
trap '[ -z "$REVIEW_PID" ] || kill -TERM "$REVIEW_PID" 2>/dev/null; exit 130' INT
trap '[ -z "$REVIEW_PID" ] || kill -TERM "$REVIEW_PID" 2>/dev/null; exit 143' TERM

fail() {
  REASON="$1"
  [ -n "${2:-}" ] && log "$2"
  exit 1
}

usage() {
  cat >&2 <<'USAGE'
Usage: run-ocr.sh --repo <path> --base <sha-or-ref> --goal <GOAL.md>
                  [--head <sha-or-ref>] [--model <model-id>]
                  [--concurrency <n>] [--timeout <seconds>] [--check]
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --head) HEAD="${2:-}"; shift 2 ;;
    --goal) GOAL="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; REASON="help"; exit 0 ;;
    *) usage; fail bad_arguments "unknown argument: $1" ;;
  esac
done

case "$TIMEOUT_SECONDS" in ''|0|*[!0-9]*) fail bad_arguments "--timeout must be a positive integer" ;; esac
case "$CONCURRENCY" in ''|0|*[!0-9]*) fail bad_arguments "--concurrency must be a positive integer" ;; esac
[ -n "$MODEL" ] || fail bad_arguments "--model must not be empty"

command -v jq >/dev/null 2>&1 || fail jq_missing "jq is required"
command -v git >/dev/null 2>&1 || fail git_missing "git is required"
command -v perl >/dev/null 2>&1 || fail timeout_unsupported 'perl is required for the portable timeout guard'
[ -f "$RULE_PATH" ] || fail rule_missing "review rule file is missing: $RULE_PATH"

# ---- Endpoint credentials --------------------------------------------------------
# Reuse the LiteLLM provider block already configured for OpenCode rather than asking
# for a second copy of the same endpoint and key. IMPS_OCR_URL / IMPS_OCR_TOKEN win
# when set, so pointing this at a different endpoint needs no config file at all.
OCR_URL="${IMPS_OCR_URL:-}"
OCR_TOKEN="${IMPS_OCR_TOKEN:-}"
if [ -z "$OCR_URL" ] || [ -z "$OCR_TOKEN" ]; then
  [ -f "$OPENCODE_CONFIG_PATH" ] || fail provider_config_missing "set IMPS_OCR_URL and IMPS_OCR_TOKEN, or configure the litellm provider in $OPENCODE_CONFIG_PATH"
  [ -z "$OCR_URL" ] && OCR_URL="$(jq -r '.provider.litellm.options.baseURL // empty' "$OPENCODE_CONFIG_PATH" 2>/dev/null)"
  [ -z "$OCR_TOKEN" ] && OCR_TOKEN="$(jq -r '.provider.litellm.options.apiKey // empty' "$OPENCODE_CONFIG_PATH" 2>/dev/null)"
fi
[ -n "$OCR_URL" ] || fail provider_config_missing 'no endpoint: set IMPS_OCR_URL or provider.litellm.options.baseURL'
[ -n "$OCR_TOKEN" ] || fail provider_config_missing 'no credential: set IMPS_OCR_TOKEN or provider.litellm.options.apiKey'
# OpenCode stores the proxy root and appends the OpenAI path itself; OCR expects the
# OpenAI-compatible base. Normalise rather than making the operator keep two spellings.
case "$OCR_URL" in
  */v1|*/v1/) OCR_URL="${OCR_URL%/}" ;;
  *) OCR_URL="${OCR_URL%/}/v1" ;;
esac

# ---- OCR install -----------------------------------------------------------------
# Gate on the *installed version*, not on presence. A presence-only check leaves a stale
# global install in place forever, and `command -v` alone can find a launcher whose
# platform binary never finished downloading — that dies at the review call with exit
# 127, after every setup step has already run.
export OCR_NO_UPDATE=1  # else bin/ocr.js detaches an updater that reinstalls mid-run
if ! "$OCR_BIN" version 2>/dev/null | grep -qF "v${OCR_PIN_VERSION} "; then
  command -v npm >/dev/null 2>&1 || fail ocr_missing "npm is required to install @alibaba-group/open-code-review@${OCR_PIN_VERSION}"
  npm install -g "@alibaba-group/open-code-review@${OCR_PIN_VERSION}" >/dev/null 2>&1 \
    || fail ocr_install_failed "cannot install @alibaba-group/open-code-review@${OCR_PIN_VERSION}"
fi
command -v "$OCR_BIN" >/dev/null 2>&1 || fail ocr_missing 'ocr is not on PATH'
"$OCR_BIN" version 2>/dev/null | grep -qF "v${OCR_PIN_VERSION} " \
  || fail ocr_version_mismatch "ocr is not pinned version ${OCR_PIN_VERSION}"
"$OCR_BIN" review --help 2>&1 | grep -q -- '--format' || fail flags_unsupported 'ocr review lacks --format'

if [ "$CHECK_ONLY" = 1 ]; then
  STATUS="ok"
  REASON=""
  exit 0
fi

# ---- Inputs ----------------------------------------------------------------------
[ -n "$REPO" ] && [ -n "$BASE" ] && [ -n "$GOAL" ] || { usage; fail bad_arguments '--repo, --base, and --goal are required unless using --check'; }
REPO="$(cd "$REPO" 2>/dev/null && pwd -P)" || fail bad_arguments '--repo is not a directory'
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail bad_arguments '--repo is not a git worktree'
git -C "$REPO" rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || fail bad_arguments '--base is not a commit'
git -C "$REPO" rev-parse --verify "$HEAD^{commit}" >/dev/null 2>&1 || fail bad_arguments '--head is not a commit'
[ -f "$GOAL" ] || fail bad_arguments '--goal is not a readable file'

SOURCE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
SOURCE_STATUS="$(git -C "$REPO" status --porcelain=v1)"
MERGE_BASE="$(git -C "$REPO" merge-base "$BASE" "$HEAD" 2>/dev/null)" || fail bad_arguments 'cannot compute merge-base'
[ -n "$MERGE_BASE" ] || fail bad_arguments 'cannot compute merge-base'
HEAD_SHA="$(git -C "$REPO" rev-parse "$HEAD")"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/imps-ocr-review.XXXXXX")" || fail tmpdir_failed 'cannot create temporary review directory'
mkdir -p "$TMP_ROOT/home" || fail tmpdir_failed 'cannot initialize temporary review directory'

# ---- Background: the acceptance criteria the diff is judged against ---------------
# OCR caps background context; the reference implementation warns at 7800 chars and
# truncates to 7500. GOAL.md is the Definition of Done plus Global Constraints, which
# is exactly what a reviewer needs and is normally well inside that cap.
BACKGROUND_FILE="$TMP_ROOT/background.md"
{
  printf '%s\n' 'This diff is judged against the acceptance criteria below. A finding must name a'
  printf '%s\n\n' 'concrete breaking scenario and a concrete fix. Do not manufacture findings.'
  cat "$GOAL"
} > "$BACKGROUND_FILE" || fail snapshot_failed 'cannot capture GOAL.md as review background'
BG_CHARS="$(wc -c < "$BACKGROUND_FILE" | tr -d ' ')"
if [ "$BG_CHARS" -gt 7800 ]; then
  log "background is ${BG_CHARS} chars; truncating to 7500"
  head -c 7500 "$BACKGROUND_FILE" > "$BACKGROUND_FILE.trunc" \
    && printf '\n...(truncated)\n' >> "$BACKGROUND_FILE.trunc" \
    && mv "$BACKGROUND_FILE.trunc" "$BACKGROUND_FILE"
fi

# ---- Run ---------------------------------------------------------------------------
export HOME="$TMP_ROOT/home"          # keep `ocr config set` out of the real HOME
export OCR_LLM_URL="$OCR_URL"
export OCR_LLM_TOKEN="$OCR_TOKEN"
export OCR_LLM_MODEL="$MODEL"
export OCR_LLM_TIMEOUT="${IMPS_OCR_LLM_TIMEOUT:-180}"

"$OCR_BIN" config set language English >/dev/null 2>&1 || true

RESULT_PATH="$TMP_ROOT/result.json"
run_with_timeout() {
  # `exec` means Perl becomes OCR, so the alarm kills the reviewed process itself and
  # cannot leave a watchdog child behind. macOS ships Perl; see the preflight.
  perl -e '$SIG{ALRM} = sub { exit 124 }; alarm shift @ARGV; exec @ARGV or exit 127' \
    "$TIMEOUT_SECONDS" "$@" >"$RESULT_PATH" 2>"$TMP_ROOT/ocr.err" &
  REVIEW_PID=$!
  wait "$REVIEW_PID"
  local rc=$?
  REVIEW_PID=""
  return "$rc"
}

run_with_timeout "$OCR_BIN" review \
  --from "$MERGE_BASE" --to "$HEAD_SHA" \
  --format json \
  --concurrency "$CONCURRENCY" \
  --rule "$RULE_PATH" \
  --background-file "$BACKGROUND_FILE"
RUN_RC=$?
# `exec` resets Perl's signal handler but keeps its alarm on macOS, so an alarm can
# surface as SIGALRM's 142 exit status instead of Perl's requested 124.
if [ "$RUN_RC" -eq 124 ] || [ "$RUN_RC" -eq 142 ]; then fail timeout 'OCR review timed out'; fi
[ "$RUN_RC" -eq 0 ] || { log "$(tail -n 20 "$TMP_ROOT/ocr.err" 2>/dev/null)"; fail ocr_failed 'OCR review did not complete'; }

# ---- Map OCR output onto the imps review contract ----------------------------------
# OCR emits {"comments":[{path,start_line,end_line,body}], …} and has no severity field
# of its own, so references/ocr-review-rule.json instructs it to prefix every comment
# body with [blocker]/[major]/[minor]/[nit]. An untagged comment falls back to `major`:
# unclassifiable review output must block rather than quietly pass, which is the same
# fail-closed rule the rest of this gate follows.
jq -e 'type == "object"' "$RESULT_PATH" >/dev/null 2>&1 \
  || { log "$(head -c 400 "$RESULT_PATH" 2>/dev/null)"; fail malformed_verdict 'OCR did not emit a JSON object'; }
if ! jq -e 'has("comments")' "$RESULT_PATH" >/dev/null 2>&1; then
  # OCR reports "nothing to review" as a message with no comments key.
  if jq -e 'has("message")' "$RESULT_PATH" >/dev/null 2>&1; then
    log "OCR produced no comments: $(jq -r '.message' "$RESULT_PATH")"
    VERDICT="APPROVE"; FINDINGS="[]"; STATUS="ok"; REASON=""
  else
    fail malformed_verdict 'OCR result has neither "comments" nor "message"'
  fi
else
  FINDINGS="$(jq -c '
    def sev($b): ($b | ascii_downcase
      | if test("^\\s*\\[?blocker\\b") then "blocker"
        elif test("^\\s*\\[?major\\b") then "major"
        elif test("^\\s*\\[?minor\\b") then "minor"
        elif test("^\\s*\\[?nit\\b") then "nit"
        else "major" end);
    [ .comments[]
      | (.body // .content // "") as $b
      | { severity: sev($b),
          path: (.path // ""),
          line: (((.start_line // .end_line // .line // 1)
                  | if type == "number" then . else 1 end)
                 | if . < 1 then 1 else . end),
          message: ($b | sub("^\\s*\\[?(blocker|major|minor|nit)\\]?[:\\s-]*"; ""; "i")) }
      | select(.path != "" and .message != "")
    ]' "$RESULT_PATH")" || fail malformed_verdict 'cannot map OCR comments onto the review contract'
  printf '%s' "$FINDINGS" | jq -e '
    type == "array" and all(.[];
      type == "object" and
      (.severity | IN("blocker","major","minor","nit")) and
      (.path | type == "string") and (.line | type == "number") and (.line >= 1) and
      (.message | type == "string") and (.message | length > 0))
  ' >/dev/null 2>&1 || fail malformed_verdict 'mapped findings did not satisfy the review contract'
  # OCR has no verdict of its own: a blocker or major is the blocking signal, matching
  # the contract's own rule that APPROVE may not carry either.
  if printf '%s' "$FINDINGS" | jq -e 'any(.[]; .severity == "blocker" or .severity == "major")' >/dev/null 2>&1; then
    VERDICT="CHANGES_REQUESTED"
  else
    VERDICT="APPROVE"
  fi
  STATUS="ok"; REASON=""
fi

AFTER_HEAD="$(git -C "$REPO" rev-parse HEAD)"
AFTER_STATUS="$(git -C "$REPO" status --porcelain=v1)"
[ "$SOURCE_HEAD" = "$AFTER_HEAD" ] && [ "$SOURCE_STATUS" = "$AFTER_STATUS" ] || fail source_mutated 'the source checkout changed during review'

exit 0
