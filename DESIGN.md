# Design — review-pantheon

Five read-only review agents and a fail-closed PR gate that runs them. Agent-CLI-agnostic:
Claude-first, with pluggable provider lanes (Codex, Gemini, Cursor). This document is the
contract — the personas, runners, and workflow are all implementations of what's written here.

## The idea

Most AI code review collapses two different jobs into one pass. This system splits them:

- **The hunter (Artemis)** reviews the change itself: correctness risks, untested failure
  paths, shortcuts, rule violations. She assumes nothing works until the code shows it does.
- **The verifier (Apollo)** audits the *claim* of completed work: re-runs stated verification,
  diffs what was claimed against what git actually shows, checks required records were written.
  He assumes nothing was done until evidence shows it was.

They are twins, not duplicates — different questions, different failure modes caught. Three
optional specialists extend the panel for judgment calls rather than every PR:

- **Diogenes** — simplicity auditor: is this MORE than it needs to be?
- **Plato** — coherence auditor: does this have a coherent shape, or is it ad-hoc sprawl?
- **Socrates** — options analyst: run BEFORE building, maps distinct approaches and go/no-go.

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

## House rules are pluggable

Artemis and Apollo check "house rules" as blockers — but every team's rules differ. The gate
passes the target repo's `REVIEW_RULES.md` (path configurable) into the prompt context; agents
treat each listed rule as a blocker-class check. Ships with `REVIEW_RULES.example.md`
(no secrets in diffs, no direct commits to the default branch, tests updated with behavior).

## Configuration

`gate.conf` in the target repo root (simple `key=value`, all optional):

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
- The GitHub Action pins `anthropics/claude-code-action` to a full commit SHA, checks out with
  `persist-credentials: false`, and fails loud (not skip) when its token secret is absent.

## Follow-up mode

Re-reviewing a PR after new commits reviews `last_reviewed_sha..head`, and the prompt tells the
agent to read its own prior PR comment instead of re-auditing from scratch. Reviewed SHAs are
tracked in `.review-gate-state.json` (git-ignored; bootstraps empty).

## Deliberately absent

- No fleet/multi-repo sweep — the gate runs on one repo, from that repo. Loop it yourself.
- No third-party reviewer integration (e.g. bot-review aggregation) — extension point, not core.
- No auto-merge, ever. The gate posts a verdict; a human merges.
- No write access needed beyond posting one PR comment.

## Layout

```
agents/            five canonical personas (the single source of truth)
cli/review-gate    the runner: builds prompts, calls a provider lane, validates verdicts,
                   posts ONE combined PR comment (signal headline + verdict table + folded findings)
cli/providers/     provider lanes (claude, codex, gemini, cursor)
action/review.yml  GitHub Actions twin gate — same personas, structured output, fail-closed
                   decision step with `if: always()`
install.sh         idempotent installer into a target repo (refuses to clobber customized files)
docs/              anything that doesn't fit above
```
