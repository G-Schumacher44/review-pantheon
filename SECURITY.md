# Security policy

review-pantheon runs read-only reviewer agents against untrusted content — a PR diff, including
fork PRs — by design. The gate's whole job is to survive being handed attacker-controlled input.
This page is the triage map: what's in scope, what a compromised reviewer could reach, how the
read-only tier is bounded, why fork PRs are not gated, and how to report a vulnerability. Canonical
mechanism lives in DESIGN.md's ["Security posture"](DESIGN.md#security-posture) section (the full
read-provenance and exec-surface matrices); this page states the facts that matter when triaging a
report and points there once for the how.

## Supported surface

Supported: the CLI — `pantheon gate` / `pantheon counsel` (the `pantheon` Python package,
`pantheon/*.py`) — and the published action (`action.yml`) as shipped from `dev` / `main` on this
repo. Every install method that lands a workflow file in a target repo (`install.sh`'s Way A,
`examples/review-gate.yml`'s Way C) is a thin caller of that same `action.yml`, not a separate
implementation. A fork with local modifications, or an older pinned SHA of the published action,
is outside this policy's scope — report against the current `dev` first.

## Blast radius

If a reviewer agent were fully compromised by injected content, this is what it could reach on the
surfaces this repo directly controls, independent of every layer above.

- **GitHub permissions are the outer bound — as shipped, not as enforced by `action.yml` itself.**
  Both documented consumer stubs — `examples/review-gate.yml` (Way C) and `install.sh`'s generated
  `.github/workflows/review.yml` (Way A) — set `contents: read` and `pull-requests: write`: no
  write access to code, branches, releases, or repo settings, only posting one PR comment. This is
  not a hard ceiling the published action enforces, though — a composite action can't declare its
  own `permissions:` block (`action.yml`'s header comment states this); it inherits whatever the
  calling workflow grants. A consumer who wires this action into a job with broader permissions
  (e.g. `contents: write`) hands a compromised run that broader reach. Use the documented
  `contents: read` / `pull-requests: write` block — widening it defeats this layer.
- **The reviewer is pinned, not a moving target.** The published action pins
  `anthropics/claude-code-action` to a full commit SHA
  (`d40ddef4c030e508327d6e35a9c45f3368482c50`, v1.0.195), not a floating tag — every consumer
  inherits that pin. Way A adds a second pin on top: its generated stub references
  `G-Schumacher44/review-pantheon` by a full commit SHA, not the floating `v1` tag Way C uses.
  Re-pinning either is an explicit, auditable edit, never a silent change under a consumer.
- **A credential the model echoes back is redacted before it can reach the posted comment — but
  only literal or shape-matched forms.** `pantheon.render`'s redaction chokepoint strips any
  literal credential value the render process's env holds (including the reviewer's forwarded
  token) plus any known GitHub / Anthropic credential-shaped token, from every field before the
  comment is posted. This is not complete coverage: a model that splits, encodes, or paraphrases a
  credential before emitting it defeats both the literal-value and shape-based passes, and the
  shape pass only covers formats this module has been taught. It narrows the exposure window; it
  does not close it. See DESIGN.md's "Security posture" section, "Credential redaction at render
  time," for the mechanism.

## Execution tiers

The default `execution=readonly` tier restricts Bash on exactly the two surfaces that invoke
Claude — the CLI (`pantheon.providers`' claude lane) and the published action (`action.yml`) — via
a `Bash(<wrapper path> *)` allowlist plus `--permission-mode dontAsk`. The codex / gemini / cursor
lanes invoke their own CLIs, which have no equivalent tool-scoping mechanism in v1, so a best-effort
lane carries **no tool restriction at all**; its only guard against a hostile fork PR is the same
fail-closed verdict handling every lane gets. See DESIGN.md's "Security posture" for the
exec-surface matrix — what the wrapper validates and what it rejects.

### Built-in read commands denied under `readonly`

Claude Code auto-approves a built-in set of read commands before `--allowedTools` is consulted, in
every permission mode: `ls`, `cat`, `echo`, `pwd`, `head`, `tail`, `grep`, `find`, `wc`, `which`,
`diff`, `stat`, `du`, `cd`, and `git`. Under `readonly` those are denied explicitly, so each is
forced back through the allowlist and fails closed; `git` is denied deliberately, routing every git
read through the wrapper (invoked by its own absolute path, never a bareword) instead. `trusted`
emits no deny list — full Bash is that tier's explicit opt-in, for reviewing your own repo's PRs
from your own checkout (this repo's own CI uses it exactly that way) and never for a fork PR you
don't control.

**The honest limit: `Read`, `Grep`, and `Glob` are not path-scoped at all.** They can read any path
the process can read; nothing in this tier confines them, and on the CLI surface that is by design —
the provider runs from a neutral scratch directory and the prompt hands the agent the checkout's
absolute path. The neutral cwd is not a read boundary. What it does buy is config isolation: a
repo-supplied `.claude/settings.json` hook, `.mcp.json` server, or `env` block is not discovered,
because discovery keys off the working directory. None of this eliminates a schema-valid, deceptive
verdict from an agent that injected content has fully compromised — an accepted, documented limit,
not an open gap. Cross-review by a second agent is the backstop there, not a guarantee.

## Fork pull requests

**Fork PRs are not gated. That is a structural property of GitHub Actions, not a bug here.** GitHub
withholds `secrets.*` from a `pull_request` run originating in a fork — the PR's own code executes
in that job, so any credential available there would be an outside contributor's for the taking. The
model credential therefore arrives empty, no provider call is possible, and the action detects the
fork at its auth step and skips every subsequent step, emitting a **NOT GATED** notice rather than
pinning a permanently-red check. **A green check on a fork PR means the gate skipped, not that the
change passed — review it manually.** Think twice before making this a *required* check on a repo
that accepts outside contributions: a required check that reports success with every step skipped
reads as "reviewed" when nothing was.

### Never use `pull_request_target`

This is the trap, and it is the first thing a search engine will suggest.

`pull_request_target` runs with the base repository's context and **does** expose secrets — while
the content under review is still an outside contributor's. Since this gate exists to fetch and
process that diff, adopting that trigger is the textbook configuration for handing a stranger's
content a live credential and a write-scoped token. **Every other control in this project sits below
the trigger** — base-pinned personas and decider, the read-only git wrapper, the argv allowlist, the
neutral provider cwd — and none of them can compensate for that choice. It is a one-word change that
silently voids the entire threat model, and it is enforced mechanically here:
`tests/check_action_expressions.py` fails the build if `pull_request_target` appears in either Action
surface or any `.github/workflows/*.yml`. Note that `install.sh` does not vendor that guard — an
adopter inherits the workflow, not this repo's CI enforcement, so the prohibition is yours to keep.

- **Neither maintainer approval nor a `workflow_run` two-stage pattern restores gating.** Approving
  a first-time contributor's workflow controls only whether the secretless run executes at all — it
  does not grant that run secrets, so an approved fork PR still reaches NOT GATED. The `workflow_run`
  artifact pattern (GitHub's documented general answer) does not work here either; the action refuses
  that trigger outright, and it would have nothing to review regardless. DESIGN.md's ["Deliberately
  absent"](DESIGN.md#deliberately-absent) section covers why.

What you *can* do with a fork contribution: review it yourself (the gate is one input to a
maintainer's judgment, not a replacement); bring the commits into the base repository as an ordinary
same-repo PR, which is gated normally (a deliberate act of vouching, not a bypass); or run the CLI
locally against the fork PR, under `readonly`, from a checkout you control.

> A repo whose `.github/workflows/review.yml` predates issue #36's install rework reports fork PRs
> as *skipped* rather than *success*, and may have stale required-check contexts. Migration steps
> live in [RELEASING.md](RELEASING.md#migrating-a-pre-36-installed-workflow).

## Reporting a vulnerability

**Report privately — do not open a public issue.** Use GitHub's private security advisory flow on
this repo: **Security tab → Report a vulnerability**
([direct link](https://github.com/G-Schumacher44/review-pantheon/security/advisories/new)). This
keeps the report and any discussion out of public view until a fix is ready.

What to include: the surface affected (CLI / published action), the smallest reproduction you have,
and — if it's an injection-class finding — what the injected content achieved (e.g. "read a file
outside base-pinned provenance," "escaped the read-only wrapper's argv validation"), not just that a
prompt was echoed back.

**What to expect:** an acknowledgment within a few days. From there, a fix-or-track disposition —
either a fix lands and the advisory is credited on release, or, if the report turns out to be
expected behavior under a documented trade-off (`trusted` granting full Bash is the common one — the
thing worth reporting is a path where `readonly` silently behaves like `trusted`), that gets
explained back to you instead of silently closed.
