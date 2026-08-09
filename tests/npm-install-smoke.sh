#!/usr/bin/env bash
# tests/npm-install-smoke.sh — OPERATOR-RUN, not part of tests/run.sh or CI.
#
# Packs dist/opencode/ (build/npm/'s source, generated verbatim by build/generate.py —
# see build/npm/README.md) as an npm tarball and installs it into throwaway prefixes:
#
#   1. a normal install — postinstall runs, commands/scripts land under a throwaway
#      OPENCODE_CONFIG_DIR, `doctor` reports healthy, `uninstall` removes exactly what
#      was written.
#   2. a `--ignore-scripts` install — postinstall never runs, nothing lands, `doctor`
#      detects and reports the gap (non-zero exit), and running `install` explicitly
#      self-heals it.
#
# Needs npm registry access (npm's own install machinery talks to the registry even for
# a local tarball path, e.g. metadata/audit checks) that a sandboxed imp cannot reach —
# this script exists and is well-formed, but is never executed inside an imp run. Run it
# yourself with:
#
#   bash tests/npm-install-smoke.sh
#
# Everything happens inside a mktemp -d workspace that is removed on exit; nothing
# outside it (no real $HOME, no real ~/.config/opencode) is touched.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist/opencode"

if [ ! -f "$DIST/package.json" ]; then
  echo "skip: $DIST/package.json missing — run 'python3 build/generate.py' first" >&2
  exit 0
fi

command -v npm >/dev/null 2>&1 || { echo "skip: npm not on PATH" >&2; exit 0; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== packing $DIST =="
TARBALL="$(cd "$DIST" && npm pack --silent --pack-destination "$WORK")"
TARBALL_PATH="$WORK/$TARBALL"
test -f "$TARBALL_PATH" || fail "npm pack did not produce $TARBALL_PATH"

# -------------------------------------------------------------------- normal install
NORMAL_PREFIX="$WORK/normal-npm-prefix"
NORMAL_CONFIG="$WORK/normal-opencode-config"
mkdir -p "$NORMAL_PREFIX" "$NORMAL_CONFIG"

echo "== normal install =="
OPENCODE_CONFIG_DIR="$NORMAL_CONFIG" npm install --silent --no-audit --no-fund \
  --prefix "$NORMAL_PREFIX" "$TARBALL_PATH"

test -f "$NORMAL_CONFIG/.seankoji-plugins-manifest.json" || fail "postinstall did not write a manifest"
find "$NORMAL_CONFIG/commands" -name '*.md' 2>/dev/null | grep -q . || fail "no commands landed after a normal install"
echo "ok: commands landed after normal install"

BIN="$NORMAL_PREFIX/node_modules/.bin/claude-plugins-opencode"
test -x "$BIN" || fail "bin CLI not installed at $BIN"

DOCTOR_OUT="$(OPENCODE_CONFIG_DIR="$NORMAL_CONFIG" "$BIN" doctor)"
echo "$DOCTOR_OUT" | grep -qi "ok: install looks healthy" || fail "doctor did not report a healthy normal install: $DOCTOR_OUT"
echo "ok: doctor reports healthy on normal install"

echo "== uninstall (normal) =="
OPENCODE_CONFIG_DIR="$NORMAL_CONFIG" "$BIN" uninstall
test -f "$NORMAL_CONFIG/.seankoji-plugins-manifest.json" && fail "manifest survived uninstall"
find "$NORMAL_CONFIG" -name '*.md' 2>/dev/null | grep -q . && fail "command files survived uninstall"
echo "ok: uninstall removed manifest-tracked files"

# ------------------------------------------------------------- --ignore-scripts install
IGNORE_PREFIX="$WORK/ignore-npm-prefix"
IGNORE_CONFIG="$WORK/ignore-opencode-config"
mkdir -p "$IGNORE_PREFIX" "$IGNORE_CONFIG"

echo "== --ignore-scripts install =="
OPENCODE_CONFIG_DIR="$IGNORE_CONFIG" npm install --silent --no-audit --no-fund --ignore-scripts \
  --prefix "$IGNORE_PREFIX" "$TARBALL_PATH"

test -f "$IGNORE_CONFIG/.seankoji-plugins-manifest.json" && fail "--ignore-scripts should not have run postinstall"
echo "ok: --ignore-scripts install stayed completable without running postinstall"

IGNORE_BIN="$IGNORE_PREFIX/node_modules/.bin/claude-plugins-opencode"
test -x "$IGNORE_BIN" || fail "bin CLI missing even under --ignore-scripts (package itself failed to install)"

set +e
IGNORE_DOCTOR_OUT="$(OPENCODE_CONFIG_DIR="$IGNORE_CONFIG" "$IGNORE_BIN" doctor)"
IGNORE_DOCTOR_STATUS=$?
set -e
echo "$IGNORE_DOCTOR_OUT" | grep -qi "not installed" || fail "doctor did not report the --ignore-scripts gap: $IGNORE_DOCTOR_OUT"
[ "$IGNORE_DOCTOR_STATUS" -ne 0 ] || fail "doctor exited 0 despite reporting a gap"
echo "ok: doctor detects and reports the --ignore-scripts gap"

echo "== self-heal: running install explicitly after --ignore-scripts =="
OPENCODE_CONFIG_DIR="$IGNORE_CONFIG" "$IGNORE_BIN" install
find "$IGNORE_CONFIG/commands" -name '*.md' 2>/dev/null | grep -q . || fail "explicit install did not land commands"
OPENCODE_CONFIG_DIR="$IGNORE_CONFIG" "$IGNORE_BIN" uninstall

echo "PASS: npm install smoke test"
