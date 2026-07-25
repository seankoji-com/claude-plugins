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
  --oracle-guard    'tests/test_thing.py'
```

`--attempt-timeout`/`--oracle-timeout` (seconds, default 300/120) bound the
model run and the oracle run respectively — without them a stalled provider or
a hung test suite blocks forever with no contract line at all until someone
notices and kills the process. `--oracle-guard` (optional pathspec, e.g. a
test file) checks whether the model's own edits touched it; see
`oracle_files_modified` below.

The **final line of stdout is always** exactly one JSON object, on every exit
path — success, oracle exhaustion, failed preflight, rejected model:

```json
{"status":"pass","attempts":2,"session_id":"ses_…","cost_usd":0.0087,
 "oracle_exit":0,"log_path":"/abs/path.jsonl","abort_reason":null,
 "oracle_files_modified":null}
```

`session_id`, `cost_usd`, `oracle_exit`, `log_path` and `oracle_files_modified`
are nullable. `oracle_files_modified` is a JSON array of paths (or `null`) —
non-null means the model's own edits touched a file matching `--oracle-guard`.
This is fail-closed by construction, not by reader diligence: a guard hit is
reported as `status:"fail"` with `abort_reason:"oracle_guard_violated"`, never
as a tainted `"pass"` a naive `jq -r .status` consumer would miscount as
genuine. `abort_reason` is `null` on normal paths (including a clean oracle
exhaustion), else one of `preflight_smoke_failed`, `model_rejected`,
`config_missing`, `bad_arguments`, `auth_missing`, `opencode_missing`,
`sandbox_bypass_refused`, `dispatch_dir_failed`, `log_path_failed`,
`jq_missing`, `unexpected_exit`, `oracle_timeout`, `oracle_sandbox_failed`,
`commit_failed`, `worktree_dirty`, `oracle_guard_violated`,
`gitmeta_tampered`, `commit_lineage_invalid`. Exit code is still non-zero on
failure. All progress goes to stderr.

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

### Known limitation: the bash denylist is a typo-guard, not egress control

`templates/opencode.sandbox.json`'s bash denylist (`rm -rf *`, `git push *`, `sudo *`,
`curl *` denied, everything else allowed) only blocks opencode's own permission layer —
it does nothing at the OS level. `/usr/bin/curl`, `wget`, `nc`, or
`python3 -c 'import urllib...'` all match the wildcard allow and run fine, and the
sandbox grants network egress by design. Egress is unrestricted in v1 — the denylist
exists to stop an *accidental* `rm -rf *`/`git push`, not a deliberate one.

---

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

| # | Task | Model | First-pass? | Attempts | Cost (USD) | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | | | | | | |
| 2 | | | | | | |
| 3 | | | | | | |
| 4 | | | | | | |
| 5 | | | | | | |

**Go/no-go, stated plainly:**

- **>70% first-pass oracle rate → open the `/imps:go` follow-up issue.**
- **<40% → stop.** The tier is not worth the harness.
- In between: collect more tasks before deciding.

*No field data has been collected yet.*
