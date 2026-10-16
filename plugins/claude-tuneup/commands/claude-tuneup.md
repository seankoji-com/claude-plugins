---
description: >
  Use when Claude Code permission prompts are repetitive or settings scopes may be untidy.
  Scans transcripts, proposes safe read-only rules, and audits global versus project scope;
  do not use for changing tool behavior or granting write permissions.
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
- (no flag) — run all three; scan and audit propose changes before step 4's shared approval and apply

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
  "global_settings_source": null,
  "extra_global_bash_heads": [],
  "extra_global_read_paths": [],
  "project_scan_dirs": [],
  "project_compose_globs": ["docker-compose*.yml", "compose*.yml"],
  "project_service_names": []
}
```

- `global_settings_source` — optional absolute or `~/` path to the authoritative
  global settings source. Use the source repository's documented edit path when a
  renderer manages the runtime file; this option never authorizes extra writes.
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

**Global** (the verified `GLOBAL_SETTINGS_TARGET` selected below) — patterns that apply anywhere:

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
- Same-class-as-interpreter commands: `awk` (has `system()`/`getline | "cmd"` — arbitrary exec), `find * -exec *`, `sed -e 's/.../e'` (the `e` substitution flag executes its match), `xargs` without a safe-flag check (can invoke anything downstream), `source`/`.` (executes an arbitrary file's contents in-shell), `op run` (executes a command with secrets injected — the command it runs is the arbitrary part)
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

- Run both `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/scan_perms.py --json` (patterns, source lines, and completed/error/unobserved result counts from the last 50 transcripts) and `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/scan_perms.py` (SSH/sudo drill prefixes). Read the JSON-cited transcript lines for the complete remote command and quote style before forming a rule; drill prefixes are not complete shell commands. If the script is absent, Phase 1 is unavailable; run with `--audit-only`.
- `~/.claude/claude-tuneup.config.json` if it exists — see **Configuration** above; fall back to the documented defaults for any field it omits, and to all defaults if the file is absent entirely.
- `~/.claude/settings.json` — effective runtime settings, read even when a separate source manages them
- `.claude/settings.json` if it exists
- `.claude/settings.local.json` if it exists
- `CLAUDE.md` and `~/.claude/CLAUDE.md` for the 3e check
- Recursive scan of `CLAUDE.md` plus any `project_scan_dirs` for SSH aliases this repo uses; files matching `project_compose_globs` for container names — informs scope classification

**Resolve the global edit target before proposing or applying changes.**
`GLOBAL_SETTINGS_TARGET` below means the verified file path, not a shell expression.

- Read supplied dotfiles instructions and settings provenance. A real runtime file
  can be rendered; absence of a symlink does not make it the portable source.
- Use `global_settings_source` when configured, otherwise discover the source from
  the owner's documented renderer/edit path. Expand only a leading `~/`; never
  evaluate path text as shell code. Resolve existing symlinks and verify that the
  file is the documented source, rather than another generated/runtime copy.
  Honor the source repository's worktree rules; do not edit a live Stow checkout.
- When no renderer manages the file, use the resolved runtime file as the target.
  For a managed file, portable edits go to its source. An explicitly requested
  machine-local override may target the runtime file and must be labeled local.
- If a configured source is missing, invalid, or cannot be verified, or a managed
  source cannot be found, stop before settings writes and report the proposal.
  Never silently fall back to editing the rendered runtime file.
- Read both files when source and runtime differ. Use the runtime for effective
  permission coverage, and the source for portable global add/remove/move proposals.
  A runtime-only rule cannot justify removing a portable project rule.
- Name the exact target in each approval and diff. Use it consistently for backup,
  edits, validation, rollback, source-repository handling and reporting. Run step 4's
  shared preflight/backups and step 5's validation for edits even with `--scan-only`.

### 2. Phase 1 — Scan (skip if `--audit-only`)

**Pre-filter**: before surfacing any candidate, load `~/.claude/settings.json`, `.claude/settings.json`, and `.claude/settings.local.json` and build the combined prefix-match set. Drop any candidate whose raw command is already prefix-covered — the scanner counts raw invocations with no visibility into existing rules, so this check is mandatory to avoid proposing rules the harness already auto-allows. (Recurring de-dupe miss — see `claude-tuneup.notes.md`.)

From JSON scan output, investigate patterns with **count ≥ 3** that aren't already in any
allowlist. Counts are observations, not proof of permission friction or approval.
Inspect the cited source lines and corresponding results before recommending a rule.
Repetition alone never justifies widening permissions. Investigate denied calls as
possible approval friction: a safe read-only command rejected for lack of an allow rule
may justify a narrow proposal for the user's approval. A deliberate user refusal or
policy restriction must be respected. Generic errors also include product/network
failures; inspect the cited result to distinguish them. Missing results mean unknown.
Each proposal must cite its transcript, call `line`, and `result_line` when present, explain the actual avoidable approval,
and show the narrow rule. If friction cannot be established, report the observation
without proposing an allow rule. Zero proposed additions is a successful audit.

For each candidate:

1. Form the rule. Default: `Bash(<head> <first-subcmd> *)`, or `Bash(<head> *)` if no subcmd. For SSH lines, use the full `Bash(ssh <host> <quote-style><remote-cmd> *)` form so quote-style is preserved.
2. Classify (global vs project) per **Scope rules** above.
3. SKIP per **Safety rules** above (interpreters, shell wildcards, mutations) AND if it's already auto-allowed.
4. SKIP if the candidate is already **prefix-covered** by any existing allow rule across global, project, AND `settings.local.json` — not just exact match. A broad grant like `Bash(ssh nas *)` subsumes every `ssh nas …` drill row; bare `mcp__portainer` subsumes every `mcp__portainer__*` tool. The scanner counts raw invocations and won't have subtracted these, so the user would never actually be prompted for them. (Recurring de-dupe miss — see `claude-tuneup.notes.md`.)
5. SKIP an MCP candidate whose tool name isn't in the currently-connected / deferred tools list (same lookup as **3f**) — a scanned name can be stale or renamed since the transcript that surfaced it.

If scan output is dominated by `python3 -c` / heredoc / for-loop invocations, don't try to allowlist them individually — they vary too much to form a stable rule. Recommend a structural fix instead: swap to `jq` (already auto-allowed) or an available MCP tool where one exists, or adopt `sandbox.autoAllowBashIfSandboxed` plus a purpose-built triage hook (e.g. an `ssh-triage`-style script) for a whole class of read-only remote calls.

Prepare candidates grouped by scope for step 4's `AskUserQuestion` (multi-select). Guarantee any risk-class candidate (per **Safety rules**) a dedicated question slot rather than letting it get silently crowded out when higher-priority items fill all four. This phase only proposes additions: do not edit settings here. All accepted Phase 1 additions are applied in step 4 after its preflight and backups, then validated in step 5.

### 3. Phase 2 — Scope audit (skip if `--scan-only`)

This phase only proposes changes. Every settings write waits for step 4's approvals, preflight and backups.

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

Flag for removal — NEVER auto-remove; include it in step 4's explicit `AskUserQuestion` confirmation. Case-drift stragglers are a recurring pattern across runs (an MCP server renaming/relaunching under different casing, or getting disconnected outright, leaves the old rule behind) — check `claude-tuneup.notes.md` for ones specific to your own setup.

### 4. Confirm & apply

If `--dry-run`, print the full proposal and stop before approval questions, backups or settings edits.

Group changes into `AskUserQuestion` blocks:

- Phase 1 adds (prepared in step 2)
- Phase 2 3a/3b/3c (one combined multi-select)
- Machine-local runtime overrides (separate explicit confirmation; name the runtime target and label the changes local)
- Stale MCP entries (3f; explicit confirmation, never auto-removed)
- Env vars (separate, never auto-applied)
- CLAUDE.md (flagged only, never auto-edited)

If there are no accepted settings edits, skip the backup and edit steps. Otherwise record the exact edit targets and their approved scope: the verified `GLOBAL_SETTINGS_TARGET` for portable changes, the actual runtime `~/.claude/settings.json` for an explicitly approved machine-local override, and the project/local settings paths as needed. When a separate portable source manages the runtime, a purported local override must not resolve back to that source; stop until the documented real-file migration is available rather than relabeling a source write as local. Deduplicate targets that resolve to the same file. A separate source and runtime file are separate targets when both have approved edits. Use this target list for backups, writes, validation and rollback. Run the shared safeguards below before any settings change, including Phase 1 additions with `--scan-only`; they are independent of Phase 2.

Pre-step A — validate before touching anything: for the runtime `~/.claude/settings.json`, `GLOBAL_SETTINGS_TARGET` (if different), `.claude/settings.json` (if present), and `.claude/settings.local.json` (if present), run `jq '.' <file> >/dev/null`. If ANY fails to parse, STOP immediately — no backup, no edits. Backing up an already-malformed file preserves the corruption, and edits on top of it compound it with no path back to known-good. Report the offending file and its parse error, then abort the run.

Pre-step B — back up every existing file in the approved target list so a validation failure can roll back the settings set. Create each snapshot in the same directory with mode 0600, without overwriting an existing backup (use a unique suffix on collision). Record original absence for a target the run will create. If a required backup cannot be created and kept private, stop before settings edits and report the exact failure; do not redirect it to `/tmp/`.

- `GLOBAL_SETTINGS_TARGET` → `<target>.bak.<timestamp>` next to the verified edit target. Check its repository's backup-ignore rules; use mode 0600 and never stage backups. Do not back up the runtime file in place of a separate source target.
- Runtime `~/.claude/settings.json` → `~/.claude/settings.json.bak.<timestamp>` when it is an approved local-override target distinct from `GLOBAL_SETTINGS_TARGET`. If both source and runtime are selected, back up both; if they resolve to the same file, back it up once.
- `.claude/settings.json` → `.claude/settings.json.bak.$(date +%Y%m%d-%H%M%S)`
- `.claude/settings.local.json` → `.claude/settings.local.json.bak.$(date +%Y%m%d-%H%M%S)`

For each selected target, including an approved runtime override, preserve this run's snapshot and the 4 most-recent other snapshots. Prune only verified snapshots in that exact target's backup family. Treat each filename as one literal path, including spaces or shell metacharacters; do not split unquoted glob output through `xargs`. Leave unrelated backups alone. Keeping at most 5 snapshots bounds disk usage across irregular runs.

Apply only the accepted changes:

Record each target's pre-edit bytes or absence as its initial expected state. Before each write, including alphabetical sorting, compare the target with its last-known expected state; stop if it differs. After each successful write, verify that the result matches the intended bytes and update the expected state to those exact bytes before another edit. Retain the original snapshot or absence and this run's last verified written bytes separately for rollback. If a write fails or its result cannot be verified, stop and report the unknown state without overwriting it.

- Apply portable global edits to the verified `GLOBAL_SETTINGS_TARGET`; never silently substitute the rendered runtime file
- Apply an explicitly approved machine-local override to its separately listed and backed-up runtime target; label it local
- Edit `.claude/settings.json`
- Edit `.claude/settings.local.json` if relevant
- Keep each settings-edit small and traceable to one named `AskUserQuestion` approval — a combined/broad rewrite can get denied as self-modification even when the equivalent scoped edit wouldn't. Try the direct `Edit` first; fall back to a `jq` command (surfaced for the user to run) only if it actually gets blocked.

Sort `permissions.allow` alphabetically after edits.

### 5. Validate

Post-edit safety net (step 4's shared preflight catches pre-existing corruption). For each modified target: `jq '.' <file> >/dev/null`. On parse failure, first check that each target still matches this run's last written bytes. If it does, restore an existing target from its recorded snapshot, including a selected runtime override, or remove a settings file this run created whose original absence was recorded. If it differs, or this run's written state is unknown, preserve the current file and private backup and report a recovery conflict; do not overwrite or delete concurrent work. Stop with a clear error listing failed validation or restoration paths. Use the exact recorded target/backup pairs rather than reconstructing names or restoring a source backup over the runtime file. Report any rollback failure; never claim a consistent settings set until restoration is verified.

After validation, apply the documented renderer only within existing authorization
and the repository's rollout rules; otherwise report activation pending. Source
changes do not prove runtime activation. Never overwrite the runtime file to
simulate that render.

### 6. Commit

If `.claude/settings.json` was modified AND it's tracked in git:

- `git add .claude/settings.json`
- `git commit -m "chore(.claude): <one-line summary>"` — body summarizes adds + audit actions
- Don't push.

If `git` errors with a config issue (e.g. unresolved merge conflict in `~/.gitconfig`), surface the error and stop — don't try to work around it.

For a tracked global source in another repository, follow that repository's worktree
and signing rules. Commit only when that repository's changes are authorized, stage
only the source paths, and never include them in this project's commit. Otherwise
report the uncommitted source patch. Runtime overrides and ignored
`.claude/settings.local.json` are never committed.

### 7. Report

Classify the run before reporting it. Use `completed` only when every requested write passed
JSON validation and the requested phases finished. Use `partial` when some approved changes
landed but another change or phase failed, `blocked` when a tool or permission refusal stopped
the requested work, `failed` when no usable change was applied, and `cancelled` when the operator
stopped the run. Preserve the exact refusal or command error in the report. Never work around a
blocked settings write with a wrapper, alternate path, or broader permission rule.
The audit schema records `blocked` directly, with the exact refusal preserved in `--notes`.

**Before printing the summary below, you MUST run this** (the script itself is
fail-soft — a missing `jq` or unwritable log dir just warns and exits 0 — but this
step is not optional; the run isn't done until it executes):

Set `AUDIT_STATUS` to `completed`, `partial`, `blocked`, `failed`, or `cancelled` before running
the command below. The default keeps the example runnable; replace it when the run did not
complete successfully.

```bash
elapsed_ms=$(( ($(date +%s) - <captured start time>) * 1000 ))
AUDIT_STATUS="${AUDIT_STATUS:-completed}"
"${CLAUDE_PLUGIN_ROOT}/scripts/audit-log.sh" \
  --plugin claude-tuneup \
  --command /claude-tuneup \
  --exit-status "$AUDIT_STATUS" \
  --duration-ms "$elapsed_ms" \
  --scope user \
  --notes "<one-line: N added, D duplicates stripped, F findings logged>"
```

Then print the concise summary:

- Run status: `completed`, `partial`, `blocked`, `failed`, or `cancelled`, with the exact error when applicable

- Phase 1: N added (M global, K project) from T transcripts
- Phase 2: D duplicates stripped, P moved global → project, G removed/moved project → global
- E env vars flagged
- C CLAUDE.md items flagged
- Report the selected global source/runtime paths, actual backup paths, and whether source changes were rendered or await activation. A machine-local override is not a portable source change.
- If committed: commit SHA
- If Phase 3 ran: F findings logged to `claude-tuneup.notes.md`

### 8. Phase 3 — Self-reflect (skip if `--no-reflect`, `--dry-run`, `--scan-only`, or `--audit-only`)

After the report, capture what went sideways so the skill improves over time. Without this step, the same papercuts recur every run.

**8a. Self-audit**

Walk through these checks against this run. Each is one bullet in the log entry; mark `none` when the check passes cleanly.

- **Auto-mode write blocks**: did any Edit/Write/cp attempt against a settings file or `~/.claude/**` get denied as "agent self-configuration"? Note the exact path. (Known: the auto-mode classifier intermittently blocks additions to `~/.claude/settings.json`. **Pure-removal edits using an empty `new_string` succeed.** For additions that are blocked, generate a `jq` command and suggest `! <cmd>` so the user can run it in-session.)
- **Backup and rollback**: did each selected edit target receive its own mode-0600 `<target>.bak.<timestamp>` snapshot, and did failed validation restore the backed-up settings set? Record the actual target and backup paths or the exact backup failure; never silently redirect backups to another path.
- **De-dupe misses**: how many Phase 1 candidates turned out to be already covered by a prefix-match of an existing allow rule (i.e. the user would never have been prompted in practice)? The frequency scanner counts raw invocations and doesn't subtract patterns the harness was already auto-allowing via existing rules — surface that gap.
- **Mode mismatch**: was `AskUserQuestion` skipped because the user signaled autonomous mode ("work without stopping", `--yes`, etc.)? List which decisions were applied via safe-default heuristics instead of explicit confirmation.
- **Risk-class candidates**: did any proposed candidate match a class that arguably belongs on the safety-block list — e.g. `awk *` (has `system()` and `getline | "cmd"`), `find * -exec *`, `sed` with the `e` substitution flag, `xargs` without `--no-run-if-empty` + safe-flag check? Note each.
- **Stale entries in global**: 3f already makes this a first-class step — note whether it caught everything, or whether a stale rule slipped past it (e.g. a case-drift variant 3f's server-name lookup didn't match).
- **Intra-allowlist redundancy**: 3a's cross-file prefix-subsumption check ("any rule whose prefix is already covered by a broader rule in ANY allow file") already covers same-file redundancy incidentally — note whether it actually caught an intra-list case, or whether one slipped past.

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
- Resolve `GLOBAL_SETTINGS_TARGET` as above; a rendered real file is not its portable source.
- In a worktree, `.claude/settings.json` edits go through git like any tracked file. `.claude/settings.local.json` is per-checkout; never mirror its changes automatically into the main checkout.
- If `.claude/` is excluded via sparse-checkout, a normal worktree can't see it to edit it — work branch-only in a transient worktree with `git sparse-checkout disable` applied, then remove the worktree after pushing.
- The transcript scanner is read-only — `--audit-only` is safe to re-run.
