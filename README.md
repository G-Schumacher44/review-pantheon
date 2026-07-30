# review-pantheon

Most AI code review collapses two different jobs into one pass: "does the code look right" and
"did the PR actually do what it says it did." A single reviewer asking both questions at once
tends to answer neither well — it skims the diff for red flags and takes the description mostly
on faith. review-pantheon splits the jobs into two agents that never talk each other into
agreement: **Artemis** hunts bugs in the diff itself, assuming nothing works until the code shows
it does; **Apollo** audits the claim of completed work, assuming nothing was done until the
evidence shows it was. Different questions, different failure modes caught, run in parallel on
every pull request as the **gate**. Three more agents — Socrates, Diogenes, Plato — form a
**counsel** tier for planning and design decisions: invoked when deciding, not when merging.
The gate that runs Artemis and Apollo fails closed: a missing or malformed verdict is a loud
orange "not gated," never a quiet green.

## 60-second quickstart

```bash
git clone <this repo> review-pantheon
./review-pantheon/install.sh /path/to/your-repo
```

That copies the five personas, the verdict-decision script, and a GitHub Actions workflow into
your repo. Then, before you trust it:

1. Set the repo secret `CLAUDE_CODE_OAUTH_TOKEN`.
2. Set the repo variable `REVIEW_GATE_ENABLED=true` (the workflow no-ops without it).
3. Open `.github/workflows/review.yml` and replace `PIN-ME-TO-A-FULL-COMMIT-SHA` with a real,
   full 40-character commit SHA for `anthropics/claude-code-action`.
4. Verify the action's input/output names (`claude_code_oauth_token`, `prompt`,
   `allowed_tools`, the `result` output) against the release you just pinned — they're
   unverified guesses, written without network access to the action's docs.
5. Open a test PR with a deliberately planted blocker and confirm the gate goes **red** before
   you trust a green result on a real one.
6. Only after step 5 passes, consider making the check required.

Prefer the CLI? `cli/review-gate --pr <number>` runs the same panel locally against any repo
with a `gh`-authenticated remote — see [CLI usage](#cli-usage) below.

## The panel

**Gate agents (the twins)** — machinery. Run on every PR, in CI and the CLI, against finished
work; only these two run automatically in CI.

| Agent | Lens | Verdict vocabulary (green / yellow / red) |
|---|---|---|
| **Artemis** | Hunts bugs in the diff — correctness, untested failure paths, shortcuts, house-rule violations. Assumes nothing works until shown. | `SHIP` / `FIX_FIRST` / `STOP` |
| **Apollo** | Verifies the claim — re-runs stated checks, diffs claimed scope against git reality, checks required records exist. Skipped loudly on docs-only diffs. | `ACCEPT` / `ACCEPT_WITH_NOTES` / `RETURN` |

**Counsel agents (the philosophers)** — planning and design, in the human loop. Invoked when
deciding, not when merging; can be added to a CLI gate run via `--agents`/`gate.conf`, but that's
the exception, not their home.

| Agent | Lens | Verdict vocabulary (green / yellow / red) |
|---|---|---|
| **Socrates** | Options and go/no-go — maps distinct approaches against the real codebase before anything is built. | `GO` / `GO_WITH_GUARDRAILS` / `NO_GO` |
| **Diogenes** | Simplicity — assumes it works, asks only if it's more than it needs to be. Applies to a proposed design as much as a landed diff. | `LEAN` / `TRIM` / `GUT` |
| **Plato** | Coherence — assumes it works, asks if it has one consistent shape or drifting sprawl. Applies to a proposed design as much as a landed diff. | `COHERENT` / `DRIFTING` / `FRACTURED` |

Artemis and Apollo are twins, not duplicates: she reviews the code, he reviews the story about
the code, and a PR can pass one and fail the other. Diogenes and Plato are foils: Diogenes attacks
over-structure, Plato attacks under-structure, so between them a design gets pushed toward exactly
as much shape as the job needs. Socrates runs earliest of all — before there's a diff for the
twins or a design for Diogenes and Plato to weigh in on.

## How the gate stays honest

These aren't afterthoughts — they're the reason to trust a green checkmark at all:

- **Fail-closed, always.** A missing, empty, or unparseable verdict is `UNVERIFIED` (🟠), never
  green. The gate extracts the trailing JSON object from whatever the model printed, validates
  it against the schema and that agent's own verdict vocabulary with `jq`, and any failure at
  any step demotes the result — it never upgrades one.
- **Read-only, by construction.** Every persona's instructions bind it to read-only git
  (`git show`, `git diff`, `git log`, `git status`) and forbid anything that mutates the tree,
  the index, or HEAD. If a check needs a tree change to answer, the agent stops and reports the
  gap instead of working around it.
- **Prompt-injection-aware.** PR metadata is attacker-controlled on forks. The runner validates
  the PR number, branch names, and head SHA against strict character-class regexes before any of
  them touch a shell command or a prompt; unsafe metadata fails closed instead of running at all.
  The GitHub Action never interpolates untrusted PR content (title, body) directly into a `run:`
  script — it goes through `env:` indirection and randomized multiline-output delimiters, the two
  concrete mitigations for the injection classes GitHub Actions is actually vulnerable to.
- **No auto-merge, ever.** The gate posts one combined PR comment — a headline signal, a verdict
  table, folded findings when it isn't green. It never merges, approves, or blocks by itself
  beyond the CI check going red. A human reads the comment and decides.
- **One persona, one source.** `agents/<name>.md` is the only copy of each personality. Both the
  CLI runner and the GitHub Action load and template that same file — never an embedded fork
  that can drift out from under it.

## Multi-provider

Claude is the default lane and the only one integration-tested in v1 (`cli/providers/claude.sh`,
using `claude -p` with a restricted, read-only tool set). Codex, Gemini, and Cursor lanes ship as
best-effort — each asserts its own CLI is installed and is clearly marked as unverified against
your installed version. The gate doesn't have to trust any of them to be well-behaved: it applies
the exact same trailing-JSON extraction and schema validation regardless of which lane produced
the output, so a misbehaving lane can degrade to `UNVERIFIED`, never to a false green.

Adding a lane is one file, `cli/providers/<name>.sh`, implementing one function:

```bash
provider_run() {
  local model="$1" prompt_file="$2"
  # run your CLI non-interactively against $prompt_file, print its raw stdout, return nonzero on failure
}
```

No other file changes — the runner sources it, calls `provider_run "$model" "$prompt_file"` under
a timeout, and treats its stdout exactly like every other lane's.

## CLI usage

```
review-gate --pr <number> [--provider <lane>] [--agents "artemis apollo"] [--dry-run]
```

Run it from inside the target repo (it resolves the repo root via `git rev-parse
--show-toplevel`). Requires `gh` and `jq`. Reads defaults from `gate.conf` at the target repo's
root — copy `gate.conf.example` to `gate.conf` there yourself and edit it; `install.sh` does not
install it for you (`gate.conf` only matters to the CLI lane, so it isn't part of the default
install). `--provider` and `--agents` override the config for a single run. `--dry-run` builds
the prompts and prints the would-be comment without calling any provider or posting anything.

Re-running against a PR that's already been reviewed at its current head SHA is a no-op; new
commits trigger a **follow-up pass** that reviews only what changed and tells the agent to read
its own prior comment first. State lives in `.review-gate-state.json` at the target repo's root
(git-ignored, bootstraps itself empty). Follow-up mode is CLI-only — see "Lane differences"
below for why the Action doesn't have it.

**Draft PRs:** the CLI exits 0 and posts nothing, and prints an unmistakable
`DRAFT — not reviewed, nothing posted` line to stdout so a caller scripting around this can't
mistake silence for a skip. See `DESIGN.md`'s lane-differences table for how the Action handles
the same case.

## Lane differences

The CLI and the GitHub Action share personas and the verdict-decision rule, but they aren't the
same tool — see `DESIGN.md`'s "Lane differences" section for the full table (follow-up mode,
config, provider choice, draft handling). Short version: the CLI is the configurable, scriptable,
provider-agnostic lane; the Action is the fixed, zero-config, Claude-only lane that runs
automatically on every PR.

## What it deliberately doesn't do

- **No fleet or multi-repo sweep.** The gate runs on one repo, on one PR, from inside that repo.
  If you want it looped across many repos, that's a loop you write around it.
- **No third-party review aggregation.** It doesn't collect or reconcile verdicts from other
  review bots — that's a plausible extension point, not something this repo takes on.
- **No auto-merge, no auto-approve.** Covered above, worth repeating: this posts a verdict, it
  never acts on one.
- **No write access beyond one PR comment.** The GitHub Action's permissions are `contents: read`
  and `pull-requests: write` — nothing broader (no `id-token: write`; it isn't needed for
  anything this workflow currently does).
- **No pretending an unverified result is safe.** If you see 🟠, something about the run itself
  failed — a malformed verdict, an unreachable ref, a provider crash. It carries no opinion about
  the PR either way; treat it as "review didn't happen," not as a pass.

## Layout

```
agents/                    five canonical personas — the single source of truth
cli/review-gate            the runner: builds prompts, calls a provider lane, validates
                            verdicts, posts one combined PR comment
cli/lib/verdict.sh         extraction + verdict-decision, including the blocker invariant
cli/providers/             provider lanes (claude, codex, gemini, cursor)
action/review.yml          GitHub Actions twin gate — one matrix job, fail-closed decision step
action/decide_verdict.py   the Action's verdict-decision rule (Python twin of cli/lib/verdict.sh)
tests/                     tests/test-verdict-decision.sh — cross-runner fixture test
install.sh                 idempotent installer into a target repo
docs/                      anything that doesn't fit above
```

See `DESIGN.md` for the full contract — verdict schema, security posture, configuration keys,
and the hard rules every agent and every provider lane is required to follow.
