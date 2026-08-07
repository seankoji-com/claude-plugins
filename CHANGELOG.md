# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Plugin versions use a per-touching-PR patch counter rather than semantic-versioning
meaning; see `CONTRIBUTING.md`.

## [Unreleased] - 2026-08-07

### Added

- `plugins/elephant-goldfish` (0.2.0) — New `/elephant-goldfish:thinking` command;
  removed recon plugin.
- `plugins/claude-tuneup` — Permission audit and settings tuneup packaged as a plugin.
  Commands: /claude-tuneup:claude-tuneup. Bundled: scripts/scan_perms.py.
- `plugins/prompt-builder` — Prompt engineering assistant packaged as a plugin.
  Commands: /prompt-builder:prompt-builder.
- `plugins/imps` — Swarm orchestrator packaged as a plugin.
  Commands: /imps:imps, /imps:status, /imps:prs, /imps:issue-mode.
  Bundled: scripts/imps-intro.py, 5 persona briefs.
- `.github/workflows/validate.yml` — CI that validates all plugin manifests, marketplace
  name-to-source consistency, script executability, and bundled-asset path hygiene.
- `schemas/plugin.schema.json` and `schemas/marketplace.schema.json` — JSON schemas.
- `elephant.md` — Durable design doc generated via /elephant-goldfish:elephant
  (dogfoods the flagship plugin against this repo).

### Changed

- `plugins/imps` (0.3.37) — Ported review-discipline mechanisms from obra/superpowers
  (#124); added Global Constraints template and adjudication vocabulary.
- `plugins/imps` (0.3.37) — Upgraded opus and sonnet model references to 5.0 (#120).
- `plugins/offload-sidecar` (0.3.2) — Synced SERVER_VERSION with plugin manifest.
- `plugins/offload-sidecar` — Renamed from `ollama-sidecar` (0.3.0): one sidecar for
  all offloadable work, local or cloud. Added an `agy` (Google Antigravity CLI)
  engine as two new LLM tiers — `flash` (Gemini Flash: vision, ~1M-token context,
  bulk cloud work) and `pro` (Gemini Pro: scarce quota, explicit opt-in) — behind a
  persistent quota gate that rejects cloud calls up front (sliding-window budgets +
  lockout deadlines parsed from agy output) instead of failing them mid-flight.
  New operations mined from real session history: `triage_ci_log`,
  `summarize_test_run`, `triage_service_log`, `digest_task_output`,
  `digest_review_comments`, `security_scan_digest`, `draft_commit_message`,
  `draft_pr_body`, `changelog_from_commits`, `html_extract` (LLM);
  `describe_image`, `verify_screenshot`, `pdf_to_structured` (vision, cloud tiers
  only); `json_digest`, `xlsx_extract` (deterministic). Existing installs of
  `ollama-sidecar` keep working but stop receiving updates — reinstall as
  `offload-sidecar`.
- `plugins/ape` — Refactored orchestration logic into a real Workflow script with
  deterministic state management (#59).
- `plugins/elephant-goldfish` — Reduced scope to the cold-judge kernel; removed
  hot-judge scaffolding and teaching-mode baggage (#58).
- `plugins/claude-tuneup` — Generalized scope rules (now applicable to any plugin
  config, not just tuneup); fixed stale docs; removed edit-proposal flow (#57).
- `plugins/prompt-builder` — Removed acronym frameworks in favor of Anthropic's
  evidence-based prompt-engineering techniques (#56).
- `plugins/ollama-sidecar` — Reframed README and tool description to clarify the
  "when jq can't parse YAML" use case (#55).
- `.claude-plugin/marketplace.json` name renamed from `claude-plugins` → `seankoji`
  (avoids CLI rejection of names containing "claude").
- `AGENTS.md` "Validate" section updated to reference CI; manual check condensed to
  a quick one-liner.

### Fixed

- `plugins/elephant-goldfish` (0.2.1) — Measure GitHub body limit in bytes (not
  characters); brace-safe rendering and hardened gh error paths.
- `plugins/offload-sidecar` (0.3.3) — Narrowed `_env()`'s unexpanded-placeholder
  guard to exact Claude Code shapes (`${user_config.<key>}`,
  `${CLAUDE_PROJECT_DIR}`) so user-written values containing `${` pass through
  untouched (#107).
- `plugins/offload-sidecar` (0.3.1) — `tls_ca_file` and `agy_bin` now expand a `~`
  prefix (new `_env_path()` helper, also applied to `AGY_QUOTA_STATE`). Neither
  Claude Code's `${user_config.*}` substitution nor this shell-less subprocess ever
  expanded `~`, so a `~`-prefixed value previously failed closed (`tls_ca_file`) or
  silently missed the binary (`agy_bin`).
- `plugins/imps` (0.3.37) — Validated `--cost-usd` as a well-formed decimal in
  audit-log; exit 1 on malformed input (#122).
- `plugins/imps` (0.3.37) — Synced CI SERVER_VERSION when auto-bumping plugin
  versions (#119).
- `plugins/imps` (0.3.37) — Realigned `parseGateDecision` test with widened gate
  regex.

### Removed

- Top-level `commands/`, `scripts/`, `personas/` directories. All content migrated
  into the respective plugin packages under `plugins/<name>/`.