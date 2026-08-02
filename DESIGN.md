# Design — review-pantheon

Five read-only agents, split by what their verdict does: two gate agents (Artemis, Apollo) whose
verdicts **enforce** — wired into a fail-closed PR gate that can block a merge — and three
counsel agents (Socrates, Diogenes, Plato) whose verdicts **inform** a human's decision and never
gate or block, regardless of what they're pointed at: a spec, a design doc, a proposal, existing
code, or a diff. Agent-CLI-agnostic: Claude-first, with pluggable provider lanes (Codex, Gemini,
Cursor). This document is the contract for this public rebuild (see the README's ["On generative
AI use"](README.md#on-generative-ai-use) note for what that means) — the personas, runners,
and workflow are all implementations of what's written here. See `docs/README.md` for a full doc
index.

## The idea

Most AI code review collapses two different jobs into one pass. This system splits them:

- **The hunter (Artemis)** reviews the change itself: correctness risks, untested failure
  paths, shortcuts, rule violations. She assumes nothing works until the code shows it does.
- **The verifier (Apollo)** audits the *claim* of completed work: re-runs stated verification,
  diffs what was claimed against what git actually shows, checks required records were written.
  He assumes nothing was done until evidence shows it was. When a governing spec file is named
  in his run context, he also checks the delivered change against the sections of it relevant
  to what changed — a contradiction there is rule 5 below, enforced per-PR, not just documented.

They are twins, not duplicates — different questions, different failure modes caught. Together
they're the **gate agents**: machinery that runs on every PR, in CI and the CLI, against
finished work.

A second tier — **counsel agents** — exists to inform, not enforce: their verdict is counsel a
human weighs in a decision, never a mechanism that gates a merge. That's a property of what
they're for, not of what they're allowed to read — they read a spec, a design doc, a proposal,
existing code, or a diff alike, the same lens applied to whichever one they're handed. Their
natural home leans early — before building, while the decision is still open — but nothing
about them is scoped to design documents only:

- **Socrates** — options analyst: usually runs earliest, maps distinct approaches and go/no-go.
- **Diogenes** — simplicity auditor: is this MORE than it needs to be?
- **Plato** — coherence auditor: does this have a coherent shape, or is it ad-hoc sprawl?

They can be added to a CLI gate run via `--agents` or `gate.conf` for a shape check alongside the
twins, but that wiring is the exception: their design purpose is a human reading their counsel
and deciding, not a pipeline deciding for them.

<details>
<summary>Gate flow at a glance</summary>

```
GATE — enforce, every PR                    COUNSEL — inform, before merging
------------------------------              ------------------------------
PR opened                                   spec / design doc / proposal
  -> prompt built (agents/<name>.md            / existing code / a diff
     persona + diff/context block)               |
  -> provider lane (cli/providers/*.sh            v
     or claude-code-action)                    philosopher
  -> JSON verdict --(missing/bad)-->            (socrates | diogenes | plato)
     fail-closed: UNVERIFIED                     |
  -> decider (verdict.sh | decide_verdict.py)     v
     blocker invariant: any "blocker"          advisory verdict
     finding forces red, verdict field           (GO / TRIM / DRIFTING / ...)
     notwithstanding                              |
  -> one combined PR comment                      v
     (signal + table + folded findings)        human decides
```

</details>

## Hard rules (non-negotiable, all agents, all providers)

1. **Read-only.** Agents inspect via read-only git (`git show <ref>:path`, `git diff`,
   `git log`, `git status`). They never run `stash` / `checkout` / `switch` / `reset` /
   `merge` / `commit` / `branch` / `rebase` or anything that mutates the tree, index, or HEAD.
   If a check would require a tree change, the agent stops and reports it as a gap. **Honest
   limit: this is a mechanical tool boundary only under `execution=readonly`** (the wrapper
   physically can't run anything else) — under `execution=trusted` it's persona instruction
   only, since the wrapper isn't in the loop at all, so nothing mechanical stops a compromised
   or misbehaving agent from mutating the tree. `trusted` exists for own-repo/trusted-author use
   only; see "Security posture" below.
2. **Fail closed.** A missing, empty, or unparseable verdict is UNVERIFIED — never green.
   Skips are loud: any agent that doesn't run reports *why* in the gate output.
3. **Evidence, not vibes.** Every finding cites `file:line` and a concrete failure scenario.
   Every verification claim includes the command run and its real output. No nits without
   consequences.
4. **One canonical persona per agent.** `agents/<name>.md` is the single source. Both runners
   (CLI and GitHub Action) load and template these files — never an embedded copy that can
   drift. (This is a lesson: three divergent copies of a persona is how review systems rot.)
5. **Docs match code.** If this file and an implementation disagree, that's a bug in one of
   them — fix the divergence, don't paper over it.

## Verdict contract

Every agent run must end with a single JSON object (and nothing after it):

```json
{
  "agent": "artemis",
  "verdict": "FIX_FIRST",
  "has_blocker": false,
  "findings": [
    {
      "severity": "should_fix",
      "file": "src/gate.sh",
      "line": 42,
      "issue": "unquoted variable in rm path",
      "scenario": "a branch name containing a space deletes the wrong path"
    }
  ],
  "summary": "one-line human-readable verdict justification"
}
```

- `severity`: `blocker` | `should_fix` | `note`.
- `has_blocker` must be `true` iff any finding is a `blocker`.
- Per-agent verdict vocabularies (each keeps its own voice; the gate maps them):

| Agent | Green | Yellow | Red |
|---|---|---|---|
| artemis | `SHIP` | `FIX_FIRST` | `STOP` |
| apollo | `ACCEPT` | `ACCEPT_WITH_NOTES` | `RETURN` |
| diogenes | `LEAN` | `TRIM` | `GUT` |
| plato | `COHERENT` | `DRIFTING` | `FRACTURED` |
| socrates | `GO` | `GO_WITH_GUARDRAILS` | `NO_GO` |

- Gate signal precedence (worst wins): any red → 🔴 blocked; any unparseable/missing verdict →
  🟠 NOT GATED (fail); any yellow or loud skip → 🟡 review notes; all green → 🟢.
- **The blocker invariant is enforced, not just documented.** Both deciders (the CLI's
  `cli/lib/verdict.sh` and the Action's `action/decide_verdict.py`) check it after schema
  validation: if any finding has `severity: "blocker"` OR `has_blocker: true`, the signal is
  forced to red regardless of the stated `verdict` field, and the gate logs that the
  invariant fired. An object where the verdict and the findings disagree is treated as red,
  not trusted at face value — see "Two runtimes, one rule" below for how both deciders stay
  in sync on this. A finding with `severity: "blocker"` (or `has_blocker: true`) forces red
  even when the stated `verdict` word itself is invalid — a typo'd or out-of-vocabulary
  `verdict` still gets overridden to red if a genuine blocker is present, rather than landing
  on the weaker "not gated" signal. That override needs an object that's at least
  type-shaped correctly first, though — see "Validation surface" below for the line between
  "malformed enough to override" and "malformed enough to distrust outright."
- A docs-only diff (only `*.md` / `docs/**` changed) may skip Apollo with a loud 🟡 skip note.

### Validation surface

Both deciders validate two different things about a verdict object, for two different
reasons, and only one of them is schema-checked:

- **The invariant-read surface — type-strict, fail-closed.** `verdict`, `has_blocker`,
  `findings`, and every `findings[].severity` are the fields the blocker invariant and the
  vocabulary lookup actually reason over — a decision gets made by comparing them, not just
  displaying them. Both deciders check their *types*, not just their presence: `verdict` must
  be a string, `has_blocker` must be strictly boolean, `findings` must be strictly an array,
  and every `findings[].severity` must be a string in `{blocker, should_fix, note}`. Any miss
  is UNVERIFIED, never green. This closes a real gap the presence-only check (`has("has_blocker")`
  etc.) left open: `"has_blocker": "true"` (a string) satisfied presence validation, and since
  both jq's `==` and Python's `is`/`==` comparisons are type-strict, the blocker invariant
  compared a string against the boolean `true` and silently never fired — a malformed verdict
  with a smuggled-in string `has_blocker` could read as a clean, ungated green. Named
  precisely: this repo has exactly two implementations of this check, `cli/lib/verdict.sh`'s
  `decide_verdict()` and `action/decide_verdict.py`'s `type_strict_ok()` — see "Two runtimes,
  one rule" for how they stay in sync.
- **The display surface — deliberately NOT schema-validated.** `file`, `line`, `issue`,
  `scenario`, and `summary` never get compared against anything or branched on — they only get
  *shown*. Validating their types here would just be a second copy of a check the render layer
  already owns: `cli/lib/render_comment.sh` sanitizes every one of these fields at render time
  (`_pantheon_sanitize_inline`, plus `.line`'s numeric-or-`?` coercion) precisely because
  they're untrusted model output reaching a Markdown/HTML surface, regardless of what the
  decider validated or didn't about that same data. The two layers check different things for
  different reasons — decision-surface types here, render-surface safety there — and neither
  substitutes for the other.

## Provider lanes

`cli/providers/<lane>.sh` — one file per provider, each implementing exactly one function:

```
provider_run <model> <prompt-file>   # prints the agent's raw output to stdout, nonzero on failure
```

- `claude.sh` — `claude -p` with a tiered, execution-scoped tool set (Read, Grep, Glob, and a
  Bash allowlist that depends on the `execution` setting — see "Security posture" below) and a
  timeout. Default lane; the only one integration-tested in v1.
- `codex.sh` — `codex exec` non-interactive.
- `gemini.sh` — `gemini` CLI non-interactive prompt mode.
- `cursor.sh` — `cursor-agent` headless.

The gate never trusts a lane to be well-behaved: it extracts the trailing JSON object from
stdout, validates it against the contract with `jq`, and treats any failure as UNVERIFIED. That
trailing object must be exactly one JSON document with nothing after it — trailing content that
is itself valid JSON (a second object, array, or scalar, not just malformed prose) is rejected
identically to malformed trailing content, matching what Python's `json.loads()` already
enforces on its own; both runtimes' extractors implement this the same way (see "Two runtimes,
one rule" below).
Provider selection: `--provider <lane>` flag, else `provider=` in config, else `claude`.
Prompts are built identically for every lane: persona file + a generated context block (diff
range, base branch, house-rules file, output-contract reminder). No lane gets a private fork
of a persona.

## Generated per-tool projections (interactive/editor targets)

The provider lanes above run the gate agents (Artemis, Apollo) headless, in CI or from
`review-gate`. The counsel agents (Socrates, Diogenes, Plato) live earlier — in the human loop,
during planning and design — which means they need to be invocable *inside* a coding-agent
session, in whatever convention that tool's editor or CLI actually supports. `install.sh`'s
`--claude`/`--cursor`/`--codex`/`--gemini` flags generate that per-tool artifact at install
time.

This looks, on its face, like the thing rule 4 forbids — a persona's content ending up in more
than one file. It isn't the same failure, because it isn't the same axis: rule 4 exists to stop
*hand-maintained* copies from drifting apart, one edited and the other forgotten. Every file
these flags write is mechanically derived from `agents/*.md` by `install.sh` at install time —
frontmatter stripped or reshaped to the target tool's schema, the persona body embedded
verbatim or referenced, and a `GENERATED — do not edit, re-run install` header stamped on top.
There is exactly one place a human edits persona content — `agents/<name>.md` — and every
projection is regenerated from it, never hand-edited independently. That's generation, not
duplication, and it's the same shape as the CLI/Action split for the verdict-decision rule (see
"Two runtimes, one rule" below): the artifact repeats, the source of truth doesn't.

Per-tool support is tiered honestly, not uniformly:

- **Claude Code (`--claude`)** — first-class. The persona files are already valid Claude Code
  subagent format (YAML frontmatter + body), so they're copied verbatim into
  `.claude/agents/`. Four canonical skills — `skills/{gate,counsel,spec-driven,design-contract}/SKILL.md`,
  the single hand-maintained source, the same rule-4 shape applied to skills instead of personas —
  are copied verbatim into `.claude/skills/<name>/SKILL.md`. A generated `/counsel` command
  (`.claude/commands/counsel.md`) wraps Socrates, Diogenes, and Plato into one invocation that
  runs Socrates first on an open decision, the other two on a proposed shape, and synthesizes
  their verdicts; a generated `/gate` command (`.claude/commands/gate.md`) thin-invokes the
  installed `gate` skill.
- **Cursor, Codex, Gemini (`--cursor`/`--codex`/`--gemini`)** — best-effort, same posture the
  provider lanes already take with unverified CLIs: each tool's repo-level custom-command (or
  closest equivalent) convention was checked against that tool's own current official docs
  before implementing, not assumed from Claude Code parity. Where a tool has no repo-level
  command convention at all, `install.sh` says so and skips it rather than inventing one — see
  the flag's own comment block in `install.sh`, and the verification matrix below for what was
  checked against which source, per tool.

<details>
<summary>Per-tool editor/CLI install matrix (verified vs. best-effort)</summary>

| Tool | What's generated | Status |
|---|---|---|
| **Claude Code** (`--claude`) | All five personas copied verbatim into `.claude/agents/`; the four canonical skills (`gate`, `counsel`, `spec-driven`, `design-contract`) copied verbatim into `.claude/skills/<name>/`; a generated `/counsel` command (`.claude/commands/counsel.md`) that runs Socrates first, then Diogenes + Plato, and synthesizes the verdicts; a generated `/gate` command (`.claude/commands/gate.md`) that thin-invokes the `gate` skill. | **Verified, first-class.** The personas are already this format; skills follow the documented [Skills](https://code.claude.com/docs/en/skills) `SKILL.md` convention (`.claude/skills/<name>/SKILL.md`, project or user scope); `/counsel` and `/gate` follow the documented [slash-command](https://docs.claude.com/en/docs/claude-code/slash-commands) convention. |
| **Cursor** (`--cursor`) | All five personas as native subagents, `.cursor/agents/*.md` (frontmatter adapted to Cursor's schema). | **Verified against current official docs** ([cursor.com/docs/subagents](https://cursor.com/docs/subagents), Cursor 2.4+). Best-effort: not integration-tested against a live Cursor install in this repo's CI. |
| **Codex CLI** (`--codex`) | All five personas as Codex Skills, `.agents/skills/<name>/SKILL.md`. | **Verified against current official docs** ([developers.openai.com/codex/skills](https://developers.openai.com/codex/skills)). Codex has no repo-level "custom command" convention, so Skills is used instead of inventing one. Best-effort: not integration-tested against a live Codex install. |
| **Gemini CLI** (`--gemini`) | All five personas as custom commands, `.gemini/commands/<name>.toml`. | **Verified against official docs** ([custom-commands.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/custom-commands.md)). Best-effort: not integration-tested against a live Gemini CLI install. |

Claude's `/counsel` is the only generated synthesis command — for the other tools, invoke the
counsel personas individually and reason across their verdicts yourself.

</details>

## Two runtimes, one rule

**Status: the verdict-decision rule is now single-sourced (port slice 5, docs/PYTHON-PORT.md
section 3's "one runtime endgame") — `pantheon/verdict.py` is the ONE implementation, called by
both lanes: the CLI (`pantheon gate`, via `pantheon.cli`) and the Action (`action.yml`'s five
"Decide verdict (<agent>)" steps and the vendored `action/review.yml`'s own "Decide verdict"
step, both invoking `pantheon/verdict.py` by its own absolute path (deliberately NOT `python3 -m
pantheon.verdict` — a Codex finding on this port's own PR: `-m` prepends the caller's cwd, the
PR's own checkout on both Action lanes, to `sys.path[0]` BEFORE any `PYTHONPATH` entry, so a
fork PR committing its own top-level `pantheon/verdict.py` would shadow the trusted one; running
the trusted file by its own path makes ITS directory `sys.path[0]` instead — the same principle
`pantheon.execution.resolve_console_script`'s own console-script resolution already relies on)
— the Action lanes resolve it from `github.action_path`/a base-pinned copy of the package rather
than a `pip install`, since it's a plain stdlib-only module needing no build step to run from a
checkout). The historical two-runtime split this section used to describe — bash+jq's
`cli/lib/verdict.sh` for the CLI,
Python's standalone `action/decide_verdict.py` for the Action, kept in sync by
`tests/test-verdict-decision.sh` cross-checking both against the same fixtures — is retired as
of this slice: `cli/lib/verdict.sh` no longer has a live caller (`cli/review-gate`, the
deprecated bash CLI, still exists for its one-release compat window, but the Python `pantheon`
CLI is what's documented as current — see README.md/docs/CLI.md), and
`action/decide_verdict.py` is now a thin shim delegating straight into `pantheon.verdict`, not a
second implementation (see that file's own header). `tests/test-verdict-decision.sh` still
passes (it now exercises the SAME code twice, once via `cli/lib/verdict.sh` — unchanged, still a
real independent implementation while bash lives — and once via the shim) alongside
`tests/test-verdict-decision-python.sh`'s direct `pantheon.verdict` coverage.

**Not yet unified:** the combined-comment RENDERER (`cli/lib/render_comment.sh` /
`action/lib/combine_verdicts.sh` / `action/review.yml`'s own inline comment-build step — see
"Combined PR comment" below) is a separate absorption this slice did not attempt; it remains
three call sites sharing bash logic, the same shape described there today. Folding it into
`pantheon.render` (already ported, Slice 2) is tracked as a follow-up, not done here.

## Combined PR comment

Every gate run posts exactly one comment: a bold signal line (🟢 clean pass / 🟡 review notes /
🟠 NOT GATED, fail-closed / 🔴 blocked) with a one-sentence plain-language read on what that
means for the merge, a verdict table (one row per agent — a docs-only skip or a same-run
failure shows up as its own loud row, never silently dropped), then a findings fold: human-
readable per-agent sections — an identity line (agent, reviewed head SHA, verdict), the agent's
own one-line summary, an overridden-verdict notice if the blocker invariant fired, and
itemized findings (severity badge, `file:line`, the issue, the concrete failure scenario) —
forced open on red/orange, collapsed otherwise. The raw per-agent verdict JSON still ships,
nested inside that fold as its own collapsed block, so the machine-readable form is never lost,
just no longer the primary read. `cli/lib/render_comment.sh` is the one implementation of this
— sourced by both `cli/review-gate` and `action/lib/combine_verdicts.sh` (the composite
action's renderer), so the CLI surface and the published-action surface read identically by
construction, not by hand-kept-in-sync wording. `action/review.yml` (the vendored,
install.sh-Way-A workflow) is the one surface that still can't reach it — a target repo never gets
a copy of `cli/lib/` (see "Published action" above) — so its "Build and post combined comment"
step remains a hand-synced inline copy of the pre-existing (plainer) table + raw-JSON-dump
shape; bringing it up to the same format needs either vendoring `cli/lib/render_comment.sh`
into install.sh's footprint or duplicating the renderer inline in that YAML, neither done here.

## House rules are pluggable

Artemis and Apollo check "house rules" as blockers — but every team's rules differ. The gate
passes the target repo's `REVIEW_RULES.md` (path configurable) into the prompt context; agents
treat each listed rule as a blocker-class check. Ships with `REVIEW_RULES.example.md`
(no secrets in diffs, no direct commits to the default branch, tests updated with behavior).

## Configuration

`gate.conf` in the target repo root (simple `key=value`, all optional) — **CLI surface only**; the
Action doesn't read it (see "Surface differences" below). `install.sh` does not install it —
CLI-surface users copy `gate.conf.example` themselves (see [docs/CLI.md](docs/CLI.md#gateconf)).

```
provider=claude          # lane in cli/providers/
model=                   # lane-specific model id; empty = lane default
base_branch=main         # merge base for the review diff
rules_file=REVIEW_RULES.md
spec_file=DESIGN.md      # governing spec, Apollo-only context; only-if-exists; empty disables
agents=artemis apollo    # panel for the standard gate
execution=readonly       # readonly (default) or trusted — see "Security posture"
```

## Security posture (kept from the private ancestor, by design)

- PR metadata is attacker-controlled on forks: the gate validates PR number (`^[0-9]+$`),
  branch names (`^[A-Za-z0-9._/-]+$`), and head/base SHA (hex) before any of them touch a
  prompt or a shell command. Unsafe metadata → UNVERIFIED, not a crash. The CLI surface
  (`cli/review-gate`) validates HEAD_SHA and BASE_SHA before either is used; the published
  action (`action.yml`) validates both PR event-context SHAs in its own dedicated step, before
  the base-pinned rules/spec reads or the docs-only diff check ever run; `action/review.yml`
  (the vendored Way-A workflow) gained the same dedicated validation step when its own
  base-pinned wrapper resolution was added (see below) — a `git show`/`git diff` call built
  from an unvalidated SHA is exactly the shell-command-injection surface this rule exists to
  close, on every surface now.
- Model output is never interpolated into shell (`run:`) directly — it travels via files and
  env vars.
- **Base-SHA-pinned context file reads.** `REVIEW_RULES.md` and the spec file (`DESIGN.md` by
  default) are read via `git show <base-sha>:<path>` — the PR's BASE commit — never from the
  checked-out working tree. This closes a fork-PR instruction-injection class: on a fork PR,
  the working tree at review time can hold the PR author's own edits to those files, and a
  rules/spec file read from there would let whoever opened the PR inject content straight into
  the reviewing agents' prompts (e.g. a house "rule" that tells the reviewer to wave everything
  through). A file the PR itself adds or edits only on its head is never read for this purpose;
  when it's absent at the base commit, the CLI surface (`cli/review-gate`'s `build_prompt()`) and
  the published action surface (`action.yml`'s "Resolve gate configuration" step +
  `action/lib/build_prompt.sh`) fall back to omitting it — a loud "not present at base — not
  applied" note for the always-on house-rules file, the same pre-existing silent skip as when
  it's absent entirely for the only-if-exists spec file. `action/review.yml` (the vendored,
  install.sh-Way-A workflow) is not part of this fix — see "Surface differences" below.
- **The class this is one instance of (issue #6).** Base-SHA-pinning REVIEW_RULES.md/DESIGN.md
  was the first fix under a broader rule: **any file that shapes what the gate *does* — not just
  what it judges by — must be read from trusted provenance before use.** "Trusted provenance" is
  one of exactly two things, never a third: the PR's **base ref** (`git show $BASE_SHA:<path>`)
  for a file living in the target repo, or **the action's own checkout**
  (`$ACTION_PATH`/`github.action_path`) for a file shipped with review-pantheon itself — this
  closes the class where a fork PR could rewrite the reviewer's own instructions or
  verdict-grading code, not just the content it's being judged on (see `agents/*.md`'s "Untrusted
  data, not instructions" for the parallel rule on judgment content). Full incident history —
  closed across two rounds after Codex found two more instances of the same gap on the PR that
  introduced the first two fixes: [docs/HARDENING-HISTORY.md](docs/HARDENING-HISTORY.md).

  **Read → provenance matrix, every surface, current state** (✅ = base-pinned or
  action's-own-checkout, i.e. trusted provenance; ⚠️ = judgment content, not gate behavior, kept
  as a documented exception; — = not applicable to that surface):

  | File read | CLI (`cli/review-gate`) | Published action (`action.yml`) | Vendored workflow (`action/review.yml`) |
  |---|---|---|---|
  | Personas (`agents/*.md`) | ✅ `$PANTHEON_ROOT/agents` — review-pantheon's own installed copy, never the target repo's | ✅ `$ACTION_PATH/agents` by default; ✅ base-pinned into `$RUNNER_TEMP` when `personas_path` is set (this PR) | ✅ base-pinned into `$RUNNER_TEMP` (this PR — was `$GITHUB_WORKSPACE`) |
  | Verdict decider (`cli/lib/verdict.sh` / `decide_verdict.py`) | ✅ `$PANTHEON_ROOT/cli/lib/verdict.sh` — this repo's own file | ✅ `$ACTION_PATH/action/decide_verdict.py` | ✅ base-pinned into `$RUNNER_TEMP` (this PR — was `$GITHUB_WORKSPACE`) |
  | Read-only git wrapper | ✅ `$PANTHEON_ROOT/cli/lib/pantheon-git-readonly.sh` | ✅ `$ACTION_PATH/cli/lib/pantheon-git-readonly.sh` | ✅ base-pinned into `$RUNNER_TEMP` (prior fix) |
  | House rules / spec (`REVIEW_RULES.md` / `DESIGN.md`) | ✅ base-pinned (`git show $BASE_SHA:path`) | ✅ base-pinned (`git show $BASE_SHA:path`) | ✅ base-pinned into `$RUNNER_TEMP` (closed by an adversarial-review fix — was `$GITHUB_WORKSPACE`, see "Surface differences") |
  | `gate.conf`'s `execution=`/`provider=`/`rules_file=`/`spec_file=`/`agents=` keys | ✅ base-pinned (all five, one `git show`+parse — an adversarial-review fix generalized `execution=`'s own pre-existing base-pinning to the other four, closing docs/CLI.md's disclosed issue #13 for `provider=` along the way) | — (no `gate.conf`; these are explicit inputs, operator-typed, not PR content) | — (no config surface at all) |
  | `gate.conf`'s `model=`/`base_branch=` keys | ⚠️ working-tree-sourced — neither affects tool-execution breadth or which file is trusted as a judgment boundary (`model` only picks which model an already-scoped provider uses; `base_branch` is a fallback only ever consulted when `gh pr view` itself doesn't report a `baseRefName`) | — | — |
  | `.review-gate-state.json` (follow-up-mode `reviewed_sha`) | ⚠️ working-tree-sourced (see "Honest limit" below) | — | — |
  | Prompt-builder shell (`cli/lib/execution.sh`, `action/lib/build_prompt.sh`, `action/lib/combine_verdicts.sh`) | ✅ this repo's own file | ✅ `$ACTION_PATH/...` | ✅ inline in the workflow file itself (this repo's own committed YAML, not the target repo's content) |
  | The diff / file contents under review | untrusted **by design** — this is the data the gate exists to evaluate; never treated as instructions (`agents/*.md`'s "Untrusted data, not instructions") | same | same |

  **A tracked symlink needs its own resolution, not a bare `git show`.** Git stores a tracked
  symlink as a mode-120000 blob whose "content" IS the link-target string, so a bare
  `git show $BASE_SHA:path` on a symlinked path returns a pathname, not the target file's
  content. Every base-pinned read this section's matrix marks ✅ routes through
  `cli/lib/pantheon-base-pin.sh`'s `pantheon_base_pinned_read` instead: it detects the
  mode-120000 case via `git ls-tree`, resolves and bounds the symlink chain (32-hop cap, refuses
  any resolution escaping the repo root or using an absolute target — loud, never a silent
  fallback to the working tree), and only then `git show`'s the resolved in-repo path at BASE.
  Its two failure modes are distinguished by return code on purpose — 2 is ordinary absence
  (an only-if-exists file like `DESIGN.md` falls back to "not applied"), 1 is REFUSED (an
  escaping or over-deep chain) and is never folded into that same silent path, so a hostile
  symlink can't be mistaken for mere absence. Fixtures: `tests/test-base-pinned-read.sh`,
  `tests/test-prompt-assembly.sh`. Discovery history (Codex P2 on this class's own PR #8):
  [docs/HARDENING-HISTORY.md](docs/HARDENING-HISTORY.md).

  **Honest limit on the sweep.** `.review-gate-state.json` (CLI-surface-only — see "Follow-up
  mode" below; git-ignored only via the `install.sh`/Way-A path, see
  [CLI.md](docs/CLI.md#the-state--follow-up-model) for the other paths) is read from the target
  repo's working tree to decide the incremental diff range for a follow-up review. In the
  specific scenario where a maintainer runs `gh pr checkout <n>` before invoking `review-gate`
  (the same local-review habit that motivated base-pinning `gate.conf`'s `execution=` key), a PR
  that force-adds a crafted `.review-gate-state.json` could in principle narrow the diff range
  Artemis is shown. Left open rather than base-pinned here: it requires a visibly unusual act
  (committing a normally-ignored — where it IS ignored — dotfile) that a reviewing agent, or a
  human skimming the file list, is likely to flag on its own, it only affects the CLI surface's
  human-operated incremental mode (not the fail-closed-by-default CI gate), and base-pinning it
  would need to special-case follow-up mode's whole "what changed since I last looked" premise.
  Tracked as a known, accepted gap rather than silently unswept.
- The GitHub Action checks out with `persist-credentials: false` and fails loud (not skip)
  when its token secret is absent. It pins `anthropics/claude-code-action` to a full commit
  SHA — `be7b93b1907a4abad570368f3c74b6fe3807510b` (v1.0.183) — read directly from that
  release's own `action.yml`, not assumed or copied from an older version's docs (a moving
  tag, or an unpinned `uses:`, is the thing to avoid here — the latter fails at job
  parse/resolve time with an obvious error rather than silently running unpinned, but a moving
  tag doesn't fail at all, it just quietly starts running whatever the tag points to next).
  If you re-pin to a newer release yourself, that's step one of the install checklist
  (`install.sh`'s printed output and the README quickstart) — the verification step there is
  "confirm the pinned SHA matches a release you trust," not "guess the interface," since the
  interface itself is now grounded (see "Published action" below).
- Both the published action and the vendored workflow pass the workflow token to
  `claude-code-action` explicitly (`github_token: ${{ github.token }}` / `${{ inputs.github_token }}`),
  so consumers never need to grant `id-token: write` — that permission is only needed for
  claude-code-action's internal OIDC-token-exchange fallback, which it skips entirely once a
  `github_token` input is supplied.
- **Tiered tool execution — read-only by default.** Every provider invocation's tool set is
  scoped by an `execution` setting: `readonly` (the default — `gate.conf`'s `execution=`, the
  CLI's `--execution` flag, or `action.yml`'s `execution` input) restricts Bash to exactly one
  Claude Code permission-rule prefix — `Bash(<pantheon-git-readonly.sh's path> *)` — with
  Read/Grep/Glob left unrestricted (already read-only by nature). `trusted` restores full Bash,
  the pre-existing v1 behavior. Reviewing a fork PR's diff means reviewing 100%-attacker-
  controlled content; an agent that prompt injection can steer into running an arbitrary shell
  command is a code-execution primitive, not a review gate, so `readonly` is the default on
  every surface that invokes a provider (`cli/providers/claude.sh`, `action.yml`,
  `action/review.yml`) — `trusted` is an explicit, documented opt-in for own-repo/trusted-author
  use only, never for reviewing a fork PR you don't control.
  - The CLI surface's wrapper ships alongside `cli/lib/execution.sh` and is picked up automatically
    (`bootstrap.sh` and `install.sh` both vendor it — see "Layout" below). `action.yml` reads it
    from its own checkout (`github.action_path`, no vendoring needed — that checkout is
    review-pantheon's own trusted tree, never the reviewed PR's). `action/review.yml` (the
    vendored, no-config-surface surface — see "Surface differences") is different: `install.sh`
    vendors the wrapper INTO the target repo, and that repo's own checkout in this workflow pulls
    the PR's own tree — so a naive `Bash(<path under $GITHUB_WORKSPACE> *)` rule would let a PR
    simply replace the wrapper script with an arbitrary executable while the identical
    permission-rule path still authorized running it. Fixed the same way this repo already closes
    the identical class for `REVIEW_RULES.md`/`DESIGN.md` base-pinning: a dedicated "Resolve
    read-only git wrapper (base-pinned)" step reads the wrapper's content from the PR's **base**
    commit via `git show`, writes it to `$RUNNER_TEMP` (never the checked-out working tree), and
    every `--allowedTools`/context-note reference points at that resolved path — preceded by the
    same "Validate PR base/head SHAs" check `action.yml` already has, on this surface too. A
    Way-A installer who genuinely needs `trusted` edits that vendored file directly, same as
    before.
  - Every runtime's generated per-run prompt tells the agent to call the wrapper in place of raw
    `git` when `readonly` is active (`cli/lib/execution.sh`'s `pantheon_execution_context_note`,
    templated into all three prompt-builders — `cli/review-gate`'s `build_prompt()`,
    `action/lib/build_prompt.sh`, and `action/review.yml`'s inline copy) — the persona files
    themselves stay install-agnostic (DESIGN.md rule 4) and can't embed a path that differs per
    install, so the per-run context block is where that substitution is told.
  - Codex, Gemini, and Cursor's provider lanes have no equivalent tool-scoping mechanism in
    their own CLIs as of v1, so this tiering currently applies to the Claude lane — the only
    integration-tested one — across all three surfaces that invoke it; that gap is disclosed,
    not silently assumed closed.
  - **What the wrapper closes today, in full: `cli/lib/pantheon-git-readonly.sh`'s own header
    comment** is the single canonical enumeration (every git config key, attribute, or
    environment variable that names an executable or a write target, checked against git's own
    docs for reachability from the four allowlisted subcommands with no explicit model-supplied
    flag — vector → neutralization → verification status). Read that file directly rather than
    duplicating the table here. Getting there took eight rounds of individual Codex/Apollo
    findings against this same wrapper, each reproduced live against the pre-fix version before
    the fix landed: [docs/HARDENING-HISTORY.md](docs/HARDENING-HISTORY.md).
- **Provider processes launch from a neutral cwd, never the repo checkout — the CLI (Python)
  lane only, an adversarial-review fix.** `--allowedTools`/the read-only wrapper scope what a
  provider CLI's *tool calls* can do, but a provider CLI's own STARTUP also auto-discovers
  repo-local configuration from its current working directory — entirely before any tool call,
  entirely outside `--allowedTools`'s reach: a PR-committed `.mcp.json` (Claude Code auto-loads
  and SPAWNS every listed MCP server — arbitrary command execution, not a scoped tool call), a
  PR-committed `.claude/settings.json` (hooks that fire on tool events, including an ALLOWED
  `Read`), or `CLAUDE.md`-style project-memory files (PR-controlled prompt content injected
  before this repo's own persona framing ever runs). Live-reproduced by the reviewer with a fake
  `claude` binary that printed which MCP servers it would spawn and confirmed a PR-committed hook
  would fire on an allowed `Read`. Closed with three layers, none alone sufficient:
  1. `pantheon.cli` creates a scratch directory it owns (never the checkout, never anywhere
     inside it) and passes it as every provider's own `cwd` (`pantheon.providers`' `neutral_cwd`
     parameter) — nothing repo-local for a provider's own startup-time scan to find. The agent
     still reaches repo content exclusively through the readonly git wrapper (now told the real
     repo root via a fixed `--repo-root` literal baked into its own Bash-tool permission prefix —
     see `pantheon.cli._wrapper_invocation`) and explicit `Read`/`Grep`/`Glob` calls against the
     repo root's own now-advertised absolute path (the prompt's Run-context block; previously
     only the basename).
  2. The claude lane also passes `--bare` — verified against Claude Code's current official
     headless docs before adding, not assumed: documented to skip auto-discovery of hooks,
     skills, plugins, MCP servers, auto memory, and CLAUDE.md, in one flag, layered on top of (not
     instead of) the neutral cwd. Codex/Gemini/Cursor have **no documented equivalent flag** as of
     this writing (each CLI's own current official docs were checked) — a disclosed, honest
     residual exposure for those three best-effort lanes, narrowed (nothing repo-local in a
     neutral cwd) but not eliminated, not silently treated as closed.
  3. `pantheon.providers._PROVIDER_ENV_PASSTHROUGH_KEYS` (the explicit env allowlist every
     provider subprocess receives) was re-audited against "does this key exist only because it's
     convenient, or because a named lane's documented auth/locale surface genuinely needs it" —
     every key survived; none were removed (each ties to a specific lane's documented env-var
     auth mechanism, a locale/temp-dir convention every listed CLI needs to run, or the
     proxy-transport fix a prior Codex wave already justified).
  - **A consequence of exposing the repo's absolute path (step 1 above) that needed its own
    close: the reviewing model can echo that path back into a finding's own text, which then
    reaches the POSTED PR comment.** On a CI runner that's a harmless ephemeral path; on a CLI-lane
    run from a maintainer's own machine it's their real home directory (often containing their
    username), published into what may be a public PR — an information-disclosure regression an
    otherwise-correct fix would have introduced. Closed mechanically, not by asking the persona
    nicely: `pantheon.render`'s existing sanitize-at-render chokepoint (`sanitize_inline` — the
    same function DESIGN.md's "Validation surface" section already describes as the one place
    every model-controlled display field is sanitized before it reaches a comment) now also
    redacts every occurrence of the repo's absolute path to the placeholder `<repo>`, in every
    human-readable field AND the machine-tail raw-JSON block (the same information would otherwise
    just resurface there, unredacted). The prompt's own Run-context block additionally tells the
    persona explicitly that findings must cite repo-RELATIVE paths (belt-and-suspenders — never
    the primary control, since prompt instructions are advisory, not enforced). Fixture:
    `tests/test-render-comment-python.sh`'s repo-root-redaction case — a verdict whose summary/
    issue/file/scenario contain the absolute repo root renders with every occurrence replaced by
    `<repo>`, including the machine tail, with a regression-direction guard proving the redaction
    is opt-in (via `PANTHEON_REPO_ROOT`) and doesn't fire when unset.
- **Every `gate.conf` key that shapes gate BEHAVIOR is base-pinned, not just `execution=` — an
  adversarial-review fix generalizing a class this repo's own docs/CLI.md had already disclosed
  as unfixed (issue #13, for `provider=` specifically).** `provider=`/`rules_file=`/`spec_file=`/
  `agents=` now resolve from the PR's BASE commit only (`pantheon.cli._load_base_pinned_gate_conf`
  — one `git show`+parse for all five keys alongside `execution=`), the identical mechanism and
  identical `gh pr checkout <n>`-before-invoking-the-CLI trust boundary `execution=`'s own
  base-pinning already existed to close: a working-tree-sourced `provider=` could point at any
  known lane, silently swapping WHICH agent CLI's own judgment gates the merge; a working-tree-
  sourced `rules_file=`/`spec_file=` could redirect either key at a path absent at base, silently
  downgrading the base-pinned CONTENT read's own loud "not present" fallback into a full bypass
  of the real house rules/spec without ever touching their trusted text; a working-tree-sourced
  `agents=` could swap the enforcing twin panel for a weaker or non-blocking list. `model=`/
  `base_branch=` remain working-tree-sourced — neither affects tool-execution breadth or which
  file is trusted as a judgment boundary — see the "Read → provenance matrix" table above for the
  current split. An explicit `--provider`/`--agents` CLI flag still wins, exactly like
  `--execution` already did over its own base-pinned default — this closes PR-controlled
  CONFIGURATION, never an operator's own explicit, interactively-typed choice.
- **`REVIEW_RULES.md`/`DESIGN.md` are now base-pinned on the vendored workflow (`action/review.yml`)
  too — an adversarial-review fix closing this surface's own disclosed exception, see "Surface
  differences" below.** This step's "Build prompt" step used to only PRESENCE-CHECK these two
  files at `$GITHUB_WORKSPACE` (the PR's own HEAD checkout) and tell the agent "present — go read
  it"; the agent then read the actual CONTENT live from that same PR-controlled working tree via
  its own `Read` tool, entirely outside base-pinning — a reviewer built a working PoC (a PR
  editing `REVIEW_RULES.md` on its own head to add a favorable house rule, applied verbatim).
  Fixed the identical way the wrapper/persona/pantheon-package reads on this same surface already
  are: `pantheon_base_pinned_read` resolves CONTENT from the PR's BASE commit into `$RUNNER_TEMP`,
  fenced with the same randomized BEGIN/END anti-collision markers `action/lib/build_prompt.sh`
  already uses for this content, now added to this step's own inline copy alongside them.
- **`PR_TITLE`/`BASE_REF` are now fenced with the same randomized-marker treatment file content
  already got, on both Action surfaces** (`action/review.yml`'s inline "Build prompt" step,
  `action/lib/build_prompt.sh`) — an adversarial-review finding: these two PR-event-context
  values were interpolated straight into the surrounding prose unfenced, while base-pinned file
  content got the anti-injection BEGIN/END treatment. `PR_TITLE` specifically is PR-author-
  controlled data; both now get the identical fence-and-label treatment, at a smaller scale.
- **Honest limit on all of the above.** None of this — metadata validation, base-SHA pinning,
  randomized data-block fences, verdict schema/type validation, the blocker invariant,
  untrusted-data persona framing (every persona is told explicitly that everything it reads is
  data, not instructions, and that a directive found inside it is itself a reportable finding —
  see `agents/*.md`'s "Untrusted data, not instructions"), or default-readonly execution —
  eliminates the risk of a schema-valid, deceptive verdict from an agent that injected content
  has fully compromised. Together they raise the bar and make an attempt more visible (an
  injection attempt is itself a flagged finding, not a silent verdict flip) rather than making
  one impossible. Cross-review by a second independent agent (Artemis vs. Apollo) is the
  mitigation against any one agent being fooled — not a guarantee against it.

## Follow-up mode (CLI surface only)

Re-reviewing a PR after new commits reviews `last_reviewed_sha..head`, and the prompt tells the
agent to read its own prior PR comment instead of re-auditing from scratch. Reviewed SHAs are
tracked in `.review-gate-state.json` (bootstraps empty; git-ignored only via the `install.sh`
Way-A path — see [CLI.md](docs/CLI.md#the-state--follow-up-model) for the other install paths),
written by `update_review_gate_state()` **only for a green or yellow overall outcome** — a red or
UNVERIFIED result (a transient provider timeout, a malformed model response, anything that
didn't actually gate the PR) leaves the file untouched, so the next run retries from the last
SUCCESSFULLY recorded SHA (the full PR only if there was never one) instead of treating a failed
run as if it had reviewed anything. A prior version of this write ran unconditionally after any
successful `gh pr comment` post regardless of the computed verdict, which meant an UNVERIFIED
result still marked the head reviewed and a follow-up run would only re-review what changed since
a run that never actually gated anything — see `tests/test-state-persistence.sh` for the fixture
proving both directions. This is a CLI-only feature, kept deliberately: the Action re-reviews the
full diff on every push already (a fresh runner, no persisted state between runs, and GitHub's own
UI shows the diff since your last review anyway), but a human running `review-gate` repeatedly
against the same long-lived PR would otherwise burn a full review's worth of tokens on every
incremental commit. A reviewer recommended cutting follow-up mode for simplicity; we kept it — the
token-cost problem it solves is real for the CLI surface and doesn't exist for the Action.

## Surface differences

The CLI and the Action share personas and the verdict-decision rule, but they are not
identical tools. Differences are intentional, not oversights:

| | CLI (`cli/review-gate`) | GitHub Action (`action/review.yml`) |
|---|---|---|
| Follow-up mode | Yes — incremental diff since last reviewed SHA (see above). | No — re-reviews the full diff on every push; no state persisted between runs. |
| Configuration | `gate.conf` (provider, model, base branch, rules file, agent list, execution tier). | None — twin panel (artemis, apollo), `REVIEW_RULES.md`, and the read-only execution tier are hardcoded in the workflow. |
| Provider choice | Pluggable lane (`--provider`, `cli/providers/*.sh`); Claude is the only integration-tested one. | Claude only, via `anthropics/claude-code-action`. |
| Draft handling | Detects `isDraft` via `gh pr view`; exits 0, prints `DRAFT — not reviewed, nothing posted` to stdout, posts nothing. | Job-level `if: github.event.pull_request.draft == false` skips the run entirely; nothing posted. Same outcome (no review, no comment), different mechanism. |
| Rules/spec file provenance | Base-SHA-pinned (`git show <base-sha>:<path>`) — see "Security posture" above. | Base-SHA-pinned into `$RUNNER_TEMP` (closed by an adversarial-review fix — this surface's inline "Build prompt" step is still a third, hand-synced copy of the prompt-build logic, see "Layout" below, but it now resolves rules/spec CONTENT the same way its "Resolve gate scripts (base-pinned)" step already resolves the persona/pantheon-verdict trio, instead of presence-checking `$GITHUB_WORKSPACE` and letting the agent read live PR-head content). This closes what was the one remaining open item in issue #6's provenance sweep on this surface — see "Security posture" above for the fix and its own PoC. |
| Persona / verdict-decider provenance | N/A — always `$PANTHEON_ROOT/agents` and `cli/lib/verdict.sh`, this repo's own installed copy; the target repo never supplies these on the CLI surface. | Base-pinned on both GitHub Action surfaces, same as the CLI's non-issue: the published `action.yml` reads `$ACTION_PATH/agents` and `$ACTION_PATH/action/decide_verdict.py` by default (this repo's own trusted checkout), base-pinned into `$RUNNER_TEMP` when `personas_path` opts into reading from the target repo instead; `action/review.yml` (a **different** file from this table's column) base-pins both into `$RUNNER_TEMP` via its own "Resolve gate scripts (base-pinned)" step (issue #6 — closed in this PR; previously read straight from `$GITHUB_WORKSPACE`, the PR's own checkout, same class as the read-only git wrapper fix above). |

## Published action

`action.yml` at the repo root is a **third** surface on top of the CLI and the vendored
`action/review.yml`: a composite GitHub Action a target repo consumes with a `uses:
G-Schumacher44/review-pantheon@v1` reference and nothing else — zero files land in that repo
(contrast with `install.sh`'s Way A, which vendors personas + `action/review.yml` + a deprecated
`decide_verdict.py` compat shim + the `pantheon` package's verdict-decision module
(`pantheon/__init__.py`, `pantheon/jqjson.py`, `pantheon/verdict.py` — the base-pinned trio
`action/review.yml`'s own decide step now runs by invoking `pantheon/verdict.py`'s own absolute
path, never `python3 -m pantheon.verdict` — see "Two runtimes, one rule" above for why) into the
target repo precisely so its own runner can see them; the published action instead reads all of
that from its own checkout at `github.action_path`, the copy GitHub Actions pulls for the
`uses:` reference). `examples/review-gate.yml` is the whole consumer-side install — copy it to
`.github/workflows/review-gate.yml` and wire one secret.

- **Bundled personas, overridable.** `agents/*.md` in this repo is read by default
  (`github.action_path/agents`); a target repo can point `personas_path` at its own directory
  instead (e.g. a repo-local fork of a persona) without forking this repo.
- **`agents` input, same fixed five.** Same panel DESIGN.md defines everywhere else —
  `artemis apollo socrates diogenes plato` — default `"artemis apollo"`, the standard gate.
- **Sequential, not matrix — a real tradeoff, not an oversight.** `action/review.yml` runs
  Artemis and Apollo as two matrix legs (parallel), passing results between jobs via
  upload/download-artifact because matrix legs can't expose distinct job outputs to a
  downstream job. A **composite action cannot use `strategy`/`matrix` at all** — that's a
  job-level-only GitHub Actions concept, verified against GitHub's own composite-action docs,
  not assumed — so `action.yml` runs every enabled agent sequentially in one job instead. The
  payoff is simplicity: no artifact round-trip, no separate job, one `uses:` line for the
  consumer; the cost is wall-clock (N agents run one after another). Given this surface exists
  specifically for the simplest possible install, that tradeoff was made on purpose.
- **The `anthropics/claude-code-action` pin is now real**, not a placeholder — see the
  "Security posture" section above for the SHA, the release, and where it was verified.
- **Fail-closed still applies.** Every agent step in `action.yml` runs with
  `continue-on-error: true` (so a provider failure or a red/unverified verdict never halts the
  action before it can post a comment and report the result), and the action's own final step
  fails the job on red or unverified — same posture as the CLI's exit code and
  `action/review.yml`'s decide step, just phrased for a composite action's constraints (no
  `if: always()` chains needed when nothing upstream is allowed to hard-fail in the first
  place — see `action.yml`'s own header comment for the composite-action mechanics this
  relies on and what was verified about them, including that `steps.<id>.outcome` inside a
  composite action was historically broken and has since been fixed upstream).

**Honest limitation:** this action can't be integration-tested end-to-end — a real `uses:
G-Schumacher44/review-pantheon@v1` invocation against a real PR — until this repo is public on
GitHub (a private repo's actions aren't resolvable via a bare `owner/repo@ref` reference from
another repo without extra token plumbing this project doesn't want to require). Until then,
`.github/workflows/ci.yml`'s `composite-action-self-check` job covers what CAN be verified
without that: `action.yml` and `examples/*.yml` parse as YAML, every file `action.yml`
references under `github.action_path` actually exists, and the embedded/added shell scripts
pass `bash -n` and shellcheck (already true via the repo-wide shellcheck job for the two new
`action/lib/*.sh` files).

## Deliberately absent

- No fleet/multi-repo sweep — the gate runs on one repo, from that repo. Loop it yourself.
- No third-party reviewer integration (e.g. bot-review aggregation) — extension point, not core.
- No auto-merge, ever. The gate posts a verdict; a human merges.
- No write access needed beyond posting one PR comment.
- No review of draft PRs, on either surface — see "Surface differences" above for how each
  surface enforces that.

## Layout

```
pantheon/                  the current CLI (docs/PYTHON-PORT.md) — `pantheon gate`/`pantheon
                           counsel`, stdlib-only, pipx/pip-installable (pyproject.toml). Also the
                           sole implementation of the verdict-decision rule as of port slice 5
                           (see "Two runtimes, one rule" above): `pantheon/verdict.py`, called by
                           both the CLI and the Action lanes. `pantheon.reviewgate_shim`
                           (`review-gate` console script) is a one-release deprecated compat
                           shim, not a second implementation.
agents/                    five canonical personas (the single source of truth), plus
                           __init__.py — a packaging-only marker (no code, no re-exports) so
                           setuptools ships this directory as `pantheon.agents` in the wheel
                           (pyproject.toml's package-dir remap); invisible to every consumer
                           that reads the *.md files directly (bash CLI, install.sh,
                           bootstrap.sh, action.yml/action/review.yml) — see the file's own
                           header comment
skills/                    four canonical Claude Code skills (gate, counsel, spec-driven,
                           design-contract) — the single hand-maintained source, same shape as
                           agents/ under rule 4; install.sh --claude copies them verbatim into
                           .claude/skills/<name>/SKILL.md, never regenerated
cli/review-gate            DEPRECATED (port slice 5, one-release compat window) — the bash
                           runner: builds prompts, calls a provider lane, validates verdicts,
                           posts ONE combined PR comment. `pantheon gate` (above) is the current
                           CLI; this stays present, unchanged, only for the transition — see its
                           own header comment and docs/PYTHON-PORT.md section 7
cli/lib/verdict.sh         extraction + verdict-decision (blocker invariant included) —
                           sourced by cli/review-gate AND tests/test-verdict-decision.sh
cli/lib/render_comment.sh  the combined-comment renderer — sourced by cli/review-gate AND
                           action/lib/combine_verdicts.sh (see "Combined PR comment" below)
cli/lib/execution.sh       tiered tool-execution policy (readonly default, trusted opt-in) —
                           sourced by cli/review-gate, exported to cli/providers/claude.sh via
                           PANTHEON_ALLOWED_TOOLS; also sourced by action/lib/build_prompt.sh
                           for the per-run execution context note (see "Security posture" above)
cli/lib/pantheon-git-readonly.sh  the argv-validating read-only git wrapper the readonly tier
                           routes Bash through instead of a bare command-prefix pattern —
                           vendored by bootstrap.sh (CLI surface) and install.sh
                           (.github/review-agents/, for action/review.yml); read in place by
                           action.yml from its own checkout (see "Security posture" above)
cli/lib/pantheon-base-pin.sh  symlink-safe base-pinned reads (issue #6's class, round-2:
                           a bare `git show $BASE_SHA:path` on a symlinked path returns the
                           link-target STRING, not the target's content) — sourced by
                           cli/review-gate and by action.yml's "Resolve gate configuration"
                           step; vendored by bootstrap.sh (CLI surface) into the bootstrap prefix
                           alongside cli/lib/execution.sh and cli/lib/pantheon-git-readonly.sh
                           (unlike that wrapper, install.sh does NOT separately vendor this file
                           — action/review.yml carries its own hand-synced inline copy instead (a
                           target repo never gets cli/lib/ — same reason as the prompt-build
                           logic it already hand-syncs, see "Surface differences" below))
cli/providers/             provider lanes (claude, codex, gemini, cursor)
action/review.yml          GitHub Actions twin gate — one matrix job (artemis, apollo legs),
                           artifact-based result passing, fail-closed decision step
action/decide_verdict.py   DEPRECATED (port slice 5, one-release compat window) — a thin shim
                           delegating to `pantheon.verdict`, the now-sole implementation of the
                           verdict-decision rule (see "Two runtimes, one rule" above). Neither
                           `action.yml` nor `action/review.yml` calls this file anymore (both
                           invoke `pantheon/verdict.py` by its own absolute path directly,
                           never `python3 -m pantheon.verdict` — see "Two runtimes, one rule"
                           above); still vendored by
                           install.sh, unchanged, only so nothing scripting against it directly
                           breaks mid-transition
action/lib/                shared shell helpers for action.yml (build_prompt.sh,
                           combine_verdicts.sh) — combine_verdicts.sh sources
                           cli/lib/render_comment.sh (relative path, safe because the
                           published action ships this whole repo); NOT used by
                           action/review.yml, which keeps its prompt-build and comment-post
                           logic inline and hand-synced (see "Published action" above and
                           "Combined PR comment" below for why that one surface still differs)
action.yml                 the published composite action (see "Published action" above) —
                           the whole install for a target repo is examples/review-gate.yml
examples/review-gate.yml   the ~20-line consumer stub for action.yml; the entire footprint of
                           the published-action surface in a target repo
tests/                     20 fixture-test scripts (13 one-per-seam, six Python-port black-box
                           equivalents docs/PYTHON-PORT.md's Slices 2 through 4 added, plus the
                           pantheon/jqjson.py JSON-boundary mechanical assertion Slice 2's
                           follow-up round added — see that doc's sections 4 and 5) —
                           CONTRIBUTING.md's dev-setup table is the canonical, complete list
                           (verified against
                           `git ls-tree -r tests/`; CI asserts the two stay in sync). Don't
                           re-list them here — that's exactly the forked-inventory shape rule 5
                           exists to prevent.
install.sh                 idempotent installer into a target repo (refuses to clobber
                           customized files); does not install gate.conf; --claude/--cursor/
                           --codex/--gemini generate per-tool projections of agents/*.md for
                           in-session use (see "Generated per-tool projections" above)
bootstrap.sh                user-level, repo-independent CLI install (Way B) — a single
                           self-contained script (no shared lib, deliberately, since the
                           curl|bash install path fetches it alone); --version vX.Y.Z pins the remote-
                           fetch path to a tagged, checksum-verified GitHub Release instead of
                           dev's current HEAD (see RELEASING.md and .github/workflows/
                           release.yml below)
.github/workflows/release.yml  tag-push (`v*.*.*`, strict-semver-validated) release gate: re-
                           runs ci.yml's lint-and-test suite pinned at the tag, then builds the
                           versioned CLI-surface tarball + SHA256SUMS and publishes both as a
                           GitHub Release
RELEASING.md                the operator's release ceremony — dev green, dev->main promotion
                           PR, tagging main, moving the v1 major tag, post-release verification
docs/                      anything that doesn't fit above
```
