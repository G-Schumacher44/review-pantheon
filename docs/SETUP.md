# Setup — install, first run, troubleshooting

This is the CLI-first walkthrough: get `review-gate` installed, run it once against a real PR
without spending a token, then run it for real. For the zero-footprint, Action-only surface (no
CLI, no files in your repo), see
[Way C](#way-c--published-action-zero-repo-footprint-action-only) below. Binding contract:
`DESIGN.md`. Doc index: [docs/README.md](README.md). Full flag/`gate.conf` reference once
you're past first run: [CLI.md](CLI.md).

## Prerequisites

| Tool | Needed for | Notes |
|---|---|---|
| `bash` | Everything | 3.2+ (stock macOS) through 5.x (Linux). No bashisms newer than that. **Windows:** the CLI surface needs a POSIX shell — use WSL or Git Bash. The Action surface runs on GitHub's Linux runners and works from any OS with no local shell at all. |
| `git` | Everything | The CLI locates the target repo via `git rev-parse --show-toplevel` and fetches PR refs directly (`refs/pull/<n>/head`) — no local branch checkout needed. |
| `jq` | Everything | Verdict extraction and validation (`cli/lib/verdict.sh`) is `jq`-based. |
| `gh`, authenticated | Everything | `review-gate` shells out to `gh pr view` / `gh pr comment`. Run `gh auth status` first if unsure. |
| `python3` | Action surface only | `action/decide_verdict.py` is the Action's verdict decider. The CLI surface doesn't need Python at all — its decider is `cli/lib/verdict.sh` (bash + `jq`). |
| `curl` | `bootstrap.sh` remote-fetch (`curl \| bash`) only | Only needed for the no-local-checkout install path — fetches the repo tarball from GitHub's codeload endpoint. Not needed for a local-checkout install, `install.sh`, or normal CLI/Action use. |
| `tar` | `bootstrap.sh` remote-fetch (`curl \| bash`) only | Extracts the tarball `curl` fetches. Same scope as `curl` above — not needed otherwise. |
| One provider CLI | Actually calling a model | `claude` (Claude Code CLI) is the default lane and the only one integration-tested. `codex`, `gemini`, `cursor-agent` are best-effort — see DESIGN.md's ["Provider lanes"](../DESIGN.md#provider-lanes) section. `--dry-run` (below) needs none of these installed. |
| Authenticated `claude` CLI | A live (non-`--dry-run`) run on the default provider lane | Check with `claude auth status` before your first live run — an unauthenticated CLI fails the provider call, which surfaces as `UNVERIFIED` per agent (see [Troubleshooting](#troubleshooting) below), not a clear "log in" message. `--dry-run` needs no authentication at all — it never calls a provider. |

## Three ways to install

<details>
<a name="way-a--vendored-install-installsh-files-land-in-your-repo"></a>
<summary><strong>Way A — vendored install (<code>install.sh</code>): files land in your repo</strong></summary>

```bash
git clone <this repo> review-pantheon
./review-pantheon/install.sh /path/to/your-repo
```

Copies the five personas, the verdict-decision script, and the GitHub Action workflow into
your target repo (`.github/review-agents/`, `.github/workflows/review.yml`), so your repo's own
CI checkout can see them without depending on review-pantheon existing on that runner. Prefer
this over Way C if you want the gate's own files reviewable in your repo's history. Add
`--claude --cursor --codex --gemini` to also generate in-editor/in-CLI projections of the
counsel agents. Idempotent — see `install.sh`'s own header comment and the README's
[Quick start](../README.md#quick-start).

You still run the CLI surface (`cli/review-gate`) from the review-pantheon checkout itself, not
from the target repo — Way A's `install.sh` doesn't touch the CLI at all, only the Action.

**Post-install checklist:**

1. Set the repo secret `CLAUDE_CODE_OAUTH_TOKEN`.
2. Set the repo variable `REVIEW_GATE_ENABLED=true` (the workflow no-ops without it).
3. `.github/workflows/review.yml` ships pinned to a real, verified
   `anthropics/claude-code-action` commit SHA (see that file's header comment for the release
   and the source it was checked against) — if you re-pin it yourself, confirm the SHA still
   matches a release you trust before relying on this gate.
4. Open a test PR with a deliberately planted blocker and confirm the gate goes **red** first.
5. Only after step 4 passes, consider making the check required.

</details>

<details>
<summary><strong>User-level install (<code>install.sh --user</code>): personas follow you across every repo</strong></summary>

```bash
./review-pantheon/install.sh --user --claude --cursor --codex --gemini
```

Same generators as Way A's `--claude`/`--cursor`/`--codex`/`--gemini`, run at **user level**
(`$HOME`) instead of into a target repo, so the counsel personas are available in every project
on the machine without re-installing per-repo. No target-repo argument — `--user` errors if one
is given — and at least one tool flag is required. The gate files (workflow, `decide_verdict.py`,
`REVIEW_RULES.md`) are **not** installed under `--user`: a PR gate belongs to one repo's CI, so
run plain `install.sh /path/to/repo` (Way A) per repo for those.

Verified per tool against each tool's current official docs (see `install.sh`'s own
`install_claude`/`install_cursor`/`install_codex`/`install_gemini` comment blocks for the exact
sources) — all four have a documented user-level location, the same relative layout as the
repo-level one:

| Tool | User-level destination |
|---|---|
| **Claude Code** | `$HOME/.claude/agents/*.md` (personas verbatim) + `$HOME/.claude/commands/counsel.md` |
| **Cursor** | `$HOME/.cursor/agents/*.md` |
| **Codex CLI** | `$HOME/.agents/skills/<name>/SKILL.md` |
| **Gemini CLI** | `$HOME/.gemini/commands/*.toml` |

Gemini CLI note: a project-level `.gemini/commands/<name>.toml` always wins over the user-level
copy when a name collides — so if you also run Way A's `--gemini` in a given repo, that repo's
own personas take priority over the ones installed by `--user`, per Gemini CLI's own documented
precedence rule.

Same idempotency contract as Way A — `install.sh` reuses the identical generator functions,
parameterized by destination root, not a duplicated code path.

</details>

<details>
<a name="way-b--user-level-install-bootstrapsh-zero-repo-footprint"></a>
<summary><strong>Way B — user-level install (<code>bootstrap.sh</code>): zero repo footprint</strong></summary>

```bash
git clone <this repo> review-pantheon
./review-pantheon/bootstrap.sh --prefix ~/.review-pantheon
export PATH="$HOME/.review-pantheon/cli:$PATH"
```

Installs `review-gate`, its provider lanes, and the five personas into a prefix directory
(default `~/.review-pantheon`) — nothing is written into any target repo. Add the printed
`export PATH=...` line to your shell rc yourself (`bootstrap.sh` won't edit it for you). From
then on, `review-gate --pr <n>` works from inside any repo with a `gh`-authenticated remote,
same as running it from an in-repo checkout. This is the CLI surface only — it doesn't install the
GitHub Action; pair it with Way A or Way C in a given repo if you want both surfaces.

Also works via `curl | bash` once this repo is public on GitHub:

```bash
curl -fsSL <raw-url-to-bootstrap.sh> | bash -s -- --prefix ~/.review-pantheon
```

`bootstrap.sh` detects it isn't running from a local checkout and fetches a tarball of the repo
via GitHub's codeload endpoint instead. That endpoint 404s against a private repo — until this
repo is public, the curl path fails with an explicit message and a `git clone` fallback command,
rather than silently doing nothing. Clone-and-run (the first form above) works today regardless.

Idempotent, same cmp-and-skip contract as `install.sh`: re-running only touches files that
changed; a file you've hand-edited in the prefix is left alone and reported skipped. Be aware
this contract can't tell "hand-edited" from "stale": a file left over from an older
`bootstrap.sh` run that simply differs from the currently-shipped source is skipped the exact
same way, so it won't pick up upstream fixes on its own — upgrading an existing prefix means
removing the file (or the whole prefix) first, then re-running.

Want to pin to a specific tagged release instead of tracking `dev`'s current HEAD? Add
`--version vX.Y.Z` to the remote-fetch (`curl | bash`) form above — it fetches that release's
checksummed tarball and verifies it (`sha256sum`/`shasum`) before extracting, dying loud on a
mismatch rather than installing an unverified archive. See RELEASING.md for how tags get cut.

</details>

<details open>
<a name="way-c--published-action-zero-repo-footprint-action-only"></a>
<summary><strong>Way C — published action: zero repo footprint, Action-only</strong></summary>

Skip `install.sh` and `bootstrap.sh` entirely. Copy [`examples/review-gate.yml`](../examples/review-gate.yml)
to `.github/workflows/review-gate.yml` in your repo and wire one secret — that file is the
whole install. `action.yml` at this repo's root is a composite GitHub Action; the `uses:
G-Schumacher44/review-pantheon@v1` reference reads personas and the verdict-decision script
from its own checkout, so nothing lands in your repo at all. See `DESIGN.md`'s ["Published
action"](../DESIGN.md#published-action) section for what's bundled, what's overridable
(`personas_path`, `agents`, `rules_file`, `spec_file`, `model`, `execution`), and the sequential-vs-matrix
tradeoff this surface makes.

`action.yml`'s auth surface is deliberately narrow — exactly two inputs, and it fails loud
unless exactly one is set:

| Route | Input | Notes |
|---|---|---|
| Claude Code OAuth token | `claude_code_oauth_token` | The stub's default; a token from `claude setup-token` or your Claude Code subscription. |
| Anthropic API key | `anthropic_api_key` | Pay-as-you-go via the Anthropic API. |

**Bedrock/Vertex/Foundry or OIDC workload-identity federation are NOT wired through this
composite action** — `anthropics/claude-code-action` itself supports them (`use_bedrock`,
`use_vertex`, `use_foundry`, `anthropic_federation_rule_id`, and friends — see
[its cloud-providers docs](https://github.com/anthropics/claude-code-action/blob/main/docs/cloud-providers.md)),
but `action.yml`'s own auth-assert step requires one of the two inputs above and doesn't expose
a passthrough for the cloud-provider ones. If you need pure cloud-provider auth (no Anthropic
token at all), use Way A instead: `install.sh` vendors `action/review.yml` into your repo,
which is then yours to edit — add the cloud-provider inputs to its `with:` block directly.

**Post-install checklist:**

1. Set the repo secret `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY` — wire whichever one
   into the stub's `with:` block; see the auth-surface table above).
2. Set the repo variable `REVIEW_GATE_ENABLED=true` (the workflow no-ops without it).
3. Open a test PR with a deliberately planted blocker and confirm the gate goes **red** first.
4. Only after step 3 passes, consider making the check required.

Still want the Action surface but prefer the files reviewable in your own repo's history (or don't
want to depend on this repo being public)? That's Way A, not Way C — `install.sh` vendors
`action/review.yml` instead of referencing this repo's `action.yml` directly.

</details>

## First run — the demo

Run this against **any repo you have locally that has a `gh`-authenticated remote and at least
one open PR** — it doesn't have to be review-pantheon itself, and it doesn't require `install.sh`
or `bootstrap.sh` to have been run against that repo at all:

```bash
cd /path/to/any/repo/with/an/open/pr
/path/to/review-pantheon/cli/review-gate --pr <number> --dry-run
```

(Or, with Way B installed and on `PATH`: `review-gate --pr <number> --dry-run` from inside that
repo.)

`--dry-run` does real work, right up to the point of spending a token or writing anything:

1. Validates the PR number, branch names, and head SHA against the same strict character-class
   regexes the live path uses (unsafe metadata still fails closed here, not just live).
2. Runs `gh pr view` for real — real title, real head/base refs, real draft status.
3. Fetches the real base and head refs (`refs/pull/<n>/head`) and computes the real diff range.
4. Detects docs-only diffs and follow-up-mode state (`.review-gate-state.json`) exactly as a
   live run would.
5. Builds the real prompt file per agent — persona body + the generated context block (diff
   range, base branch, house-rules file, output-contract reminder) — and writes it to a temp dir.
6. Prints, per agent, the provider command it *would* run: `[dry-run] would run: cli/providers/<lane>.sh provider_run "<model>" "<prompt_file>"`.
7. Prints the exact comment it *would* post to the PR — headline, verdict table (each row reads
   `DRY_RUN`), and the full-findings block — to stdout, never to GitHub.

Zero tokens spent (no provider is invoked), zero risk to the PR (nothing is posted, no PR is ever
recorded as reviewed — `.review-gate-state.json`'s `reviewed_sha` entry is only written after a
successful `gh pr comment` **and** only when the overall result is green or yellow; an unverified
or red result leaves it untouched, so the next run retries from the last SUCCESSFULLY reviewed SHA
— the full PR only if there was never one — instead of quietly treating a failed run as reviewed).
One caveat: `review-gate` bootstraps `.review-gate-state.json` to `{}` on first run if the file
doesn't exist yet, unconditionally, before the `--dry-run` check — so a dry run against a repo
that's never run `review-gate` before does leave a fresh, empty state file in the working tree.
Full detail: [CLI.md](CLI.md#the-state--follow-up-model).

## First live run

Drop `--dry-run` and it runs for real:

```bash
review-gate --pr <number>
```

Each agent's provider lane actually runs, its output goes through the same extraction and
validation `--dry-run` only simulated, and one combined comment gets posted to the PR:

```markdown
### 🟢 **Clean pass**
No blocker or review-note findings from any agent — this reads as safe to merge on the gate's own signal.

| Agent | Verdict | Top finding |
|---|---|---|
| artemis | `SHIP` — green | — |
| apollo | `ACCEPT` — green | — |

<details>
<summary>Full findings (0)</summary>
...
</details>

_review-pantheon — fails closed: a missing or unparseable verdict reads as NOT GATED, never as a pass._
```

— or, when there's something to say, the same shape but with a per-agent identity line
(`**artemis** @ \`<sha>\` — 🟡 FIX_FIRST`), that agent's own one-line summary, and itemized
findings (severity badge, `file:line`, the issue, the concrete failure scenario) inside the
findings fold — forced open on red/orange, collapsed otherwise. The raw per-agent verdict JSON
still ships too, nested inside that fold as its own collapsed block. Headline emoji/color
follows worst-wins precedence (🟢 green, 🟡 yellow/loud-skip, 🟠 unverified/not-gated, 🔴
red/blocked) — full rule in [DESIGN.md](../DESIGN.md#verdict-contract), comment shape in
[DESIGN.md](../DESIGN.md#combined-pr-comment).

Exit codes: `0` on green or yellow, nonzero on red or unverified — `review-gate`'s exit status
is meant to be usable as a CI/script gate on its own, independent of reading the posted comment.
A draft PR is a special case: exit `0`, nothing posted, nothing reviewed (see
[Troubleshooting](#troubleshooting) below).

## Troubleshooting

<details>
<summary>Draft PR — the run exits 0 but nothing was posted</summary>

```
review-gate: PR #42 is a draft — skipping loudly. No review run, no comment posted.
DRAFT — not reviewed, nothing posted
```

This is the intended behavior, not a failure — see `DESIGN.md`'s
[Deliberately absent](../DESIGN.md#deliberately-absent) list. Mark the PR ready for review and
re-run.

</details>

<details>
<summary>UNVERIFIED verdicts — the fail-closed causes</summary>

An 🟠 `UNVERIFIED` result means the gate refused to trust what the provider printed. It is not a
crash; it's the fail-closed rule in `DESIGN.md` rule 2 doing its job. The four causes, in the
order `cli/lib/verdict.sh`'s `decide_verdict` checks them:

1. **No parseable JSON found at all** — the provider's raw output never contained a `{...}`
   block `extract_last_json` could pull out (it takes the LAST `^{`-anchored block through EOF,
   so trailing prose after real JSON, or two JSON objects with the second one meant as a
   correction, are both handled — but a response that never emits JSON isn't recoverable).
2. **Missing required keys** — the parsed object is missing one of `agent`, `verdict`,
   `has_blocker`, `findings`, `summary`.
3. **Bad vocabulary / wrong agent field** — the `verdict` string isn't in that agent's allowed
   vocabulary (e.g. artemis reporting `"LGTM"` instead of `SHIP`/`FIX_FIRST`/`STOP`), or the
   `agent` field doesn't match the agent that was actually invoked.
4. **Provider lane failure** — the CLI itself exited nonzero or timed out (see below) before
   producing any output to extract from.

Check `review-gate`'s stderr (`note "$agent: $reason — UNVERIFIED"`) for which of these fired,
then check the raw provider output for that agent — usually the model padded its JSON with
prose, or the persona prompt got truncated.

Note what does **not** cause UNVERIFIED: a verdict/findings mismatch (e.g. `verdict: SHIP` next
to a `severity: blocker` finding). That's the blocker invariant instead — it forces the color to
red, not unverified, because a well-formed object that contradicts itself is a known blocker, a
stronger signal than "not gated."

</details>

<details>
<summary>Provider CLI not authenticated — reads as UNVERIFIED, not a login prompt</summary>

An unauthenticated `claude` CLI fails cause 4 above ("provider lane failure") — `claude -p ...`
exits nonzero instead of printing a verdict, so every agent on that run reads `UNVERIFIED` rather
than a distinct "please log in" message; `--dry-run` never hits this because it never calls the
CLI. Run `claude auth status` before your first live run to catch this ahead of time; `claude
auth login` if it isn't. The same applies per provider CLI on a non-default `--provider` lane
(`codex`, `gemini`, `cursor-agent`) — check that CLI's own auth command instead.

</details>

<details>
<summary>Timeout behavior</summary>

Each agent's provider call is wrapped with a timeout (`REVIEW_GATE_TIMEOUT`, default 600s).
GNU coreutils `timeout` is used when present (Linux CI, this repo's `Dockerfile.smoke`); on
stock macOS, where it isn't, `run_with_timeout` falls back to a manual TERM-then-KILL against
the child and its subprocesses (a provider CLI can spawn its own children). A timed-out agent is
reported the same way as any other provider-lane failure: `UNVERIFIED`, not a crash of the whole
run — the other agents in `--agents` still run and get reported.

</details>

<details>
<summary>Force-push fallback to full-range review</summary>

Follow-up mode normally reviews only `last_reviewed_sha..head` and asks the agent to read its
own prior comment first. If the PR's head was force-pushed, rebased, or had its history
rewritten since the last review, the previously reviewed SHA may no longer be an ancestor of the
new head — an existence check alone isn't enough to catch this (the old commit object can still
be fetchable, just not connected to the new history). `review-gate` checks ancestry explicitly
(`git merge-base --is-ancestor`) and falls back to reviewing the **full PR diff** again when it
fails, with a note in the prompt explaining why:

```
Follow-up review: a prior pass at <sha> exists but it is not an ancestor of the current head
(force-push, rebase, or history rewrite). Reviewing the full PR diff again.
```

This is expected after any force-push — not a bug, and not something you need to clear
`.review-gate-state.json` for.

</details>

<details>
<summary>Path resolution — running review-gate from a Way B (bootstrap) install</summary>

`review-gate` locates its own `agents/` and `cli/providers/` directories relative to its own
real location (symlink-resolved), not relative to the target repo it's reviewing. This works
whether it's invoked in-repo (`cli/review-gate`), from a `bootstrap.sh` prefix directly
(`~/.review-pantheon/cli/review-gate`), or through a symlink onto your own `PATH` pointing at
either of those. If you see a `source: no such file or directory` error mentioning
`cli/lib/verdict.sh`, the install is incomplete (missing `cli/lib/` or `cli/providers/` next to
`review-gate`) rather than a symlink problem — re-run `bootstrap.sh`.

</details>
