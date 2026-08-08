---
name: clean
description: Delete ape's cloned repos for this project (keeps reports)
---

🐒 This is the "I say so" step — the only sanctioned way to delete ape's clones.

1. Workspace: `~/tmp/repo-research/<project-slug>/` (slug = current directory basename). If it doesn't exist, say so and stop.
2.  Show `du -sh` for `repos/` and list its contents so the user sees exactly what is about to go.
3. Ask the user to confirm.
4. On confirmation,  delete `repos/` ONLY. Keep `fingerprint.md`, `reports/`, and `RECOMMENDATIONS.md` — they are cheap, and they make re-synthesis and future runs cheaper.
5. Only if the user passed `--all` (or explicitly asks): wipe the whole workspace directory after a second confirmation.
