# Checklist-file mode — /imps:imps

*Read by the orchestrator only when Mode detection resolved a single `.md` argument to
an existing file. Do not run the free-text phases of `commands/imps.md` — this is the
whole workflow for this mode.*

**1. Read the checklist file.**
The file path was resolved during mode detection. Read its full contents. Parse every
line matching `- [ ] ` (unchecked) or `- [x] ` (already checked) as a checklist item.
For each unchecked item, extract:
- The claim text (the line itself, stripped of the checkbox prefix)
- The `Verify:` sub-line (one line immediately following, or a labelled sub-bullet)
- The `Done when:` sub-line (same structure)

Items missing either `Verify:` or `Done when:` are surfaced as a parsing warning and
skipped; do not fabricate criteria.

**2. Confirm the resolved file with the operator.**
Print the resolved file path and item count:
```
Resolved checklist: <absolute-path>
Items to verify (unchecked): N
```
Ask: "Proceed with running these N verification commands?" Wait for confirmation.
Do not proceed to step 3 without an explicit yes — this is the gate that prevents
arbitrary shell execution from an unexpected file match.

**3. Build a query-only task table (Type=`query`).**
Create `GOAL.md` at the run's `GOAL_PATH` — derive it with
`eval "$("${CLAUDE_PLUGIN_ROOT}/scripts/imps-paths.sh")"`, then `mkdir -p "$RUNS_DIR"`
(see `commands/imps.md` -> **Run identity and the slug**; never re-derive the slug
inline) — using the standard spine format (see `commands/imps.md` Phase 2), with:
- Task = each unchecked checklist item (label = first 60 chars of the claim)
- Model = haiku for shell/grep checks; sonnet for items marked `[JUDGMENT — sonnet]`
- Type = `query` for all (read-only; no code changes)
- Depends-on = `—` unless one item's `Verify` step depends on a prior item's output

**4. Dispatch verification imps.**
For each task, spawn a `query` imp (haiku or sonnet, worktree-isolated=false) that:
- Runs the `Verify:` command(s)
- Evaluates output against `Done when:`
- Returns `PASS` or `FAIL: <reason>` (one line each)

Fan out in parallel where `Depends-on = —`. Collect results. (These are cheap read-only
audits — dispatch them directly; no state file or Workflow script is involved unless
remediation is chosen in step 6.)

**5. Emit the audit report.**
Print a structured summary:

```
## Audit — <filename> — <date>

### Passed ✅ (<N>)
- [x] <item claim>

### Failed ❌ (<N>)
- [ ] <item claim>
      Result: <reason from imp>

### Skipped ⚠️ (<N>) — missing Verify/Done-when
- [ ] <item claim>
```

**6. Offer remediation dispatch.**
If any items FAILED, ask the operator:
> "N items failed. Dispatch remediation imps (code/publish tasks) for all, some, or none?"

- **All / specific selection** → add them as `code` or `publish` tasks to the existing
  GOAL.md, then follow the free-text flow from `commands/imps.md` Phase 2 Step 5 onward:
  write the state file and hand the run to the Workflow script (model-routed,
  worktree-isolated for code changes).
- **None** → stop here. The audit report is the deliverable.

Do NOT auto-dispatch fixes without operator confirmation. Default is read-only.
