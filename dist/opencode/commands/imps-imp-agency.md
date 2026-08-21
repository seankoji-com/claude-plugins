---
description: >
  Use when an entire repository needs a read-only fitness and technical-health audit that
  produces an /imps-ready remediation plan. Do not use for one change's downstream
  effects; use /imps-blast-radius for that narrower question.
argument-hint: '[--focus dim1,dim2] [--out path]'
---

# /imps-imp-agency — audit the repo, brief the imps

Arguments: `$ARGUMENTS`

**Before executing any steps**, output the following intro block so the user knows what's happening:

> 🔍 **imp-agency** — whole-repo audit → imps-ready plan
>
> A wrangler subagent runs the audit end to end — one finder per dimension (purpose,
> docs, CI, tests, security, performance, UX, stack, ops, DX, verification), every serious finding
> adversarially refuted, a completeness critic, then synthesis into an `/imps`
> checklist plan. Effectiveness before craftsmanship: the purpose finder asks whether
> each component earns its existence and may verdict **delete** — those land in an
> operator-decision section of the plan, never as auto-remediation items. The finder
> traffic stays inside the subagent; you get back the plan and a one-line verdict,
> ready to `/clear` and dispatch remediation.

---

You are a senior engineering orchestrator running a whole-repo health audit. You do **one
thing in your own context** — resolve the project profile and show it to the user as a
gate — then hand the entire audit to the **imp-agency** subagent, which produces the plan
and returns just its `## Context` block and the item split. You are **read-only in the
repo**: no edits, no commits, no worktree. The only write is the plan file, outside the
repo. Everything noisy (finder returns, refuter traffic, critic output) lives in the
subagent.

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

## Phase 1 — Audit (imp-agency wrangler)

Finding, refutation, the completeness critic, and synthesis all run inside ONE
`imp-agency` subagent — none of the per-dimension finder returns, refuter traffic, or
critic output should reach your context. Load `SendMessage` first
(`ToolSearch: "select:SendMessage"`) — a `blocked` checkpoint is answered through it, and
the wrangler keeps its context across the resume.

**Spawn synchronously** via the Agent tool:

```
Agent(
  subagent_type: 'imps:👺',
  prompt: `Run your audit segment per your brief.
    Project profile: <the full profile content from Phase 0>
    Focus: <the --focus dims, or "all applicable dimensions">
    Out path: <the resolved absolute --out path>
    Plugin root: __PLUGIN_ROOT__`
)
```

Keep the `agentId` from the spawn — you `SendMessage` this same wrangler if it blocks, so
the resume lands in the context that already ran the finders.

**Agent-type fallback:** if `imps:👺` is not registered in this session, spawn
`general-purpose` with the full body of `agents/imp-agency.md` prepended to the prompt. If
subagents are unavailable entirely, execute that file's protocol inline in this session
(same steps, no offload) and note the degradation to the user.

**Answering checkpoints:**

- **`final`** — this is the deliverable. Print the `context_block` field verbatim, then the
  handoff below. Do **not** read the plan file yourself to "check" it — that re-absorbs
  exactly what the offload avoided.
- **`blocked` (`reason: "out_unwritable"`)** — surface `detail` to the user; once they give
  a writable absolute path, `SendMessage` the wrangler `retry out: <new-abs-path>`.
- **`blocked` (`reason: "profile_insufficient"`)** — the profile was missing something
  finders needed (`detail` says what). Fix it in Phase 0 terms and re-spawn a fresh
  wrangler with the corrected profile.
- **`blocked` (`reason: "no_findings"`)** — no confirmed P0–P2 finding survived
  refutation. Tell the user the repo passed, relaying the grades and any deferred-only
  notes from `detail`; there is no plan to dispatch and no resume verb.
- **`blocked` (`reason: "synthesis_invalid"`)** — the synthesis render failed the
  wrangler's structural checks twice; nothing was written. Show the user the `detail`
  excerpt; on their go, `SendMessage` the wrangler `retry synthesis` (one more render —
  finders are not re-run).

**Wrangler death mid-segment:** if `SendMessage` errors or the wrangler returns
malformed/non-JSON output, re-spawn a fresh `imps:👺` with the same Phase 1 prompt. The
audit is read-only and idempotent, so a re-run re-burns finder budget but produces a valid
plan — note that to the user, it isn't silent. If the re-spawn also fails, fall back to
executing the protocol inline.

## Handoff

On `final`, print the `context_block` verbatim, then exactly this (copy-pasteable — it's
the operator's next move):

```
Plan saved: <out_path>
Items: <total> (<p0> P0 · <p1> P1 · <p2> P2) — all should FAIL verification until remediated.
Delete verdicts: <delete_verdicts> — operator decision, in the plan's "Delete verdicts" section; imps never auto-delete.

Next steps:
1. /clear                      (the audit context is spent; imps re-read everything from the plan)
2. /imps <out_path>

Checklist mode will re-verify every item, report the failures, and offer to
dispatch remediation imps.
```

Omit the `Delete verdicts:` line when the checkpoint's `delete_verdicts` is 0 or absent.

Do not launch `/imps` yourself, and do not start fixing findings — the operator
decides when the imps run.
