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
  He assumes nothing was done until evidence shows it was.

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
  in sync on this.
- A docs-only diff (only `*.md` / `docs/**` changed) may skip Apollo with a loud 🟡 skip note.

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
agents=artemis apollo    # panel for the standard gate
```

## Security posture (kept from the private ancestor, by design)

- PR metadata is attacker-controlled on forks: the gate validates PR number (`^[0-9]+$`),
  branch names (`^[A-Za-z0-9._/-]+$`), and head SHA (hex) before any of them touch a prompt
  or a shell command. Unsafe metadata → UNVERIFIED, not a crash.
- Model output is never interpolated into shell (`run:`) directly — it travels via files and
  env vars.
- The GitHub Action checks out with `persist-credentials: false` and fails loud (not skip)
  when its token secret is absent. It does **not** yet pin `anthropics/claude-code-action` to
  a commit SHA — it ships with a loud placeholder, `PIN-ME-TO-A-FULL-COMMIT-SHA`, that refuses
  to run until you replace it (an unpinned `uses:` fails at job parse/resolve time with an
  obvious error, it doesn't silently no-op or run unpinned). Pinning it is step one of the
  install checklist (`install.sh`'s printed output and the README quickstart), not optional
  follow-up.

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
                           verdicts, posts ONE combined PR comment (signal headline +
                           verdict table + folded findings)
cli/lib/verdict.sh         extraction + verdict-decision (blocker invariant included) —
                           sourced by cli/review-gate AND tests/test-verdict-decision.sh
cli/providers/             provider lanes (claude, codex, gemini, cursor)
action/review.yml          GitHub Actions twin gate — one matrix job (artemis, apollo legs),
                           artifact-based result passing, fail-closed decision step
action/decide_verdict.py   the Action's verdict-decision rule (Python twin of
                           cli/lib/verdict.sh — see "Two runtimes, one rule"); installed into
                           the target repo, not embedded in the workflow YAML
tests/                     tests/test-verdict-decision.sh — cross-runner fixture test;
                           tests/test-install.sh — install.sh editor/CLI lane fixture test
install.sh                 idempotent installer into a target repo (refuses to clobber
                           customized files); does not install gate.conf; --claude/--cursor/
                           --codex/--gemini generate per-tool projections of agents/*.md for
                           in-session use (see "Generated per-tool projections" above)
docs/                      anything that doesn't fit above
```
