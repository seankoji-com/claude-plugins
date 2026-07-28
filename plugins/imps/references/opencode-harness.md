# opencode execute-tier harness (v1)

Keep judgment work on Claude; offload *mechanical* implementation to `opencode`
running cheap open models, each task in an isolated git worktree under an OS-level
sandbox.

v1 is **harness + measurement only**. Nothing here changes `/imps`. These are
hand-invocable scripts; whether `/imps:go` ever gets built is decided by the
numbers from the measurement protocol at the bottom of this file.

> **Scope: maintainers working inside the `claude-plugins` checkout.** Every
> command and permission rule below is written repo-relative
> (`plugins/imps/scripts/…`) and only resolves from the repo root. From an
> *installed* plugin the same files live under `${CLAUDE_PLUGIN_ROOT}` — substitute
> that prefix in both the commands and the `permissions.allow` entries, or they
> will not resolve and the rules will never match.

The load-bearing idea is the **oracle**: a cheap model is good at grinding
iterations against a hard pass/fail signal and bad at knowing when to stop. Every
offloaded task carries a machine-checkable acceptance command; the harness loops
the model against it and gives up after N attempts rather than trusting
self-report. The commit is made by the harness, never by the model.

---

## Pieces

| File | Role |
| --- | --- |
| `${CLAUDE_PLUGIN_ROOT}/scripts/opencode-dispatch.sh` | one task: sandboxed model run → oracle loop → deterministic commit → JSON contract line |
| `${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-wrap.sh` | the only place that talks to a sandbox backend |
| `${CLAUDE_PLUGIN_ROOT}/scripts/sandbox-smoke.sh` | free assertions that the wrapper actually contains what it claims |
| `${CLAUDE_PLUGIN_ROOT}/sandbox/deny-credentials.sbpl.in` | terminal Seatbelt denies, appended after the backend's own rules |
| `${CLAUDE_PLUGIN_ROOT}/templates/opencode.sandbox.json` | hardened worktree-level opencode config |
| `${CLAUDE_PLUGIN_ROOT}/tests/e2e.sh` + `tests/fixtures/fx-*` | live end-to-end proof (costs a few cents, opt-in) |

## Prerequisites

- **macOS.** The backend is Seatbelt via `agent-safehouse`. Every test skips
  cleanly on Linux, which is what keeps `ubuntu-latest` CI green.
- **`agent-safehouse`** (`brew install agent-safehouse`). The binary is called
  **`safehouse`**, not `agent-safehouse`, and on a Homebrew install it is **not on
  `$PATH`** — it lives at `$(brew --prefix)/opt/agent-safehouse/bin/safehouse`.
  `sandbox-wrap.sh` probes `$PATH` first and then the Homebrew keg path; override
  with `IMPS_SAFEHOUSE_BIN`.
- **`opencode`** on `$PATH`, authenticated (`~/.local/share/opencode/auth.json`).
- **`jq`**, **`git`**.

Check the backend without running anything:

```bash
bash plugins/imps/scripts/sandbox-wrap.sh --check   # exit 0 = usable, 2 = not
```

## Running it

```bash
bash plugins/imps/scripts/opencode-dispatch.sh \
  --worktree        /abs/path/to/worktree \
  --prompt-file     /abs/path/to/task-prompt.md \
  --oracle          'python3 -m pytest tests/test_thing.py -q' \
  --model           opencode-go/qwen3.7-max \
  --max-attempts    3 \
  --attempt-timeout 300 \
  --oracle-timeout  120 \
  --oracle-guard    'tests/test_thing.py' \
  --expect-oracle   red \
  --result-branch   imps/opencode/thing-fix
```

`--attempt-timeout`/`--oracle-timeout` (seconds, default 300/120) bound the
model run and the oracle run respectively — without them a stalled provider or
a hung test suite blocks forever with no contract line at all until someone
notices and kills the process. **`--attempt-timeout` is a terminal abort of the
whole dispatch, not just of one attempt:** a killed attempt (`rc 124`) reports
`abort_reason:"attempt_timeout"` and the dispatch stops there — the oracle
never runs afterward, and the loop never retries, because the killed attempt's
truncated edits stay in the worktree and would otherwise ship if a later
attempt happened to go green. `--oracle-guard` (optional pathspec, e.g. a
test file) checks whether the model's own edits touched it; see
`oracle_files_modified` below.

`--expect-oracle red|green|any` (default `any`) runs the oracle once, inside
the sandbox, before the first model attempt, and classifies the starting state
as `oracle_start_state:"red"|"green"`. `red`/`green` additionally require that
classification to match, aborting `oracle_preflight_mismatch` before a model
attempt is spent if it doesn't. The preflight runs unconditionally, even under
the default `any` — recording the starting state is the point, not only the
gate. Cost: one extra oracle run per dispatch — time, not model spend.

`--result-branch <name>` additionally publishes the dispatch's commit at
`refs/heads/<name>`, on top of the unconditional `refs/imps/dispatch/*` ref
every successful commit now writes regardless of whether this flag is passed
at all — a dispatch commit is durable whether or not you ever pass
`--result-branch`. List or prune the auto-refs by hand:

```bash
git for-each-ref 'refs/imps/dispatch/*'
git update-ref -d refs/imps/dispatch/<ts>-<sha>   # prune one
```

They live outside `refs/heads/`, so they stay out of `git branch` and out of
ordinary branch-pruning tools — nothing removes them automatically.

The **final line of stdout is always** exactly one JSON object, on every exit
path — success, oracle exhaustion, failed preflight, rejected model:

```json
{"status":"pass","attempts":2,"session_id":"ses_…","cost_usd":0.0087,
 "oracle_exit":0,"log_path":"/abs/path.jsonl","abort_reason":null,
 "oracle_files_modified":null,"commit_sha":"a1b2c3d…",
 "oracle_start_state":"red"}
```

`session_id`, `cost_usd`, `oracle_exit`, `log_path`, `oracle_files_modified`,
`commit_sha` and `oracle_start_state` are nullable. `oracle_files_modified` is
a JSON array of paths (or `null`) — non-null means the model's own edits
touched a file matching `--oracle-guard`. This is fail-closed by construction,
not by reader diligence: a guard hit is reported as `status:"fail"` with
`abort_reason:"oracle_guard_violated"`, never as a tainted `"pass"` a naive
`jq -r .status` consumer would miscount as genuine. `commit_sha` is the
harness's own commit, populated once a commit exists — including on
`abort_reason:"result_ref_failed"`, which reports `status:"fail"` precisely
because a commit landed but its durable ref did not; that is how an operator
recovers work that committed but never got a ref. `oracle_start_state` is the
preflight's `"red"`/`"green"` classification of the worktree before the model
ever runs, or `null` only when the preflight itself had no verdict to give
(timeout or sandbox failure) — never fabricated as a guess. `abort_reason` is
`null` on normal paths (including a clean oracle exhaustion), else one of
`preflight_smoke_failed`, `model_rejected`, `config_missing`, `bad_arguments`,
`auth_missing`, `opencode_missing`, `sandbox_bypass_refused`,
`dispatch_dir_failed`, `log_path_failed`, `jq_missing`, `unexpected_exit`,
`oracle_timeout`, `oracle_sandbox_failed`, `commit_failed`, `worktree_dirty`,
`oracle_guard_violated`, `gitmeta_tampered`, `commit_lineage_invalid`,
`attempt_timeout`, `oracle_preflight_mismatch`, `no_model_changes`,
`result_ref_failed`. Exit code is still non-zero on failure. All progress goes
to stderr.

**`status:"pass"` alone is not the composite pass invariant** — see "the
oracle is not fully tamper-proof" below. A consumer that only checks `status`
can still be looking at an oracle-green result with no red→green transition
proving the task was actually implemented, or one that gamed the oracle; read
`oracle_start_state` and the rest of that invariant before trusting a pass.

`log_path` lives under the dispatch dir, never in the worktree: the harness
runs `git add -A`, so an event-stream log written inside would be committed and
the "a commit exists" assertion would still pass — with a multi-MB JSONL in the
diff.

Read `--help` by reading the script; `commands/*.md` and `scripts/*.sh` are the
source of truth, this file only describes them.

## Model guard

Only `opencode-go/*` and `opencode/*` are accepted, and the **whole** model
string is then re-checked for `claude`/`anthropic` as a *substring*. A prefix-only
check is defeated by `--model openrouter/anthropic/claude-sonnet-4`, which would
bill a Claude model through opencode — the exact anti-goal of this tier.

Defaults worth knowing: `opencode-go/qwen3.7-max` is the working default,
`opencode-go/deepseek-v4-flash` is the cost floor (and what `e2e.sh` uses).

---

## The sandbox

`sandbox-wrap.sh --worktree <dir> --gitmeta <dir> --datadir <dir> -- <cmd>`
applies the sandbox and `exec`s the command; its exit status passes through
unaltered.

| | |
| --- | --- |
| read/write | the worktree, the gitmeta dir (minus hooks/config — see below), the dispatch data dir, `/dev/null` |
| read-only | the backend's default system roots, plus `~/.gitconfig`, `~/.gitignore_global`, `~/.opencode/bin` |
| denied | everything else — explicitly `~/.local/share/opencode`, `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.claude/.credentials.json`, and `<gitmeta>/hooks`, `<gitmeta>/config`, `<gitmeta>/config.worktree`, `<gitmeta>/info/exclude` |
| network | allowed (the model API is remote) |

**No wholesale `$TMPDIR` grant.** Earlier versions granted `$TMPDIR` broadly so the
dispatch log and the rendered deny-profile had somewhere to live — but neither
actually needed sandbox access at all (both are written by processes *outside*
the sandbox boundary), and the real reason a sandboxed model needs some writable
tmp path is its own runtime scratch usage (Bun/opencode internals). `opencode-dispatch.sh`
now overrides its own `TMPDIR` to a subdirectory of the dispatch data dir before
invoking the sandbox, so that scratch usage stays inside the already-granted
`--datadir` path — a sandboxed process can no longer read or write every other
process's temp files on the host.

Two things that look like details and are not:

- **`--add-dirs-ro "$HOME/.gitconfig:$HOME/.gitignore_global"` is mandatory.**
  Without it `git status`/`git commit` fail outright with
  `fatal: unable to access '<home>/.gitconfig': Operation not permitted`.
  safehouse does not grant the user's global git config by default, and git needs
  it even for a purely local operation.
- **`/dev/null` write access is mandatory** or git dies in obscure ways.

**Never pass `--enable=wide-read`.** safehouse is deny-by-default and `wide-read`
is an opt-in its own help text flags as dangerous: it grants read across `/`,
which would hand a cheap `--auto` model with network egress every credential on
the machine.

`SANDBOX_MODE` selects the backend: `safehouse` (default) or `sbpl`. **`sbpl` is
reserved but not implemented in v1** — selecting it exits 2 rather than silently
degrading. Stage 0 verified safehouse live against this exact configuration, so
shipping a hand-written Seatbelt profile nothing had ever exercised would be worse
than shipping none: a profile that is quietly too permissive still "works".

There is deliberately **no `none` mode on the flag surface.** The harness runs
behind a Claude Code permission entry that already disables Claude Code's own Bash
sandbox, so an unsandboxed run would have no boundary at any layer. The debug
bypass requires `IMPS_SANDBOX_DANGEROUSLY_DISABLE=i-accept-full-privilege`, and
`opencode-dispatch.sh` refuses to run at all when that variable is set.

### The git common dir is not fully writable — this is the boundary that matters most

`opencode-dispatch.sh`'s own commit runs **outside** the sandbox (see "The commit
is deliberately unsigned" below) — deliberately, since it needs to run after the
sandboxed model has finished editing. For a real dispatch (a linked worktree,
which is how this harness is actually used), the gitmeta dir granted to the
sandbox is the *shared* git common directory — the same one the main checkout and
every other worktree of that repo use.

Put those two facts together and a model with write access to gitmeta the
straightforward way (needed for its own sandboxed `git add`/`git status`/index
operations to work at all) could write `hooks/post-commit` or set
`core.fsmonitor` in `config`, and have that script executed at full, unsandboxed
operator privilege the moment the harness's own commit runs — reaching
`~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.claude/.credentials.json`, and the
1Password agent socket: everything `deny-credentials.sbpl.in` exists to deny,
reached by a completely different path. **This was found independently by two
reviewers during review, one of whom reproduced it as a working exploit** against
a real linked worktree using exactly the flags the shipped code used at the time.

Mitigated two ways at first — `deny-credentials.sbpl.in` denying writes to
`<gitmeta>/hooks`, `<gitmeta>/config`, `<gitmeta>/config.worktree` and
`<gitmeta>/info/exclude`, plus `-c core.hooksPath=/dev/null --no-verify` on the
harness's own commit — but **that combination was itself an overclaim**: it
guards the *static* config/hooks locations, not the *pointer* files git
actually follows to find them. The worktree's own `.git` file is a plain-text
redirect (`gitdir: <path>`) and is necessarily writable — it lives inside the
granted worktree, not gitmeta. A model can rewrite it to point at a
model-created fake gitdir, also inside the worktree, with its own `config`
setting `core.fsmonitor` (or a `.gitattributes` clean/smudge filter) to an
arbitrary command. `<gitmeta>/worktrees/<name>/commondir` is the other half of
the same redirect chain and was likewise left writable. A third reviewer
reproduced this as a working exploit against the "fixed" code, including the
harness's own commit landing as a **root commit in the fake gitdir** —
`status:"pass"` and all, while the real repo never received the work.

Actually closed by verifying the pointer files themselves haven't moved,
rather than trying to enumerate every config surface they could redirect to:

1. `opencode-dispatch.sh` snapshots `$WT/.git` and (for a linked worktree) the
   per-worktree gitdir's `commondir`, `gitdir`, and `HEAD` files *before* the
   model ever runs (`GITMETA_POINTER_BASELINE`, hashed with `shasum -a 256` —
   `cksum` is CRC32 and forgeable by a model that can read the pointer files
   and run `cksum` itself inside the sandbox), and refuses to commit —
   `abort_reason:"gitmeta_tampered"` — if any byte of any of them differs
   afterward. This is the check that actually decides whether the boundary
   holds; everything else here is defense in depth around it. Ordering
   matters: this comparison runs before *any* other unsandboxed git command
   touches the worktree, including the `--oracle-guard` diff — an earlier cut
   ran the guard diff first, and a redirected `$WT/.git` got its fake
   `core.fsmonitor` hook executed at operator privilege by that diff, one
   statement before the snapshot check that would have caught it.
2. `deny-credentials.sbpl.in` still denies writes to `<gitmeta>/hooks`,
   `<gitmeta>/config`, `<gitmeta>/config.worktree` and `<gitmeta>/info/exclude`
   directly — the rest of gitmeta (index, objects, refs) stays writable, so
   legitimate sandboxed git operations are unaffected. `sandbox-smoke.sh`'s
   `gitmeta-hooks-write-denied` and `gitmeta-config-write-denied` assertions
   keep this verified, not just asserted in prose.
3. The harness's own (unsandboxed) `git add`/`commit` add both
   `-c core.hooksPath=/dev/null --no-verify` and `-c core.fsmonitor=false` —
   defense in depth in case a hook or fsmonitor setting exists for a reason
   unrelated to this attack (pre-existing in the target repo, not
   model-planted); it must not fire from a script whose whole point is
   running untrusted model output.
4. After a successful commit, `git merge-base --is-ancestor "$BASE_SHA" HEAD`
   confirms the new commit actually descends from the pre-dispatch HEAD —
   catching a root commit in a redirected gitdir even if the byte-snapshot
   above somehow missed the redirect.

### Seatbelt does not nest

Running `sandbox-smoke.sh` from inside another sandbox (Claude Code's own Bash
sandbox, most obviously) makes every wrapped call fail with
`sandbox_apply: Operation not permitted` — which says nothing about this profile.
The script detects that with a nesting probe and exits **77** ("cannot run here"),
which `tests/run.sh` renders as a `skip` line rather than a pass or a failure.
Run it unsandboxed to get a real result.

### Credential isolation

Both halves are required. Redirecting writes alone does not help, because the real
`auth.json` stays readable and the sandbox has network egress.

1. **All four `XDG_*` dirs are redirected** to per-dispatch directories under
   `$TMPDIR`, and only `auth.json` is copied into the redirected data dir:

   ```
   XDG_DATA_HOME=<dispatch>/data     XDG_STATE_HOME=<dispatch>/state
   XDG_CONFIG_HOME=<dispatch>/config XDG_CACHE_HOME=<dispatch>/cache
   ```

   Redirecting only `XDG_DATA_HOME` is not enough: opencode 1.18.4 also uses
   `XDG_STATE_HOME` and `XDG_CACHE_HOME` at boot, and attempts a **write** to
   `XDG_CONFIG_HOME` even when the directory already exists — an unredirected boot
   fails outright with `EEXIST … mkdir '<home>/.config/opencode'`. A fully cold
   boot works once all four are redirected together. The dispatch dir persists
   across attempts within one dispatch so `--session` resumption works, and is
   deleted on exit (it holds a copy of `auth.json`); keep it with
   `IMPS_KEEP_DISPATCH_DIR=1` when debugging.
2. **The originals are denied** by `sandbox/deny-credentials.sbpl.in`, appended
   via `--append-profile`. safehouse emits appended profiles *after* its generated
   rules and Seatbelt is last-match-wins, so a trailing deny is authoritative.

`sandbox-smoke.sh`'s `gh-config-denied` assertion is the load-bearing one behind
this claim — safehouse grants `~/.config/gh` by default, so it is the only probe
that actually exercises the `--append-profile` override (the others are already
denied by safehouse's own defaults and would stay green even if the override
silently broke). The script creates a placeholder `~/.config/gh` when one is
absent, specifically so this assertion is never silently skipped on a host that
happens not to have `gh` installed — exactly the host where a regression here
would otherwise go undetected. It never touches a real `~/.config/gh`.

**Bonus, discovered rather than designed:** redirecting `XDG_CONFIG_HOME` means the
real `~/.config/opencode/opencode.json` is never found or merged, so the
worktree-level `opencode.json` installed from `templates/opencode.sandbox.json` is
the sandbox's **only** effective opencode config. The dispatcher's
`jq -e '.permission.external_directory == "deny"'` assertion therefore checks
exactly what governs the run, with no merge ambiguity. It asserts *content*, not
presence: `--auto` with a default `external_directory: "ask"` runs silently
uncontained.

### Sandbox choice — evaluation evidence

Run live on this machine on 2026-07-25, unsandboxed, with real spend.
**Verdict: safehouse passes every criterion; it is the chosen backend and v1
needs no SBPL fallback.**

| Criterion | Result |
| --- | --- |
| write inside worktree allowed | pass — `--workdir` auto-grants it |
| `touch ~/.sbprobe` | pass — denied (`Operation not permitted`, exit 1) |
| `git status` / `git commit` in a real worktree | pass — once `--add-dirs-ro "$HOME/.gitconfig:$HOME/.gitignore_global"` is granted (undocumented default gap) |
| `cat ~/.local/share/opencode/auth.json` | pass — denied by default; no grant needed |
| `cat ~/.config/gh/...` | **readable by default** — safehouse grants this out of the box for generic coding-agent use (`gh` PR automation). Not appropriate here; explicitly denied via the terminal `--append-profile`. Confirmed the deny overrides the default grant (`ls ~/.config/gh` exit 0 without it, exit 2 with it). |
| opencode boots + reaches the Go API, cold `XDG_DATA_HOME` | pass — once **all four** `XDG_*` vars are redirected together; a partial redirect fails boot outright |
| redirected data dir read/write | pass |
| **live end-to-end `opencode run`** | pass — `opencode-go/deepseek-v4-flash` replied to a real prompt; JSON event stream parsed, `cost: $0.00118608` |

Two non-default grants safehouse needs beyond its own baseline: `--add-dirs-ro` for
`.gitconfig`/`.gitignore_global`, and `--env-pass TERM` (safehouse sanitizes the
environment by default, and Bun's own crash paths get confusing without `TERM`).
One default grant that must be *removed* for this use case: `~/.config/gh` read
access. `~/.ssh` and `~/.config/gh` are safehouse defaults tuned for general
coding agents and are deliberately overridden here.

### Two traps worth naming

- **Output redirection must land inside a granted path.** `$TMPDIR` qualifies; an
  unrelated tmp-like path does not. Redirecting the wrapped process's stdout or
  stderr outside every granted directory produces an `fstat: EPERM` on the
  inherited fd, which cascades into a misleading crash deep in opencode's bundled
  npm internals (`TypeError: undefined is not an object (evaluating
  'process.stderr.isTTY')`). It looks like an opencode/safehouse incompatibility
  and is not.
- **A `mkcert rootCA.pem` warning on stderr is expected and harmless** — a system
  TLS cert probe unrelated to opencode. Not a failure.

### The commit is deliberately unsigned

```sh
git -C "$WT" -c core.fsmonitor=false add -A -- ':(exclude)opencode.json'
git -C "$WT" -c user.name=imps-opencode -c user.email=imps@local \
    -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    commit -q -m "opencode: <prompt> (attempt N)" --no-gpg-sign --no-verify
```

This operator's global `~/.gitconfig` signs commits via an SSH key served by the
1Password desktop-app agent, which is — correctly — unreachable from inside the
sandbox. Granting it would mean handing a cheap `--auto` model live signing
credentials, defeating the isolation entirely. The `-c` flags are the
defense-in-depth half of the gitmeta-pointer fix above — see that section for
why hooks/fsmonitor must not fire from this specific commit, and for the
byte-snapshot check that's actually load-bearing rather than these flags.

This is a **narrow, deliberate exception, not a general precedent**: a synthetic
bot commit in an ephemeral, throwaway worktree, not final shared history. Any real
promotion of this work into a shared branch goes through the normal reviewed,
signed flow (out of v1 scope).

Commit failure is **not** silently treated as success: if `git commit` fails for
any reason (nothing staged, disk full), the dispatch reports `status:"fail"` with
`abort_reason:"commit_failed"` rather than a phantom `"pass"` — an oracle that
went green with no surviving commit is not distinguishable from a broken harness
any other way.

### Known limitation: the oracle is not fully tamper-proof

The model can edit anything in the worktree, including the file(s) the oracle
depends on. The retry prompt tells it not to, and the fixtures are trivial enough
that gaming them is more work than solving them, but v1 does not *enforce* this
by default — it makes it **visible**: pass `--oracle-guard <pathspec>` (the
fixtures pass `'*test*'`) and a model edit that touches a guarded file surfaces as
a non-null `oracle_files_modified` in the contract, distinct from a genuine pass,
instead of being indistinguishable from one. Still not enforcement — read the
diff before promoting anything — but the measurement protocol below can now tell
the two apart instead of silently counting a gamed pass as a real one.

**The composite pass invariant.** A result is trustworthy only if *all* of the
following hold: the preflight classified the start as red
(`oracle_start_state:"red"`) · the attempt was not killed
(`abort_reason != "attempt_timeout"`) · the model staged something
(`abort_reason != "no_model_changes"`) · the oracle went green at the end
(`status:"pass"`) · the commit descends from the pre-dispatch `BASE_SHA`
(enforced by the `merge-base --is-ancestor` check before any ref is written) ·
a durable ref exists (`abort_reason != "result_ref_failed"`). Every one of the
measurement round's false passes below fails at least one clause — task 1
fails the model-staged-something clause (caught, at the time, by
`commit_failed`; under this invariant `no_model_changes`/`--expect-oracle`
would catch the same thing earlier, and the attempt-timeout clause would in
fact abort that dispatch first); task 3, a pure refactor against an
already-passing suite, fails the red-start clause; task 4's counted attempt
was killed by the attempt timeout and fails the not-killed clause. This is the
concrete answer to this section's own "read the diff before promoting
anything": it closes every *structural* false-pass this round found,
mechanically and for free. It does **not** close a *semantic* one — no
clause here inspects what the change actually says, only whether the
mechanics ran cleanly, so a result that clears every clause above (as a
green-suite task like task 3 legitimately can, or as task 4's dispatch would
have if its attempt hadn't happened to hit the timeout) can still be wrong the
way tasks 3 and 4 were: silently deleted comments, a silently weakened guard.
Diff review is still required before promoting anything; the invariant
narrows what diff review has to catch, it does not replace it.

**Apparent contradiction, resolved:** `--expect-oracle green` exists for
pure-refactor tasks (confirming the worktree is already green before letting a
model touch it), and such a dispatch can *never* satisfy the composite
invariant's red-start clause — that is expected, not a bug, since a refactor
task isn't making the red-to-green claim the invariant certifies. The default
`any` doesn't enforce the red-start clause either. So `status:"pass"` alone —
even `abort_reason == null` — never tells you whether a result meets the
composite invariant; a consumer must also read `oracle_start_state`.

**Remaining contaminant, not closed by any of the above:** the *in-loop*
oracle's own byproducts (e.g. `__pycache__/`, `.pytest_cache/`) still enter the
harness's `git add -A` on the attempt that produces the final commit.
Restore-to-clean before the model runs neutralises only the pre-model half of
this; a `pytest`-style oracle can still carry incidental build artifacts into
the commit, and — because that commit is now durable and gets merged onward —
into a shared branch. Read the diff before promoting.

### Known limitation: the bash denylist is a typo-guard, not egress control

`templates/opencode.sandbox.json`'s bash denylist (`rm -rf *`, `git push *`, `sudo *`,
`curl *` denied, everything else allowed) only blocks opencode's own permission layer —
it does nothing at the OS level. `/usr/bin/curl`, `wget`, `nc`, or
`python3 -c 'import urllib...'` all match the wildcard allow and run fine, and the
sandbox grants network egress by design. Egress is unrestricted in v1 — the denylist
exists to stop an *accidental* `rm -rf *`/`git push`, not a deliberate one.

### Known limitation: OpenCode Go's own rate limit surfaces as a generic error

Live-verified 2026-07-27: hitting OpenCode Go's 5-hour usage cap mid-dispatch does
**not** produce a distinct `abort_reason` — every attempt fails instantly with
`opencode exited 1` and stderr `error: An unknown error occurred (Unexpected)`,
indistinguishable at that layer from a real opencode/sandbox fault. The actual
cause (`AI_APICallError: 5-hour usage limit reached. Resets in <N>`) only surfaces
by running `opencode run` **unsandboxed**, directly, with `--print-logs --log-level
DEBUG` — the sandboxed path swallows it. If a dispatch fails instantly on every
attempt with this exact message and no `log_path` content, check the account's
usage window (`https://opencode.ai/workspace/<id>/go`) before assuming the harness
or the target repo is at fault — it cost real diagnosis time to tell the two apart
during this measurement round. Not fixed in v1: the contract's `abort_reason` enum
has no `rate_limited` value yet.

### Known limitation: `run_with_timeout`'s stdout can make opencode crash on startup, and the crash is indistinguishable from a real oracle failure

Live-verified 2026-07-27: every dispatch through the real `opencode-dispatch.sh`
path (9+ attempts across two separate dispatch runs, including a trivial
zero-edit task with `--oracle 'true'`) failed with an identical Bun crash at
opencode startup, **before the model ever sees the task prompt**:

```
error: EPERM: operation not permitted, fstat
      at new WriteStream (internal:fs/streams:244:58)
      at refresh (internal:util/colors:18:39)
      ...
TypeError: undefined is not an object (evaluating 'process.stderr.isTTY')
```

The proximate cause: `opencode run --dir "$WT" --model "$MODEL" --format json
--auto` is invoked as `run_with_timeout "$ATTEMPT_TIMEOUT" run_sandboxed_direct
"${oc_args[@]}" | tee -a "$LOG_PATH" >&2` (line ~678) — the pipe to `tee` is
established *before* `run_with_timeout` backgrounds the command, so the
sandboxed opencode process's stdout is the write end of a pipe inherited
across a `set -m` + `&` + `sandbox-exec` exec boundary. Something in that
specific fd's lineage makes Bun's internal color-detection code (triggered
while lazily formatting an unrelated assertion error from opencode's own
startup, itself still unexplained) hit an `fstat` Seatbelt denies.

**This is not the rate-limit gap above** — different signature, and
unsandboxed `opencode run` with the same model/account works fine throughout
(ruling out account-level causes). It is also not deterministic: 4/4 direct
`sandbox-wrap.sh` + `opencode` invocations (same XDG/env setup, stdout piped
through plain `| tail`, no `run_with_timeout`) succeeded cleanly in the same
session, immediately after 5 consecutive real-dispatch failures. Sequential
vs. concurrent dispatch was tested and ruled out as the differentiator — a
lone dispatch failed 5/5 attempts. `--print-logs --log-level DEBUG` does not
prevent it either (tested, still crashed). `NO_COLOR`/`CI`/`FORCE_COLOR`
cannot be tested from the caller at all: `sandbox-wrap.sh`'s `ENV_PASS`
(line ~301) only forwards `TERM`, `TMPDIR`, and the four `XDG_*` vars, so
those three never reach the sandboxed process regardless of what the caller
exports.

**Consequence for the measurement protocol:** the harness reports this as an
ordinary oracle failure — `oracle_exit=1`, `abort_reason: null` — identical in
shape to a genuine model failure. Same measurement-poisoning risk as the
rate-limit gap above, different root cause. As of this writing the harness
**cannot be trusted to complete a real dispatch on demand**; not fixed in v1.



## The Claude Code permission entry

The dispatcher must run **outside** Claude Code's own Bash sandbox (Seatbelt does
not nest), which means a `Bash` call with `dangerouslyDisableSandbox: true`. That
goes through the permission gate.

The grant lives in **`.claude/settings.local.json`**, which is **git-ignored**, not
in a tracked `settings.json`. A committed sandbox-off grant in a public marketplace
repo would be inherited by every contributor and agent session that clones it.

Add these entries verbatim, merging into any existing `permissions.allow` array:

```json
{
  "permissions": {
    "allow": [
      "Bash(bash plugins/imps/scripts/sandbox-smoke.sh)",
      "Bash(bash plugins/imps/scripts/opencode-dispatch.sh *)",
      "Bash(bash plugins/imps/tests/e2e.sh)",
      "Bash(bash plugins/imps/tests/e2e.sh *)"
    ]
  }
}
```

Narrow prefix rules only — never an over-broad `Bash(*)`.

`sandbox.allowUnsandboxedCommands` is the **policy-level prerequisite**: it
defaults to `true`, but when it is `false` (typically from managed settings) the
`dangerouslyDisableSandbox` parameter is ignored entirely and no permission rule
can re-enable it. If your org sets it false, this harness cannot run.

The repo's own `.gitignore` lists `.claude/settings.local.json`. Before that rule
existed the path was ignored only by a machine-local `~/.gitignore_global`, so on
any other clone a routine `git add -A` would have committed the grant. Confirm the
repo rule — not the global one — is the one taking effect:

```bash
git check-ignore -v --no-index .claude/settings.local.json | grep -q '^\.gitignore:'
```

---

## Tests

```bash
bash plugins/imps/scripts/sandbox-smoke.sh          # free; any Mac; run UNSANDBOXED
IMPS_OPENCODE_E2E=1 bash plugins/imps/tests/e2e.sh  # real opencode calls, a few cents
```

Both are wired into `tests/run.sh`. The E2E skips unless **all four** hold:
`uname -s` is `Darwin` · `opencode` on `$PATH` · `~/.local/share/opencode/auth.json`
exists · `IMPS_OPENCODE_E2E=1`. The first keeps `ubuntu-latest` green; the fourth
stops a maintainer on a Mac from being silently billed by a plain `tests/run.sh`.
A skip prints `skip <name>: <reason>` and stays outside the pass/fail counters — a
never-run E2E must never be counted as a pass.

Fixtures live in `plugins/imps/tests/fixtures/fx-*/`: a tiny broken function, a
test that is its own oracle, `fx-prompt.md`, and `fx-oracle` (the acceptance
command). Pick one with `bash plugins/imps/tests/e2e.sh fx-slugify`.

Two CI traps if you add fixtures:

- Every tracked `plugins/**/*.sh` and `*.py` must be mode `100755` and every `.sh`
  must be `shellcheck --severity=warning` clean — fixtures included. Deliberately
  *broken* content must use a non-executable extension (`.txt`, `.bash.in`); the
  shipped fixtures are wrong-but-valid instead.
- The bundled-asset leak check builds its basename set from every file under a
  plugin's non-`commands` dirs, so a fixture named `settings.*`, `learnings.*`,
  `runs.*`, `workflows.*` or `projects.*` would red CI by matching a `~/.claude/…`
  path in an unrelated plugin's command file. **Prefix every fixture `fx-`/`fx_`.**

---

## Measurement protocol (the actual point of v1)

Route **at least 5 real mechanical tasks** by hand — no `/imps` integration.
Good candidates: a failing test to make pass, a mechanical refactor with an
existing test suite, a lint-clean-up with a linter as the oracle.

For each: `opencode-go/qwen3.7-max` unless cost matters, in which case
`opencode-go/deepseek-v4-flash`. Record from the contract line and from
`~/.claude/audit.jsonl` (`tier: "opencode"`, `attempts`).

**`~/.claude/audit.jsonl` is the real measurement log — never redirect it for a
real hand-routed task.** `e2e.sh` does redirect it (`AUDIT_LOG_FILE=<scratch>`),
specifically so fixture runs never land here: they are deliberately trivial and
pass first-try, and would inflate the first-pass rate this protocol exists to
measure honestly. If you ever need to test the harness itself against a real
task-shaped prompt without it counting toward the go/no-go number, redirect
`AUDIT_LOG_FILE` the same way.

**Definition: `pass` means verified-correct, not oracle-green.** This round's
own findings (below) are why: two of its three oracle-green results were
wrong on human diff review. Diff review is folded into the criterion itself,
not appended as a footnote afterward — a task counts as a pass only if the
oracle went green **and** a diff review confirms the change is behaviorally
and semantically correct, not merely that the oracle accepted it.
`audit.jsonl`/the contract's `status:"pass"` records the oracle's own verdict
only; the table's "First-pass?" column and prose below distinguish
oracle-pass from verified-pass explicitly wherever they differ.

| # | Task | Model | First-pass? | Attempts | Cost (USD) | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Replace hand-rolled `.gitignore`-scope `case` matching in `opencode-dispatch.sh`'s `--oracle-guard` handling with `git check-ignore` (issue #98 item 2) | `opencode-go/qwen3.7-max` | No | 1 | 0.028324 | Model never edited the target file — spent the full 300s attempt-timeout reading an unrelated file, then the attempt timed out. Oracle trivially passed (nothing changed, so nothing regressed), but the harness's `commit_failed` path correctly refused to count it: nothing was staged, so nothing was committed. A pure-refactor oracle can't itself distinguish "did nothing" from "refactored correctly" — this is exactly why the harness treats an oracle-pass-with-no-commit as a fail rather than trusting the oracle alone. → resolved going forward by `no_model_changes`/`--expect-oracle`: the stage-emptiness check now catches this before commit is even attempted, independent of the `commit_failed` path that caught it here (and the terminal `attempt_timeout` would abort this exact dispatch even earlier). |
| 2 | Move `run_with_timeout_probe` + its `__SOURCED__` test-only guard out of `opencode-dispatch.sh` into a new sourced helper file (issue #98 item 4) | `opencode-go/qwen3.7-max` | Yes | 1 | 0.020679875 | Genuine first-pass: model ran `tests/run.sh` itself mid-turn, saw 4 failures, diagnosed a real bash nested-`source`/`return` subtlety the task prompt hadn't spelled out (the guard has to exist in both the new helper file and the still-sourcing production script), fixed it, and reran clean before the harness's own oracle check ran. |
| 3 | Consolidate the six inline `REAL_GITDIR` transformations in `sandbox-wrap.sh` into one `resolve_and_validate_gitdir()` function (issue #98 item 3) | `opencode-go/qwen3.7-max` | Yes | 1 | 0.011696875 | Oracle passed and a human diff review confirms the refactor is behaviorally faithful — the load-bearing collapse-before-fail-closed step ordering (a previously live-verified bug fix) is preserved exactly, as are every `die` message and the fallback's `core.fsmonitor=false` scrub. **But:** the model silently deleted every explanatory comment in the block — the same security-rationale prose issue #98 item 1 says has already prevented one regression from recurring. The oracle has no way to catch this; it only asserts behavior, not documentation. Counted as first-pass per the protocol's own oracle-only definition, but the raw pass rate below overstates "ready to trust unsupervised" — a diff read is still required, exactly as the harness's own known-limitations section already says. |
| 4 | Retry: replace the hand-rolled `.gitignore`-scope matching with `git check-ignore` (issue #98 item 2) | `opencode-go/qwen3.7-max` | **No** | 1 | 0.03069475 | Oracle passed (`audit.jsonl` entry `a-400e4d9c` shows `exit_status: completed`) — but diff review found a real behavioral regression the oracle cannot see. The model's implementation tests whether a synthetic probe filename is ignored by the changed `.gitignore`'s actual content, instead of the original's pure directory-containment check the task explicitly required be preserved. Empirically confirmed: with `GUARD_DIR=tests` and `tests/.gitignore` containing only `*.pyc`, `git check-ignore -v --no-index tests/__imps_scope_probe__` exits 1 (not ignored) — so a changed `tests/.gitignore` in the *same directory as the guard* would silently NOT be flagged, even though the task's own spec says same-directory is always in scope. This weakens the fail-closed guard the whole block exists for. **Not merged.** Also note: this attempt's opencode process was itself killed by the 300s attempt-timeout mid-run (`attempt 1 timed out after 300s`), and the harness committed the work anyway once the oracle went green — a killed attempt shipping code. → resolved: `--attempt-timeout` is now a terminal abort (`attempt_timeout`); the oracle never runs after a kill, so a killed attempt can no longer produce `status:"pass"`. A first attempt at this task (same day, before this fix) ran 5/5 attempts against a worktree whose oracle could never pass — that worktree carried the still-unimplemented `resolve_model_alias` fixtures from task 5's prep, so `bash tests/run.sh` was failing for reasons unrelated to this task before the model touched anything. Voided; not counted (`audit.jsonl` entry `a-b28ae495`). |
| 5 | Add `resolve_model_alias()` (`cheap`→`opencode-go/deepseek-v4-flash`, `default`→`opencode-go/qwen3.7-max`, passthrough otherwise), wired in before the model-allowlist check (issue #96, one narrow slice) | `opencode-go/qwen3.7-max` | Yes | 1 | 0.0213345 | Genuine first-pass, diff-verified: matches the prompt's spec exactly, placed alongside the file's other small helpers, sourceable under the existing `__SOURCED__` pattern, no unrelated changes. `bash tests/run.sh`: 37/37 (the 4 red-test fixtures written ahead of this dispatch now pass). **This is the first dispatch-produced code in this entire round to actually ship** — cherry-picked onto this branch as `2e33e24`, unlike tasks 2 and 3 above. |

All five rows above ran `--oracle 'bash tests/run.sh'` (the repo's full behavioral+unit suite) with `--oracle-guard 'tests/*'` — each row's cell above notes its own dispatch worktree's starting point, including row 4's voided contaminated-worktree first attempt and its clean cherry-picked re-run, and row 5's own pre-placed red-test fixtures. Five real tasks **meets** the protocol's own ≥5 floor — see the concluding paragraphs below for what that number does, and does not, license. At the time these five exhausted this repo's currently-open, well-scoped, existing-oracle candidates (the remaining items in issue #98 — the comment-density extraction and the cleanup TOCTOU fix — don't have a machine-checkable pass/fail condition, so per this protocol's own rule they stay on Claude rather than being forced through this harness for the sake of a bigger sample); any future round needs new real tasks as they arise, in this repo or elsewhere.

**Attempt #4, not counted either way:** a genuine real task turned up in a different repo (`dazn-fantasy-football`, maintainer-authorized for this round) — `apps/engine/pyproject.toml` on that repo's own `main` had literal unresolved git conflict markers committed into it, breaking `uv sync` outright. Every dispatch attempt against it failed instantly with the generic `An unknown error occurred (Unexpected)`; live diagnosis (see the "OpenCode Go's own rate limit surfaces as a generic error" limitation above) found the real cause was the account's OpenCode Go 5-hour usage cap, already exhausted by tasks 1–3 above plus diagnostic runs — not a harness or repo bug. The dispatch never produced a contract line and isn't in `audit.jsonl`, so it isn't recorded as a fail. Fixed directly by hand instead of waiting out the ~2h reset, since the bug was actively blocking that repo; a genuine 4th opencode-routed data point is still owed once quota resets.

**Tasks 2 and 3's actual code was never shipped — only their writeups were.** Discovered 2026-07-27 while trying to extend this round: `run_with_timeout_probe` is still defined directly in `opencode-dispatch.sh` (never moved to a sourced helper, despite task 2's row above), and `resolve_and_validate_gitdir()` does not exist anywhere in `sandbox-wrap.sh` or any branch in this repo (task 3's consolidation). Both dispatches ran in ephemeral worktrees that were never merged or even branched from — the PRs that recorded these results (#100, #101) touched only this reference doc. So issue #98 items 3 and 4 are **still open** despite being recorded here as first-pass. This is the exact loss `--result-branch` and the unconditional `refs/imps/dispatch/*` ref close: every successful commit now writes a durable ref regardless of any flag, so the commit survives worktree deletion instead of evaporating with it. Task 5 above was the first dispatch in this round to actually land its commit; any dispatch that passes today does the same automatically.

**The `run_with_timeout` dispatch crash (previous known-limitation entry above) is fixed.** Root cause confirmed and closed same day: the pipe to `tee` was replaced with a direct append-redirect to the log file (commit `94f6d99`). Verified with 5/5 clean trivial dispatches (vs. 0/9 through the unfixed script), then with two real tasks — see rows 4 and 5 above. The live `tee`-to-stderr echo during a run is gone as a result; read `$LOG_PATH` (or `tail -f` it) instead.

**A second, harness-adjacent mistake showed up while retrying task 4.** The first retry (after the crash fix) ran in a worktree cut from a branch tip that already carried task 5's not-yet-implemented `resolve_model_alias` red-test fixtures — so `bash tests/run.sh` could never return 0 regardless of what task 4's model did. All 5 attempts genuinely ran, genuinely failed the (unpassable) oracle, and the run was voided rather than counted (`audit.jsonl` entry `a-b28ae495`). Re-run from a clean cherry-picked base (fix only, no unrelated fixtures) to get row 4's real result. → resolved: `--expect-oracle green` (or `red`) now runs exactly this check as a preflight and aborts `oracle_preflight_mismatch` before a single model attempt is spent, instead of burning all 5 attempts against an oracle that could never pass.

**Excluded from this table:** four earlier `tier:"opencode"` entries in `~/.claude/audit.jsonl` from 2026-07-25 (project `imps-headimp-fixes`, model `opencode-go/deepseek-v4-flash`, all within an 11-minute span: 3 failed, 1 passed first-try); six from 2026-07-27 crash-poisoned by the (now-fixed) `run_with_timeout` bug: `a-c6f9f267`, `a-ee1ca19e`, `a-f936b1c1`, `a-22041f8c`, `a-b77adc43`, `a-2b5b697d`; five fix-verification trials (trivial zero-edit control tasks, not real measurement): `a-f9190a23`, `a-a0bd67ad`, `a-87fe6992`, `a-71f55491`, `a-62d3432b`; and the voided contaminated-oracle task-4 attempt: `a-b28ae495`. Sixteen IDs total — if you're computing a pass rate from `audit.jsonl` directly rather than this table, exclude all of them or the number is wrong. Note also that `a-400e4d9c` (row 4's real attempt) shows `exit_status: completed` in `audit.jsonl` — the harness only knows the oracle passed; it has no way to record the diff-review finding that this table does. Don't trust `audit.jsonl` alone for a rate; the human-reviewed table above is authoritative.

**Go/no-go:**

- **>70% first-pass oracle rate → open the `/imps:go` follow-up issue.**
- **<40% → stop.** The tier is not worth the harness.
- In between: collect more tasks before deciding.

**No verdict, and not extending further.** 5 real tasks, 3/5 first-pass (60%) — inside the ambiguous band, and per the protocol's own rule that should mean collecting more. Not doing that here, deliberately: **two of the three counted passes were oracle-green and wrong** (task 3's silently deleted security comments; task 4's silently weakened fail-closed guard, this round's most consequential single finding), both caught only by human diff review, neither catchable by the oracle-only pass rate this go/no-go rule is built on. A 6th or 7th hand-picked task would add a data point to a measurement whose instrument is already known to be unreliable — more samples don't fix that. Before this protocol produces a trustworthy number, the oracle-only definition of "pass" needs revision (e.g., mandatory diff review folded into the criterion, not treated as a footnote) or the go/no-go rule needs to weight verified-correct passes differently from oracle-only passes. That's the real conclusion of this round, not a percentage. (This doc's own revision above — `pass` now means verified-correct — is that fix; it does not, on its own, change any number recorded above.)

**Two findings this round leaves at different epistemic weights — do not conflate them:**

- **Green-at-start blindness is a proven structural property, not a one-off.** A
  green-at-start oracle cannot distinguish "implemented correctly" from "did
  nothing" — it is satisfied either way. Task 1 is the demonstration: the
  *oracle* went green on an attempt where the model never edited the target
  file at all; the *harness* — not the oracle — caught it, via
  `commit_failed` (nothing staged, so nothing committed). The guard worked;
  the oracle was blind. That is a caught phantom pass, not an uncaught one —
  the fix this round adds (`no_model_changes`/`--expect-oracle`) exists to
  keep that catch working by a more direct mechanism, not because task 1 slipped
  through. (Task 1 also hit the attempt timeout; under this round's
  terminal-abort change it would now stop at `attempt_timeout` before the
  oracle ever ran.)
- **The red-arm result is an n=1 hypothesis, not a rate.** Task 5 — the
  round's one genuinely verified, shipped success — was dispatched against an
  oracle that started red. It is also, of this round's five tasks, the
  smallest and most narrowly scoped. One red-start task cannot be separated
  from "this was also the easiest task" with n=1; the result is a hypothesis
  worth testing again with task size held constant, not evidence of a red-start
  success rate.

**What the reframe changes and what it does not.** Redefining `pass` as
verified-correct changes *which experiment to run next* — red-start dispatches
with task size controlled for, rather than more hand-picked tasks of whatever
shape turns up — because that is the confound the n=1 red-arm result leaves
open. It does **not** retroactively convert this round's 40% verified-correct
figure into a go; that figure, the "no verdict" call, and the two
oracle-green-but-wrong tasks all stand exactly as recorded above.

*5 real tasks recorded (2026-07-27), all on `qwen3.7-max`: 3/5 first-pass (60%) on the oracle's own terms, but 2 of those 3 counted passes were later found to be wrong on diff review (task 3: silent comment loss; task 4 attempted twice more the same day — once voided by a contaminated oracle, once oracle-green but a real security regression) — so genuinely-correct-and-verified is 2/5 (40%), not 3/5. Task 5 is the round's one unambiguous, verified, actually-shipped success. Round concludes here at n=5, no go/no-go verdict, with the oracle-only pass-rate metric itself flagged as unreliable pending revision — see above.*
