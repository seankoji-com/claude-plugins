<!-- OpenCode overrides for /imps-imp-agency. -->
<!-- Two sections only: both resolve the audit output path through the home environment -->
<!-- variable, which dist/ forbids, and both name Claude model aliases that resolve to -->
<!-- nothing on this platform (docs/platform-matrix.md, "Already measured"). -->

<!-- REPLACE-SECTION: ## Input -->
## Input

- `--focus <dims>` (optional) — comma-separated subset of the dimension keys
  (`purpose`, `docs`, `ci`, `tests`, `security`, `performance`, `ux`, `stack`, `ops`,
  `dx`); default is all applicable. A user unwilling to accept "delete this component"
  as a finding should focus away from `purpose` — arguing with the output wastes the run.
- `--out <path>` (optional) — where to write the plan. Default:
  `~/.config/opencode/imps/audits/<repo-name>-<YYYY-MM-DD>.md`. Must resolve to an
  **absolute, whitespace-free path outside the repo** — `/imps` checklist mode only
  triggers on a single token, and the audit is read-only in the repo. Resolved and
  validated in Phase 0 (below) before dispatching.
<!-- END-SECTION -->

<!-- REPLACE-SECTION: ## Phase 0 — Project profile (you; inline or haiku scouts, no wrangler yet) -->
## Phase 0 — Project profile (you; inline or cheap-tier scouts, no wrangler yet)

Never hardcode a stack. Resolve the profile once and pass it to the wrangler verbatim —
it gates every downstream token, so a wrong profile produces convergent garbage at scale.
Do this inline, or delegate the mechanical lookups to cheap read-only scout runs and
assemble the result:

- `DEFAULT_BRANCH` (self-detect via `git remote show origin`), current SHA, repo
  name/remote.
- **Stack manifest** — languages, frameworks, package manager, from manifests
  (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `compose*.yml`, …).
- `GATE_CMDS` — the repo's canonical build/lint/test/type commands and their dirs
  (`package.json` scripts, `Makefile`, `pyproject.toml`, CI config, `AGENTS.md`/
  `CONTRIBUTING.md`).
- **CI inventory** — workflow files, triggers, runner types.
- **UI surface?** — is anything browser-renderable, and what serves it locally.
- **Browser-rig availability** — probe cheaply for whatever browser automation this
  session has. Unreachable → the `ux` finder works code-grounded; record the downgrade so
  the wrangler notes it in Coverage.
- **Project docs** — README, AGENTS.md, CONTRIBUTING — the claims the `docs` finder
  checks against reality.
- **Reason for being** — what problem the repo solves, for whom, and what observable
  success looks like, distilled from the README/manifests/docs into ≤3 lines. Every
  `purpose`-finder judgment keys off this, so it is the profile field most worth getting
  right — and the one only the user can truly confirm. If part of the honest reason is
  "the maintainer enjoys building it", record that as a stated goal; otherwise every
  hobby component ablates to "delete".

**Resolve and validate the `--out` path** (before dispatching — the agent trusts that you
did):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
OUT="${out:-}"
[ -n "$OUT" ] || OUT=~/.config/opencode/imps/audits/"$(basename "$REPO_ROOT")-$(date +%F).md"
# Expand a leading ~ without interpolating the home variable — no generated artifact may
# carry a machine path (see build/README.md, "dist/ invariants").
case "$OUT" in "~/"*) OUT="$(cd ~ && pwd)/${OUT#\~/}" ;; esac
case "$OUT" in
  *[[:space:]]*)  echo "REJECT: path contains whitespace (checklist mode needs a single token) — pass a space-free --out" ;;
  "$REPO_ROOT"/*) echo "REJECT: --out is inside the repo; the audit is read-only there" ;;
  /*) mkdir -p "$(dirname "$OUT")" && echo "OUT ok: $OUT" ;;
  *)  echo "REJECT: --out must be an absolute path" ;;
esac
```

On a REJECT, ask the user for an absolute path outside the repo and re-resolve — do not
dispatch the wrangler with an unresolved or in-repo path. Pass the resolved absolute
`$OUT` as the agent's `Out path`.

**Show the profile to the user before dispatching the wrangler.** A wrong profile is cheap
to correct now and expensive to discover after the fan-out. Flag the **reason for being**
line explicitly when `purpose` is in scope — confirming it doubles as kill authority: the
user is agreeing that components which don't serve it are fair game for delete verdicts.
<!-- END-SECTION -->
