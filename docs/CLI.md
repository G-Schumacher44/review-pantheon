# CLI guide — `review-gate`

The CLI-lane reference: every flag, every `gate.conf` key, the execution tiers, the
follow-up-mode state model, exit codes, and worked examples. For install steps and the
zero-token first run, see [SETUP.md](SETUP.md). For the binding contract (verdict schema,
security posture, the full read-provenance matrix), see [DESIGN.md](../DESIGN.md). Everything
below is grounded in `cli/review-gate`'s own `--help` output and `cli/lib/*.sh` — if this doc and
the code ever disagree, that's DESIGN.md rule 5's bug, not a judgment call.

## Command reference

```
review-gate --pr <number> [--provider <lane>] [--agents "artemis apollo"]
            [--execution readonly|trusted] [--dry-run]
```

| Flag | Required | Default | What it does |
|---|---|---|---|
| `--pr <number>` | yes | — | The PR to review. Digits only — anything else fails closed before any network call. |
| `--provider <lane>` | no | `gate.conf`'s `provider=`, else `claude` | Provider lane in `cli/providers/` (`claude`, `codex`, `gemini`, `cursor`). Unknown lane name fails fast. |
| `--agents "a b c"` | no | `gate.conf`'s `agents=`, else `"artemis apollo"` | Space-separated agent list. Each name must be one of `artemis apollo diogenes plato socrates`; an empty resolved list is a hard error. |
| `--execution <tier>` | no | `gate.conf`'s `execution=` (base-pinned — see below), else `readonly` | `readonly` restricts Bash to the read-only git wrapper; `trusted` restores full Bash. See [Execution tiers](#execution-tiers-readonly-vs-trusted). |
| `--dry-run` | no | off | Builds prompts and prints the would-be comment; calls no provider, posts nothing, writes no state. |
| `-h`, `--help` | no | — | Prints usage and exits 0. |

An explicit `--execution` is resolved immediately, before any `gh`/network call — it's an
operator-typed action, not PR content, so it doesn't wait on anything. Every other flag not
listed here doesn't exist; an unrecognized argument prints usage and exits nonzero.

## `gate.conf`

Lives at the target repo's root, simple `key=value`, one per line, everything optional (falls
back to the default shown). **CLI-lane only** — the published action and the vendored workflow
don't read it at all; `action.yml`'s equivalents are explicit `with:` inputs, and
`action/review.yml` has no config surface (see DESIGN.md's ["Lane
differences"](../DESIGN.md#lane-differences)). `install.sh` does not install `gate.conf` for
you — copy [`gate.conf.example`](../gate.conf.example) yourself.

| Key | Default | Notes |
|---|---|---|
| `provider` | `claude` | Lane in `cli/providers/` (without `.sh`). |
| `model` | *(empty)* | Lane-specific model id; empty means "let the lane pick its own default." |
| `base_branch` | `main` | Merge base for the review diff — overridden by the PR's own `baseRefName` when `gh pr view` reports one. |
| `rules_file` | `REVIEW_RULES.md` | Path (relative to target repo root) to the house-rules file. See [REVIEW_RULES.example.md](../REVIEW_RULES.example.md). |
| `spec_file` | `DESIGN.md` | Governing spec doc — Apollo-only context, only-if-present. Set `spec_file=` (empty) to disable. |
| `agents` | `artemis apollo` | Space-separated panel for the standard gate. |
| `execution` | `readonly` | `readonly` or `trusted` — see below. |

**One key is read differently from the rest, deliberately.** Every key above except `execution`
is read straight from the target repo's checked-out working tree. `execution=` is read from the
PR's **base commit** (`git show $BASE_SHA:gate.conf`) instead — never the working tree — because
a maintainer who runs `gh pr checkout <n>` before invoking `review-gate` (a common local-review
habit) would otherwise have a hostile PR's own `execution=trusted` silently restore full Bash
before the gate inspects anything. This is the CLI-lane instance of the same base-pinned-provenance
rule DESIGN.md's security posture applies to personas, the verdict decider, and the read-only
wrapper itself — see DESIGN.md's ["Security
posture"](../DESIGN.md#security-posture-kept-from-the-private-ancestor-by-design) for the full
read-provenance matrix and why the other `gate.conf` keys don't need the same treatment (they
don't control tool-execution breadth).

## Execution tiers: readonly vs trusted

`readonly` is the default on every surface that invokes Claude — the CLI (`cli/providers/
claude.sh`), the published action (`action.yml`), and the vendored workflow
(`action/review.yml`). All three configure the identical `Bash(<wrapper path> *)` allowlist plus
`--permission-mode dontAsk`, routing every Bash call through `cli/lib/pantheon-git-readonly.sh`
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
against the unpatched wrapper before asserting the fix: `cli/lib/pantheon-git-readonly.sh`'s own
header comment and `tests/test-git-readonly-wrapper.sh`.

</details>

**The built-in bypass — read this before assuming coverage is total.** Claude Code itself always
allows a small, non-configurable set of bare read-only commands (plain `git diff`/`show`/`log`/
`status`, no flags) regardless of tier — those never reach the wrapper at all, so none of the
forced-environment protections above apply to them. This is expected (Claude Code's own
built-in), but it means a bare `git status` outside the wrapper can still perform its default
optional index refresh, and a bare object read in a partial clone can still lazy-fetch — real
side effects, not eliminated by this tier. See [SECURITY.md](../SECURITY.md#scope-notes--read-before-assuming-a-finding-is-new)
for the full honest scope note.

**Provider-lane caveat.** This tiering is Claude-specific. `cli/providers/{codex,gemini,
cursor}.sh` invoke their own CLIs directly and never consume `PANTHEON_ALLOWED_TOOLS` or the
wrapper — Codex, Gemini, and Cursor have no equivalent tool-scoping mechanism in their own CLIs
as of v1. Running one of those lanes against a hostile fork PR gets the same fail-closed verdict
handling every lane gets (schema validation, the blocker invariant, `UNVERIFIED` on anything
malformed) but **no tool-call boundary at all**. Disclosed, not silently assumed closed — see
DESIGN.md's "Security posture" section, "Tiered tool execution."

**When to flip `trusted`.** `execution=trusted` (or `--execution trusted`) restores full Bash.
Reserve it for reviewing your own repo's own PRs from your own checkout — this repo's own CI
self-reviews its PRs exactly that way. Never point `trusted` at a fork PR you don't control:
reviewing untrusted content is the whole reason `readonly` exists.

## The state / follow-up model

`.review-gate-state.json` lives at the target repo's root (git-ignored, bootstraps itself to
`{}` on first run). Shape: `{"<pr-number>": {"reviewed_sha": "<sha>"}}`.

- **Same head SHA already recorded** → the run is a no-op: a note to stderr, exit 0, nothing
  posted.
- **A different, newer head SHA recorded** → follow-up mode: the diff range narrows to
  `<reviewed_sha>..<head_sha>` instead of the full PR, and the prompt tells the agent to read its
  own prior comment first rather than re-auditing everything.
- **Force-push / rebase / history rewrite since the recorded SHA** → `review-gate` checks
  ancestry (`git merge-base --is-ancestor`), not just that the old SHA still exists as a fetchable
  object (it can be fetchable and no longer an ancestor). When ancestry fails, it falls back to
  reviewing the **full PR diff again**, with a note in the prompt explaining why — expected
  after any force-push, not a bug, and not something that needs `.review-gate-state.json`
  cleared by hand.
- **The recording rule is green/yellow-only, on purpose.** The state file is updated only after
  a successful `gh pr comment` post **and** only when the overall result is `green` or `yellow`.
  A `red` or `unverified` outcome leaves it untouched, so the next run retries the whole PR
  instead of treating a run that never actually gated anything as reviewed. `--dry-run` and a
  draft-PR skip never reach this step at all — no comment is posted, so no state is written.

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

## Worked examples

<details>
<summary>Zero-token dry-run demo</summary>

```bash
review-gate --pr 42 --dry-run
```

Real `gh pr view`, real fetched refs, real diff range and docs-only/follow-up detection, real
prompt assembly per agent — right up to the point of calling a provider. Prints, per agent, the
command it *would* run and the comment it *would* post, to stdout only. Zero tokens, zero risk,
no state written. Full walkthrough: [SETUP.md](SETUP.md#first-run--the-demo).

</details>

<details>
<summary>First live gate</summary>

```bash
review-gate --pr 42
```

Drops `--dry-run`. Each configured agent's provider lane actually runs; one combined comment
posts to the PR; exit code reflects the overall signal (see above).

</details>

<details>
<summary>Re-gate after new commits (follow-up mode)</summary>

```bash
review-gate --pr 42
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
review-gate --pr 42 --agents "socrates diogenes plato"
```

The counsel agents' natural home is the planning conversation, before anything is merge-gated —
running them through `review-gate` against a PR is the documented exception, not the default
workflow (see README's ["The panel"](../README.md#the-panel)). Apollo's docs-only skip and the
blocker invariant still apply per-agent as normal; none of the three counsel verdicts can force
red on their own the way Artemis/Apollo's can — they inform, they don't gate.

</details>

<details>
<summary>Provider switch</summary>

```bash
review-gate --pr 42 --provider codex
```

Or set `provider=codex` in `gate.conf` to make it the default for that repo. Only `claude` is
integration-tested; `codex`, `gemini`, `cursor` are best-effort — each asserts its own CLI is on
`PATH` and is unverified against your installed version, and (per [Execution
tiers](#execution-tiers-readonly-vs-trusted) above) carries no readonly-tier tool restriction at
all. `--provider` overrides `gate.conf` for a single run only.

</details>
