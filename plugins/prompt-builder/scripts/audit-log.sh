#!/usr/bin/env bash
# audit-log.sh — append one structured entry to the shared cross-plugin audit log.
#
# Every self-improvement / reflection command in this marketplace (imps, prompt-builder,
# claude-tuneup, ...) calls this once per run so entries land in one queryable,
# append-only JSONL file instead of each plugin growing its own differently-shaped
# free-text log. Schema mirrors the {command, duration_ms, cost_estimate_usd,
# exit_status} shape from maestro's audit.jsonl (github.com/sharpdeveye/maestro).
#
# This file is bundled identically into every plugin's scripts/ dir — plugins in this
# marketplace are installed independently, so there is no cross-plugin runtime path to
# require a shared lib from (see AGENTS.md). Keep the copies byte-identical;
# tests/run.sh diffs them against each other.
#
# Usage:
#   audit-log.sh --plugin <name> --command <slash-command> --exit-status <status> \
#     --duration-ms <int> [--notes <text>] [--cost-usd <number>] [--scope <user|project>] \
#     [--tier <text>] [--attempts <int>]
#
#   status: completed | partial | failed | cancelled
#   scope, if omitted, is auto-detected: "project" inside a git repo, else "user"
#   tier, attempts: optional; null when omitted (e.g. tier="opencode" for offloaded work)
#
# Best-effort by design: a missing `jq`, an unwritable log dir, or a write failure warns
# on stderr and exits 0 rather than breaking the caller's primary command — this is
# telemetry, not a gate. Malformed arguments (bad enum, non-numeric duration) exit 1,
# since those are bugs in the calling command, not the environment.
# fail-soft by design: telemetry must never break the caller (see AGENTS.md)
set -uo pipefail

AUDIT_FILE="${AUDIT_LOG_FILE:-$HOME/.claude/audit.jsonl}"

# Pure single-arg helpers, kept above the arg loop so the unit test harness (which
# sources this script with __SOURCED__=1 and calls one function directly) can exercise
# them without going through argv parsing. --tier and --attempts are both optional, so
# unlike --duration-ms's `''|*[!0-9]*` check (which must reject empty), these must map
# an empty/unset value to JSON null rather than an error.
tier_json()     { [ -z "${1:-}" ] && { echo null; return; }; jq -Rn --arg t "$1" '$t'; }
attempts_json() { [ -z "${1:-}" ] && { echo null; return; }
                  case "$1" in *[!0-9]*) echo "audit-log: --attempts must be a non-negative integer, got '$1'" >&2; return 1;; esac
                  printf '%s\n' "$1"; }
# A well-formed decimal: only digits and dots, at least one digit, at most one dot
# (leading- or trailing-dot forms like ".5"/"5." are fine — jq's own number parser
# accepts both, so rejecting them here would be stricter than the JSON we hand it).
# Stripping up to the first dot and checking the remainder for a second dot is what
# catches "1.2.3"/"..." without a bash 4+ regex engine.
cost_json()     { [ -z "${1:-}" ] && { echo null; return; }
                  case "$1" in *[!0-9.]*) echo "audit-log: --cost-usd must be a well-formed decimal number, got '$1'" >&2; return 1;; esac
                  case "$1" in *[0-9]*) ;; *) echo "audit-log: --cost-usd must be a well-formed decimal number, got '$1'" >&2; return 1;; esac
                  case "${1#*.}" in *.*) echo "audit-log: --cost-usd must be a well-formed decimal number, got '$1'" >&2; return 1;; esac
                  printf '%s\n' "$1"; }
${__SOURCED__:+false} : || return 0

plugin="" command="" exit_status="" duration_ms="" notes="" cost_usd="" scope="" tier="" attempts=""

while [ $# -gt 0 ]; do
  case "$1" in
    --plugin) plugin="${2:-}"; shift 2 ;;
    --command) command="${2:-}"; shift 2 ;;
    --exit-status) exit_status="${2:-}"; shift 2 ;;
    --duration-ms) duration_ms="${2:-}"; shift 2 ;;
    --notes) notes="${2:-}"; shift 2 ;;
    --cost-usd) cost_usd="${2:-}"; shift 2 ;;
    --scope) scope="${2:-}"; shift 2 ;;
    --tier) tier="${2:-}"; shift 2 ;;
    --attempts) attempts="${2:-}"; shift 2 ;;
    *) echo "audit-log: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$exit_status" in
  completed|partial|failed|cancelled) ;;
  *) echo "audit-log: --exit-status must be one of completed|partial|failed|cancelled, got '$exit_status'" >&2; exit 1 ;;
esac

case "$duration_ms" in
  ''|*[!0-9]*) echo "audit-log: --duration-ms must be a non-negative integer, got '$duration_ms'" >&2; exit 1 ;;
esac

[ -n "$plugin" ] || { echo "audit-log: --plugin is required" >&2; exit 1; }
[ -n "$command" ] || { echo "audit-log: --command is required" >&2; exit 1; }

if [ -n "$scope" ]; then
  case "$scope" in
    user|project) ;;
    *) echo "audit-log: --scope must be user or project, got '$scope'" >&2; exit 1 ;;
  esac
else
  if git rev-parse --show-toplevel >/dev/null 2>&1; then scope="project"; else scope="user"; fi
fi

project_name=""
if [ "$scope" = "project" ]; then
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$toplevel" ] && project_name="$(basename "$toplevel")"
fi

# attempts_json and cost_json validate format even without jq present — a malformed
# --attempts/--cost-usd is an argument bug in the caller, not an environmental gap, so it
# must exit 1 regardless (see AGENTS.md). tier_json needs jq to produce a safely-quoted
# JSON string, so it's deferred past the jq-presence check below to avoid a spurious "jq:
# command not found" on a jq-less machine that's about to exit 0 anyway.
attempts_json_val="$(attempts_json "$attempts")" || exit 1
cost_json_val="$(cost_json "$cost_usd")" || exit 1

if ! command -v jq >/dev/null 2>&1; then
  echo "audit-log: 'jq' not on PATH — skipping structured log entry" >&2
  exit 0
fi

tier_json_val="$(tier_json "$tier")"

if ! mkdir -p "$(dirname "$AUDIT_FILE")" 2>/dev/null; then
  echo "audit-log: cannot create $(dirname "$AUDIT_FILE") — skipping structured log entry" >&2
  exit 0
fi

id="a-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ -n "$id" ] || id="a-$$${RANDOM:-0}"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if ! jq -nc \
  --arg id "$id" \
  --arg ts "$ts" \
  --arg plugin "$plugin" \
  --arg command "$command" \
  --arg scope "$scope" \
  --arg project "$project_name" \
  --arg exit_status "$exit_status" \
  --argjson duration_ms "$duration_ms" \
  --argjson cost_estimate_usd "$cost_json_val" \
  --argjson tier "$tier_json_val" \
  --argjson attempts "$attempts_json_val" \
  --arg notes "${notes:0:200}" \
  '{id:$id, ts:$ts, plugin:$plugin, command:$command, scope:$scope,
    project:(if $project == "" then null else $project end),
    exit_status:$exit_status, duration_ms:$duration_ms, cost_estimate_usd:$cost_estimate_usd,
    tier:$tier, attempts:$attempts, notes:$notes}' >> "$AUDIT_FILE" 2>/dev/null; then
  echo "audit-log: failed to write to $AUDIT_FILE" >&2
  exit 0
fi
