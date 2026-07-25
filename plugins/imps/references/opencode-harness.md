# opencode execute-tier harness (v1)

Keep judgment work on Claude; offload *mechanical* implementation to `opencode`
running cheap open models, each task in an isolated git worktree under an OS-level
sandbox.

v1 is **harness + measurement only**. Nothing here changes `/imps`. These are
hand-invocable scripts; whether `/imps:go` ever gets built is decided by the
numbers from the measurement protocol at the bottom of this file.

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
  --worktree     /abs/path/to/worktree \
  --prompt-file  /abs/path/to/task-prompt.md \
  --oracle       'python3 -m pytest tests/test_thing.py -q' \
  --model        opencode-go/qwen3.7-max \
  --max-attempts 3
```

The **final line of stdout is always** exactly one JSON object, on every exit
path — success, oracle exhaustion, failed preflight, rejected model:

```json
{"status":"pass","attempts":2,"session_id":"ses_…","cost_usd":0.0087,
 "oracle_exit":0,"log_path":"/abs/path.jsonl","abort_reason":null}
```

`session_id`, `cost_usd`, `oracle_exit` and `log_path` are nullable.
`abort_reason` is `null` on normal paths (including a clean oracle exhaustion),
else one of `preflight_smoke_failed`, `model_rejected`, `config_missing`,
`bad_arguments`, `auth_missing`, `opencode_missing`, `sandbox_bypass_refused`,
`dispatch_dir_failed`, `log_path_failed`, `jq_missing`, `unexpected_exit`. Exit
code is still non-zero on failure. All progress goes to stderr.

`log_path` deliberately lives under `$TMPDIR`, never in the worktree: the harness
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
| read/write | the worktree, the gitmeta dir, the dispatch data dir, `$TMPDIR`, `/dev/null` |
| read-only | the backend's default system roots, plus `~/.gitconfig`, `~/.gitignore_global`, `~/.opencode/bin` |
| denied | everything else — explicitly `~/.local/share/opencode`, `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/.claude/.credentials.json` |
| network | allowed (the model API is remote) |

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

`sandbox-smoke.sh`'s `auth-json-denied` assertion is the *only* thing behind this
claim; if the file is absent on the host, the script says so rather than counting
a vacuous check as a pass.

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
git -C "$WT" add -A
git -C "$WT" -c user.name=imps-opencode -c user.email=imps@local -c commit.gpgsign=false \
    commit -q -m "opencode: <prompt> (attempt N)" --no-gpg-sign
```

This operator's global `~/.gitconfig` signs commits via an SSH key served by the
1Password desktop-app agent, which is — correctly — unreachable from inside the
sandbox. Granting it would mean handing a cheap `--auto` model live signing
credentials, defeating the isolation entirely.

This is a **narrow, deliberate exception, not a general precedent**: a synthetic
bot commit in an ephemeral, throwaway worktree, not final shared history. Any real
promotion of this work into a shared branch goes through the normal reviewed,
signed flow (out of v1 scope).

### Known limitation: the oracle is not tamper-proof

`$TMPDIR` is granted read/write wholesale, and the model can edit anything in the
worktree — including the test file the oracle runs. The retry prompt tells it not
to, and the fixtures are trivial enough that gaming them is more work than solving
them, but v1 does not *enforce* this. Read the diff before promoting anything.

### Known limitation: the bash denylist is a typo-guard, not egress control

`templates/opencode.sandbox.json`'s bash denylist (`rm -rf *`, `git push *`, `sudo *`,
`curl *` denied, everything else allowed) only blocks opencode's own permission layer —
it does nothing at the OS level. `/usr/bin/curl`, `wget`, `nc`, or
`python3 -c 'import urllib...'` all match the wildcard allow and run fine; the sandbox
grants network egress and `$TMPDIR` wholesale (including the redirected `auth.json` copy
and every other dispatch's scratch dir). Egress is unrestricted by design in v1 — the
denylist exists to stop an *accidental* `rm -rf *`/`git push`, not a deliberate one.

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
`~/.claude/audit.jsonl` (`tier: "opencode"`, `attempts`):

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
