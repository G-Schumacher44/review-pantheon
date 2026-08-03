---
name: gate
description: Operate review-pantheon's review gate (Artemis + Apollo) from a Claude Code session — dry-run before spending tokens, run it live, read the combined verdict comment correctly, work with follow-up mode, and dispose findings. Use when asked to "run the gate," "gate this PR," "pantheon gate this," "review-gate this," "what does this verdict mean," "is this PR gated," or "check the review status" for a review-pantheon-gated repo.
---

# Operating the gate

review-pantheon's gate is `pantheon gate` (installed via `pipx`/`pip`, or on `PATH` via a Way-B
install) run against one PR. Full flag/`gate.conf` reference:
[docs/CLI.md](https://github.com/G-Schumacher44/review-pantheon/blob/main/docs/CLI.md). The
verdict schema and combined-comment shape are the binding contract:
[DESIGN.md](https://github.com/G-Schumacher44/review-pantheon/blob/main/DESIGN.md#verdict-contract).
This skill doesn't restate either — it's the procedure for using them from inside a session.
Links below point at review-pantheon's own GitHub repo, not a relative path — this file gets
copied into `.claude/skills/gate/` by `install.sh`, so a relative link would resolve against the
installed location instead of the source repo.

## Locating `pantheon`

`install.sh --claude` installs this skill and the `/gate` command — it does NOT install the CLI
itself. `pantheon` only ends up on `PATH` via a real `pipx`/`pip install`, or via a Way-B
(`bootstrap.sh`) install. Before assuming it's missing:

1. `command -v pantheon` — an installed package (or a Way-B install) puts it on `PATH`.
2. Look for a sibling review-pantheon checkout with a venv (e.g.
   `../review-pantheon` with `pip install -e .` run into its own venv) — a Way-A install still
   runs the CLI from that checkout, not from the target repo.
3. Check the default Way-B prefix directly: `~/.review-pantheon/venv/bin/pantheon`.
4. None of those resolve? Tell the user the CLI surface isn't installed yet and point at
   [docs/SETUP.md](https://github.com/G-Schumacher44/review-pantheon/blob/main/docs/SETUP.md)'s
   three install ways — don't try to run a command that
   doesn't exist and report the resulting error as if the gate itself failed.

## 1. Dry-run first — zero tokens

```
pantheon gate --pr <number> --dry-run
```

Does everything real up to the point of spending a token: real `gh pr view`, real diff range,
real docs-only/follow-up detection, real per-agent prompt assembly — then prints, per agent, the
provider command it *would* run and the comment it *would* post, to stdout only. No provider is
called, nothing is posted, no PR is ever recorded as reviewed. Run this before every first live
gate on a PR you haven't seen the shape of yet.

**Caveat: even `--dry-run` can leave a new untracked file.** `pantheon gate` bootstraps
`.review-gate-state.json` to `{}` unconditionally on first run, before the dry-run branch is even
reached — so the very first `--dry-run` against a repo that's never run the gate before leaves a
fresh, empty state file in the working tree. A Way-A (`install.sh`) install already added it to
`.gitignore`; running straight from a checkout or a Way-B (`bootstrap.sh`) install did not. If
you're on one of those paths, check `git status` after a first dry-run and add the entry yourself
before it gets swept into an unrelated `git add -A`.

## 2. Live run

Drop `--dry-run`:

```
pantheon gate --pr <number>
```

Each configured agent's provider lane runs for real; one combined comment posts to the PR. Exit
code `0` means the overall signal is green or yellow — usable as a gate on its own, independent of
reading the comment. Nonzero means red or unverified, or that posting the comment itself failed
after the verdict was computed.

## 3. Reading the combined verdict

- **Signal precedence (worst wins):** 🔴 red/blocked beats 🟠 unverified/not-gated (a missing or
  unparseable verdict from any invoked agent) beats 🟡 yellow/loud-skip beats 🟢 all-green. A
  single red or missing verdict among several green ones still reads red/orange overall.
- **Identity lines.** Each agent's findings-fold section opens with `**<agent>** @ \`<sha>\` —
  <emoji> <VERDICT>`, then that agent's own one-line summary, then itemized findings (severity
  badge, `file:line`, the issue, the concrete failure scenario).
- **Invariant-override notice.** If any finding carries `severity: "blocker"` (or
  `has_blocker: true`), the color is forced to red regardless of what the `verdict` word itself
  says — a well-formed object that contradicts itself is treated as a known blocker, not trusted
  at face value. When this fires, the agent's section carries an explicit overridden-verdict
  notice. Read that notice as the real signal, not the stated verdict string next to it.
- The raw per-agent verdict JSON still ships, nested as a collapsed block inside the fold — reach
  for it only when the rendered findings are ambiguous about what a field actually said.

## 4. Follow-up mode (CLI surface only)

Re-running `pantheon gate --pr <number>` against a PR that already has a recorded `reviewed_sha` in
`.review-gate-state.json` reviews only `reviewed_sha..head` and tells the agent to read its own
prior comment instead of re-auditing from scratch. The state only advances on a green or yellow
outcome — a red or unverified run leaves it untouched, so the next attempt still retries from the
last *successfully* recorded SHA rather than treating a failed gate as if it had reviewed
anything. A force-push past the recorded SHA is detected by ancestry check and falls back to a
full-PR review automatically, with a note explaining why — expected, not a bug.

## 5. Findings discipline — fixed or tracked, never dropped

Grounded in
[CONTRIBUTING.md](https://github.com/G-Schumacher44/review-pantheon/blob/main/CONTRIBUTING.md#ground-rules)'s
ground rules; apply this to
every finding a live gate posts, not just the ones you agree with:

- **Fix or track — no third option.** Either resolve the finding in the same PR, or open an issue
  for it and reply on the review thread pointing at that issue number before resolving the
  thread. A thread left open with nothing linked is the one state this repo doesn't allow.
- **Reply is not resolve.** Posting a reply that addresses a finding doesn't close the loop by
  itself — the thread still needs to be marked resolved (or explicitly tied to the tracking
  issue you just opened). Don't stop at the reply.
- **Class-close over instance patches.** When a finding is one instance of a broader shape — the
  same defect reachable more than one way, not a one-off typo — fix the shape once rather than
  patching only the reported line and leaving siblings live. Say so explicitly when you disposition
  it: "closed as a class" reads differently than "closed this one occurrence."

Don't duplicate `docs/CLI.md`'s flag table or `gate.conf` reference here — read that doc directly
for anything not covered above (provider selection, execution tiers, exit codes, worked examples).
