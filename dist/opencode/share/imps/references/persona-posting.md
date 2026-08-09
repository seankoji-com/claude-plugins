# Persona posting-identity protocol

*Shared by every caller that runs the five-persona review panel — `commands/issue-mode.md`
Phase 4 and the free-text run's own panel alike. Generalized on purpose: this file
names the identity/fail-closed rule itself, not any one caller's phase numbering, artifact
shape, or trigger. Each caller supplies its own context (when the panel runs, where a
failed-post finding is recorded) around this shared rule — do not restate this content in
a caller; cite this file instead.*

**Posting identity — dedicated GitHub Apps, not the caller.** By default each persona
posts through its own GitHub App identity (`mm-solution-architect`, `mm-grumpy-engineer`,
`mm-sre`, `mm-business-analyst`, `mm-ux-designer`) via `~/.config/opencode/scripts/persona-post.sh`,
which mints that App's own installation token — never the calling session's own `gh` /
GitHub-MCP credentials. This fixes the identity/attribution half of a real problem:
without it, the same session that authored the PR's content would post its own
`VERDICT: APPROVE` under its own name, with no distinguishable reviewer at all. Posting
through the `mm-*` Apps gives each persona a genuinely separate, traceable GitHub actor.
**It is not an unforgeable gate** — the calling session still holds (via 1Password) the
credentials `persona-post.sh` uses to mint every App's token, so a compromised or
misbehaving session could still mint an APPROVE under any `mm-*` identity without truly
running that persona's review. Treat this as independent attribution and audit trail, not
as a branch-protection control the authoring session itself is unable to satisfy. The one
thing this mechanism *does* guarantee, enforced below rather than by prompt discipline
alone: when the App path fails for a persona, that persona's verdict never silently
reappears under the calling session's own identity — see **Fallback** below. Each
persona's slug maps straight onto its App (`solution-architect` also accepts the alias
`technical-architect`); the script itself handles JWT minting and installation-token
exchange from 1Password (vault `robot.house`, item `persona-app-<slug>`) — no other setup
is required per repo beyond having the Apps installed there.

Post like this — **one temp file per persona**, never a shared path (when multiple
personas post concurrently, a shared `/tmp/review.md` lets one persona's write race
another's read and post the wrong body under the wrong identity):
```bash
f="$(mktemp "${TMPDIR:-/tmp}/review-<slug>.XXXXXX.md")"
printf '%s' "$REVIEW_BODY" > "$f"
~/.config/opencode/scripts/persona-post.sh <slug> <owner/repo> pr-review <PR> "$f" <APPROVE|REQUEST_CHANGES|COMMENT>
```
`pr-review` files a **real GitHub PR review** — map the verdict protocol's
`APPROVE | CHANGES_REQUESTED` straight onto the script's event argument (`APPROVE` /
`REQUEST_CHANGES`; use `COMMENT` when genuinely undecided, per each persona's brief —
see the note on `COMMENT` under **Verdict protocol** below, since it does not add a
third VERDICT outcome). The plain-body form above, with the `- [severity] file:line —
finding` bullets the verdict protocol already requires, satisfies each persona brief's
review-format intent for most findings; reach for a JSON payload instead
(`{"body": "...", "event": "...", "comments": [...]}`, filename ending `.json`) only
when a finding needs true GitHub line-anchoring in the PR's Files tab — the script
sends a `.json` file to the Reviews API verbatim.

**Verify the post landed — do not trust the exit code alone.** `persona-post.sh` can
swallow a failure without a clean non-zero exit (e.g. the App isn't installed on this
repo → the installation-token exchange or the Reviews API answers with a 404/422 that
a thin wrapper may not propagate). After each call, confirm the review actually exists —
`gh api repos/<owner>/<repo>/pulls/<PR>/reviews --jq '.[-1].id,.[-1].user.login'` (or
the GitHub MCP's `pull_request_read`) — and check the returned `user.login` matches the
expected `mm-*` identity. Anything else (non-zero exit, no matching review, or a review
posted under the wrong identity) counts as a failure for that persona and takes the
fallback path below.

**Fallback (script absent, that repo has no `mm-*` Apps installed, 1Password locked, no
`op` access, the script exits non-zero, or verification above doesn't find a matching
review): fail closed — never post under the calling session's own identity.** The
calling session's own GitHub credentials authored, merged, or (via a Head Imp fix-loop)
directly amended the diff under review; posting that persona's verdict under the calling
session's identity when its dedicated App is unavailable would silently collapse
"independent review" back into the session reviewing its own work — exactly the failure
this identity separation exists to prevent, and worse, doing so with no separate human
decision in the loop. Instead: record that persona's full VERDICT block in the caller's
own findings/result record, tagged `posting: failed — dedicated App unavailable, not
posted`, for the operator to read directly or post by hand if they choose. One persona's
script failure never fails the whole panel — every other persona still posts normally
through its own App; only the failed persona's verdict moves from "posted" to "inline,
unposted."

**Verdict protocol (both modes — reviews and comments):** every persona review ends:

```
VERDICT: APPROVE | CHANGES_REQUESTED @ <sha>
- [blocker|major|minor|nit] <file:line if applicable> — <finding>
```

CHANGES_REQUESTED requires ≥1 `blocker` or `major`. Minors and nits are recorded
but never block. A `COMMENT`-event review (posted only when genuinely undecided) still
resolves to `VERDICT: APPROVE` when no blocker/major is present — `COMMENT` is a
posting nuance on *how* the review lands, not a third VERDICT outcome; the protocol
stays two-valued. The caller always parses VERDICT lines from the posted body and keeps
its own tally — **this is the sole source of truth, not GitHub's aggregate review-state
field.** That field is absent entirely on the comment-only fallback path, and even where
a real review exists it collapses `APPROVE`/`COMMENT` into a distinction (`APPROVED` vs.
`COMMENTED`) that VERDICT-line parsing already resolves unambiguously. Never assume every
persona used the real-review path just because some did — read each persona's own posted
body for its VERDICT line rather than inferring panel-wide status from the PR's
review-state summary.
