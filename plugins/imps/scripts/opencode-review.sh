#!/usr/bin/env bash
# opencode-review.sh — isolated, read-only OpenCode diff review for /imps.
#
# The final stdout line is always this JSON contract. All diagnostics stay on stderr:
# {"status":"ok|blocked","verdict":"APPROVE|CHANGES_REQUESTED|null","findings":[],
#  "model":"…","provider":"…","session_id":"…|null","duration_ms":0,
#  "cost_usd":0|null,"reason":"…|null"}
#
# This deliberately does not reuse opencode-dispatch.sh. Dispatch edits a worktree and
# commits. This helper copies only the reviewed diff into a disposable snapshot, denies
# OpenCode tools that could mutate or reach outside it, and verifies the source checkout
# did not change before returning a verdict.
set -uo pipefail

exec 3>&1
exec 1>&2

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
OPENCODE_BIN="${IMPS_OPENCODE_BIN:-opencode}"
AUTH_PATH="${IMPS_OPENCODE_AUTH_PATH:-$HOME/.local/share/opencode/auth.json}"
MODEL="${IMPS_OPENCODE_REVIEW_MODEL:-openai/gpt-5.6-terra}"
VARIANT="${IMPS_OPENCODE_REVIEW_VARIANT:-high}"
REPO=""
BASE=""
HEAD="HEAD"
GOAL=""
TIMEOUT_SECONDS="300"
CHECK_ONLY=0

STATUS="blocked"
VERDICT=""
FINDINGS='[]'
PROVIDER=""
SESSION_ID=""
COST_USD=""
REASON="unexpected_exit"
START_EPOCH="$(date +%s 2>/dev/null || printf '0')"
TMP_ROOT=""
SNAPSHOT=""
AUTH_COPY=""
EMITTED=0
REVIEW_PID=""

log() { printf 'opencode-review: %s\n' "$*" >&2; }

json_string() { jq -Rn --arg value "${1:-}" '$value'; }
json_number() {
  case "${1:-}" in
    ''|*[!0-9.]*|*.*.*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

duration_ms() {
  local now
  now="$(date +%s 2>/dev/null || printf '0')"
  case "$START_EPOCH:$now" in
    *[!0-9:]*|:) printf '0' ;;
    *) printf '%s' "$(( (now - START_EPOCH) * 1000 ))" ;;
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

cleanup() {
  [ -z "$TMP_ROOT" ] || rm -rf "$TMP_ROOT"
}
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
Usage: opencode-review.sh --repo <path> --base <sha-or-ref> --goal <GOAL.md>
                          [--head <sha-or-ref>] [--model <provider/model>]
                          [--variant <reasoning-effort>]
                          [--timeout <seconds>] [--check]
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --head) HEAD="${2:-}"; shift 2 ;;
    --goal) GOAL="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --variant) VARIANT="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; REASON="help"; exit 0 ;;
    *) usage; fail bad_arguments "unknown argument: $1" ;;
  esac
done

case "$MODEL" in
  openai/*) PROVIDER="openai" ;;
  openrouter/openai/*) PROVIDER="openrouter" ;;
  # Deliberately scoped, not a blanket `openrouter/*`: opening the whole openrouter
  # namespace would also admit `openrouter/anthropic/*`, routing a Claude model through
  # here — the exact thing this guard exists to block. deepseek is allowlisted by name.
  openrouter/deepseek/*) PROVIDER="openrouter" ;;
  *) fail model_rejected "model must be openai/*, openrouter/openai/*, or openrouter/deepseek/*" ;;
esac
case "$VARIANT" in
  ''|none|low|medium|high|xhigh|max) ;;
  *) fail bad_arguments "--variant must be one of: none low medium high xhigh max" ;;
esac
case "$TIMEOUT_SECONDS" in ''|0|*[!0-9]*) fail bad_arguments "--timeout must be a positive integer" ;; esac

command -v jq >/dev/null 2>&1 || fail jq_missing "jq is required"
command -v "$OPENCODE_BIN" >/dev/null 2>&1 || fail opencode_missing "opencode is not on PATH"
command -v perl >/dev/null 2>&1 || fail timeout_unsupported 'perl is required for the portable timeout guard'
[ -f "$AUTH_PATH" ] || fail auth_missing "selected provider credential is unavailable"
jq -e --arg provider "$PROVIDER" 'has($provider)' "$AUTH_PATH" >/dev/null 2>&1 || fail auth_missing "selected provider credential is unavailable"
"$OPENCODE_BIN" run --help 2>&1 | grep -q -- '--format' || fail flags_unsupported 'opencode run lacks --format'
"$OPENCODE_BIN" run --help 2>&1 | grep -q 'json' || fail flags_unsupported 'opencode run lacks JSON output'

# Query in a temporary XDG tree too. Provider state must never leak into the real config.
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/imps-opencode-review.XXXXXX")" || fail tmpdir_failed 'cannot create temporary review directory'
mkdir -p "$TMP_ROOT"/{data/opencode,state,config/opencode,cache,tmp} || fail tmpdir_failed 'cannot initialize temporary review directory'
AUTH_COPY="$TMP_ROOT/data/opencode/auth.json"
jq --arg provider "$PROVIDER" 'with_entries(select(.key == $provider))' "$AUTH_PATH" > "$AUTH_COPY" || fail auth_copy_failed 'cannot isolate selected provider credential'
chmod 600 "$AUTH_COPY" || fail auth_copy_failed 'cannot protect temporary credential copy'
export XDG_DATA_HOME="$TMP_ROOT/data"
export XDG_STATE_HOME="$TMP_ROOT/state"
export XDG_CONFIG_HOME="$TMP_ROOT/config"
export XDG_CACHE_HOME="$TMP_ROOT/cache"
export TMPDIR="$TMP_ROOT/tmp"

"$OPENCODE_BIN" models "$PROVIDER" --pure --verbose >"$TMP_ROOT/models.json" 2>"$TMP_ROOT/models.err" || fail model_unavailable 'opencode could not list the selected provider models'
jq -e --arg model "$MODEL" '.. | strings | select(. == $model)' "$TMP_ROOT/models.json" >/dev/null 2>&1 || fail model_unavailable 'configured model is not reported by opencode'

if [ "$CHECK_ONLY" = 1 ]; then
  STATUS="ok"
  REASON=""
  exit 0
fi

[ -n "$REPO" ] && [ -n "$BASE" ] && [ -n "$GOAL" ] || { usage; fail bad_arguments '--repo, --base, and --goal are required unless using --check'; }
REPO="$(cd "$REPO" 2>/dev/null && pwd -P)" || fail bad_arguments '--repo is not a directory'
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail bad_arguments '--repo is not a git worktree'
git -C "$REPO" rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || fail bad_arguments '--base is not a commit'
git -C "$REPO" rev-parse --verify "$HEAD^{commit}" >/dev/null 2>&1 || fail bad_arguments '--head is not a commit'
[ -f "$GOAL" ] || fail bad_arguments '--goal is not a readable file'

SOURCE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
SOURCE_STATUS="$(git -C "$REPO" status --porcelain=v1)"
SNAPSHOT="$TMP_ROOT/snapshot"
mkdir -p "$SNAPSHOT/changed" "$SNAPSHOT/standards" || fail snapshot_failed 'cannot initialize review snapshot'
git -C "$REPO" diff --binary "$BASE..$HEAD" -- ':!*lock*' ':!dist' > "$SNAPSHOT/diff.patch" || fail snapshot_failed 'cannot capture reviewed diff'
git -C "$REPO" diff --name-only "$BASE..$HEAD" -- ':!*lock*' ':!dist' > "$TMP_ROOT/paths"
while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  case "$path" in *..*|/*) fail snapshot_failed 'unsafe changed path from git' ;; esac
  mkdir -p "$SNAPSHOT/changed/$(dirname "$path")" || fail snapshot_failed 'cannot create changed-file path'
  if git -C "$REPO" cat-file -e "$HEAD:$path" 2>/dev/null; then
    git -C "$REPO" show "$HEAD:$path" > "$SNAPSHOT/changed/$path" || fail snapshot_failed 'cannot capture changed file'
  fi
done < "$TMP_ROOT/paths"
git -C "$REPO" ls-files | grep -E '(^|/)(AGENTS\.md|CLAUDE\.md|CONTRIBUTING\.md|CODING_STANDARDS\.md)$' > "$TMP_ROOT/standards" || true
while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  mkdir -p "$SNAPSHOT/standards/$(dirname "$path")"
  git -C "$REPO" show "$HEAD:$path" > "$SNAPSHOT/standards/$path" 2>/dev/null || true
done < "$TMP_ROOT/standards"
cp "$GOAL" "$SNAPSHOT/GOAL.md" || fail snapshot_failed 'cannot capture GOAL.md'
cp "$PLUGIN_ROOT/agents/head-imp.md" "$SNAPSHOT/head-imp.md" || fail snapshot_failed 'cannot capture review brief'

cat > "$TMP_ROOT/config/opencode/opencode.json" <<'JSON'
{
  "permission": {
    "edit": "deny",
    "bash": { "*": "deny" },
    "task": "deny",
    "webfetch": "deny",
    "external_directory": "deny"
  }
}
JSON

cat > "$SNAPSHOT/REVIEW_PROMPT.md" <<'PROMPT'
Review only the supplied snapshot. Do not attempt edits, commands, delegation, web access,
or external-directory access. The snapshot contains diff.patch, complete changed files,
repository standards, GOAL.md, and the shared Head Imp review brief.

Apply the brief's architecture, line-correctness, and contract-fit checks. Read the full
changed files before judging them. A blocker or major must identify a concrete breaking
scenario and a concrete fix. Do not manufacture findings.

Your final non-empty text line MUST be exactly one JSON object prefixed by `IMPS_REVIEW_V1 `:
IMPS_REVIEW_V1 {"verdict":"APPROVE","findings":[]}
or
IMPS_REVIEW_V1 {"verdict":"CHANGES_REQUESTED","findings":[{"severity":"major","path":"path","line":1,"message":"concrete breaking scenario and fix"}]}

Only severities blocker, major, minor, nit are allowed. APPROVE requires no blocker or
major findings. Do not include Markdown fences or any extra text on that final line.
PROMPT

run_with_timeout() {
  # `exec` means Perl becomes OpenCode, so alarm kills the actual reviewed process and
  # cannot leave a watchdog/sleep child behind. macOS includes Perl; see the preflight.
  perl -e '$SIG{ALRM} = sub { exit 124 }; alarm shift @ARGV; exec @ARGV or exit 127' \
    "$TIMEOUT_SECONDS" "$@" >"$TMP_ROOT/events.jsonl" 2>"$TMP_ROOT/opencode.err" &
  REVIEW_PID=$!
  wait "$REVIEW_PID"
  local rc=$?
  REVIEW_PID=""
  return "$rc"
}

if [ -n "$VARIANT" ]; then
  run_with_timeout "$OPENCODE_BIN" run --pure --dir "$SNAPSHOT" --model "$MODEL" --variant "$VARIANT" --format json "$(cat "$SNAPSHOT/REVIEW_PROMPT.md")"
else
  run_with_timeout "$OPENCODE_BIN" run --pure --dir "$SNAPSHOT" --model "$MODEL" --format json "$(cat "$SNAPSHOT/REVIEW_PROMPT.md")"
fi
RUN_RC=$?
# `exec` resets Perl's signal handler but keeps its alarm on macOS, so an alarm can
# surface as SIGALRM's 142 exit status instead of Perl's requested 124.
if [ "$RUN_RC" -eq 124 ] || [ "$RUN_RC" -eq 142 ]; then fail timeout 'OpenCode review timed out'; fi
[ "$RUN_RC" -eq 0 ] || fail opencode_failed 'OpenCode review did not complete'

SESSION_ID="$(jq -r '.. | objects | .sessionID? // .session_id? // empty' "$TMP_ROOT/events.jsonl" 2>/dev/null | tail -n 1)"
COST_USD="$(jq -r '.. | objects | .cost? // .cost_usd? // empty' "$TMP_ROOT/events.jsonl" 2>/dev/null | tail -n 1)"
jq -r '.. | objects | select(.type? == "text") | (.text? // .part?.text? // empty)' "$TMP_ROOT/events.jsonl" 2>/dev/null > "$TMP_ROOT/text" || fail malformed_events 'OpenCode JSON event stream was malformed'
FINAL_LINE="$(grep '^IMPS_REVIEW_V1 ' "$TMP_ROOT/text" | tail -n 1 | sed 's/^IMPS_REVIEW_V1 //')"
[ -n "$FINAL_LINE" ] || fail malformed_verdict 'OpenCode did not emit a strict final verdict'
printf '%s' "$FINAL_LINE" | jq -e '
  type == "object" and
  ((.verdict == "APPROVE") or (.verdict == "CHANGES_REQUESTED")) and
  (.findings | type == "array") and
  all(.findings[]; type == "object" and
    (.severity | IN("blocker", "major", "minor", "nit")) and
    (.path | type == "string") and (.line | type == "number") and (.line >= 1) and
    (.message | type == "string") and (.message | length > 0)) and
  (if .verdict == "APPROVE" then all(.findings[]; .severity != "blocker" and .severity != "major") else true end)
' >/dev/null 2>&1 || fail malformed_verdict 'OpenCode final verdict did not satisfy the review contract'
VERDICT="$(printf '%s' "$FINAL_LINE" | jq -r '.verdict')"
FINDINGS="$(printf '%s' "$FINAL_LINE" | jq -c '.findings')"

AFTER_HEAD="$(git -C "$REPO" rev-parse HEAD)"
AFTER_STATUS="$(git -C "$REPO" status --porcelain=v1)"
[ "$SOURCE_HEAD" = "$AFTER_HEAD" ] && [ "$SOURCE_STATUS" = "$AFTER_STATUS" ] || fail source_mutated 'the source checkout changed during review'

STATUS="ok"
REASON=""
exit 0
