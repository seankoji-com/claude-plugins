#!/usr/bin/env bash
# Stubbed contract tests for the read-only OCR review harness. No network, no real
# OCR install, and no source-repository mutation is needed here.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
REVIEW="$PLUGIN_ROOT/scripts/run-ocr.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/imps-ocr-tests.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; fail=$((fail + 1)); }

mkdir -p "$ROOT/bin" "$ROOT/tmp" "$ROOT/realhome"

# `ocr` stub. STUB_CASE selects the review payload; STUB_VERSION exercises the version
# gate. Every review invocation records the endpoint and model it was handed, so the URL
# normalisation and credential plumbing can be asserted without printing the secret.
cat > "$ROOT/bin/ocr" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  version) printf 'open-code-review v%s (deadbeef) darwin/arm64\n' "${STUB_VERSION:-1.10.1}"; exit 0 ;;
  config) exit 0 ;;
  review)
    if [ "${2:-}" = "--help" ]; then printf '%s\n' '--from --to --format json --concurrency --rule --background-file'; exit 0; fi
    printf '%s\n' "${OCR_LLM_URL:-}" > "$STUB_URL_SINK"
    printf '%s\n' "${OCR_LLM_MODEL:-}" >> "$STUB_URL_SINK"
    case "${STUB_CASE:-approve}" in
      timeout) sleep 5 ;;
      not_json) printf 'this is not json\n' ;;
      no_keys) printf '%s\n' '{"unexpected":true}' ;;
      message_only) printf '%s\n' '{"message":"no reviewable changes"}' ;;
      major) printf '%s\n' '{"comments":[{"path":"lib/a.js","start_line":1,"end_line":1,"body":"[major] zero input divides by zero; guard it"}]}' ;;
      nit_only) printf '%s\n' '{"comments":[{"path":"lib/a.js","start_line":1,"end_line":1,"body":"[nit] prefer const"}]}' ;;
      untagged) printf '%s\n' '{"comments":[{"path":"lib/a.js","start_line":1,"end_line":1,"body":"this looks suspicious"}]}' ;;
      content_field) printf '%s\n' '{"comments":[{"path":"lib/a.js","line":3,"content":"[blocker] drops the error"}]}' ;;
      *) printf '%s\n' '{"comments":[]}' ;;
    esac
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$ROOT/bin/ocr"

# The installer stub creates a pinned binary in the requested isolated prefix. This
# proves the harness does not depend on the operator's global npm prefix or cache.
cat > "$ROOT/bin/npm" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [ "${STUB_NPM_FAIL:-0}" = 1 ]; then exit 1; fi
prefix=""
previous=""
for arg in "$@"; do
  if [ "$previous" = --prefix ]; then prefix="$arg"; fi
  previous="$arg"
done
[ -n "$prefix" ] || exit 2
mkdir -p "$prefix/bin"
printf '#!/usr/bin/env bash\nSTUB_VERSION=1.10.1 exec %q "$@"\n' "$STUB_OCR_SOURCE" > "$prefix/bin/ocr"
chmod +x "$prefix/bin/ocr"
STUB
chmod +x "$ROOT/bin/npm"
export STUB_OCR_SOURCE="$ROOT/bin/ocr"

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

# Credentials come from an opencode.json-shaped file. The key is a recognisable sentinel
# so the tests can prove it never reaches stdout or stderr.
CONFIG="$ROOT/opencode.json"
write_config() { printf '%s\n' "$1" > "$CONFIG"; }
GOOD_CONFIG='{"provider":{"litellm":{"options":{"baseURL":"http://endpoint.invalid:4000","apiKey":"secret-litellm-key"}}}}'
write_config "$GOOD_CONFIG"

run_review() {
  env STUB_CASE="${STUB_CASE:-approve}" STUB_VERSION="${STUB_VERSION:-1.10.1}" \
    STUB_NPM_FAIL="${STUB_NPM_FAIL:-0}" \
    STUB_URL_SINK="$ROOT/url-sink" \
    HOME="$ROOT/realhome" TMPDIR="$ROOT/tmp" PATH="$ROOT/bin:$PATH" \
    IMPS_OCR_BIN=ocr IMPS_OCR_VERSION=1.10.1 IMPS_OPENCODE_CONFIG_PATH="$CONFIG" \
    "$REVIEW" --repo "$ROOT/repo" --base "$BASE" --goal "$ROOT/GOAL.md" --timeout 3 "$@"
}

check_contract() { jq -e 'has("status") and has("verdict") and has("findings") and has("reason") and has("model") and has("provider")' "$1" >/dev/null; }

out="$ROOT/out" err="$ROOT/err"

STUB_CASE=approve run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && check_contract "$out" && jq -e '.status == "ok" and .verdict == "APPROVE" and (.findings | length) == 0' "$out" >/dev/null; then ok 'clean diff approves'; else bad 'clean diff approves' "rc=$rc"; fi
if ! grep -q 'secret-litellm-key' "$out" "$err"; then ok 'credential never reaches stdout or stderr'; else bad 'credential never reaches stdout or stderr' 'secret leaked'; fi
if [ -z "$(find "$ROOT/tmp" -mindepth 1 -maxdepth 1 -name 'imps-ocr-review.*' -print 2>/dev/null)" ]; then ok 'cleanup after success'; else bad 'cleanup after success' 'temporary review directory remained'; fi

# OpenCode stores the endpoint as a bare root; OCR needs the OpenAI-compatible base.
# Getting this wrong 404s every request, so assert the normalisation directly.
if [ "$(head -n 1 "$ROOT/url-sink" 2>/dev/null)" = "http://endpoint.invalid:4000/v1" ]; then ok 'base URL normalised to /v1'; else bad 'base URL normalised to /v1' "got $(head -n 1 "$ROOT/url-sink" 2>/dev/null)"; fi
if [ "$(sed -n 2p "$ROOT/url-sink" 2>/dev/null)" = "deepseek-v4-flash" ]; then ok 'default model reaches OCR'; else bad 'default model reaches OCR' "got $(sed -n 2p "$ROOT/url-sink" 2>/dev/null)"; fi

STUB_CASE=major run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.verdict == "CHANGES_REQUESTED" and .findings[0].severity == "major" and .findings[0].path == "lib/a.js" and (.findings[0].message | test("^\\[?major") | not)' "$out" >/dev/null; then ok 'tagged major blocks and strips its tag'; else bad 'tagged major blocks and strips its tag' "rc=$rc $(cat "$out")"; fi

STUB_CASE=nit_only run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.verdict == "APPROVE" and .findings[0].severity == "nit"' "$out" >/dev/null; then ok 'nit-only approves but still reports the finding'; else bad 'nit-only approves but still reports the finding' "rc=$rc $(cat "$out")"; fi

# The fail-closed rule: OCR has no severity field, so a model that ignores the rule
# file's tagging instruction must block rather than quietly pass.
STUB_CASE=untagged run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.verdict == "CHANGES_REQUESTED" and .findings[0].severity == "major"' "$out" >/dev/null; then ok 'untagged comment defaults to major and blocks'; else bad 'untagged comment defaults to major and blocks' "rc=$rc $(cat "$out")"; fi

STUB_CASE=content_field run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.verdict == "CHANGES_REQUESTED" and .findings[0].severity == "blocker" and .findings[0].line == 3' "$out" >/dev/null; then ok 'accepts content/line field spelling'; else bad 'accepts content/line field spelling' "rc=$rc $(cat "$out")"; fi

STUB_CASE=message_only run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.verdict == "APPROVE" and (.findings | length) == 0' "$out" >/dev/null; then ok 'message-only result approves'; else bad 'message-only result approves' "rc=$rc $(cat "$out")"; fi

for case_name in not_json no_keys; do
  STUB_CASE="$case_name" run_review >"$out" 2>"$err"; rc=$?
  if [ "$rc" != 0 ] && jq -e '.reason == "malformed_verdict"' "$out" >/dev/null; then ok "$case_name blocks"; else bad "$case_name blocks" "rc=$rc"; fi
done

STUB_CASE=timeout run_review --timeout 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" != 0 ] && jq -e '.reason == "timeout"' "$out" >/dev/null; then ok 'timeout blocks'; else bad 'timeout blocks' "rc=$rc"; fi

# Presence is not enough: a stale global install is exactly what a `command -v` check
# would wave through, so the harness pins the version and replaces it in an isolated
# prefix. The npm stub also proves the install uses the requested prefix.
STUB_VERSION=1.9.0 STUB_CASE=approve run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == "APPROVE"' "$out" >/dev/null; then ok 'version mismatch installs pinned OCR in an isolated prefix'; else bad 'version mismatch installs pinned OCR in an isolated prefix' "rc=$rc $(cat "$out")"; fi

STUB_VERSION=1.9.0 STUB_NPM_FAIL=1 STUB_CASE=approve run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" != 0 ] && jq -e '.reason == "ocr_install_failed"' "$out" >/dev/null; then ok 'failed OCR install blocks'; else bad 'failed OCR install blocks' "rc=$rc $(cat "$out")"; fi

write_config '{"provider":{}}'
STUB_CASE=approve run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" != 0 ] && jq -e '.reason == "provider_config_missing"' "$out" >/dev/null; then ok 'missing endpoint config blocks'; else bad 'missing endpoint config blocks' "rc=$rc"; fi
write_config "$GOOD_CONFIG"

# Explicit env overrides must win over the config file, including an endpoint that
# already carries /v1 — normalising that twice would produce /v1/v1.
STUB_CASE=approve IMPS_OCR_URL="http://override.invalid:8080/v1" IMPS_OCR_TOKEN=tok IMPS_OCR_MODEL=other-model run_review >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && [ "$(head -n 1 "$ROOT/url-sink")" = "http://override.invalid:8080/v1" ] && jq -e '.model == "other-model"' "$out" >/dev/null; then ok 'env overrides win and /v1 is not doubled'; else bad 'env overrides win and /v1 is not doubled' "rc=$rc got $(head -n 1 "$ROOT/url-sink")"; fi

STUB_CASE=approve run_review --concurrency 0 >"$out" 2>"$err"; rc=$?
if [ "$rc" != 0 ] && jq -e '.reason == "bad_arguments"' "$out" >/dev/null; then ok 'rejects non-positive --concurrency'; else bad 'rejects non-positive --concurrency' "rc=$rc"; fi

STUB_CASE=approve run_review --check >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == null' "$out" >/dev/null; then ok '--check preflight passes without reviewing'; else bad '--check preflight passes without reviewing' "rc=$rc $(cat "$out")"; fi

before="$(git -C "$ROOT/repo" status --porcelain=v1; git -C "$ROOT/repo" rev-parse HEAD)"
STUB_CASE=approve run_review >"$out" 2>"$err"; rc=$?
after="$(git -C "$ROOT/repo" status --porcelain=v1; git -C "$ROOT/repo" rev-parse HEAD)"
if [ "$rc" = 0 ] && [ "$before" = "$after" ]; then ok 'source repository remains unchanged'; else bad 'source repository remains unchanged' 'git state changed'; fi

# `ocr config set` writes into HOME; the harness redirects HOME so the operator's real
# OCR config is never touched. Scoped to OCR's own config paths rather than asserting
# HOME is untouched wholesale: the preflight's `npm install -g` legitimately populates
# ~/.npm/_cacache and ~/.npm/_logs, and it has to, because redirecting HOME around the
# global install would put the binary somewhere that gets deleted on exit.
if [ -z "$(find "$ROOT/realhome" -maxdepth 2 -mindepth 1 \( -name '.ocr*' -o -name 'ocr' \) -print -quit 2>/dev/null)" ]; then ok 'real HOME keeps no OCR config'; else bad 'real HOME keeps no OCR config' 'ocr config was written to the real HOME'; fi

# A background non-interactive Bash inherits ignored TERM on some macOS shells, which
# makes a signal test about the test runner rather than the harness. Keep the behavioral
# cleanup assertions above for success/failure, then pin the signal path structurally.
if grep -q 'trap.*HUP' "$REVIEW" && grep -q 'trap.*INT' "$REVIEW" && grep -q 'trap.*TERM' "$REVIEW" && grep -q 'cleanup; emit_contract' "$REVIEW"; then ok 'cleanup path is installed for signals'; else bad 'cleanup path is installed for signals' 'missing signal cleanup trap'; fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
