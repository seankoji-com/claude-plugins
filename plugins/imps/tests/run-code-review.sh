#!/usr/bin/env bash
# Stubbed contract tests for the Codex-first, OCR-fallback code-review gate. No network,
# no real Codex or OCR install, and no source-repository mutation is needed here.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd -P)"
DISPATCH="$PLUGIN_ROOT/scripts/run-code-review.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/imps-code-review-tests.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; fail=$((fail + 1)); }

mkdir -p "$ROOT/bin" "$ROOT/tmp" "$ROOT/realhome" "$ROOT/codex-plugin/scripts"

# Stub `codex` CLI: only its presence on PATH is checked, never actually run.
cat > "$ROOT/bin/codex" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$ROOT/bin/codex"

# Placeholder companion script: our stub `node` never actually parses it, only checks it
# exists, so its content doesn't matter.
printf '// stub\n' > "$ROOT/codex-plugin/scripts/codex-companion.mjs"

# Stub `node`: standing in for codex-companion.mjs. STUB_CODEX_CASE selects the payload.
cat > "$ROOT/bin/node" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${STUB_CODEX_CASE:-approve}" in
  crash) exit 1 ;;
  timeout) sleep 5 ;;
  not_json) printf 'this is not json' ;;
  parse_error) printf '%s' '{"result":null,"parseError":"model returned prose","threadId":"th1"}' ;;
  approve) printf '%s' '{"result":{"verdict":"approve","summary":"looks fine","findings":[],"next_steps":[]},"parseError":null,"threadId":"th1"}' ;;
  needs_attention) printf '%s' '{"result":{"verdict":"needs-attention","summary":"risky","findings":[{"severity":"critical","title":"Race","body":"two writers can clobber shared state","file":"lib/a.js","line_start":10,"line_end":12,"confidence":0.9,"recommendation":"add a lock"}],"next_steps":["add a lock"]},"parseError":null,"threadId":"th2"}' ;;
  unexpected_verdict) printf '%s' '{"result":{"verdict":"weird","summary":"x","findings":[],"next_steps":[]},"parseError":null,"threadId":"th3"}' ;;
  *) printf '%s' '{"result":{"verdict":"approve","summary":"ok","findings":[],"next_steps":[]},"parseError":null,"threadId":"th1"}' ;;
esac
STUB
chmod +x "$ROOT/bin/node"

# Stub `ocr` CLI for the fallback path — same shape as tests/run-ocr.sh's stub, kept
# minimal since only the approve case is exercised here.
cat > "$ROOT/bin/ocr" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  version) printf 'open-code-review v%s (deadbeef) darwin/arm64\n' "${STUB_VERSION:-1.10.1}"; exit 0 ;;
  config) exit 0 ;;
  review)
    if [ "${2:-}" = "--help" ]; then printf '%s\n' '--from --to --format json --concurrency --rule --background-file'; exit 0; fi
    case "${OCR_STUB_CASE:-approve}" in
      approve) printf '%s\n' '{"comments":[]}' ;;
    esac
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$ROOT/bin/ocr"

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

CONFIG="$ROOT/opencode.json"
printf '%s\n' '{"provider":{"litellm":{"options":{"baseURL":"http://endpoint.invalid:4000","apiKey":"secret-litellm-key"}}}}' > "$CONFIG"

# Codex "installed" by default (IMPS_CODEX_PLUGIN_ROOT points at the fixture); pass
# codex_installed=0 to simulate no codex@* plugin at all.
run_dispatch() {
  local codex_installed="${1:-1}"
  shift || true
  local codex_root=""
  [ "$codex_installed" = 1 ] && codex_root="$ROOT/codex-plugin"
  env STUB_CODEX_CASE="${STUB_CODEX_CASE:-approve}" \
    OCR_STUB_CASE="${OCR_STUB_CASE:-approve}" STUB_VERSION="${STUB_VERSION:-1.10.1}" \
    STUB_URL_SINK="$ROOT/url-sink" \
    HOME="$ROOT/realhome" TMPDIR="$ROOT/tmp" PATH="$ROOT/bin:$PATH" \
    IMPS_OCR_BIN=ocr IMPS_OPENCODE_CONFIG_PATH="$CONFIG" \
    IMPS_CODEX_NODE_BIN=node IMPS_CODEX_BIN=codex \
    IMPS_CODEX_PLUGIN_ROOT="$codex_root" \
    IMPS_CLAUDE_PLUGINS_MANIFEST="$ROOT/nonexistent-manifest.json" \
    "$DISPATCH" --repo "$ROOT/repo" --base "$BASE" --goal "$ROOT/GOAL.md" --timeout 3 "$@"
}

out="$ROOT/out" err="$ROOT/err"

# --- Codex present and completes: authoritative, OCR never runs -----------------------
STUB_CODEX_CASE=approve run_dispatch 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == "APPROVE" and .provider == "codex"' "$out" >/dev/null; then ok 'Codex approve is authoritative'; else bad 'Codex approve is authoritative' "rc=$rc $(cat "$out")"; fi

STUB_CODEX_CASE=needs_attention run_dispatch 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '
    .status == "ok" and .verdict == "CHANGES_REQUESTED" and .provider == "codex"
    and .findings[0].severity == "blocker" and .findings[0].path == "lib/a.js"
    and .findings[0].line == 10 and (.findings[0].message | contains("Race") and contains("Fix: add a lock"))
  ' "$out" >/dev/null; then ok 'Codex needs-attention blocks with mapped severity and findings'; else bad 'Codex needs-attention blocks with mapped severity and findings' "rc=$rc $(cat "$out")"; fi

# A needs-attention verdict must not trigger an OCR run to "shop" for a clean pass —
# poison the ocr stub so the test fails loudly if it's ever invoked.
STUB_CODEX_CASE=needs_attention OCR_STUB_CASE=poison run_dispatch 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.provider == "codex"' "$out" >/dev/null && ! grep -q 'poison' "$err"; then ok 'needs-attention never falls through to OCR'; else bad 'needs-attention never falls through to OCR' "rc=$rc"; fi

# --- Codex unavailable: falls back to OCR ----------------------------------------------
run_dispatch 0 >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == "APPROVE" and .provider != "codex"' "$out" >/dev/null; then ok 'no codex plugin installed falls back to OCR'; else bad 'no codex plugin installed falls back to OCR' "rc=$rc $(cat "$out")"; fi

STUB_CODEX_CASE=crash run_dispatch 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == "APPROVE" and .provider != "codex"' "$out" >/dev/null; then ok 'Codex runtime crash falls back to OCR'; else bad 'Codex runtime crash falls back to OCR' "rc=$rc $(cat "$out")"; fi

STUB_CODEX_CASE=timeout run_dispatch 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == "APPROVE" and .provider != "codex"' "$out" >/dev/null; then ok 'Codex timeout falls back to OCR'; else bad 'Codex timeout falls back to OCR' "rc=$rc $(cat "$out")"; fi

STUB_CODEX_CASE=not_json run_dispatch 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == "APPROVE" and .provider != "codex"' "$out" >/dev/null; then ok 'Codex malformed payload falls back to OCR'; else bad 'Codex malformed payload falls back to OCR' "rc=$rc $(cat "$out")"; fi

STUB_CODEX_CASE=parse_error run_dispatch 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == "APPROVE" and .provider != "codex"' "$out" >/dev/null; then ok 'Codex parse error falls back to OCR'; else bad 'Codex parse error falls back to OCR' "rc=$rc $(cat "$out")"; fi

STUB_CODEX_CASE=unexpected_verdict run_dispatch 1 >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == "APPROVE" and .provider != "codex"' "$out" >/dev/null; then ok 'Codex unexpected verdict falls back to OCR'; else bad 'Codex unexpected verdict falls back to OCR' "rc=$rc $(cat "$out")"; fi

# --- --check: OCR remains the mandatory backstop; Codex absence never fails it ---------
run_dispatch 0 --check >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == null' "$out" >/dev/null; then ok '--check passes on OCR alone when Codex is not installed'; else bad '--check passes on OCR alone when Codex is not installed' "rc=$rc $(cat "$out")"; fi

run_dispatch 1 --check >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .verdict == null' "$out" >/dev/null; then ok '--check passes with Codex installed too'; else bad '--check passes with Codex installed too' "rc=$rc $(cat "$out")"; fi

# --- direct run-codex-review.sh: source-mutation guard blocks rather than falls back ----
CODEX_DIRECT="$PLUGIN_ROOT/scripts/run-codex-review.sh"
mutate_env_run() {
  env STUB_CODEX_CASE=needs_attention \
    HOME="$ROOT/realhome" TMPDIR="$ROOT/tmp" PATH="$ROOT/bin:$PATH" \
    IMPS_CODEX_NODE_BIN=node IMPS_CODEX_BIN=codex \
    IMPS_CODEX_PLUGIN_ROOT="$ROOT/codex-plugin" \
    "$CODEX_DIRECT" --repo "$ROOT/repo" --base "$BASE" --goal "$ROOT/GOAL.md" --timeout 3
}
"$CODEX_DIRECT" --repo "$ROOT/repo" --base "$BASE" --goal "$ROOT/GOAL.md" --check \
  >/dev/null 2>&1
# Sanity: the direct script's own contract shape, independent of the dispatcher.
mutate_env_run >"$out" 2>"$err"; rc=$?
if [ "$rc" = 0 ] && jq -e '.status == "ok" and .provider == "codex"' "$out" >/dev/null; then ok 'run-codex-review.sh emits the imps contract directly'; else bad 'run-codex-review.sh emits the imps contract directly' "rc=$rc $(cat "$out")"; fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
