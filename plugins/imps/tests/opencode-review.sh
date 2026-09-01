#!/usr/bin/env bash
# Stubbed contract tests for the read-only OpenCode review harness. No network, real
# OpenCode account, or source-repository mutation is needed here.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
REVIEW="$PLUGIN_ROOT/scripts/opencode-review.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/imps-review-tests.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; fail=$((fail + 1)); }
assert() { "$@"; }

mkdir -p "$ROOT/bin" "$ROOT/home/.config/opencode" "$ROOT/tmp"
cat > "$ROOT/bin/opencode" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  run)
    if [ "${2:-}" = "--help" ]; then
      printf '%s\n' '--format json --model --dir'
      exit 0
    fi
    case "${STUB_CASE:-approve}" in
      timeout) sleep 5 ;;
      malformed_events) printf 'not json\n' ;;
      malformed_verdict) printf '%s\n' '{"type":"text","text":"IMPS_REVIEW_V1 {bad}"}' ;;
      changes) printf '%s\n' '{"type":"text","text":"IMPS_REVIEW_V1 {\"verdict\":\"CHANGES_REQUESTED\",\"findings\":[{\"severity\":\"major\",\"path\":\"lib/a.js\",\"line\":2,\"message\":\"zero input fails; validate it\"}]}"}' ;;
      provider_only)
        jq -e '.provider | keys == ["litellm"]' "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null || exit 9
        jq -e '.permission.edit == "deny" and .permission.task == "deny"' "$XDG_CONFIG_HOME/opencode/opencode.json" >/dev/null || exit 9
        printf '%s\n' '{"type":"text","text":"IMPS_REVIEW_V1 {\"verdict\":\"APPROVE\",\"findings\":[]}"}' ;;
      *) printf '%s\n' '{"type":"text","text":"IMPS_REVIEW_V1 {\"verdict\":\"APPROVE\",\"findings\":[]}"}' ;;
    esac
    ;;
  models)
    case "${STUB_CASE:-approve}" in
      missing_model) printf '%s\n' '[{"id":"litellm/other"}]' ;;
      line_models) printf '%s\n' 'litellm/deepseek-v4-flash' ;;
      *) printf '%s\n' '[{"id":"litellm/deepseek-v4-flash"}]' ;;
    esac
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$ROOT/bin/opencode"

git init -q "$ROOT/repo"
git -C "$ROOT/repo" config user.email test@example.invalid
git -C "$ROOT/repo" config user.name test
mkdir -p "$ROOT/repo/lib"
printf 'const value = 1;\n' > "$ROOT/repo/lib/a.js"
git -C "$ROOT/repo" add . && git -C "$ROOT/repo" commit -qm base
BASE="$(git -C "$ROOT/repo" rev-parse HEAD)"
printf 'const value = 2;\n' > "$ROOT/repo/lib/a.js"
git -C "$ROOT/repo" add . && git -C "$ROOT/repo" commit -qm change
printf '%s\n' '## Definition of Done' '- [ ] test' '## Global Constraints' '_None._' > "$ROOT/GOAL.md"

write_config() { printf '%s\n' "$1" > "$ROOT/home/.config/opencode/opencode.json"; }
write_config '{"provider":{"litellm":{"npm":"@ai-sdk/openai-compatible","options":{"baseURL":"https://litellm.example.invalid/v1","apiKey":"secret-lite"},"models":{"deepseek-v4-flash":{"name":"DeepSeek V4 Flash"}}},"other":{"options":{"apiKey":"secret-other"}}}}'

run_review() {
  env STUB_CASE="${STUB_CASE:-approve}" HOME="$ROOT/home" TMPDIR="$ROOT/tmp" PATH="$ROOT/bin:$PATH" IMPS_OPENCODE_BIN=opencode \
    IMPS_OPENCODE_CONFIG_PATH="$ROOT/home/.config/opencode/opencode.json" \
    "$REVIEW" --repo "$ROOT/repo" --base "$BASE" --goal "$ROOT/GOAL.md" --timeout 1 "$@"
}

check_contract() { jq -e '.status and has("verdict") and has("findings") and has("reason")' "$1" >/dev/null; }

out="$ROOT/out" err="$ROOT/err"
STUB_CASE=approve run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && check_contract "$out" && jq -e '.status == "ok" and .provider == "litellm" and .model == "litellm/deepseek-v4-flash" and .verdict == "APPROVE"' "$out" >/dev/null && ! grep -q 'secret-' "$out" "$err"; then ok 'pinned LiteLLM DeepSeek and secret-free contract'; else bad 'pinned LiteLLM DeepSeek and secret-free contract' "rc=$rc"; fi
[ -z "$(find "$ROOT/tmp" -mindepth 1 -maxdepth 1 -name 'imps-opencode-review.*' -print)" ] && ok 'cleanup after success' || bad 'cleanup after success' 'temporary review directory remained'

STUB_CASE=line_models run_review --check >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .model == "litellm/deepseek-v4-flash"' "$out" >/dev/null; then ok 'accepts line-oriented OpenCode model listing'; else bad 'accepts line-oriented OpenCode model listing' "rc=$rc"; fi

STUB_CASE=approve run_review --model anthropic/claude-sonnet >"$out" 2>"$err"; rc=$?
if [ "$rc" != 0 ] && jq -e '.reason == "model_rejected"' "$out" >/dev/null; then ok 'rejects same-lineage model'; else bad 'rejects same-lineage model' "rc=$rc"; fi

for rejected_model in openai/gpt-5.6-terra openrouter/deepseek/deepseek-v4-flash litellm/deepseek-v4-pro; do
  STUB_CASE=approve run_review --model "$rejected_model" >"$out" 2>"$err"; rc=$?
  if [ "$rc" != 0 ] && jq -e '.reason == "model_rejected"' "$out" >/dev/null; then ok "rejects unpinned model $rejected_model"; else bad "rejects unpinned model $rejected_model" "rc=$rc"; fi
done

STUB_CASE=approve run_review --variant bogus >"$out" 2>"$err"; rc=$?
if [ "$rc" != 0 ] && jq -e '.reason == "bad_arguments"' "$out" >/dev/null; then ok 'rejects unknown --variant'; else bad 'rejects unknown --variant' "rc=$rc"; fi

mv "$ROOT/home/.config/opencode/opencode.json" "$ROOT/home/.config/opencode/opencode.json.missing"
STUB_CASE=approve run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" != 0 ] && jq -e '.reason == "provider_config_missing"' "$out" >/dev/null; then ok 'missing LiteLLM provider config blocks'; else bad 'missing LiteLLM provider config blocks' "rc=$rc"; fi
mv "$ROOT/home/.config/opencode/opencode.json.missing" "$ROOT/home/.config/opencode/opencode.json"

STUB_CASE=missing_model run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" != 0 ] && jq -e '.reason == "model_unavailable"' "$out" >/dev/null; then ok 'missing model blocks'; else bad 'missing model blocks' "rc=$rc"; fi

STUB_CASE=timeout run_review --timeout 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" != 0 ] && jq -e '.reason == "timeout"' "$out" >/dev/null; then ok 'timeout blocks'; else bad 'timeout blocks' "rc=$rc"; fi

for case_name in malformed_events malformed_verdict; do
  STUB_CASE="$case_name" run_review >"$out" 2>"$err"; rc=$?
  if [ "$rc" != 0 ] && jq -e '.reason | test("malformed")' "$out" >/dev/null; then ok "$case_name blocks"; else bad "$case_name blocks" "rc=$rc"; fi
done

STUB_CASE=changes run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.verdict == "CHANGES_REQUESTED" and .findings[0].severity == "major"' "$out" >/dev/null; then ok 'strict changes-requested verdict'; else bad 'strict changes-requested verdict' "rc=$rc"; fi

STUB_CASE=provider_only run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.provider == "litellm"' "$out" >/dev/null; then ok 'copies only LiteLLM provider configuration'; else bad 'copies only LiteLLM provider configuration' "rc=$rc"; fi

before="$(git -C "$ROOT/repo" status --porcelain=v1; git -C "$ROOT/repo" rev-parse HEAD)"
STUB_CASE=approve run_review >"$out" 2>"$err"; rc=$?
after="$(git -C "$ROOT/repo" status --porcelain=v1; git -C "$ROOT/repo" rev-parse HEAD)"
if [ "$rc" = 0 ] && [ "$before" = "$after" ]; then ok 'source repository remains unchanged'; else bad 'source repository remains unchanged' 'git state changed'; fi

# A background non-interactive Bash inherits ignored TERM on some macOS shells, which
# makes a signal test about the test runner rather than the harness. Keep the behavioral
# cleanup assertions above for success/failure, then pin the signal path structurally.
if grep -q 'trap.*HUP' "$REVIEW" && grep -q 'trap.*INT' "$REVIEW" && grep -q 'trap.*TERM' "$REVIEW" && grep -q 'cleanup; emit_contract' "$REVIEW"; then ok 'cleanup path is installed for signals'; else bad 'cleanup path is installed for signals' 'missing signal cleanup trap'; fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
