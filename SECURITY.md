# Security policy

## Supported surface

review-pantheon runs read-only reviewer agents against untrusted content (a PR diff, including
fork PRs) by design — the gate's whole job is to survive being handed attacker-controlled input.
The default `execution=readonly` tier is the relevant guarantee: see DESIGN.md's ["Security
posture"](DESIGN.md#security-posture) section for the full read-provenance matrix (which files
are base-pinned or read from a trusted checkout, and why) and, within that same section, "Tiered
tool execution" for the wrapper's exec-surface matrix — what `pantheon/execution.py` validates in
a Bash call and what it deliberately rejects.

Supported: the CLI — `pantheon gate`/`pantheon counsel` (the `pantheon` Python package,
`pantheon/*.py`) — and the published action (`action.yml`) as shipped from `dev`/`main` on this
repo. Every install method that lands a workflow file in a target repo (`install.sh`'s Way A,
`examples/review-gate.yml`'s Way C) is a thin caller of that same `action.yml`, not a separate
implementation, since issue #36 deleted the vendored `action/review.yml` reimplementation that
used to exist here. A fork with local modifications, or an older pinned SHA of the published
action, is outside this policy's scope — report against the current `dev` first.

## Reporting a vulnerability

**Report privately — do not open a public issue.** Use GitHub's private security advisory flow on
this repo: **Security tab → Report a vulnerability**
([direct link](https://github.com/G-Schumacher44/review-pantheon/security/advisories/new)). This
keeps the report and any discussion out of public view until a fix is ready.

What to include: the surface affected (CLI / published action), the smallest
reproduction you have, and — if it's an injection-class finding — what the injected content
achieved (e.g. "read a file outside base-pinned provenance," "escaped the read-only wrapper's argv
validation"), not just that a prompt was echoed back.

**What to expect:** an acknowledgment within a few days. From there, a fix-or-track disposition —
either a fix lands and the advisory is credited on release, or, if the report turns out to be
expected behavior under a documented trade-off (see below), that gets explained back to you
instead of silently closed.

## Scope notes — read before assuming a finding is new

Canonical detail for everything below lives in DESIGN.md's ["Security
posture"](DESIGN.md#security-posture) section (the full read-provenance matrix and the wrapper's
exec-surface matrix; fix-round history lives in this repo's git history, not in a doc) — what
follows is a scoped summary of what matters when triaging a report, not a second full retelling.

### `readonly` only tool-scopes two Claude surfaces

`execution=readonly` (the default) restricts Bash on exactly two surfaces, both of them
invoking Claude: the CLI (`pantheon.providers`' claude lane) and the published action
(`action.yml`) — each configures the same `Bash(<wrapper path> *)` allowlist plus
`--permission-mode dontAsk`. Every workflow-file install method (Way A, Way C) is a thin caller
of `action.yml`, so it inherits this scoping rather than configuring its own. The codex/gemini/cursor
lanes in `pantheon.providers` invoke their own CLIs directly and never consume the wrapper:
Codex, Gemini, and Cursor have no equivalent tool-scoping mechanism in their own CLIs as of v1,
so a best-effort lane carries **no tool restriction at all** — its only guard against a hostile
fork PR is the same fail-closed verdict handling every lane gets, not a tool-call boundary.

### Bypassing the wrapper is not the same as having no side effects

Claude Code's own small, built-in, non-configurable set of always-approved bare read-only
commands (plain `git diff`/`show`/`log`/`status`, no flags) never reaches the wrapper at all, on
any tier. Don't read "expected, allowed by Claude Code" as "genuinely read-only": the wrapper
forces `GIT_OPTIONAL_LOCKS=0` and `GIT_NO_LAZY_FETCH=1` specifically because plain git doesn't
default to either, so a bare `git status` outside the wrapper can still write `.git/index`, and a
bare object read in a partial clone can still lazy-fetch — real, reproduced side effects this
policy doesn't treat as gate-defeating.

### What `readonly` closes, and its honest limit

For everything the wrapper does see (any flag, any subcommand beyond the built-in-safe set
above), it closes the arbitrary-command-execution primitive through the tool-call surface on the
two Claude surfaces. That's one layer among several — base-pinned provenance, schema
validation, the blocker invariant, cross-review by a second agent — not a claim that reviewing a
hostile fork PR is safe in general. **None of it eliminates a schema-valid, deceptive
verdict from an agent that injected content has fully compromised** — an accepted, documented
limit, not a gap this policy is tracking as open.

### `trusted` is an explicit, known trade — own-repo/trusted-author use only

Setting `execution=trusted` restores full Bash. It exists for reviewing your own repo's own PRs
from your own checkout (this repo's own CI uses it exactly that way) and is never appropriate for
reviewing a fork PR you don't control. A report that `trusted` grants full Bash access is expected
behavior, not a finding — the thing worth reporting is a path where `readonly` silently behaves
like `trusted`.

## Fork pull requests

**Fork PRs are not gated. That is a structural property of GitHub Actions, not a bug here, and
the gate now says so out loud instead of failing with a misleading message.**

GitHub does not expose `secrets.*` to a `pull_request` run originating from a fork. The reason is
sound: the PR's own code executes in that job, so any credential available there would be an
outside contributor's for the taking. Every documented install here — Way A's generated stub and
Way C's `examples/review-gate.yml` — triggers on `pull_request` and calls the composite action
(`action.yml`) via `uses:`. On a fork the provider credential arrives as the empty string and no
review call is possible.

What that means in practice:

- **The job runs, but the action detects the fork** at its auth step and skips every subsequent
  step, emitting a NOT GATED notice and step summary. The check ends green-because-skipped rather
  than red-because-unauthenticated. Nothing in your workflow needs to change.
- **A green check on a fork PR means the gate skipped, not that the change passed.** Review it
  manually. This is the one dangerous misreading, so it is stated at every surface a maintainer
  might look at.
- Consequently, think twice before making this a **required** status check on a repository that
  accepts outside contributions: the job runs and succeeds with every step skipped, so the check
  reports **success**. A required check does not block the PR; the hazard is the opposite one —
  "required check green" reads as "reviewed" when nothing was reviewed.
- **Pre-#36 note:** a repo whose `.github/workflows/review.yml` still carries the OLD vendored
  `action/review.yml` (installed before issue #36, never re-run through `install.sh` since) has a
  separate `fork-notice` job and the `review` job skipped at *job* level instead — the check
  reports **skipped**, not success, under that older shape. To migrate, **delete the old
  `.github/workflows/review.yml`, then re-run `install.sh`** — a bare re-run is not enough:
  the installer never overwrites a file that lacks its GENERATED marker (the old vendored copy
  has none), so it reports a skip with this same delete-and-rerun instruction instead.

  Two more migration steps if you'd gone further than the default install:
  - **Required checks (do this or every PR blocks):** the old matrix workflow reported per-agent
    contexts — `review (artemis)`, `review (apollo)` — that the generated replacement does not
    emit; it reports one `review` context. If you made the old contexts required, branch
    protection will wait forever for checks that can no longer report. Update the required list:
    remove the old matrix contexts, require `review`.
  - **Customized personas keep working by default:** the generated workflow sets
    `personas_path: .github/review-agents`, so persona copies the migration preserved (the
    installer never overwrites an edited persona) stay in effect. Only if you deleted that line
    from the generated stub does the gate fall back to review-pantheon's bundled set.

  If you want required-means-reviewed, adopt one of the patterns below first.

### Never use `pull_request_target`

This is the trap, and it is the first thing a search engine will suggest.

`pull_request_target` runs with the base repository's context and **does** expose secrets — while
the content under review is still an outside contributor's. Since this gate exists to fetch and
process that diff, adopting that trigger is the textbook configuration for handing a stranger's
content a live credential and write-scoped token.

The critical point: **every other control in this project sits below the trigger.** Base-pinned
personas and decider, the read-only git wrapper, the argv allowlist, the neutral provider cwd —
none of them can compensate for that choice, and none of them would fail if someone made it. It
is a one-word change that silently voids the entire threat model.

It is therefore enforced mechanically in **this** repository, not by convention:
`tests/check_action_expressions.py` fails the build if `pull_request_target` appears in either
Action surface or in any `.github/workflows/*.yml`, and CI runs it on every push and pull request.
Note that `install.sh` does not vendor that guard — an adopter inherits the workflow, not this
repo's CI enforcement, so the prohibition is yours to keep on your own fork of the setup.

### If you genuinely need fork review

**Gate on author association.** Members and collaborators are reviewed automatically; outside
contributions require a maintainer to approve the workflow run before it executes (GitHub supports
this natively for first-time contributors). This is the working answer today, and the only one this
project recommends.

**Not the two-stage `workflow_run` pattern.** An earlier version of this section recommended it —
a `pull_request` workflow uploading the diff as an artifact with no secrets, then a `workflow_run`
workflow reviewing that artifact in the trusted context without checking out fork code. It reads
well, it is GitHub's own documented shape for the general problem, and **it does not work with this
action.** The action refuses to run under `workflow_run` for that reason, so following the old
advice now fails loudly rather than silently doing something unsafe. Two independent reasons:

- **The input surface does not exist.** `action.yml` declares no `pr_number` / `base_sha` /
  `head_sha` inputs; every step reads them from `github.event.pull_request.*`. Under `workflow_run`
  that context is absent, and GitHub documents `workflow_run.pull_requests` as **empty for
  fork-originated pull requests** — precisely the case this section exists to serve. Stage 2 would
  have nothing to review.
- **"Never checks out the fork's code" is not the same as "the fork's blobs are absent."** This
  action requires `git diff <base>...<head>` to resolve, which means the fork's commit objects must
  be present in the runner's git history. Once fetched, the read-only git wrapper can read that
  content exactly as it would a checkout. The property the pattern was recommended for does not
  hold here even when the pattern is followed correctly.

Restoring this path would take explicit `pr_number`/`base_sha`/`head_sha` inputs plus a diff-only
resolution that never fetches fork commits. Until then, treat fork PRs as NOT GATED — which is what
the action reports on them, by design (GitHub withholds the model credential from fork-originated
`pull_request` runs, so the gate exits with a notice rather than pretending to review).

## Blast radius

If a reviewer agent were fully compromised by injected content, here's what it could reach on the
surfaces this repo directly controls, independent of every layer above:

- **GitHub permissions are the outer bound — as shipped, not as enforced by `action.yml` itself.**
  Both documented consumer stubs — `examples/review-gate.yml` (Way C) and `install.sh`'s
  generated `.github/workflows/review.yml` (Way A) — set `contents: read` and `pull-requests:
  write` — no write access to code, branches, releases, or repo settings, only posting one PR
  comment. **This is not a hard ceiling the published action enforces on every consumer,
  though:** a composite action can't declare its own `permissions:` block (`action.yml`'s own
  header comment states this) — it inherits whatever the CALLING workflow grants. A consumer who
  wires `uses: G-Schumacher44/review-pantheon@<ref>` into a job with broader permissions (e.g.
  `contents: write`) hands a compromised run that broader reach; GitHub enforces the *consumer's*
  chosen scope, not this repo's documented minimum. Use the documented `contents: read` /
  `pull-requests: write` block — widening it defeats this layer.
- **The reviewer itself is pinned, not a moving target.** The published action pins
  `anthropics/claude-code-action` to a full commit SHA
  (`239e3a730883eeb5c53db12b0fc9573b3024b126`, v1.0.191 — read directly from that release's own
  `action.yml`, not assumed or copied from older docs), not a moving tag — every consumer
  inherits that pin, since there is only the one implementation now (issue #36). Way A adds a
  second pin on top: the generated stub itself references `G-Schumacher44/review-pantheon` by a
  full commit SHA, not the floating `v1` tag Way C's stub uses — re-pinning either one is an
  explicit, auditable edit, not something that changes under a consumer on its own.
