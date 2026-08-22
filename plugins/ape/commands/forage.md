---
description: >
  Use when the current project needs broad discovery across multiple OSS repositories
  for transferable techniques. Do not use when the user already named one GitHub source;
  use /ape:study for that depth-first comparison.
argument-hint: [focus area, e.g. testing | architecture | dx — optional]
allowed-tools: Task, Workflow, Read, Write, Glob, Grep, Bash(gh:*), Bash(mkdir:*), Bash(cp:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/init-workspace.sh:*), Bash(tree:*), Bash(ls:*), Bash(cat:*), Bash(du:*)
disable-model-invocation: true
---

Forage open-source repositories for techniques transferable to this project.

Focus area: $ARGUMENTS (if empty: architecture, testing, and developer experience broadly).

Workspace: `~/tmp/repo-research/<project-slug>/` where the slug is the current directory's basename. Every phase writes its artifacts here so synthesis can be re-run later without re-foraging, and so the user can inspect raw outputs.

## Phase 0 — Preflight + fingerprint (you; no subagents, no Workflow yet)

1. Run `gh auth status`. If unauthenticated, stop and tell the user to run `gh auth login` — nothing downstream works without it.
2. Run `${CLAUDE_PLUGIN_ROOT}/scripts/init-workspace.sh` — a single preapprovable command that creates `repos/` and `reports/` under the workspace and reports whether `fingerprint.md` already exists (with its `ls -la` timestamp).
3. If the script reported an existing `fingerprint.md` and its timestamp is under 30 days old, reuse it. Otherwise write it (≤150 words): stack, domain, architecture, notable existing patterns, 3–5 current weaknesses relevant to the focus area, and an explicit **already-in-use** list of techniques and tooling. Nothing on the already-in-use list may be recommended later.
4. Show the fingerprint to the user before dispatching anything. It gates every downstream token — a wrong fingerprint produces convergent garbage at scale.

## Phase 1 — Sync the Workflow script

Workflow scripts only load from `~/.claude/workflows/*.js` — a plugin cannot ship one that runs directly. Each run, re-sync the bundled canonical copy over the previous one so it always matches the installed plugin version (a plain overwrite, not a version/hash check — simpler and can't drift). **The `Workflow` tool call below is not Bash — it does not expand `~`,** so resolve and echo the absolute path here first, and pass that literal echoed value (never the `~/...` form) into Phase 2:

```bash
mkdir -p ~/.claude/workflows
cp "${CLAUDE_PLUGIN_ROOT}/scripts/ape-forage.workflow.js" ~/.claude/workflows/ape-forage.js
WORKFLOW_DEST="$HOME/.claude/workflows/ape-forage.js"
echo "$WORKFLOW_DEST"
```

## Phase 2 — Run the expedition

Invoke the `Workflow` tool:

```
Workflow({
  scriptPath: "<the echoed $WORKFLOW_DEST value, e.g. /Users/you/.claude/workflows/ape-forage.js>",
  args: {
    pluginRoot: "${CLAUDE_PLUGIN_ROOT}",
    fingerprint: "<the full fingerprint content from Phase 0>",
    focusArea: "<focus area, or \"architecture, testing, and developer experience broadly\" if empty>",
    workspaceDir: "<the workspace dir from Phase 0>"
  }
})
```

This runs in the background — discovery (3 axes in parallel), a ranking judgment call, cloning with one automatic retry on failure, per-repo analysis (in parallel), and synthesis are all real control flow inside the script now, not a hand-rolled checkpoint/resume protocol. Tell the user the expedition is running and that you'll report back when it completes — then stop; you'll be notified automatically.

**On completion, branch on the returned `status`:**

- **`final`** — this is the expedition's deliverable, not a status update. Present the `recommendations` field to the user directly, verbatim — do not re-summarize it, and do not read `RECOMMENDATIONS.md` or `reports/*.md` yourself to "check" it. Mention `nearMisses` if non-empty, and the `stats` line (repos analyzed, techniques surfaced).
- **`blocked` (`reason: "no_candidates"`)** — nothing survived discovery/triage/ranking. Tell the user and stop; a fresh run is the only way forward (a different focus area may surface more candidates).
- **`blocked` (`reason: "clone_failed"`)** — surface the `failed` list to the user. Once they've addressed the cause (auth, rate-limit, disk space), re-run `/ape:forage` — the fingerprint will be reused from cache, so the re-run costs only discovery through clone again, not the whole expedition.

**If the `Workflow` tool is unavailable in this session:** tell the user this command requires the `Workflow` tool and stop — there is no prose fallback path.
