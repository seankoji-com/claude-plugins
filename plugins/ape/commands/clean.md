---
description: >
  Use only when the operator wants to delete ape's cloned repositories for this project.
  Keeps reports unless --all is explicit; do not use for ordinary workspace cleanup.
argument-hint: [--all to also wipe fingerprint and reports]
allowed-tools: Bash(du:*), Bash(ls:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/clean-ape-workspace.sh:*), Bash(basename:*), Read, Glob
disable-model-invocation: true
---

🐒 This is the "I say so" step — the only sanctioned way to delete ape's clones.

1. Workspace: `~/tmp/repo-research/<project-slug>/` (slug = current directory basename). If it doesn't exist, say so and stop.
2. Show `du -sh` for the top-level `repos/` and every
   `studies/<owner>__<repo>/repos/` directory, then list their contents so the user sees
   exactly what is about to go. Use `Glob`, not an unbounded filesystem search, to resolve
   the study clone directories.
3. Ask the user to confirm.
4. On confirmation, run `${CLAUDE_PLUGIN_ROOT}/scripts/clean-ape-workspace.sh <workspace-path> --confirm`. This deletes `repos/` ONLY. Keep `fingerprint.md`, `reports/`, and `RECOMMENDATIONS.md` — they are cheap, and they make re-synthesis and future runs cheaper.
5. Only if the user passed `--all` (or explicitly asks): run `${CLAUDE_PLUGIN_ROOT}/scripts/clean-ape-workspace.sh <workspace-path> --all --confirm` after a second confirmation.
