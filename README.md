<!-- banner: docs/assets/banner.png — to be added -->

<div align="center">

[![CI](https://github.com/G-Schumacher44/review-pantheon/actions/workflows/ci.yml/badge.svg)](https://github.com/G-Schumacher44/review-pantheon/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![fail-closed by design](https://img.shields.io/badge/fail--closed-by%20design-brightgreen)](#how-the-gate-stays-honest)
[![providers](https://img.shields.io/badge/providers-claude%20%7C%20codex%20%7C%20gemini%20%7C%20cursor-blue)](#provider-lanes)

</div>

# review-pantheon — a fail-closed AI review gate and counsel panel for spec-driven development

- AI-assisted, spec-driven development produces work faster than a human can independently
  verify it — the bottleneck moves from writing the change to trusting the report of it.
- Most "AI code review" collapses two different questions into one pass: does the diff look
  right, and did the PR actually do what it claims. A single reviewer answering both tends to
  skim the code for red flags and take the description mostly on faith.
- A pass with no fail-closed rule turns a missing, empty, or malformed verdict into a quiet
  green — the one failure mode that's worse than an honest red.

## What review-pantheon is

A portable review gate — a GitHub Action plus a provider-agnostic CLI — built around **five
read-only agent personas** (`agents/*.md`), split into two tiers: two **gate agents** (Artemis,
Apollo) whose verdicts enforce and can block a merge, and three **counsel agents** (Socrates,
Diogenes, Plato) whose verdicts inform a human decision and never gate.

The verdict-decision rule — trailing-JSON extraction, schema validation, the blocker invariant —
is implemented **twice, once per runtime** (`cli/lib/verdict.sh` in bash, `action/decide_verdict.py`
in Python) and kept in sync by **9 cross-runner fixtures** in `tests/test-verdict-decision.sh`.
**4 provider lanes** (`cli/providers/{claude,codex,gemini,cursor}.sh`) plug into the same CLI —
Claude is the only one integration-tested. `tests/test-install.sh` runs **68 assertions** against
the installer's gate-only path and its per-tool flags (`install.sh fixtures: 68 passed, 0 failed`
is its own summary line). The GitHub Action's permissions are `contents: read` and
`pull-requests: write` — no write access beyond posting one PR comment.

## Quick start

```bash
git clone <this repo> review-pantheon
./review-pantheon/install.sh /path/to/your-repo
```

That copies the five personas, the verdict-decision script, and a GitHub Actions workflow into
your repo (`--claude --cursor --codex --gemini` additionally generates in-editor/CLI projections
of the counsel agents — see [Provider lanes](#provider-lanes)). Then, before trusting it, work
through the **post-install checklist** `install.sh` prints:

1. Set the repo secret `CLAUDE_CODE_OAUTH_TOKEN`.
2. Set the repo variable `REVIEW_GATE_ENABLED=true` (the workflow no-ops without it).
3. Open `.github/workflows/review.yml` and replace `PIN-ME-TO-A-FULL-COMMIT-SHA` with a real,
   full 40-character commit SHA for `anthropics/claude-code-action`.
4. Verify that action's input/output names (`claude_code_oauth_token`, `prompt`, `allowed_tools`,
   the `result` output) against the release you pinned — written without network access, unverified.
5. Open a test PR with a deliberately planted blocker and confirm the gate goes **red** first.
6. Only after step 5 passes, consider making the check required.

Prefer the CLI? `cli/review-gate --pr <number>` runs the same panel locally against any repo with
a `gh`-authenticated remote — see [CLI usage](#cli-usage).

## The panel

**Gate agents (the twins)** — enforce. Run on every PR, in CI and the CLI, against finished work;
only these two run automatically in CI, and only these two verdicts can block a merge.

| Agent | Lens | Verdict vocabulary (green / yellow / red) |
|---|---|---|
| **Artemis** | Hunts bugs in the diff — correctness, untested failure paths, shortcuts, house-rule violations. Assumes nothing works until shown. | `SHIP` / `FIX_FIRST` / `STOP` |
| **Apollo** | Verifies the claim — re-runs stated checks, diffs claimed scope against git reality, checks required records exist. Skipped loudly on docs-only diffs. | `ACCEPT` / `ACCEPT_WITH_NOTES` / `RETURN` |

**Counsel agents (the philosophers)** — inform, never enforce. Their verdict is counsel a human
weighs in a decision, not a mechanism that gates a merge — true whatever they're pointed at (spec,
design doc, proposal, existing code, or a diff). Natural home is early, before merging; can be
added to a CLI gate run via `--agents`/`gate.conf`, but that's the exception.

| Agent | Lens | Verdict vocabulary (green / yellow / red) |
|---|---|---|
| **Socrates** | Options and go/no-go — maps distinct approaches against the real codebase before anything is built. | `GO` / `GO_WITH_GUARDRAILS` / `NO_GO` |
| **Diogenes** | Simplicity — assumes it works, asks only if it's more than it needs to be. | `LEAN` / `TRIM` / `GUT` |
| **Plato** | Coherence — assumes it works, asks if it has one consistent shape or drifting sprawl. | `COHERENT` / `DRIFTING` / `FRACTURED` |

Artemis and Apollo are twins, not duplicates: she reviews the code, he reviews the story about the
code, and a PR can pass one and fail the other. Diogenes and Plato are foils: Diogenes attacks
over-structure, Plato attacks under-structure. Socrates typically runs earliest — before there's
anything else in the room for the rest of the panel to weigh in on.

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

## Spec-driven development

review-pantheon is built for teams where a written spec is the contract, not a suggestion someone
skims once and stops checking.

- `DESIGN.md` in this repo is itself that contract — its rule 5 states it plainly: if the design
  doc and the implementation disagree, that's a bug in one of them, not a documentation nit.
- `REVIEW_RULES.example.md` is a template for an executable house-spec: rules the gate passes into
  every prompt and treats as blocker-class checks on every PR, not guidelines someone reads once.
- Apollo's entire job is verifying delivery against claim — checking that what a PR says happened
  is what git actually shows happened. That's the verification half of spec-driven development.

A spec says what should be true; without a tier that checks it stayed true, it drifts quietly.
review-pantheon is that tier — not a replacement for writing the spec, the check that it didn't
silently diverge from the code.

## How the gate stays honest

- **Fail-closed, always.** A missing, empty, or unparseable verdict is `UNVERIFIED` (orange), never
  green. The gate extracts the trailing JSON object from whatever the model printed, validates it
  against the schema and that agent's own verdict vocabulary with `jq`; any failure demotes the
  result — it never upgrades one.
- **Read-only, by construction.** Every persona is bound to read-only git (`git show`, `git diff`,
  `git log`, `git status`) and forbidden from mutating the tree, index, or HEAD. If a check needs a
  tree change to answer, the agent stops and reports the gap instead.
- **Prompt-injection-aware.** PR metadata is attacker-controlled on forks. The runner validates PR
  number, branch names, and head SHA against strict character-class regexes before any touch a
  shell command or prompt; unsafe metadata fails closed. The Action never interpolates untrusted PR
  content (title, body) directly into a `run:` script — it goes through `env:` indirection.
- **No auto-merge, ever.** The gate posts one combined PR comment — headline signal, verdict table,
  folded findings when it isn't green. A human reads it and decides.
- **One persona, one source.** `agents/<name>.md` is the only hand-maintained copy of each
  personality; both runners load and template that same file.

<details>
<summary>Verdict JSON contract</summary>

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

`severity` is `blocker` | `should_fix` | `note`; `has_blocker` must be `true` iff any finding is a
`blocker`. If a finding is `blocker` or `has_blocker: true`, the signal is forced red regardless
of the stated `verdict` — an object where the verdict and the findings disagree is treated as red,
not trusted at face value. Full schema and the color-map table: `DESIGN.md`.

</details>

## Provider lanes

Claude is the default lane and the only one integration-tested (`cli/providers/claude.sh`, using
`claude -p` with a restricted, read-only tool set). Codex, Gemini, and Cursor ship as best-effort —
each asserts its own CLI is installed and is marked unverified against your installed version. The
gate applies identical trailing-JSON extraction and schema validation to every lane, so a
misbehaving one degrades to `UNVERIFIED`, never to a false green.

Adding a lane is one file, `cli/providers/<name>.sh`, implementing one function:

```bash
provider_run() {
  local model="$1" prompt_file="$2"
  # run your CLI non-interactively against $prompt_file, print its raw stdout, return nonzero on failure
}
```

The gate agents run headless, from CI or `review-gate`. The **counsel agents** belong in the
planning conversation itself, so `install.sh --claude --cursor --codex --gemini` generates
per-tool projections of them — every generated file carries a `GENERATED — do not edit, re-run
install` header and is regenerated from `agents/*.md`, never hand-maintained.

<details>
<summary>Per-tool editor/CLI install matrix (verified vs. best-effort)</summary>

| Tool | What's generated | Status |
|---|---|---|
| **Claude Code** (`--claude`) | All five personas copied verbatim into `.claude/agents/`, plus a generated `/counsel` command (`.claude/commands/counsel.md`) that runs Socrates first, then Diogenes + Plato, and synthesizes the verdicts. | **Verified, first-class.** The personas are already this format; `/counsel` follows the documented [slash-command](https://docs.claude.com/en/docs/claude-code/slash-commands) convention. |
| **Cursor** (`--cursor`) | All five personas as native subagents, `.cursor/agents/*.md` (frontmatter adapted to Cursor's schema). | **Verified against current official docs** ([cursor.com/docs/subagents](https://cursor.com/docs/subagents), Cursor 2.4+). Best-effort: not integration-tested against a live Cursor install in this repo's CI. |
| **Codex CLI** (`--codex`) | All five personas as Codex Skills, `.agents/skills/<name>/SKILL.md`. | **Verified against current official docs** ([developers.openai.com/codex/skills](https://developers.openai.com/codex/skills)). Codex has no repo-level "custom command" convention, so Skills is used instead of inventing one. Best-effort: not integration-tested against a live Codex install. |
| **Gemini CLI** (`--gemini`) | All five personas as custom commands, `.gemini/commands/<name>.toml`. | **Verified against official docs** ([custom-commands.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/custom-commands.md)). Best-effort: not integration-tested against a live Gemini CLI install. |

Claude's `/counsel` is the only generated synthesis command — for the other tools, invoke the
counsel personas individually and reason across their verdicts yourself.

</details>

## CLI usage

```
review-gate --pr <number> [--provider <lane>] [--agents "artemis apollo"] [--dry-run]
```

Run it from inside the target repo. Requires `gh` and `jq`. Reads defaults from `gate.conf` at
the target repo's root — copy `gate.conf.example` yourself; `install.sh` does not install it
(`gate.conf` only matters to the CLI lane). `--provider` and `--agents` override the config for a
single run.

<details>
<summary>Full flag reference and follow-up mode</summary>

- `--pr <number>` — required, the PR to review.
- `--provider <lane>` — override `gate.conf`'s `provider=` for this run.
- `--agents "<space-separated list>"` — override `gate.conf`'s `agents=` for this run.
- `--dry-run` — builds the prompts and prints the would-be comment without calling any provider
  or posting anything.

Re-running against a PR that's already been reviewed at its current head SHA is a no-op; new
commits trigger a **follow-up pass** that reviews only what changed and tells the agent to read
its own prior comment first. State lives in `.review-gate-state.json` at the target repo's root
(git-ignored, bootstraps itself empty). Follow-up mode is CLI-only — see [Lane
differences](#lane-differences) for why.

**Draft PRs:** the CLI exits 0 and posts nothing, and prints an unmistakable
`DRAFT — not reviewed, nothing posted` line to stdout.

</details>

## Lane differences

The CLI and the GitHub Action share personas and the verdict-decision rule, but they aren't the
same tool.

| | CLI (`cli/review-gate`) | GitHub Action (`action/review.yml`) |
|---|---|---|
| Follow-up mode | Yes — incremental diff since last reviewed SHA. | No — re-reviews the full diff on every push; no persisted state. |
| Configuration | `gate.conf` (provider, model, base branch, rules file, agent list). | None — twin panel (artemis, apollo) hardcoded in the workflow. |
| Provider choice | Pluggable lane; Claude is the only integration-tested one. | Claude only, via `anthropics/claude-code-action`. |
| Draft handling | Detects `isDraft` via `gh pr view`; exits 0, posts nothing. | Job-level `if:` skips the run entirely; nothing posted. Same outcome, different mechanism. |

See `DESIGN.md`'s "Lane differences" section for the full rationale.

## Works with Conductor

[aug-conductor-wrkflw](https://github.com/G-Schumacher44/aug-conductor-wrkflw) is a public,
project-agnostic spec/slice/handoff scaffold by the same author. They pair: Conductor structures
the plan (slices, handoffs, the exact next step); review-pantheon verifies the delivery (the
gate) and pressure-tests the plan before it's built (the counsel).

## What it deliberately doesn't do

- **No fleet or multi-repo sweep.** The gate runs on one repo, on one PR, from inside that repo.
- **No third-party review aggregation.** It doesn't collect or reconcile verdicts from other
  review bots — a plausible extension point, not something this repo takes on.
- **No auto-merge, no auto-approve.** This posts a verdict, it never acts on one.
- **No write access beyond one PR comment.** `contents: read` + `pull-requests: write` only.
- **No pretending an unverified result is safe.** Orange means the run itself failed, not that
  the PR is fine — "review didn't happen," never a pass.

## Docs

Full doc index, including a per-persona table with each agent's lens and verdict vocabulary:
[docs/README.md](docs/README.md). Start with `DESIGN.md` for the binding contract.

---

**On generative AI use.** This repo was authored by Claude-based agents working from `DESIGN.md`
as the binding spec — the same document described above as the contract the code must match.
Every commit was gated by the repo's own review method before landing: hunter and verifier
audits (Artemis, Apollo) plus a delivery-verify pass, run against this codebase the same way it
runs against any other. Human-directed, spec-driven, self-gated.

## License

MIT — © 2026 Garrett Schumacher. See [LICENSE](LICENSE).
