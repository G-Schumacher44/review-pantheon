# Hardening history — the read-only wrapper's round-by-round record

This is a changelog, not the contract. `DESIGN.md`'s ["Security
posture"](../DESIGN.md#security-posture-kept-from-the-private-ancestor-by-design) section is
canonical for **current-state** behavior — what the `readonly` execution tier does today, the
read-provenance matrix, the wrapper's exec-surface matrix. This file exists so that current-state
description doesn't have to carry ~240 lines of round-by-round discovery narrative just to stay
readable. If anything here and `DESIGN.md`'s current-state description disagree, `DESIGN.md`
wins — this file is a historical record of how the wrapper got to its current shape, not a second
copy of what it does now.

Each round below was closed on a real PR, usually off a live Codex or Apollo finding reproduced
against the pre-fix wrapper before the fix landed — the same "not green-by-construction" standard
this repo's own fixture tests hold themselves to. `cli/lib/pantheon-git-readonly.sh`'s own header
comment is the single canonical enumeration of what the wrapper closes today; `DESIGN.md` defers
to it rather than duplicating that table. `tests/test-git-readonly-wrapper.sh` carries the live
fixtures referenced throughout.

- **Round 1 (bare prefix) → round 2 (wrapper) — a real finding, self-caught.** The first
  version of this tier used bare `Bash(git diff *)` / `Bash(git show *)` / `Bash(git log *)` /
  `Bash(git status *)` patterns. A Codex review on this PR caught that a command-prefix match
  has no understanding of git's own argument grammar: `Bash(git diff *)` also permits
  `git diff --output=tracked-file` (git's own docs describe `--output <file>` as writing to a
  file) and `git diff --ext-diff` (spawns an arbitrary external helper) — neither read-only in
  any sense that matters, and a prefix match on a command the MODEL chose to type is not a
  boundary when prompt injection is exactly what's steering the model. Fixed by routing
  `readonly` through `cli/lib/pantheon-git-readonly.sh` instead: it validates the FULL argv
  itself (subcommand must be exactly `diff`/`show`/`log`/`status`; every remaining argument
  must be a plain ref/path/range — no flags of any kind, not even a per-subcommand "safe" list)
  before ever calling real `git`, and forces a pager/editor/external-diff-free environment on
  top. See that script's own header comment for the full rationale, including what it does and
  does not claim to fix (Claude Code's own Bash-permission handling of CHAINED shell commands —
  `cmd1 && cmd2`, `;`, `|` — is a property of the `claude` CLI itself, tracked upstream, not
  something a wrapper script run from inside one permitted invocation can patch; this tier is
  defense in depth on top of whatever the installed `claude` CLI provides there, not a
  substitute for it).
- **Round 3 — configured diff drivers, index writes, and permission-mode (fresh Codex/Apollo
  evidence after round 2 landed).** Three more findings, all fixed in the wrapper/invocation
  layer, none requiring another rethink of the shape above:
  - Rejecting `--ext-diff` as an explicit argument doesn't stop a *configured* external diff
    driver from firing on a plain, validation-passing `diff`/`show` — a `.gitattributes` entry
    (`*.foo diff=evil`) plus a `diff.evil.command=...` config entry activates the driver
    without the model ever typing `--ext-diff`. Codex reproduced this live against the
    round-2 wrapper. Fixed by forcing `--no-ext-diff --no-textconv` onto every `diff`/`show`
    call the wrapper makes — injected by the wrapper itself, not accepted from the model's
    argv (still rejected as a flag like any other), so no config or attributes state the
    target repo happens to carry can re-enable a driver or content filter. Reproduced-then-
    fixed with a real helper script in `tests/test-git-readonly-wrapper.sh`.
  - `git status` performs an optional index refresh that writes `.git/index` by default,
    contradicting this tier's "never mutates the index" framing and able to race a concurrent
    repo operation on a shared runner. Fixed with `GIT_OPTIONAL_LOCKS=0` in the wrapper's
    forced environment (git's own documented mechanism for disabling optional lock-taking
    operations) — verified with a real mtime-unchanged assertion, not just absence of an
    error.
  - **`--permission-mode dontAsk`, not left unset.** A live run of `action.yml` with no
    explicit permission mode (an Apollo finding from this PR's own self-review, observed
    first-hand during that very run) showed the wrapper's own invocation sitting unanswerable
    while bare `git log`/`git diff` kept working — the inverse of the intended restriction.
    Root cause, confirmed against Claude Code's own docs: a tool call matching `--allowedTools`
    still goes through a permission decision that nothing can answer outside an interactive
    terminal unless a mode says otherwise, while Claude Code separately treats a *built-in,
    not-configurable* set of Bash commands — including "read-only forms of `git`" — as always-
    approved **in every mode**, wrapper or no wrapper. `dontAsk` is documented as the mode for
    "locked-down CI and scripts": it auto-denies anything not pre-approved and never waits for
    input. Added to all three provider-invocation surfaces (`cli/providers/claude.sh`,
    `action.yml`, `action/review.yml`), replacing the CLI surface's prior `--permission-mode
    default` (whose own docs describe it as prompting on first use, not denying).
  - **Honest consequence of that built-in bypass:** a bare `git diff`/`show`/`log`/`status`
    with no flags can run without ever reaching `pantheon-git-readonly.sh` at all, on any
    tier, because Claude Code itself always allows those — this is expected and fine (they're
    genuinely read-only), but it means the wrapper's actual job is everything *beyond* that
    built-in-safe set (any flag, any other subcommand), not "every git invocation routes
    through it." The wrapper remains the enforcement point for that broader surface regardless
    of what Claude Code's own undocumented internal classifier does or doesn't catch on its
    own — an explicit, versioned, this-repo-owned guarantee instead of a dependency on
    upstream behavior this repo can't audit.
  - The very first PR that runs `install.sh` in a repo and adds `action/review.yml` + the
    wrapper together has the wrapper at its own head but not yet at base — base-pinning
    correctly refuses to read it from the working tree even for that PR (falling back "just
    this once" would reopen the exact vulnerability base-pinning exists to close), so that
    step fails loud with an explanation and a workaround (merge the bootstrap PR via another
    path once) rather than either silently degrading or leaving an unexplained failure.
- **Round 4 — configured fsmonitor hooks, a config-key sweep, and the own-repo trusted
  disposition.** One more Codex finding plus a deliberate audit pass, both closed in the
  wrapper:
  - A pathname-valued `core.fsmonitor` — git's own config docs define that as the path to an
    external "fsmonitor hook" command — ran on a validation-passing `status`, **and** on plain
    `diff` too (git consults the hook to speed up its working-tree scan regardless of which
    read command triggered the scan); `GIT_OPTIONAL_LOCKS=0` did nothing to stop it, a
    different mechanism entirely. Reproduced live by Codex, reproduced again here against a
    real marker-writing hook before landing the fix, on both subcommands. Fixed by forcing
    `-c core.fsmonitor=false` as a GLOBAL config override the wrapper injects itself, applied
    to every subcommand (the hook is a property of the repository scan, not of any one
    subcommand) — a `-c key=value` must precede the subcommand in git's own argument grammar,
    which is exactly why the flag-refusal loop rejects the model ever supplying its own; the
    wrapper's own overrides are trusted precisely because nothing the model supplies can reach
    or alter them, a distinction now stated explicitly in the wrapper's own header comment.
  - Swept git's config docs for every other key that names an executable and is reachable from
    the four allowlisted subcommands with no explicit flag: `core.pager`/`core.editor` (already
    closed by env + `-c`), `log.showSignature`+`gpg.program` (tested live — did not fire on the
    git version this was verified against, forced `-c log.showSignature=false` anyway as
    no-cost insurance), and confirmed `core.sshCommand`/`credential.helper`/`protocol.*.allow`
    are genuinely unreachable — none of `diff`/`show`/`log`/`status` contact a remote, and
    nothing network-capable (`fetch`, `pull`, `clone`, `push`, `ls-remote`, …) is on the
    allowlist. That reachability claim is stated as a standing invariant in the wrapper's own
    comment, not a one-time check: if a future change ever adds a networked subcommand to the
    allowlist, it needs re-auditing. `difftool`/`mergetool`-only config (`difftool.*`,
    `merge.tool`) is unreachable the same way — neither subcommand is allowlisted. Every
    wrapper fixture that proves a config-driven bypass is closed also carries a negative
    control in the same fixture repo (RAW git, same config, MUST fire the marker) —
    the direct check on "did skip test coverage quietly rot into a check that can't fail" this
    whole codebase already applies to itself elsewhere (its own review method: a check that
    can't fail carries no information).
  - **Own-repo disposition.** This repo's own CI self-test (`.github/workflows/ci.yml`'s
    `composite-action-self-check` job) reviews review-pantheon's own PRs, from its own
    checkout, opened by its own maintainer — precisely the own-repo/trusted-author case
    `execution=trusted`'s own docs name as the exception to the readonly default. Set
    explicitly on that one invocation; every other consumer of `action.yml` (reviewing someone
    else's fork PR) is unaffected and still defaults to `readonly`.
- **Round 5 — trace-output-sink environment variables (Codex P2).** git's own docs define
  `GIT_TRACE` and its siblings as trace-output sinks: set to an absolute path, git APPENDS
  trace records there on every invocation — no flag, no config, just an inherited environment
  variable. Reproduced live before fixing: `GIT_TRACE=<path to a tracked file>` pointed at a
  file inside a real repo, run through the pre-fix wrapper, grew that file and left the
  working tree dirty — a write, reachable purely from ambient environment (a debugging-enabled
  CI runner, a shell that happened to have one of these set) rather than anything a hostile PR
  controls directly. `GIT_TRACE2_EVENT`'s directory-sink form (a directory value creates a
  per-process file inside it) is a distinct code path, reproduced and fixed the same way.
  Fixed by unsetting every documented trace-output-sink variable in the wrapper's forced
  environment: the general trace, the per-subsystem traces (fsmonitor, pack access, packet,
  packfile, performance, refs, setup, shallow, curl and its verbose sibling
  `GIT_CURL_VERBOSE`), and the Trace2 library's three sinks (human-readable, JSON event,
  perf). Both trace mechanisms now carry a live fixture with a negative control (raw git DOES
  write/create the marker; the wrapper does not), the same "not green-by-construction"
  standard every config-driven-bypass fixture in this file already holds itself to.
- **Round 6 — a comprehensive exec/write-surface close, plus base-pinning `gate.conf`'s
  `execution=` itself.** After five rounds of individual findings on the same wrapper, this
  round did one exhaustive pass instead of another single patch:
  - **`cli/lib/pantheon-git-readonly.sh`'s header comment is now the single canonical
    enumeration** of every git config key, attribute, or environment variable that names an
    executable or a write target, checked against git's own documentation for reachability
    from the four allowlisted subcommands with no explicit model-supplied flag — a table of
    vector → neutralization → verification status, plus a "not reachable" section (aliases,
    remote-touching mechanisms) with the reasoning for why each is out of scope, stated as a
    standing invariant, not a one-time check. Read that file directly rather than duplicating
    the table here — this section only calls out what's new since Round 5.
  - **Clean/smudge filters** (`filter.<name>.clean`, activated via `.gitattributes` —
    distinct from the ext-diff/textconv machinery Round 2 closed): fire on a `diff` that
    touches the WORKING TREE (a bare `diff` or `diff <single-ref>`), never on a blob-to-blob
    range comparison. Reproduced live on both forms; confirmed `show`/`log`/`status` never
    trigger this mechanism at all. Fixed structurally, not by blocklisting the filter
    mechanism itself: `diff` now requires its first positional argument to contain `..` (a
    proper range) — the ONLY form DESIGN.md rule 1 and every generated run-context prompt
    ever told an agent to use in the first place, so this costs no legitimate capability.
  - **Auto-maintenance** (`gc.auto`, `maintenance.auto`): tested for a live trigger from
    `status` (git's own trace output showed no gc/maintenance invocation) — not reproducible,
    forced off anyway (`-c gc.auto=0 -c maintenance.auto=false`) as the same no-cost-insurance
    posture as Round 4's `log.showSignature=false`.
  - **`gate.conf`'s `execution=` key itself is now base-pinned**, closing a gap in the
    wrapper's own trust model: `cli/review-gate` never checks out the PR branch, but a
    maintainer who first runs `gh pr checkout <n>` (a common local-review habit) before
    invoking `review-gate` would have the PR's own head content checked out — including a
    hostile `gate.conf` shipping its own `execution=trusted` to restore unrestricted Bash
    before the gate inspects anything. Same trust boundary as `REVIEW_RULES.md`/`DESIGN.md`
    base-pinning, applied to this one security-sensitive `gate.conf` key; every other
    `gate.conf` key (provider, model, base_branch, rules_file, spec_file, agents) is
    lower-stakes and stays working-tree-sourced, unchanged. An explicit `--execution` CLI flag
    is operator-typed input, not PR-controlled configuration, so it's resolved and validated
    immediately (fail-fast, before any `gh`/network call) rather than waiting on `BASE_SHA` —
    only the gate.conf-sourced fallback waits for the base-pinned read.
- **Round 7 — the three findings deferred off PR #5 (issue #7), closed out.** Round 6's own
  header-comment matrix flagged these as new-since-Round-5; they were tracked as a follow-up
  rather than reopening PR #5's scope.
  - **`GIT_NO_LAZY_FETCH=1`**, forced alongside `GIT_OPTIONAL_LOCKS=0`. In a partial clone
    (`--filter=blob:none`) missing a promisor object, an allowlisted `diff`/`show`/`log`
    touching that object silently contacts the configured remote and writes the fetched pack
    into `.git/objects` — a network round-trip AND a write, from a subcommand this wrapper's
    whole premise is "no transport, no write." Reproduced live against a local `file://` remote
    (no real network needed to exercise the identical lazy-fetch code path git uses for any
    remote): a fresh bare partial clone, reading the tip blob with `GIT_NO_LAZY_FETCH` unset
    grew `.git/objects` from 4 to 8 files; the pre-fix wrapper (which set no such variable)
    reproduced the exact same growth. With `GIT_NO_LAZY_FETCH=1` forced, the identical read
    instead fails closed (`fatal: bad object HEAD:<path>`) with zero objects written.
  - **`GIT_REDIRECT_STDOUT`/`GIT_REDIRECT_STDERR` scrubbed**, unset alongside the existing
    `GIT_TRACE*` block — git's own docs describe these as a Git for Windows mechanism that
    redirects `git.exe`'s own stdout/stderr handles to a named path, the same
    inherited-environment-driven class as the trace sinks Round 5 already closed. Confirmed as
    a documented no-op on this repo's (non-Windows) development and CI platforms via a local
    repro (set + run, no file created) — the fixture for this one is necessarily structural
    (the scrub is present in the wrapper source) rather than a live marker-file proof, and says
    so rather than pretending a Linux CI runner exercised a Windows-only code path.
  - **The `..`-substring diff-range check replaced with real revspec validation.** The
    substring check (`"$first_positional" == *..*`) accepted the STRING "foo..bar" as a
    "range" whether or not "foo" and "bar" were real revisions. A tracked working-tree file
    literally named `foo..bar`, with a configured clean filter, exploits git's own
    disambiguation rule — fall back to treating an unparseable revision-shaped token as a
    PATHSPEC when it names an existing path — so `diff foo..bar` becomes a working-tree diff of
    that one file, reopening the exact clean-filter path the original substring check was
    meant to close. Reproduced live against the pre-fix wrapper (checked out from its
    pre-Round-7 commit): `diff foo..bar` in a repo with that file and filter configured ran
    clean, no refusal, and the filter fired. Fixed structurally: each side of the range is now
    independently resolved via `git rev-parse --verify --quiet <side>^{commit}` before diff
    ever runs, under the same hardened environment as every other git invocation this wrapper
    makes; a side beginning with `-` is refused outright first (never handed to `rev-parse` as
    a potentially flag-shaped argument), and a side that fails to resolve is named in the
    refusal, not silently reinterpreted as a pathspec.
  - All three carry live-proof fixtures in `tests/test-git-readonly-wrapper.sh` (raw-git
    negative controls where the platform allows one; an honest structural-only note for the
    Windows-only redirect sinks), each independently reproduced failing against the pre-fix
    wrapper before the fix landed — the same "not green-by-construction" standard every
    config-driven-bypass fixture in this file already holds itself to.
- **Round 8 — caller-supplied `--` shifts a revspec-validated range into pathspec position
  (Codex, round 2 on the PR carrying Round 7).** Revspec-verifying both sides of a diff range is
  NOT sufficient on its own: `git diff -- A..B`, forwarded verbatim by Round 7's wrapper, is
  parsed by real git as a PURE PATHSPEC — not a revision — because of the leading `--`, even
  though `A` and `B` independently resolve as real commits via `rev-parse --verify`. A tracked
  working-tree file literally named `<A>..<B>` (trivially constructable: any two real ancestor
  commit SHAs) plus a configured clean filter reopens the exact clean-filter RCE Round 7 was
  written to close — reached through argument POSITION (a caller-supplied `--`) rather than
  argument CONTENT. Reproduced live against Round 7's own pushed commit: `diff -- <A..B>` ran
  clean, no refusal, filter fired. Fixed by the wrapper owning the pathspec boundary end to end,
  not by blocklisting the leading-`--` shape specifically: the caller can never supply `--` at
  all now (closed in the top-level argv-validation loop, for every subcommand — show/log/status
  swept for the same argument-position class, not just diff), `diff` accepts EXACTLY one
  positional argument (so there is no second, pathspec-shaped slot even without an explicit
  `--`), and the wrapper appends its OWN trailing `--` after the validated range on exec (never
  a caller-influenced one). The previously-accepted `diff <range> -- <path>` pathspec-scoping
  form is consequently no longer supported — it was never a documented DESIGN.md rule 1 usage,
  and was exactly the surface this bypass exploited. Carries the same live-proof-plus-negative-
  control fixture pattern (`tests/test-git-readonly-wrapper.sh`), independently reproduced
  failing against Round 7's pushed commit before this fix landed.

## The provenance class — issue #6

Base-SHA-pinning `REVIEW_RULES.md`/`DESIGN.md` closed twice already before this class's own rule
was stated precisely — the read-only git wrapper (`pantheon-git-readonly.sh`, base-pinned into
the vendored workflow) and `gate.conf`'s `execution=` key (base-pinned in the CLI surface) — when
two more instances of the identical gap surfaced as Codex P1 findings on the SAME PR that added
those two fixes, because the fix had been applied per-instance instead of as a swept, complete
pass: `action/review.yml` still ran `.github/review-agents/decide_verdict.py` and read
`.github/review-agents/${AGENT_NAME}.md` straight out of `$GITHUB_WORKSPACE` — the PR's own
checkout. A fork PR could have replaced `decide_verdict.py` to run arbitrary Python and print
whatever verdict-shaped JSON it wanted, or rewritten its own persona file to soften the hunt list
or force a `SHIP`/`ACCEPT` verdict — the gate would have reviewed the fork PR with reviewers and
a grader the fork PR itself controlled. Both are now base-pinned into `$RUNNER_TEMP` the same way
the wrapper is (`action/review.yml`'s "Resolve gate scripts (base-pinned)" step), with the same
fail-loud-not-silent behavior on a bootstrap PR where the files don't exist at base yet. The
published action's `personas_path` override — when set, previously resolved from
`$GITHUB_WORKSPACE/$PERSONAS_PATH` instead of `$ACTION_PATH/agents` — closed the same way:
base-pinned into `$RUNNER_TEMP` when set, unchanged (still `$ACTION_PATH`, already trusted) when
unset. Current-state result: DESIGN.md's "Security posture" read-provenance matrix.

## Round 2 (base-pinning class) — the symlink gap, self-caught

Base-pinning a read as `git show $BASE_SHA:path` is correct for a regular file, but git stores
a tracked **symlink** as a mode-120000 blob whose "content" IS the link target string — `git
show` on a symlinked path therefore returned a pathname, not the referenced file's content, for
every base-pinned read that touches personas, the decider, or rules/spec. A target repo using a
symlinked custom persona (a real pattern: `.github/custom-personas/artemis.md ->
../../agents/artemis.md`) got a broken prompt where the pre-base-pinning checkout-based read
had worked. `cli/lib/pantheon-base-pin.sh`'s `pantheon_base_pinned_read` closes this (Codex P2 on
this class's own PR #8): it detects the mode-120000 case via `git ls-tree`, resolves the target
relative to the symlink's own directory, normalizes the result using pure string manipulation (no
filesystem access — a git-tree-relative path isn't something `realpath` can resolve), refuses
(loud, `git show`'d path never falls back to the working tree) any resolution that escapes the
repository root or has an absolute target, bounds the chain depth at 32 hops (the same convention
`cli/review-gate`'s `resolve_real_dir` and `bootstrap.sh` already use for symlink-following
elsewhere), and only then `git show`'s the resolved in-repo path at BASE. Fixtures:
`tests/test-base-pinned-read.sh` (unit-level, including a fixture-sanity check that reproduces
the raw-pathname bug with a bare `git show` before asserting the fix), plus symlink-aware cases
added to the existing `action/review.yml`/`action.yml` integration fixtures in
`tests/test-prompt-assembly.sh`.
