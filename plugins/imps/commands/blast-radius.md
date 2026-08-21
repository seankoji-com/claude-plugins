---
name: imps:blast-radius
description: >
  Use when a PR, diff, commit range, or named file change needs read-only analysis of what
  could break beyond the edited lines. Do not use for a whole-repo audit or to implement
  fixes; use /imps:imp-agency or /imps:imps for those jobs.
argument-hint: '[PR number | commit range | file paths; defaults to working-tree diff]'
disable-model-invocation: true
---

# /imps:blast-radius

Arguments: `$ARGUMENTS`

Before inspecting anything, say:

> 💥 **blast-radius** — proving what this change can affect beyond its diff

This command is read-only. Do not edit files, create branches, publish reviews, or fix a
finding. Analyze one change set and return the evidence an operator needs before merge.

## 1. Resolve the change set

Interpret the argument in this order:

1. A PR number: inspect its base, head, changed files, and diff with read-only GitHub and
   git commands.
2. A commit range: use that range exactly.
3. Existing file paths: compare their working-tree and index changes.
4. No argument: inspect the current working-tree and index diff against `HEAD`.

State the resolved base, head, and changed-file count. If the target is ambiguous, ask
one short question. Treat a blocked command as a denial; report the resulting evidence
gap instead of bypassing it.

## 2. State the apparent intent

In at most three lines, infer what the change is trying to preserve or alter. Name the
one or two safety invariants most likely to matter. If intent cannot be inferred from the
diff, commit, PR, tests, and nearby docs, mark it unknown rather than inventing it.

## 3. Trace outward

For every changed public symbol, format, schema, command, config key, lifecycle hook, or
generated source, follow consumers outside the changed lines. Search all relevant
languages and layers, then inspect enough surrounding code to distinguish a real consumer
from a textual match. Check these edges when applicable:

- callers, importers, registries, manifests, generators, and generated artifacts;
- wire formats, persisted data, cache keys, migrations, and backward compatibility;
- duplicated implementations, vendored or pinned dependency behavior, and local patches;
- CLI, UI, API, automation, documentation, and operational consumers;
- ordering, retries, cleanup, concurrency, timing, feature flags, and fallback paths.

Do not stop at grep. A matching name is a lead, not proof; the dangerous edge is often an
implicit contract with a different name.

## 4. Climb the proof ladder

Assign every material claim the strongest level actually reached:

1. **Text match**: a possible consumer was found.
2. **Source path**: the control or data flow reaches that consumer.
3. **Failure path**: a concrete input or state explains how the invariant could fail.
4. **Executable proof**: an existing focused test, check, or safe reproduction confirms
   or clears the risk.

Run the smallest existing, deterministic, read-only verification that can reach level 4.
Never write a new test during this command. If executable proof is unavailable or blocked,
label the claim **unproven** and say exactly what command or harness would settle it.

## 5. Report

Return these sections, in order:

1. **Change and invariants**: resolved target, apparent intent, and safety invariants.
2. **Confirmed blast radius**: affected consumers with file and line evidence.
3. **Risks**: severity, proof level, concrete failure path, and smallest verification.
4. **Cleared edges**: plausible consumers investigated and ruled out, with evidence.
5. **Before merge**: only the remaining actions needed to convert unproven risks into
   executable proof. Say `None` when every material edge is cleared.

Keep source observations separate from inference. Do not inflate a missing harness into a
confirmed product bug, and do not clear a risk merely because the edited unit tests pass.
