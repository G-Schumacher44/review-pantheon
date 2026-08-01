# Design — review-pantheon

Five read-only agents, split by what their verdict does: two gate agents (Artemis, Apollo) whose
verdicts **enforce** — wired into a fail-closed PR gate that can block a merge — and three
counsel agents (Socrates, Diogenes, Plato) whose verdicts **inform** a human's decision and never
gate or block, regardless of what they're pointed at: a spec, a design doc, a proposal, existing
code, or a diff. Agent-CLI-agnostic: Claude-first, with pluggable provider lanes (Codex, Gemini,
Cursor). This document is the contract — the personas, runners, and workflow are all
implementations of what's written here. See `docs/README.md` for a full doc index.

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

## Hard rules (non-negotiable, all agents, all providers)

1. **Read-only.** Agents inspect via read-only git (`git show <ref>:path`, `git diff`,
   `git log`, `git status`). They never run `stash` / `checkout` / `switch` / `reset` /
   `merge` / `commit` / `branch` / `rebase` or anything that mutates the tree, index, or HEAD.
   If a check would require a tree change, the agent stops and reports it as a gap.
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

- `claude.sh` — `claude -p` with a restricted tool set (Read, Grep, Glob, Bash) and a timeout.
  Default lane; the only one integration-tested in v1.
- `codex.sh` — `codex exec` non-interactive.
- `gemini.sh` — `gemini` CLI non-interactive prompt mode.
- `cursor.sh` — `cursor-agent` headless.

The gate never trusts a lane to be well-behaved: it extracts the trailing JSON object from
stdout, validates it against the contract with `jq`, and treats any failure as UNVERIFIED.
Provider selection: `--provider <lane>` flag, else `provider=` in config, else `claude`.
Prompts are built identically for every lane: persona file + a generated context block (diff
range, base branch, house-rules file, output-contract reminder). No lane gets a private fork
of a persona.

## Generated per-tool projections (interactive/editor lanes)

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
  `.claude/agents/`. A generated `/counsel` command (`.claude/commands/counsel.md`) wraps
  Socrates, Diogenes, and Plato into one invocation that runs Socrates first on an open
  decision, the other two on a proposed shape, and synthesizes their verdicts.
- **Cursor, Codex, Gemini (`--cursor`/`--codex`/`--gemini`)** — best-effort, same posture the
  provider lanes already take with unverified CLIs: each tool's repo-level custom-command (or
  closest equivalent) convention was checked against that tool's own current official docs
  before implementing, not assumed from Claude Code parity. Where a tool has no repo-level
  command convention at all, `install.sh` says so and skips it rather than inventing one — see
  the flag's own comment block in `install.sh` and the README's "Provider lanes" section for
  what was verified vs. best-effort, and against which source, per tool.

## Two runtimes, one rule

The CLI runner and the GitHub Action are separate processes on separate runtimes — bash+jq for
the CLI (`cli/lib/verdict.sh`), Python for the Action (`action/decide_verdict.py`, installed
into the target repo and run from there, not embedded in the workflow YAML). That split is
accepted deliberately: the Action can't cleanly `source` a bash file across its step
boundaries, and the CLI shouldn't require a Python interpreter just to run `review-gate`. Two
implementations of the same rule is normally the kind of drift rule 4 warns against for
personas — the mitigation here is the same shape as that rule's, applied to code instead of
prose: both files carry a comment pointing at the other, and
`tests/test-verdict-decision.sh` runs the same fixture set through both and fails if they
disagree with each other or with the expected result. They must implement identically:
- the same per-agent verdict vocabulary → color map,
- the same fail-closed rule (missing/unparseable/out-of-vocabulary verdict → unverified),
- the same blocker invariant (see the verdict contract above).

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
action's renderer), so the CLI lane and the published-action lane read identically by
construction, not by hand-kept-in-sync wording. `action/review.yml` (the vendored,
install.sh-Way-A workflow) is the one lane that still can't reach it — a target repo never gets
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

`gate.conf` in the target repo root (simple `key=value`, all optional) — **CLI lane only**; the
Action doesn't read it (see "Lane differences" below). `install.sh` does not install it —
CLI-lane users copy `gate.conf.example` themselves (README documents this under CLI usage).

```
provider=claude          # lane in cli/providers/
model=                   # lane-specific model id; empty = lane default
base_branch=main         # merge base for the review diff
rules_file=REVIEW_RULES.md
spec_file=DESIGN.md      # governing spec, Apollo-only context; only-if-exists; empty disables
agents=artemis apollo    # panel for the standard gate
```

## Security posture (kept from the private ancestor, by design)

- PR metadata is attacker-controlled on forks: the gate validates PR number (`^[0-9]+$`),
  branch names (`^[A-Za-z0-9._/-]+$`), and head SHA (hex) before any of them touch a prompt
  or a shell command. Unsafe metadata → UNVERIFIED, not a crash.
- Model output is never interpolated into shell (`run:`) directly — it travels via files and
  env vars.
- **Base-SHA-pinned context file reads.** `REVIEW_RULES.md` and the spec file (`DESIGN.md` by
  default) are read via `git show <base-sha>:<path>` — the PR's BASE commit — never from the
  checked-out working tree. This closes a fork-PR instruction-injection class: on a fork PR,
  the working tree at review time can hold the PR author's own edits to those files, and a
  rules/spec file read from there would let whoever opened the PR inject content straight into
  the reviewing agents' prompts (e.g. a house "rule" that tells the reviewer to wave everything
  through). A file the PR itself adds or edits only on its head is never read for this purpose;
  when it's absent at the base commit, the CLI lane (`cli/review-gate`'s `build_prompt()`) and
  the published action lane (`action.yml`'s "Resolve gate configuration" step +
  `action/lib/build_prompt.sh`) fall back to omitting it — a loud "not present at base — not
  applied" note for the always-on house-rules file, the same pre-existing silent skip as when
  it's absent entirely for the only-if-exists spec file. `action/review.yml` (the vendored,
  install.sh-Way-A workflow) is not part of this fix — see "Lane differences" below.
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

## Follow-up mode (CLI lane only)

Re-reviewing a PR after new commits reviews `last_reviewed_sha..head`, and the prompt tells the
agent to read its own prior PR comment instead of re-auditing from scratch. Reviewed SHAs are
tracked in `.review-gate-state.json` (git-ignored; bootstraps empty). This is a CLI-only
feature, kept deliberately: the Action re-reviews the full diff on every push already (a fresh
runner, no persisted state between runs, and GitHub's own UI shows the diff since your last
review anyway), but a human running `review-gate` repeatedly against the same long-lived PR
would otherwise burn a full review's worth of tokens on every incremental commit. A reviewer
recommended cutting follow-up mode for simplicity; we kept it — the token-cost problem it
solves is real for the CLI lane and doesn't exist for the Action.

## Lane differences

The CLI and the Action share personas and the verdict-decision rule, but they are not
identical tools. Differences are intentional, not oversights:

| | CLI (`cli/review-gate`) | GitHub Action (`action/review.yml`) |
|---|---|---|
| Follow-up mode | Yes — incremental diff since last reviewed SHA (see above). | No — re-reviews the full diff on every push; no state persisted between runs. |
| Configuration | `gate.conf` (provider, model, base branch, rules file, agent list). | None — twin panel (artemis, apollo) and `REVIEW_RULES.md` are hardcoded in the workflow. |
| Provider choice | Pluggable lane (`--provider`, `cli/providers/*.sh`); Claude is the only integration-tested one. | Claude only, via `anthropics/claude-code-action`. |
| Draft handling | Detects `isDraft` via `gh pr view`; exits 0, prints `DRAFT — not reviewed, nothing posted` to stdout, posts nothing. | Job-level `if: github.event.pull_request.draft == false` skips the run entirely; nothing posted. Same outcome (no review, no comment), different mechanism. |
| Rules/spec file provenance | Base-SHA-pinned (`git show <base-sha>:<path>`) — see "Security posture" above. | Still reads `REVIEW_RULES.md`/`DESIGN.md` straight from the checked-out working tree (this lane's inline "Build prompt" step is a third, hand-synced copy of the prompt-build logic — see "Layout" below — and wasn't brought forward in this fix). The published `action.yml` lane (a **different** file from this table's `action/review.yml` column) got the same base-pinning as the CLI. |

## Published action

`action.yml` at the repo root is a **third** lane on top of the CLI and the vendored
`action/review.yml`: a composite GitHub Action a target repo consumes with a `uses:
G-Schumacher44/review-pantheon@v1` reference and nothing else — zero files land in that repo
(contrast with `install.sh`'s Way A, which vendors personas + `action/review.yml` +
`decide_verdict.py` into the target repo precisely so its own runner can see them; the
published action instead reads all of that from its own checkout at `github.action_path`, the
copy GitHub Actions pulls for the `uses:` reference). `examples/review-gate.yml` is the whole
consumer-side install — copy it to `.github/workflows/review-gate.yml` and wire one secret.

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
  consumer; the cost is wall-clock (N agents run one after another). Given this lane exists
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
- No review of draft PRs, on either lane — see "Lane differences" above for how each lane
  enforces that.

## Layout

```
agents/                    five canonical personas (the single source of truth)
cli/review-gate            the runner: builds prompts, calls a provider lane, validates
                           verdicts, posts ONE combined PR comment (see "Combined PR comment"
                           below)
cli/lib/verdict.sh         extraction + verdict-decision (blocker invariant included) —
                           sourced by cli/review-gate AND tests/test-verdict-decision.sh
cli/lib/render_comment.sh  the combined-comment renderer — sourced by cli/review-gate AND
                           action/lib/combine_verdicts.sh (see "Combined PR comment" below)
cli/providers/             provider lanes (claude, codex, gemini, cursor)
action/review.yml          GitHub Actions twin gate — one matrix job (artemis, apollo legs),
                           artifact-based result passing, fail-closed decision step
action/decide_verdict.py   the Action's verdict-decision rule (Python twin of
                           cli/lib/verdict.sh — see "Two runtimes, one rule"); installed into
                           the target repo, not embedded in the workflow YAML — also read
                           in-place by action.yml (see below), never installed for that lane
action/lib/                shared shell helpers for action.yml (build_prompt.sh,
                           combine_verdicts.sh) — combine_verdicts.sh sources
                           cli/lib/render_comment.sh (relative path, safe because the
                           published action ships this whole repo); NOT used by
                           action/review.yml, which keeps its prompt-build and comment-post
                           logic inline and hand-synced (see "Published action" above and
                           "Combined PR comment" below for why that one lane still differs)
action.yml                 the published composite action (see "Published action" above) —
                           the whole install for a target repo is examples/review-gate.yml
examples/review-gate.yml   the ~20-line consumer stub for action.yml; the entire footprint of
                           the published-action lane in a target repo
tests/                     tests/test-verdict-decision.sh — cross-runner fixture test;
                           tests/test-install.sh — install.sh editor/CLI lane fixture test;
                           tests/test-action-refs.sh — asserts every file action.yml
                           references under github.action_path actually exists;
                           tests/test-render-comment.sh — combined-comment renderer fixture
                           test (see "Combined PR comment" below);
                           tests/test-prompt-assembly.sh — spec-aware Apollo prompt-assembly
                           fixture test across all three runtimes (action/lib/build_prompt.sh,
                           cli/review-gate's build_prompt(), action/review.yml's inline copy),
                           including the cross-runner wording-identity check
install.sh                 idempotent installer into a target repo (refuses to clobber
                           customized files); does not install gate.conf; --claude/--cursor/
                           --codex/--gemini generate per-tool projections of agents/*.md for
                           in-session use (see "Generated per-tool projections" above)
docs/                      anything that doesn't fit above
```
