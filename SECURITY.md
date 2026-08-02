# Security policy

## Supported surface

review-pantheon runs read-only reviewer agents against untrusted content (a PR diff, including
fork PRs) by design — the gate's whole job is to survive being handed attacker-controlled input.
The default `execution=readonly` tier is the relevant guarantee: see DESIGN.md's ["Security
posture"](DESIGN.md#security-posture-kept-from-the-private-ancestor-by-design) section for the
full read-provenance matrix (which files are base-pinned or read from a trusted checkout, and
why) and, within that same section, "Tiered tool execution" for the wrapper's exec-surface
matrix — what `pantheon-git-readonly.sh` validates in a Bash call and what it deliberately
rejects.

Supported: the CLI (`cli/review-gate`), the published action (`action.yml`), and the vendored
workflow (`action/review.yml`) as shipped from `dev`/`main` on this repo. A fork with local
modifications, or an older pinned SHA of the published action, is outside this policy's scope —
report against the current `dev` first.

## Reporting a vulnerability

**Report privately — do not open a public issue.** Use GitHub's private security advisory flow on
this repo: **Security tab → Report a vulnerability**
([direct link](https://github.com/G-Schumacher44/review-pantheon/security/advisories/new)). This
keeps the report and any discussion out of public view until a fix is ready.

What to include: the surface affected (CLI / published action / vendored workflow), the smallest
reproduction you have, and — if it's an injection-class finding — what the injected content
achieved (e.g. "read a file outside base-pinned provenance," "escaped the read-only wrapper's argv
validation"), not just that a prompt was echoed back.

**What to expect:** an acknowledgment within a few days. From there, a fix-or-track disposition —
either a fix lands and the advisory is credited on release, or, if the report turns out to be
expected behavior under a documented trade-off (see below), that gets explained back to you
instead of silently closed.

## Scope notes — read before assuming a finding is new

Canonical detail for everything below lives in DESIGN.md's ["Security
posture"](DESIGN.md#security-posture-kept-from-the-private-ancestor-by-design) section (the full
read-provenance matrix, the wrapper's exec-surface matrix, and the round-by-round hardening
history in [docs/HARDENING-HISTORY.md](docs/HARDENING-HISTORY.md)) — what follows is a scoped
summary of what matters when triaging a report, not a second full retelling.

### `readonly` only tool-scopes three Claude surfaces

`execution=readonly` (the default) restricts Bash on exactly three surfaces, all of them
invoking Claude: the CLI (`cli/providers/claude.sh`), the published action (`action.yml`), and
the vendored workflow (`action/review.yml`) — each configures the same `Bash(<wrapper path> *)`
allowlist plus `--permission-mode dontAsk`. `cli/providers/{codex,gemini,cursor}.sh` invoke their
own CLIs directly and never consume the wrapper: Codex, Gemini, and Cursor have no equivalent
tool-scoping mechanism in their own CLIs as of v1, so a best-effort lane carries **no tool
restriction at all** — its only guard against a hostile fork PR is the same fail-closed verdict
handling every lane gets, not a tool-call boundary.

### Bypassing the wrapper is not the same as having no side effects

Claude Code's own small, built-in, non-configurable set of always-approved bare read-only
commands (plain `git diff`/`show`/`log`/`status`, no flags) never reaches the wrapper at all, on
any tier. Don't read "expected, allowed by Claude Code" as "genuinely read-only": the wrapper
forces `GIT_OPTIONAL_LOCKS=0` and `GIT_NO_LAZY_FETCH=1` specifically because plain git doesn't
default to either, so a bare `git status` outside the wrapper can still write `.git/index`, and a
bare object read in a partial clone can still lazy-fetch — real, reproduced side effects (see
DESIGN.md's "Security posture," Round 3 and Round 4) this policy doesn't treat as gate-defeating.

### What `readonly` closes, and its honest limit

For everything the wrapper does see (any flag, any subcommand beyond the built-in-safe set
above), it closes the arbitrary-command-execution primitive through the tool-call surface on the
three Claude surfaces. That's one layer among several — base-pinned provenance, schema
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

## Blast radius

If a reviewer agent were fully compromised by injected content, here's what it could reach on the
surfaces this repo directly controls, independent of every layer above:

- **GitHub permissions are the outer bound — as shipped, not as enforced by `action.yml` itself.**
  `examples/review-gate.yml` (the published action's documented consumer stub) and
  `action/review.yml` (the vendored workflow) both set `contents: read` and `pull-requests:
  write` — no write access to code, branches, releases, or repo settings, only posting one PR
  comment. **This is not a hard ceiling the published action enforces on every consumer,
  though:** a composite action can't declare its own `permissions:` block (`action.yml`'s own
  header comment states this) — it inherits whatever the CALLING workflow grants. A consumer who
  wires `uses: G-Schumacher44/review-pantheon@v1` into a job with broader permissions (e.g.
  `contents: write`) hands a compromised run that broader reach; GitHub enforces the *consumer's*
  chosen scope, not this repo's documented minimum. Use the documented `contents: read` /
  `pull-requests: write` block from `examples/review-gate.yml` — widening it defeats this layer.
- **The reviewer itself is pinned, not a moving target.** Both the published action and the
  vendored workflow pin `anthropics/claude-code-action` to a full commit SHA
  (`be7b93b1907a4abad570368f3c74b6fe3807510b`, v1.0.183 — read directly from that release's own
  `action.yml`, not assumed or copied from older docs), not a moving tag. Re-pinning to a newer
  release is an explicit, auditable edit, not something that changes under a consumer on its own.
