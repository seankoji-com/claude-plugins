<!-- PLATFORM-SUPPORT: opencode=excluded agy=excluded -->

# claude-tuneup

Permission proposals must explain actual avoidable approval friction and cite the
transcript line that demonstrates it. `scripts/scan_perms.py --json` supplies source
locations (`line` for the call, `result_line` for its result or null when unobserved)
and correlated completed/error/unobserved counts, deduplicating replayed call
IDs within a transcript and identical ID/input replays across files. Results are
correlated within each file; the first scanned copy supplies the evidence, so a result
from a different file cannot silently complete a call. Repeated calls, errors, and missing results do not establish
approval or safety. The scanner reads local transcripts and never edits permissions;
zero proposed additions is a valid result.

The default text report retains streaming, raw occurrence counts and SSH/sudo drill
prefixes. JSON counts distinct call IDs, so replayed turns can make its counts lower.
Use JSON counts for the proposal threshold, then inspect source results: a permission
denial may reveal avoidable friction, but repetition never authorizes a new rule.

A three-phase permission audit and settings tuneup command for [Claude Code](https://code.claude.com/) — scans recent transcripts to surface missing allowlist entries, classifies them by global vs project scope, deduplicates across settings files, and logs findings to a running notes file you can act on.

## Platforms

| Claude Code | OpenCode | Agy |
| --- | --- | --- |
| native (this README) | **excluded** | **excluded** |

Not generated for OpenCode or Agy, and not planned. This plugin's entire subject is
Claude Code's own `settings.json` files, permission-rule syntax, and transcript store —
there is no equivalent surface on either target to port it to, so generating it would
produce a command that cannot do its job (`build/generation-manifest.json`). See
[`docs/plans/cross-platform-compat.md`](../../docs/plans/cross-platform-compat.md) for
the generation matrix.

---

## What it does

Most permission prompts are avoidable. `claude-tuneup` scans what Claude actually ran, classifies it, and proposes the minimum set of rules needed to stop the prompts — without over-permissioning.

**Phase 1 — Scan**

Reads the last 50 session transcripts and builds raw frequency tables for Bash commands, MCP tool calls, and SSH remote subcommands — the scanner (`scan_perms.py`) has no knowledge of `settings.json` or the harness's auto-allow list, it just counts invocations. The slash command then applies the actual filtering as an LLM judgment step: it drops candidates already covered by an existing allow rule (across global, project, and `settings.local.json`) and candidates the harness already auto-allows outright (e.g. `cat`, `git status`, `docker ps`), then classifies what's left as **global** (applies everywhere) or **project** (specific to this repo). Because this filtering is LLM-driven rather than hard-coded in the script, exact output can vary slightly run to run.

**Phase 2 — Audit**

Compares `~/.claude/settings.json` against `.claude/settings.json` (and `.claude/settings.local.json` if present) and proposes:

- Strip exact duplicates that appear in both files
- Strip entries in the narrower file that are prefix-subsumed by a broader rule in any file
- Move project-specific entries out of global settings
- Move generic entries up from project settings to global
- Flag stale MCP server entries whose server is no longer connected
- Flag env vars that belong to a different project
- Flag CLAUDE.md content in the wrong scope (never auto-edits — print only)

Before writing, the command resolves the authoritative global target, validates
settings JSON and backs up the selected edit targets. Failed post-edit validation
restores those backups. See the command's target-resolution and commit steps for
rendered settings and source repositories.

**Phase 3 — Self-reflect**

After each run, appends a dated entry to `~/.claude/claude-tuneup.notes.md` noting what the scan missed, what the audit flagged, and any recurring papercuts. This is a log, not a self-editing mechanism — the command never proposes or applies edits to its own body; read the notes file back yourself if you want to spot a recurring papercut and fix the command.

---

## Prerequisites

Claude Code only — no external tools required. The transcript scanner (`scan_perms.py`) is bundled with this plugin and invoked automatically.

---

## Configuration (optional)

The shipped scope rules are generic defaults — no directory layout or self-hosted
service names are hardcoded. If your setup has a specific infra layout (a fixed set of
directories that hold hostnames/SSH aliases, container manifests outside the standard
Compose filenames, extra Bash heads you consider globally safe), drop an optional
`~/.claude/claude-tuneup.config.json`:

```json
{
  "global_settings_source": null,
  "extra_global_bash_heads": ["lychee", "axiom"],
  "extra_global_read_paths": ["~/.cloudflare/**"],
  "project_scan_dirs": ["network/", "hardware/"],
  "project_compose_globs": ["stacks/*.yml"],
  "project_service_names": ["n8n"]
}
```

(The values above are one maintainer's actual homelab setup — a real example of what
this looks like filled in, not universal defaults.) Every field is optional; anything
omitted falls back to the generic default described in `commands/claude-tuneup.md`. The
command works with zero configuration.

For rendered global settings, set `global_settings_source` to the verified source
path (absolute or `~/`), or supply the source repository's documented edit path.
Portable changes use that source; explicit runtime overrides remain machine-local.
The command stops before settings writes when a managed source cannot be verified.

---

## Install

```bash
claude plugin marketplace add seankoji/claude-plugins
claude plugin install claude-tuneup@seankoji
```

---

## Usage

```
/claude-tuneup:claude-tuneup [flags]
```

Run from any git repo (or globally — Phase 2 always audits the global settings file regardless of where you invoke it).

### Flags

| Flag | Effect |
|---|---|
| `--scan-only` | Phase 1 only — propose new allowlist entries, skip the audit |
| `--audit-only` | Phase 2 only — audit existing settings, skip the transcript scan |
| `--dry-run` | Print all proposals from Phases 1 and 2; do not write anything. Skips Phase 3. |
| `--no-reflect` | Run Phases 1 and 2 but skip the self-reflect log (Phase 3) |
| _(no flag)_ | All three phases in order: scan → audit → reflect |

Default (no flag) is recommended: running Phase 1 before Phase 2 ensures that any new entries added by the scan are immediately checked by the audit for duplicates.

---

## Notes

- **Phase 1 requires `scan_perms.py`** — bundled with this plugin under `scripts/`. It is invoked automatically as `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/scan_perms.py`. If the script is absent for any reason, Phase 1 is skipped and the run falls back to `--audit-only` automatically.
- The transcript scanner is read-only — `--audit-only` is safe to re-run at any time.
- Permission rules are exact-prefix match: `Bash(npm *)` covers `Bash(npm test)` but not vice versa. The command prefers the broader rule when classifying new additions.
- Env vars flagged in Phase 2 are **never auto-removed** — they require explicit confirmation via `AskUserQuestion`.
- CLAUDE.md scope findings are printed as `file:line` notes and never auto-edited.
- **Global target**: runtime settings are read for effective permissions. Portable edits use the verified managed source, resolving symlinks where needed. A real runtime file may still be rendered. Source changes are reported separately from activation through its documented renderer.
- **Backup and rollback**: validate the runtime and every selected settings target before writes, then back up each edit target privately next to that target. Post-edit JSON failure restores all backed-up targets. This also applies to `--scan-only` edits.
- **Commits**: tracked project settings follow the project commit flow. A tracked global source follows its own repository's worktree/signing rules and existing commit authorization. Runtime overrides and ignored local settings are not committed.
- The self-reflect log lives at `~/.claude/claude-tuneup.notes.md` — one level above `commands/` so it is not auto-registered as a slash command.
- Phase 3 also appends a structured entry to `~/.claude/audit.jsonl` (shared across plugins in this marketplace — schema in the root `AGENTS.md`). Best-effort: skipped with a warning, not a failure, if `jq` is missing.
- To remove: `claude plugin uninstall claude-tuneup@seankoji`. The built-in `/fewer-permission-prompts` covers Phase 1 alone.

---

## License

MIT
