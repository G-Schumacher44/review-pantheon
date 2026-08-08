# CLI guide — `pantheon`

The CLI-surface reference: every flag, every `gate.conf` key, the execution tiers, the
follow-up-mode state model, exit codes, and worked examples. This is the doc you come back to
once `pantheon` is installed and working — for install steps and the zero-token first run, see
[SETUP.md](SETUP.md) instead; it points back here for flag detail rather than re-explaining it.
For the binding contract (verdict schema, security posture, the full read-provenance matrix),
see [DESIGN.md](../DESIGN.md). Everything below is grounded in `pantheon`'s own `--help` output
and the `pantheon` package — if this doc and the code ever disagree, that's DESIGN.md rule 5's
bug, not a judgment call.

`pantheon` is the CLI — `pantheon gate` runs the standard twin-agent gate,
`pantheon counsel` runs the counsel panel. Install: `pipx install <built pantheon artifact>`
(or `pip install` into a venv) — see [SETUP.md](SETUP.md).

## Command reference

```
pantheon gate (--pr <number> | --branch [BASE]) [--provider <lane>]
              [--agents "artemis apollo"] [--execution readonly|trusted] [--dry-run]
```

Exactly one of `--pr` / `--branch` is required — they select the two things this gate can
review. `--pr` reviews a pull request and posts the verdict as a comment. `--branch` reviews the
branch you are standing on, **before any PR exists**, and prints the verdict instead.

| Flag | Required | Default | What it does |
|---|---|---|---|
| `--pr <number>` | one of | — | The PR to review. Digits only — anything else fails closed before any network call. |
| `--branch [BASE]` | one of | `origin/HEAD`, else `main` | Review `merge-base(origin/BASE, HEAD)...HEAD` — the current branch's own diff. Needs no PR, no `gh`, and no push; works offline against an already-fetched `origin/BASE`. Prints the verdict to stdout and posts nothing. See [Pre-PR mode](#pre-pr-mode---branch). |
| `--provider <lane>` | no | `gate.conf`'s `provider=`, else `claude` | Provider lane in `pantheon.providers` (`claude`, `codex`, `gemini`, `cursor`). Unknown lane name fails fast. |
| `--agents "a b c"` | no | `gate.conf`'s `agents=`, else `"artemis apollo"` | Space-separated agent list. Each name must be one of `artemis apollo diogenes plato socrates`; an empty resolved list is a hard error. |
| `--execution <tier>` | no | `gate.conf`'s `execution=` (base-pinned — see below), else `readonly` | `readonly` restricts Bash to the read-only git wrapper; `trusted` restores full Bash. See [Execution tiers](#execution-tiers-readonly-vs-trusted). |
| `--dry-run` | no | off | Builds prompts and prints the would-be comment; calls no provider, posts nothing, records no `reviewed_sha` for the PR. Can still bootstrap an empty `.review-gate-state.json` — see [caveat below](#the-state--follow-up-model). |
| `-h`, `--help` | no | — | Prints usage and exits 0. |

An explicit `--execution` is resolved immediately, before any `gh`/network call — it's an
operator-typed action, not PR content, so it doesn't wait on anything. Every other flag not
listed here doesn't exist; an unrecognized argument prints usage and exits nonzero.

## `gate.conf`

Lives at the target repo's root, simple `key=value`, one per line, everything optional (falls
back to the default shown). **CLI surface only** — the published action and the vendored workflow
don't read it at all; `action.yml`'s equivalents are explicit `with:` inputs, and
`action/review.yml` has no config surface (see DESIGN.md's ["Surface
differences"](../DESIGN.md#surface-differences)). `install.sh` does not install `gate.conf` for
you — copy [`gate.conf.example`](../gate.conf.example) yourself.

| Key | Default | Notes |
|---|---|---|
| `provider` | `claude` | Lane in `pantheon.providers` (`claude`, `codex`, `gemini`, `cursor`). |
| `model` | *(empty)* | Lane-specific model id; empty means "let the lane pick its own default." |
| `base_branch` | `main` | Merge base for the review diff — overridden by the PR's own `baseRefName` when `gh pr view` reports one. |
| `rules_file` | `REVIEW_RULES.md` | Path (relative to target repo root) to the house-rules file. See [REVIEW_RULES.example.md](../REVIEW_RULES.example.md). |
| `spec_file` | `DESIGN.md` | Governing spec doc — Apollo-only context, only-if-present. Set `spec_file=` (empty) to disable. |
| `agents` | `artemis apollo` | Space-separated panel for the standard gate. |
| `execution` | `readonly` | `readonly` or `trusted` — see below. |

**Two keys are read differently from the rest, deliberately.** `execution=`/`provider=`/
`rules_file=`/`spec_file=`/`agents=` — every key that shapes gate BEHAVIOR — are read from the
PR's **base commit** (`git show $BASE_SHA:gate.conf`, one read for all five) instead of the
target repo's checked-out working tree; only `model=`/`base_branch=` are working-tree-sourced,
since neither affects tool-execution breadth or which file is trusted as a judgment boundary.
This closes a maintainer's `gh pr checkout <n>`-before-invoking-`pantheon gate` habit: a hostile
PR's own working-tree `gate.conf` can't silently restore full Bash (`execution=trusted`), swap
which provider CLI's judgment gates the merge (`provider=`), redirect `rules_file=`/`spec_file=`
at a path absent at base, or swap the enforcing panel (`agents=`). This is the CLI-surface
instance of the same base-pinned-provenance rule DESIGN.md's security posture applies to
personas, the verdict decider, and the read-only wrapper itself — see DESIGN.md's ["Security
posture"](../DESIGN.md#security-posture) for the full read-provenance matrix. `provider=` is
additionally validated against a fixed, enumerated lane list (`claude`/`codex`/`gemini`/
`cursor`) rather than resolved as a path to source — an unknown lane name fails fast, with no
file-execution vector to worry about in the first place.

## Execution tiers: readonly vs trusted

`readonly` is the default on every surface that invokes Claude — the CLI (`pantheon.providers`'
claude lane), the published action (`action.yml`), and the vendored workflow
(`action/review.yml`). All three configure the identical `Bash(<wrapper path> *)` allowlist plus
`--permission-mode dontAsk`, routing every Bash call through `pantheon/execution.py`'s wrapper
instead of a bare `git` prefix pattern (a prefix match can't distinguish `git diff` from `git
diff --output=tracked-file`, which git's own docs describe as a write).

**What the wrapper allows, in full:**

<details>
<summary>Argv rules and forced environment</summary>

- Subcommand must be exactly one of `diff`, `show`, `log`, `status` — DESIGN.md rule 1's four
  names. Anything else is refused outright.
- Every remaining argument must be a plain value (ref, path, range) — no flag of any kind, not
  even a bare `--`. `diff` additionally requires exactly one positional argument that is a real,
  independently-resolved revision range (`A..B`/`A...B`), not just a string containing `..`.
- Forced on every call: `--no-ext-diff --no-textconv` (closes configured diff/textconv drivers),
  `-c core.fsmonitor=false` (closes a configured fsmonitor hook), `-c core.pager=cat` +
  `GIT_PAGER=cat`/`PAGER=cat` (no pager), `GIT_EDITOR=true`/`GIT_SEQUENCE_EDITOR=true`/`-c
  core.editor=true` (no editor spawn), `-c log.showSignature=false` (no gpg subprocess),
  `GIT_OPTIONAL_LOCKS=0` (closes `status`'s default optional index-refresh write), and
  `GIT_NO_LAZY_FETCH=1` (closes a partial clone's lazy-fetch-and-write on a missing object).

Full vector-by-vector matrix, live-verification notes, and the fixtures that reproduce each one
against the unpatched wrapper before asserting the fix: `pantheon/execution.py`'s own module
docstring and `tests/test-git-readonly-wrapper.sh`.

</details>

**The built-in bypass — read this before assuming coverage is total.** Claude Code itself always
allows a small, non-configurable set of bare read-only commands (plain `git diff`/`show`/`log`/
`status`, no flags) regardless of tier — those never reach the wrapper at all, so none of the
forced-environment protections above apply to them. This is expected (Claude Code's own
built-in), but it means a bare `git status` outside the wrapper can still perform its default
optional index refresh, and a bare object read in a partial clone can still lazy-fetch — real
side effects, not eliminated by this tier. See [SECURITY.md](../SECURITY.md#scope-notes--read-before-assuming-a-finding-is-new)
for the full honest scope note.

**Provider-lane caveat.** This tiering is Claude-specific. `pantheon.providers`' codex/gemini/
cursor lanes invoke their own CLIs directly and never consume the wrapper — Codex, Gemini, and
Cursor have no equivalent tool-scoping mechanism in their own CLIs
as of v1. Running one of those lanes against a hostile fork PR gets the same fail-closed verdict
handling every lane gets (schema validation, the blocker invariant, `UNVERIFIED` on anything
malformed) but **no tool-call boundary at all**. Disclosed, not silently assumed closed — see
DESIGN.md's "Security posture" section, "Tiered tool execution."

**When to flip `trusted`.** `execution=trusted` (or `--execution trusted`) restores full Bash.
Reserve it for reviewing your own repo's own PRs from your own checkout — this repo's own CI
self-reviews its PRs exactly that way. Never point `trusted` at a fork PR you don't control:
reviewing untrusted content is the whole reason `readonly` exists. **The read-only discipline
DESIGN.md rule 1 describes ("agents never mutate the tree, index, or HEAD") is a tool boundary
under `readonly`, but under `trusted` it's persona instruction only** — the wrapper isn't in the
loop at all, so nothing mechanical stops a compromised or misbehaving agent from running a
mutating command. Fine for own-repo/trusted-author use precisely because you already trust the
content being reviewed; not a substitute for `readonly` anywhere else.

## The state / follow-up model

`.review-gate-state.json` lives at the target repo's root, bootstraps itself to `{}` on first
run. Shape: `{"<pr-number>": {"reviewed_sha": "<sha>"}}`.

**"Git-ignored" is a Way-A (`install.sh`) claim, not a universal one.** Only `install.sh` appends
`.review-gate-state.json` to the target repo's `.gitignore` for you. Running `pantheon gate`
straight from a review-pantheon checkout, or via a `bootstrap.sh` (Way B) install, adds no
`.gitignore` entry to the target repo at all — including on the very first run, which can be a
`--dry-run`. If you're on the CLI-only path (no `install.sh`), add
`.review-gate-state.json` to your target repo's `.gitignore` yourself before your first run, or
the file will sit untracked-but-visible and can get accidentally `git add -A`'d into a commit.

- **Same head SHA already recorded** → the run is a no-op: a note to stderr, exit 0, nothing
  posted.
- **A different, newer head SHA recorded** → follow-up mode: the diff range narrows to
  `<reviewed_sha>..<head_sha>` instead of the full PR, and the prompt tells the agent to read its
  own prior comment first rather than re-auditing everything.
- **Force-push / rebase / history rewrite since the recorded SHA** → `pantheon gate` checks
  ancestry (`git merge-base --is-ancestor`), not just that the old SHA still exists as a fetchable
  object (it can be fetchable and no longer an ancestor). When ancestry fails, it falls back to
  reviewing the **full PR diff again**, with a note in the prompt explaining why — expected
  after any force-push, not a bug, and not something that needs `.review-gate-state.json`
  cleared by hand.
- **The recording rule is green/yellow-only, on purpose.** The state file's `reviewed_sha` entry
  is written only after a successful `gh pr comment` post **and** only when the overall result is
  `green` or `yellow`. A `red` or `unverified` outcome leaves it untouched, so the next run
  retries from the last SUCCESSFULLY recorded SHA — the full PR only if there was never one — not
  the whole PR unconditionally: if PR review at SHA A already recorded `reviewed_sha: A`, and a
  later follow-up run at SHA B comes back red/unverified, the file still reads `A` afterward, so
  the NEXT run reviews `A..<current head>` incrementally, exactly like any other follow-up — it
  does not re-audit the whole PR from scratch just because the most recent attempt failed to
  gate. Only a PR with no prior recorded SHA at all falls back to a full-PR review on
  red/unverified. `--dry-run` and a draft-PR skip never reach this write at all — no comment is
  posted, so no `reviewed_sha` changes either way. **One caveat: `--dry-run` still bootstraps the
  file itself.**
  `pantheon gate` creates `.review-gate-state.json` as `{}` on first run if it doesn't already
  exist — unconditionally, before the dry-run/draft branches are even reached (`pantheon.cli`'s
  `[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"`) — so a `--dry-run` against a target repo
  that has never run `pantheon gate` before will leave a fresh, empty `.review-gate-state.json` in
  the working tree even though it records nothing about the PR. Not a mutation most workflows
  will notice (an empty JSON object) — but a real one, and NOT git-ignored unless you're on the
  Way-A (`install.sh`) path (see the caveat above this list). "No state written" for `--dry-run`
  means "no PR gets marked reviewed," not "the working tree is untouched."

## Exit codes + reading a verdict comment

| Exit code | Meaning |
|---|---|
| `0` | Overall signal is green or yellow — usable as a CI/script gate on its own, independent of reading the posted comment. Also the draft-PR case: exit 0, nothing posted, nothing reviewed. |
| nonzero | Overall signal is red or unverified, **or** `gh pr comment` itself failed after the verdict was computed (verdict computed but NOT posted, state not updated — see stderr). |

The posted comment is one bold signal line (🟢 clean pass / 🟡 review notes / 🟠 NOT GATED,
fail-closed / 🔴 blocked — worst-wins across agents), a verdict table (one row per agent — a
docs-only skip or a same-run provider failure is its own loud row, never silently dropped), then
a findings fold: an identity line per agent (`**artemis** @ \`<sha>\` — 🟡 FIX_FIRST`), that
agent's one-line summary, an overridden-verdict notice if the blocker invariant fired, and
itemized findings — forced open on red/orange, collapsed otherwise. The raw per-agent verdict
JSON ships too, nested inside that fold as a machine-readable tail. Full shape and the exact
color-precedence rule: DESIGN.md's ["Verdict contract"](../DESIGN.md#verdict-contract) and
["Combined PR comment"](../DESIGN.md#combined-pr-comment) sections; a real rendered example is
in [SETUP.md](SETUP.md#first-live-run).

## Pre-PR mode (`--branch`)

The PR is the most expensive place to debug: every round pays CI minutes, a re-review, and
comment ceremony. `--branch` runs the same gate against your local branch diff, so findings get
fixed in a tight loop and the PR opens hardened.

```bash
git commit -am "..."            # the gate reads COMMITS, not the dirty tree
pantheon gate --branch          # base: origin/HEAD, else main; or: --branch main
```

It answers a different question than `--pr` — *"is this branch ready to become a PR?"* — which
is why it is a separate mode rather than a flag:

| | `--pr` | `--branch` |
|---|---|---|
| Base comes from | `gh pr view` → `baseRefName` | operator-typed `BASE`, else the remote's default branch (`origin/HEAD`), else `main` — never the reviewed tree's `gate.conf` |
| Needs a PR to exist | yes | no |
| Needs `gh` / network | yes | no — local git only |
| Verdict goes to | a PR comment | stdout |
| Exit code | 0 green/yellow, 1 otherwise | same |
| Dedupe state | records `reviewed_sha` | none — every run is deliberate |

**Everything security-critical is shared, not reimplemented.** Personas, the verdict decider,
house rules, the spec and `gate.conf` are still read from the **base commit**, never your working
tree — `pantheon.basepin` takes a SHA and does not care whether it came from `gh pr view` or a
local merge-base. Only three things differ: base resolution, the prompt header, and where the
verdict goes.

Two refusals worth knowing, both fail-closed:

- **`HEAD` equals the merge-base** → nothing to review. Commit first; this gate reads commits.
- **`origin/BASE` not found locally** → fetch it first (`git fetch origin <BASE>`) or pass the
  right base. It will not silently diff against something else.

`--dry-run` behaves as it does on the PR lane: builds the prompts, prints the would-be comment,
calls no provider, exits 0.

## Worked examples

<details>
<summary>Zero-token dry-run demo</summary>

```bash
pantheon gate --pr 42 --dry-run
```

Real `gh pr view`, real fetched refs, real diff range and docs-only/follow-up detection, real
prompt assembly per agent — right up to the point of calling a provider. Prints, per agent, the
command it *would* run and the comment it *would* post, to stdout only. Zero tokens, zero risk to
the PR (nothing posted, no PR ever recorded as reviewed) — though it does bootstrap an empty
`.review-gate-state.json` if one doesn't exist yet, see [the state/follow-up
model](#the-state--follow-up-model)'s caveat. Full walkthrough:
[SETUP.md](SETUP.md#first-run--the-demo).

</details>

<details>
<summary>First live gate</summary>

```bash
pantheon gate --pr 42
```

Drops `--dry-run`. Each configured agent's provider lane actually runs; one combined comment
posts to the PR; exit code reflects the overall signal (see above).

</details>

<details>
<summary>Re-gate after new commits (follow-up mode)</summary>

```bash
pantheon gate --pr 42
```

Same command — follow-up mode is automatic, keyed off `.review-gate-state.json`. If PR #42's
head has moved since the last recorded `reviewed_sha`, this run reviews only the incremental
diff and tells the agent to read its own prior comment first (or the full diff again, loudly, if
the head was force-pushed past the recorded SHA — see [The state/follow-up
model](#the-state--follow-up-model)).

</details>

<details>
<summary>Counsel run (philosophers via --agents)</summary>

```bash
pantheon gate --pr 42 --agents "socrates diogenes plato"
```

The counsel agents' natural home is the planning conversation, before anything is merge-gated —
running them through `pantheon gate` against a PR is the documented exception, not the default
workflow (see README's ["The panel"](../README.md#the-panel)).

**Mechanically, through this CLI, they gate exactly like Artemis/Apollo do — the "counsel, not
gate" distinction is a usage convention, not a code path.** `pantheon.verdict`'s `VOCAB` table
maps each agent's own red-tier word (`socrates:NO_GO`, `diogenes:GUT`, `plato:FRACTURED`,
alongside `artemis:STOP`/`apollo:RETURN`) to `color=red` identically, and
`pantheon.render.overall_color()` takes the worst color across whatever agent list actually ran —
it has no notion of "gate agent" vs "counsel agent" at all. Run the command above and a `NO_GO` from
Socrates alone produces the same 🔴 Blocked comment and nonzero exit as a `STOP` from Artemis
would. If you wire a counsel-only `--agents` list into a CI step the way you would Artemis/Apollo,
it blocks the same way — there is no code-level safeguard keeping counsel advisory once it's run
through the gate; that separation is README's documented convention (only Artemis/Apollo run
automatically in CI) and your own `gate.conf`/CI wiring, not something this CLI enforces for you.

</details>

<details>
<summary>Provider switch</summary>

```bash
pantheon gate --pr 42 --provider codex
```

Or set `provider=codex` in `gate.conf` to make it the default for that repo. Only `claude` is
integration-tested; `codex`, `gemini`, `cursor` are best-effort — each asserts its own CLI is on
`PATH` and is unverified against your installed version, and (per [Execution
tiers](#execution-tiers-readonly-vs-trusted) above) carries no readonly-tier tool restriction at
all. `--provider` overrides `gate.conf` for a single run only.

</details>
