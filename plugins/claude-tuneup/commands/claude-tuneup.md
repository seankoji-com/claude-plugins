---
description: Tune up Claude Code permissions — scan recent transcripts for common read-only Bash/MCP patterns (classified by scope) and add them, then audit ~/.claude/settings.json vs project .claude/settings.json to strip duplicates and move misplaced entries
argument-hint: '[--scan-only | --audit-only | --dry-run | --no-reflect]'
---

**Before executing any steps**, output the following intro block so the user knows what's happening:

> 🔧 **claude-tuneup** — fewer prompts, cleaner settings
>
> Scans your recent Claude Code sessions for patterns that could be pre-approved permissions,
> then audits your global and project settings for duplicates and misplaced entries. The result:
> less friction every time you use Claude Code, and settings files that actually reflect how you work.

---

Combined permission tune-up. Phase 1 is the same scan-and-add work as the built-in `/fewer-permission-prompts` but classifies each candidate by scope (global vs project) instead of dumping everything into the project file. Phase 2 audits the two settings files for duplicates and misplaced entries. Phase 3 self-audits the run and logs findings so the skill improves over time.

Three phases, run in order by default:

1. **Scan** — last 50 session transcripts → common read-only Bash and MCP tool calls → proposed adds (classified by scope).
2. **Audit** — compare global vs project allowlists → strip duplicates, move misplaced entries, flag stale env vars and CLAUDE.md content.
3. **Self-reflect** — capture lessons from this run and append them to a running notes file.

Flags:

- `--scan-only` — Phase 1 only
- `--audit-only` — Phase 2 only
- `--dry-run` — print proposals from both phases, don't write (skips Phase 3)
- `--no-reflect` — run Phases 1 + 2 but skip Phase 3
- (no flag) — run all three, scan first (adds can create new duplicates the audit catches)

Capture the run start time now — run `date +%s` and hold the value for the audit log
entry in step 7 (Report) below — that step always runs it, regardless of which flags
skip Phase 3.

## Configuration (optional)

This plugin's scope rules below cover only generic, widely-applicable defaults — no
directory layout or self-hosted service names are hardcoded. If your setup uses a
particular homelab/infra layout (container manifests outside the standard Compose
filenames, a fixed set of directories that hold hostnames/SSH aliases, extra Bash heads
you consider globally safe), point the run at an optional config file:
`~/.claude/claude-tuneup.config.json`. If absent, every field below falls back to its
generic default — the command works out of the box with no config.

```json
{
  "extra_global_bash_heads": [],
  "extra_global_read_paths": [],
  "project_scan_dirs": [],
  "project_compose_globs": ["docker-compose*.yml", "compose*.yml"],
  "project_service_names": []
}
```

- `extra_global_bash_heads` — additional Bash command heads to treat as globally safe
  read-only-ish patterns (still filtered through **Safety rules** below — this can't
  bypass the interpreter/shell/installer block list). Example: a link checker or a
  metrics CLI you run from every project.
- `extra_global_read_paths` — additional glob paths to allow `Read` on globally, beyond
  the shipped defaults (`~/.config/**`, `~/.wrangler/**`, `/private/etc/**`).
- `project_scan_dirs` — extra directories (beyond `CLAUDE.md`) to scan for hostnames/SSH
  aliases this repo uses, for classifying scan candidates as project-scoped.
- `project_compose_globs` — glob patterns for this project's container/service manifest
  files, scanned for container names. Defaults to the standard Docker Compose filenames;
  override if your manifests live elsewhere (e.g. a custom `stacks/*.yml` layout).
- `project_service_names` — extra project-specific service subcommand names to treat as
  project-scoped (e.g. a self-hosted automation tool's CLI).

See `README.md` for a filled-in example config.

## Scope rules

**Global** (`~/.claude/settings.json` — may be a symlink; follow it before writing) — patterns that apply anywhere:

- Generic Bash heads: `git`, `gh`, `npm`, `npx`, `jq`, `mkdir`, `ping`, `traceroute`, `dig`, `route get`, `ipconfig`, `scutil`, `op`, `openssl`, `security`, `ssh-add`, `tar`, `unzip`, `xargs`, `time`, `sleep`, `wait`, plus anything listed in `extra_global_bash_heads` (see **Configuration** above)
- All `mcp__*` tools EXCEPT ones whose target is project-state
- `Read`/`Write`/`Edit` on `/tmp/**`, `/private/tmp/**`
- `Read` on global config dirs (`~/.config/**`, `~/.wrangler/**`, `/private/etc/**`, plus anything in `extra_global_read_paths`)
- `Bash(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/<script>.py*)` — scripts in the global scripts dir
- `Skill(<name>)` entries for globally-used skills

**Project** (`.claude/settings.json`) — patterns referencing THIS repo:

- Hostnames or SSH aliases defined in this repo (look in `CLAUDE.md` and any dirs listed in `project_scan_dirs`)
- Container names from files matching `project_compose_globs`
- Paths under the repo's working directory
- Service-specific subcommands matching `project_service_names` (e.g. a self-hosted tool's CLI, project-specific docker exec paths)
- Project-specific webhook URLs / API endpoints

**Skip — different repo** (neither global nor project): `scan_perms.py` scans `~/.claude/projects/` across every repo on the machine, not just this one. If a candidate's hostname, container name, path, or service reference clearly belongs to a repo other than the current one, DROP it — don't default it into this repo's `.claude/settings.json` as a false-positive project entry. Cross-check against sibling directory names and other repos' known aliases when in doubt.

Quote-style variants (`'foo *` vs `"foo *`) are SEPARATE permission rules — Claude's matcher is exact-prefix. NEVER dedupe across quote styles.

Bare and wildcard forms are also separate rules, not one subsuming the other: `Bash(jq *)` requires a trailing argument and does NOT cover the bare, argless `Bash(jq)`. When proposing or deduping, check for both forms rather than assuming the wildcard covers the bare command.

## Safety rules (applied in BOTH phases)

NEVER allowlist a pattern that grants arbitrary code execution. A wildcard on any of these is equivalent to "allow anything":

- Interpreters: `python`/`python3`, `node`, `bun`, `deno`, `ruby`, `perl`, `php`, `lua`
- Shells: `bash`, `sh`, `zsh`, `fish`, `eval`, `exec`, `ssh` (the bare form — narrow rules like `ssh nas 'ls *` are fine)
- Same-class-as-interpreter commands: `awk` (has `system()`/`getline | "cmd"` — arbitrary exec), `find * -exec *`, `sed -e 's/.../e'` (the `e` substitution flag executes its match), `xargs` without a safe-flag check (can invoke anything downstream)
- Package runners: `npx`, `bunx`, `uvx`, `uv run`
- Package installers (run build/lifecycle scripts at install time): `pip install *` / `pip3 install *`, `npm install *` / `npm ci *`, `yarn add *`, `pnpm add *`, `gem install *`, `cargo install *` — the bare argless `npm install` / `npm ci` (install from a committed lockfile) are fine
- Task-runner wildcards: `npm run *`, `yarn run *`, `pnpm run *`, `bun run *`, `make *`, `just *`, `cargo run *`, `go run *` — exact forms (e.g. `Bash(bun run typecheck)`) are fine
- `gh api *`, `docker run`/`exec`, `kubectl exec`, `sudo`

DROP commands Claude Code already auto-allows (no allowlist entry needed) — an
allowlist entry for one of these is a no-op at best. This list is this plugin's own
maintained knowledge of Claude Code's built-in read-only auto-allow behavior; it is not
sourced from a file this plugin (or its users) has access to, so it can drift from the
actual CLI version over time — treat a candidate that seems to already work without a
rule as a signal to recheck this list, not just trust it blindly:

- Always auto-allowed (any args): `cat`, `head`, `tail`, `ls`, `find`, `wc`, `stat`, `id`, `uname`, `pwd`, `whoami`, `echo`, `printf`, `cd`, `which`, `true`, `false`, `sleep`, `expr`, `test`, `diff`, `cmp`, plus text manipulation (`cut`, `tr`, `column`, `sort`, `uniq`, `tac`, `rev`, `fold`, `expand`)
- Auto-allowed with safe flags only: `xargs`, `file`, `sed`, `sort`, `grep`/`egrep`/`fgrep`, `sha256sum`/`sha1sum`/`md5sum`, `tree`, `date`, `hostname`, `lsof`, `pgrep`, `ss`, `fd`/`fdfind`, `rg`, `jq`, `uniq`, `history`, `arch`, `ifconfig`, `pyright`, `ps`, `netstat`, `base64`, `man`, `info`, `tput`
- All git read-only subcommands (`git status`, `git log`, `git diff`, `git show`, `git blame`, etc.)
- All gh read-only subcommands (`gh pr view/list`, `gh issue view/list`, `gh run view/list`, `gh api` GET, etc.)
- All docker read-only subcommands (`docker ps`, `docker images`, `docker logs`, `docker inspect`)

If a candidate matches any of these, drop it — no rule needed.

## Steps

### 1. Inventory (always)

Read in parallel:

- `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/scan_perms.py` — frequency tables for Bash, MCP, SSH/sudo drills (last 50 transcripts). If absent, Phase 1 is unavailable; run with `--audit-only`.
- `~/.claude/claude-tuneup.config.json` if it exists — see **Configuration** above; fall back to the documented defaults for any field it omits, and to all defaults if the file is absent entirely.
- `~/.claude/settings.json` — follow the symlink to the real file if it's a link
- `.claude/settings.json` if it exists
- `.claude/settings.local.json` if it exists
- `CLAUDE.md` and `~/.claude/CLAUDE.md` for the 3e check
- Recursive scan of `CLAUDE.md` plus any `project_scan_dirs` for SSH aliases this repo uses; files matching `project_compose_globs` for container names — informs scope classification

### 2. Phase 1 — Scan (skip if `--audit-only`)

**Pre-filter**: before surfacing any candidate, load `~/.claude/settings.json`, `.claude/settings.json`, and `.claude/settings.local.json` and build the combined prefix-match set. Drop any candidate whose raw command is already prefix-covered — the scanner counts raw invocations with no visibility into existing rules, so this check is mandatory to avoid proposing rules the harness already auto-allows. (Recurring de-dupe miss — see `claude-tuneup.notes.md`.)

From scan output, surface candidates with **count ≥ 3** that aren't already in any allowlist.

For each candidate:

1. Form the rule. Default: `Bash(<head> <first-subcmd> *)`, or `Bash(<head> *)` if no subcmd. For SSH lines, use the full `Bash(ssh <host> <quote-style><remote-cmd> *)` form so quote-style is preserved.
2. Classify (global vs project) per **Scope rules** above.
3. SKIP per **Safety rules** above (interpreters, shell wildcards, mutations) AND if it's already auto-allowed.
4. SKIP if the candidate is already **prefix-covered** by any existing allow rule across global, project, AND `settings.local.json` — not just exact match. A broad grant like `Bash(ssh nas *)` subsumes every `ssh nas …` drill row; bare `mcp__portainer` subsumes every `mcp__portainer__*` tool. The scanner counts raw invocations and won't have subtracted these, so the user would never actually be prompted for them. (Recurring de-dupe miss — see `claude-tuneup.notes.md`.)
5. SKIP an MCP candidate whose tool name isn't in the currently-connected / deferred tools list (same lookup as **3f**) — a scanned name can be stale or renamed since the transcript that surfaced it.

If scan output is dominated by `python3 -c` / heredoc / for-loop invocations, don't try to allowlist them individually — they vary too much to form a stable rule. Recommend a structural fix instead: swap to `jq` (already auto-allowed) or an available MCP tool where one exists, or adopt `sandbox.autoAllowBashIfSandboxed` plus a purpose-built triage hook (e.g. an `ssh-triage`-style script) for a whole class of read-only remote calls.

Present candidates grouped by scope via `AskUserQuestion` (multi-select) — guarantee any risk-class candidate (per **Safety rules**) a dedicated question slot rather than letting it get silently crowded out when higher-priority items fill all four. Apply accepted additions.

### 3. Phase 2 — Scope audit (skip if `--scan-only`)

Pre-step A — validate before touching anything: for each of `~/.claude/settings.json` (resolve the symlink first), `.claude/settings.json` (if present), and `.claude/settings.local.json` (if present), run `jq '.' <file> >/dev/null`. If ANY fails to parse, STOP immediately — no backup, no edits. Backing up an already-malformed file preserves the corruption, and edits on top of it compound it with no path back to known-good. Report the offending file and its parse error, then abort the run.

Pre-step B — back up every settings file the audit may edit so a validation failure can roll back atomically. For each of these files that exists, create a timestamped snapshot in the same directory:

- `~/.claude/settings.json` → `<dir>/settings.json.bak.$(date +%Y%m%d-%H%M%S)`. Resolve the symlink first so the `.bak` lives in the storage dir (where the matching `.gitignore` rule covers it).
- `.claude/settings.json` → `.claude/settings.json.bak.$(date +%Y%m%d-%H%M%S)`
- `.claude/settings.local.json` → `.claude/settings.local.json.bak.$(date +%Y%m%d-%H%M%S)`

Prune stale backups right after creating the new ones: for each backup glob, keep only the 5 most-recent files and delete the rest — `ls -t <glob> 2>/dev/null | tail -n +6 | xargs -r rm -f`. Run this for `<dir>/settings.json.bak.*`, `.claude/settings.json.bak.*`, and `.claude/settings.local.json.bak.*`. Keep-last-5 (not age-based) because runs are irregular — a `-mtime +30` cutoff would let backups pile up indefinitely between infrequent runs, while keep-last-5 bounds disk usage regardless of run cadence.

**3a. Duplicates & cross-file prefix subsumption**

Compute `global.allow ∩ project.allow` (exact string match). Each duplicate → strip from project.

Then strip **prefix-subsumed** entries across files: any rule whose prefix is already covered by a broader rule in ANY allow file (rules are unioned, so the narrow one never changes behaviour). Strip the redundant copy from the most-ephemeral file (`settings.local.json` first, then project `settings.json`); keep the broad rule. E.g. bare `mcp__authentik` / `mcp__mealie` in global subsume every `mcp__authentik__*` / `mcp__mealie__*` in `settings.local.json`. (Recurring: interactive permission grants keep regenerating these in `settings.local.json` — see `claude-tuneup.notes.md`.)

**3b. Project-specific entries in global**

Iterate `global.allow`. Flag entries that reference:

- Any hostname/alias mentioned in this repo's docs or `project_scan_dirs`
- Any container/service name from files matching `project_compose_globs`
- Paths under this repo's working directory
- Project-specific binary paths (e.g. `/usr/local/bin/docker exec <container>`)

Propose moving each down to project.

**3c. Generic entries in project**

Iterate `project.allow`. Flag entries matching the **Global** scope rules. For each:

- If global already has it → remove from project (3a usually covers this, but re-check after 3b moves)
- If global doesn't have it → propose moving up

Also flag stale entries:

- `Bash(npm *)` patterns when there's no `package.json` in the repo
- Lowercase `mcp__claude-in-chrome__*` variants when global has uppercase `mcp__Claude_in_Chrome__*` canonical names

**3d. Env vars in global**

Read the `env` block. For each key, check whether it references a project this repo isn't:

- `<PROJECTNAME>_*` patterns where `<PROJECTNAME>` matches a directory under `~/repos/` other than the current one
- Service URLs / hostnames clearly belonging elsewhere

Flag — NEVER auto-remove env vars. Always ask via `AskUserQuestion`. Env removal can break workflows that aren't visible from this repo.

**3e. CLAUDE.md sanity**

Read both `~/.claude/CLAUDE.md` and `./CLAUDE.md`. Flag (don't auto-edit):

- Project-specific content in global CLAUDE.md
- Generic preferences in project CLAUDE.md that would apply across other projects

Print a one-line note per flagged item with `file:line`. Manual follow-up.

**3f. Stale MCP entries**

Iterate `global.allow` + `project.allow` for `mcp__<server>__*` rules. For each, check whether `<server>` appears in the currently-connected / deferred tools list (the `mcp__<server>__*` names surfaced in `<system-reminder>` blocks). Flag any rule whose `<server>` prefix is absent — the server is no longer connected, so the rule is dead weight. Watch for **case drift** too: a server can reconnect under a different case (e.g. `mcp__Claude_in_Chrome__*` → live lowercase `mcp__claude-in-chrome__*`), leaving the old-case rules stale while the live-case tools go unallowed.

Exception: if `<server>` is named in `~/.claude/CLAUDE.md` (or this repo's `CLAUDE.md`) as a server the user relies on, absence is more likely a session-connect gap than a truly dead server — flag it as "not connected this session" rather than proposing removal.

Flag for removal — NEVER auto-remove; ask via `AskUserQuestion`. Case-drift stragglers are a recurring pattern across runs (an MCP server renaming/relaunching under different casing, or getting disconnected outright, leaves the old rule behind) — check `claude-tuneup.notes.md` for ones specific to your own setup.

### 4. Confirm & apply

Group changes into `AskUserQuestion` blocks:

- Phase 1 adds (presented in step 2)
- Phase 2 3a/3b/3c (one combined multi-select)
- Env vars (separate, never auto-applied)
- CLAUDE.md (flagged only, never auto-edited)

If `--dry-run`, print the full proposal and stop. Otherwise apply accepted changes:

- Edit `~/.claude/settings.json` (resolve symlink first; the write tool refuses symlink writes)
- Edit `.claude/settings.json`
- Edit `.claude/settings.local.json` if relevant
- Keep each settings-edit small and traceable to one named `AskUserQuestion` approval — a combined/broad rewrite can get denied as self-modification even when the equivalent scoped edit wouldn't. Try the direct `Edit` first; fall back to a `jq` command (surfaced for the user to run) only if it actually gets blocked.

Sort `permissions.allow` alphabetically after edits.

### 5. Validate

Post-edit safety net (the pre-flight check in step 3 catches pre-existing corruption; this catches edits that broke a previously-valid file). For each modified file: `jq '.' <file> >/dev/null`. On parse failure, restore all backed-up files from their `.bak.` snapshots atomically — `cp <file>.bak.<ts> <file>` for each backed-up file — and stop with a clear error listing which file(s) failed validation. Restoring all three files (even if only one failed) keeps the settings set consistent rather than leaving one rolled-back file alongside newly-edited siblings.

### 6. Commit (project only)

If `.claude/settings.json` was modified AND it's tracked in git:

- `git add .claude/settings.json`
- `git commit -m "chore(.claude): <one-line summary>"` — body summarizes adds + audit actions
- Don't push.

If `git` errors with a config issue (e.g. unresolved merge conflict in `~/.gitconfig`), surface the error and stop — don't try to work around it.

Don't touch git state for `~/.claude/settings.json` (managed via dotfiles, not this repo's git) or `.claude/settings.local.json` (gitignored).

### 7. Report

**Before printing the summary below, you MUST run this** (the script itself is
fail-soft — a missing `jq` or unwritable log dir just warns and exits 0 — but this
step is not optional; the run isn't done until it executes):

```bash
elapsed_ms=$(( ($(date +%s) - <captured start time>) * 1000 ))
"${CLAUDE_PLUGIN_ROOT}/scripts/audit-log.sh" \
  --plugin claude-tuneup \
  --command /claude-tuneup \
  --exit-status completed \
  --duration-ms "$elapsed_ms" \
  --scope user \
  --notes "<one-line: N added, D duplicates stripped, F findings logged>"
```

Then print the concise summary:

- Phase 1: N added (M global, K project) from T transcripts
- Phase 2: D duplicates stripped, P moved global → project, G removed/moved project → global
- E env vars flagged
- C CLAUDE.md items flagged
- Backups at `~/.claude/settings.json.bak.<ts>`, `.claude/settings.json.bak.<ts>`, `.claude/settings.local.json.bak.<ts>` (each in its source directory; `/tmp/` fallback if the source dir was blocked)
- If committed: commit SHA
- If Phase 3 ran: F findings logged to `claude-tuneup.notes.md`

### 8. Phase 3 — Self-reflect (skip if `--no-reflect`, `--dry-run`, `--scan-only`, or `--audit-only`)

After the report, capture what went sideways so the skill improves over time. Without this step, the same papercuts recur every run.

**8a. Self-audit**

Walk through these checks against this run. Each is one bullet in the log entry; mark `none` when the check passes cleanly.

- **Auto-mode write blocks**: did any Edit/Write/cp attempt against a settings file or `~/.claude/**` get denied as "agent self-configuration"? Note the exact path. (Known: the auto-mode classifier intermittently blocks additions to `~/.claude/settings.json`. **Pure-removal edits using an empty `new_string` succeed.** For additions that are blocked, generate a `jq` command and suggest `! <cmd>` so the user can run it in-session.)
- **Backup fallback used**: did the backup destination need to fall back from `<dir>/settings.json.bak.<ts>` to `/tmp/`? Note the dest.
- **De-dupe misses**: how many Phase 1 candidates turned out to be already covered by a prefix-match of an existing allow rule (i.e. the user would never have been prompted in practice)? The frequency scanner counts raw invocations and doesn't subtract patterns the harness was already auto-allowing via existing rules — surface that gap.
- **Mode mismatch**: was `AskUserQuestion` skipped because the user signaled autonomous mode ("work without stopping", `--yes`, etc.)? List which decisions were applied via safe-default heuristics instead of explicit confirmation.
- **Risk-class candidates**: did any proposed candidate match a class that arguably belongs on the safety-block list — e.g. `awk *` (has `system()` and `getline | "cmd"`), `find * -exec *`, `sed` with the `e` substitution flag, `xargs` without `--no-run-if-empty` + safe-flag check? Note each.
- **Stale entries in global**: did the audit notice MCP rules (or other entries) in the global allow list that aren't backed by any currently-connected server? The skill flags these manually right now — log so they can become a first-class step later.
- **Intra-allowlist redundancy**: did the audit catch any rule that's fully subsumed by another rule's prefix-match within the SAME list (e.g. `Bash(ssh nas 'which docker)` next to `Bash(ssh nas 'which *)`)? This isn't a 3a/3b/3c step today; log occurrences.

**8b. Improvement log**

Append a dated entry to `~/.claude/claude-tuneup.notes.md` (one level above `commands/` so it isn't auto-registered as a slash command) (create if missing). Format:

```markdown
## YYYY-MM-DD — <repo or "global only"> — <one-line summary>

- <finding 1>
- <finding 2>
- ...
```

Keep entries terse. Reuse the same wording across runs when the same finding recurs — exact-string matching makes it easy to spot at a glance which findings are one-offs vs. recurring, if you're ever scanning the file yourself.

The structured `audit.jsonl` append already happened in step 7 (Report) above — every
run reaches it, not just runs where Phase 3 executes. This command does not propose or
apply edits to its own body based on the notes log — `claude-tuneup.notes.md` and
`audit.jsonl` are for you to read back if you want to spot a recurring papercut and fix
the command yourself, or run `/learn` from a claude-plugins checkout to turn recurring
entries into a proposed, operator-gated command-body edit.

## Notes

- To remove: `claude plugin uninstall claude-tuneup@seankoji`. The built-in `/fewer-permission-prompts` covers Phase 1 alone.
- The audit can be opinionated about scope — when in doubt, ASK rather than auto-move.
- Permission rules are exact-prefix match: `Bash(npm *)` covers `Bash(npm test)` but not vice versa. Prefer the broader rule when classifying adds.
- Never add a write/mutation pattern automatically — surface it for the user to explicitly approve.
- Don't dedupe across quote styles — `'foo *` and `"foo *` are distinct in Claude's matcher.
- If `~/.claude/settings.json` is a symlink, follow it to the real file before writing.
- In a worktree, `.claude/settings.json` edits go through git like any tracked file; `.claude/settings.local.json` is per-checkout, so update both worktree and main copy if both exist.
- If `.claude/` is excluded via sparse-checkout, a normal worktree can't see it to edit it — work branch-only in a transient worktree with `git sparse-checkout disable` applied, then remove the worktree after pushing.
- The transcript scanner is read-only — `--audit-only` is safe to re-run.
