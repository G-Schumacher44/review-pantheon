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

What to include: the lane affected (CLI / published action / vendored workflow), the smallest
reproduction you have, and — if it's an injection-class finding — what the injected content
achieved (e.g. "read a file outside base-pinned provenance," "escaped the read-only wrapper's argv
validation"), not just that a prompt was echoed back.

**What to expect:** an acknowledgment within a few days. From there, a fix-or-track disposition —
either a fix lands and the advisory is credited on release, or, if the report turns out to be
expected behavior under a documented trade-off (see below), that gets explained back to you
instead of silently closed.

## Scope notes — read before assuming a finding is new

- **The `readonly` execution tier's guarantee is scoped to three named Claude surfaces, and
  scoped further even there — not absolute.** `execution=readonly` (the default) tool-scopes
  Bash on exactly three surfaces, all of them invoking Claude: the CLI (`cli/providers/
  claude.sh`), the published action (`action.yml`), and the vendored workflow
  (`action/review.yml`) — each configures the same `Bash(<wrapper path> *)` allowlist plus
  `--permission-mode dontAsk`. `cli/providers/{codex,gemini,cursor}.sh` invoke their own CLIs
  directly and never consume `PANTHEON_ALLOWED_TOOLS` or the wrapper: Codex, Gemini, and Cursor
  have no equivalent tool-scoping mechanism in their own CLIs as of v1, so a best-effort lane
  carries **no tool restriction at all** — its only guard against a hostile fork PR is the same
  fail-closed verdict handling every lane gets (schema validation, the blocker invariant,
  degrading to `UNVERIFIED` on anything malformed), not a tool-call boundary. On the three Claude
  surfaces, `readonly` restricts Bash to `pantheon-git-readonly.sh` for everything beyond Claude
  Code's own small, built-in, non-configurable set of always-approved bare read-only commands
  (plain `git diff`/`show`/`log`/`status`, no flags) — those never reach the wrapper at all, on
  any tier, because Claude Code itself allows them regardless. **Bypassing the wrapper is not the
  same as having no side effects — don't read "expected, allowed by Claude Code" as "genuinely
  read-only."** The wrapper forces `GIT_OPTIONAL_LOCKS=0` and `GIT_NO_LAZY_FETCH=1` specifically
  because plain git doesn't default to either: a bare `git status` outside the wrapper can still
  perform its default optional index refresh and write `.git/index`, and a bare object read
  outside the wrapper in a partial clone can still lazy-fetch and write a new object — both are
  real, reproduced side effects (see `DESIGN.md`'s "Security posture" section, Round 3's
  index-write finding and Round 4's `GIT_NO_LAZY_FETCH` finding, plus
  `tests/test-git-readonly-wrapper.sh`), just ones this policy doesn't treat as gate-defeating.
  "Bash routes through the wrapper" holds for any flag or any other subcommand on the three
  Claude surfaces, not literally every git invocation on those surfaces, and the wrapper's own
  hardening never applies to the bypass case at all. For everything the wrapper does see, it
  validates the full argv of a `diff`/`show`/`log`/`status` call before running real `git` — no
  flags accepted, forced `--no-ext-diff --no-textconv` on top of the two env vars above. This
  closes the arbitrary-command-execution primitive through the tool-call surface for that broader
  surface, on the three Claude surfaces; it is one layer among several (base-pinned provenance,
  schema validation, the blocker invariant, cross-review by a second agent), not a claim that
  reviewing a hostile fork PR is safe in general on any lane. It does not eliminate a schema-valid,
  deceptive verdict from an agent that injected content has fully compromised — that's an
  accepted, documented limit, not a gap this policy is tracking as open. Full detail: DESIGN.md's
  "Security posture" section, "Tiered tool execution," "Round 3," and "Round 4."
- **The `trusted` tier is an explicit, known trade — own-repo/trusted-author use only.** Setting
  `execution=trusted` restores full Bash. It exists for reviewing your own repo's own PRs from
  your own checkout (this repo's own CI uses it exactly that way, self-reviewing its own PRs) and
  is never appropriate for reviewing a fork PR you don't control. A report that `trusted` grants
  full Bash access is expected behavior, not a finding — the thing worth reporting is a path where
  `readonly` silently behaves like `trusted`.
