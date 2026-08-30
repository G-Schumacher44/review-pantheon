# Design — review-pantheon

Five read-only agents, split by what their verdict does: two gate agents (Artemis, Apollo) whose
verdicts **enforce** — wired into a fail-closed PR gate that can block a merge — and three
counsel agents (Socrates, Diogenes, Plato) whose verdicts **inform** a human's decision and never
gate or block, regardless of what they're pointed at: a spec, a design doc, a proposal, existing
code, or a diff. Agent-CLI-agnostic: Claude-first, with pluggable provider lanes (Codex, Gemini,
Cursor). This document is the contract for this public rebuild (see the README's ["On generative
AI use"](README.md#on-generative-ai-use) note for what that means) — the personas, runners,
and workflow are all implementations of what's written here. See `docs/README.md` for a full doc
index.

## The idea

Most AI code review collapses two different jobs into one pass. This system splits them:

- **The hunter (Artemis)** reviews the change itself: correctness risks, untested failure
  paths, shortcuts, rule violations. She assumes nothing works until the code shows it does.
- **The verifier (Apollo)** audits the *claim* of completed work: re-runs stated verification,
  diffs what was claimed against what git actually shows, checks required records were written.
  He assumes nothing was done until evidence shows it was. When a governing spec file is named
  in his run context, he also checks the delivered change against the sections of it relevant
  to what changed — a contradiction there is rule 5 below, enforced per-PR, not just documented.

They are twins, not duplicates — different questions, different failure modes caught. Together
they're the **gate agents**: machinery that runs on every PR, in CI and the CLI, against
finished work.

A second tier — **counsel agents** — exists to inform, not enforce: their verdict is counsel a
human weighs in a decision, never a mechanism that gates a merge. That's a property of what
they're for, not of what they're allowed to read — they read a spec, a design doc, a proposal,
existing code, or a diff alike, the same lens applied to whichever one they're handed. Their
natural home leans early — before building, while the decision is still open — but nothing
about them is scoped to design documents only:

- **Socrates** — options analyst: usually runs earliest, maps distinct approaches and go/no-go.
- **Diogenes** — simplicity auditor: is this MORE than it needs to be?
- **Plato** — coherence auditor: does this have a coherent shape, or is it ad-hoc sprawl?

They can be added to a CLI gate run via `--agents` or `gate.conf` for a shape check alongside the
twins, but that wiring is the exception: their design purpose is a human reading their counsel
and deciding, not a pipeline deciding for them.

<details>
<summary>Gate flow at a glance</summary>

```
GATE — enforce, every PR                    COUNSEL — inform, before merging
------------------------------              ------------------------------
PR opened                                   spec / design doc / proposal
  -> prompt built (agents/<name>.md            / existing code / a diff
     persona + diff/context block)               |
  -> provider lane (pantheon.providers            v
     or claude-code-action)                    philosopher
  -> JSON verdict --(missing/bad)-->            (socrates | diogenes | plato)
     fail-closed: UNVERIFIED                     |
  -> pantheon.verdict decides                    v
     blocker invariant: any "blocker"          advisory verdict
     finding forces red, verdict field           (GO / TRIM / DRIFTING / ...)
     notwithstanding                              |
  -> one combined PR comment                      v
     (signal + table + folded findings)        human decides
```

</details>

## Hard rules (non-negotiable, all agents, all providers)

1. **Read-only.** Agents inspect via read-only git (`git show <ref>:path`, `git diff`,
   `git log`, `git status`). They never run `stash` / `checkout` / `switch` / `reset` /
   `merge` / `commit` / `branch` / `rebase` or anything that mutates the tree, index, or HEAD.
   If a check would require a tree change, the agent stops and reports it as a gap. **Honest
   limit: this is a mechanical tool boundary only under `execution=readonly`** (the wrapper
   physically can't run anything else) — under `execution=trusted` it's persona instruction
   only, since the wrapper isn't in the loop at all, so nothing mechanical stops a compromised
   or misbehaving agent from mutating the tree. `trusted` exists for own-repo/trusted-author use
   only; see "Security posture" below.
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
- **The blocker invariant is enforced, not just documented.** `pantheon.verdict` — the ONE
  verdict-decision implementation, called by every lane (the CLI's `pantheon gate` and the
  published action's five "Decide verdict (<agent>)" steps) — checks it after schema
  validation: if any finding has
  `severity: "blocker"` OR `has_blocker: true`, the signal is forced to red regardless of the
  stated `verdict` field, and the gate logs that the invariant fired. An object where the
  verdict and the findings disagree is treated as red, not trusted at face value. A finding with
  `severity: "blocker"` (or `has_blocker: true`) forces red even when the stated `verdict` word
  itself is invalid — a typo'd or out-of-vocabulary `verdict` still gets overridden to red if a
  genuine blocker is present, rather than landing on the weaker "not gated" signal. That override
  needs an object that's at least type-shaped correctly first, though — see "Validation surface"
  below for the line between "malformed enough to override" and "malformed enough to distrust
  outright."
- A docs-only diff (only `*.md` / `docs/**` changed) may skip Apollo with a loud 🟡 skip note.

### Validation surface

`pantheon.verdict` validates two different things about a verdict object, for two different
reasons, and only one of them is schema-checked:

- **The invariant-read surface — type-strict, fail-closed.** `verdict`, `has_blocker`,
  `findings`, and every `findings[].severity` are the fields the blocker invariant and the
  vocabulary lookup actually reason over — a decision gets made by comparing them, not just
  displaying them. Types are checked, not just presence: `verdict` must be a string,
  `has_blocker` must be strictly boolean, `findings` must be strictly an array, and every
  `findings[].severity` must be a string in `{blocker, should_fix, note}`. Any miss is
  UNVERIFIED, never green. This closes a real gap a presence-only check (`has("has_blocker")`
  etc.) would leave open: `"has_blocker": "true"` (a string) satisfies presence validation, and a
  type-loose comparison would let the blocker invariant compare a string against the boolean
  `true` and silently never fire — a malformed verdict with a smuggled-in string `has_blocker`
  reading as a clean, ungated green.
- **The display surface — deliberately NOT schema-validated.** `file`, `line`, `issue`,
  `scenario`, and `summary` never get compared against anything or branched on — they only get
  *shown*. Validating their types here would just be a second copy of a check the render layer
  already owns: `pantheon.render` sanitizes every one of these fields at render time
  (`sanitize_inline`, plus `.line`'s numeric-or-`?` coercion) precisely because they're untrusted
  model output reaching a Markdown/HTML surface, regardless of what the decider validated or
  didn't about that same data. The two layers check different things for different reasons —
  decision-surface types here, render-surface safety there — and neither substitutes for the
  other.

  This binds the `--json-schema` text the provider lanes hand to the model too. It lives in
  exactly **one** place — `pantheon.providers.VERDICT_JSON_SCHEMA`. `action.yml` no longer
  carries a copy at all: it DERIVES `JSON_SCHEMA` at run time from that constant, imported
  against the action's own checkout with the subshell's cwd pinned to `$ACTION_PATH` (`python3
  -c` puts the cwd at `sys.path[0]` ahead of `PYTHONPATH`, so an unpinned cwd — the consuming
  repo's checkout — would let a PR's own top-level `pantheon/` shadow the trusted schema, the
  same cwd-shadow class closed for the decider). The drift class is gone by construction, not
  policed after the fact; the test that replaced #28's byte-identity comparison asserts the
  derivation command's exact shape, its byte-identical output, and — negative-controlled both
  ways — that a planted hostile `pantheon/providers.py` in a consumer-checkout cwd is imported
  by the UNpinned shape and ignored by the shipped one (tests/test_providers.py). History: this
  was once three copies — the third lived inline in the vendored `action/review.yml`, drifted a
  revision behind because a name-based search couldn't see it, and was deleted with that whole
  file in issue #36; issue #32 then collapsed the remaining pair to this single constant.

  **That schema may never be stricter than the decider.** A schema that rejects a verdict
  `decide()` would have accepted fails closed in the wrong direction: the run surfaces as
  UNVERIFIED / NOT GATED even though a real, reviewable verdict was produced. So the schema is
  strict on the decision surface — `agent`, `verdict`, `has_blocker`, `findings`, and
  `findings[].severity` — and leaves the five display fields **entirely unconstrained**, accepting
  every JSON type, because `decide()` does too and the render layer sanitizes whatever arrives.
  Permitting merely "string or null" there is still stricter than the decider, and still a bug.

## Provider lanes

`pantheon.providers` — one function per provider, each building the argv/env for that lane's
CLI and running it:

- `claude` — `claude -p` with a tiered, execution-scoped tool set (Read, Grep, Glob, and a
  Bash allowlist that depends on the `execution` setting — see "Security posture" below) and a
  timeout. Default lane; the only one integration-tested in v1.
- `codex` — `codex exec` non-interactive.
- `gemini` — `gemini` CLI non-interactive prompt mode.
- `cursor` — `cursor-agent` headless.

The gate never trusts a lane to be well-behaved: it extracts the trailing JSON object from
stdout, validates it against the contract via `pantheon.jqjson`, and treats any failure as
UNVERIFIED. That trailing object must be exactly one JSON document with nothing after it —
trailing content that is itself valid JSON (a second object, array, or scalar, not just
malformed prose) is rejected identically to malformed trailing content.
Provider selection: `--provider <lane>` flag, else `provider=` in config, else `claude`.
Prompts are built identically for every lane: persona file + a generated context block (diff
range, base branch, house-rules file, output-contract reminder). No lane gets a private fork
of a persona.

## Generated per-tool projections (interactive/editor targets)

The provider lanes above run the gate agents (Artemis, Apollo) headless, in CI or from
`pantheon gate`. The counsel agents (Socrates, Diogenes, Plato) live earlier — in the human loop,
during planning and design — which means they need to be invocable *inside* a coding-agent
session, in whatever convention that tool's editor or CLI actually supports. `install.sh`'s
`--claude`/`--cursor`/`--codex`/`--gemini` flags generate that per-tool artifact at install
time.

This looks, on its face, like the thing rule 4 forbids — a persona's content ending up in more
than one file. It isn't the same failure, because it isn't the same axis: rule 4 exists to stop
*hand-maintained* copies from drifting apart, one edited and the other forgotten. Every file
these flags write is mechanically derived from `agents/*.md` by `install.sh` at install time —
frontmatter stripped or reshaped to the target tool's schema, the persona body embedded
verbatim or referenced, and a `GENERATED — do not edit, re-run install` header stamped on top.
There is exactly one place a human edits persona content — `agents/<name>.md` — and every
projection is regenerated from it, never hand-edited independently. That's generation, not
duplication: the artifact repeats, the source of truth doesn't.

Per-tool support is tiered honestly, not uniformly:

- **Claude Code (`--claude`)** — first-class. The persona files are already valid Claude Code
  subagent format (YAML frontmatter + body), so they're copied verbatim into
  `.claude/agents/`. Four canonical skills — `skills/{gate,counsel,spec-driven,design-contract}/SKILL.md`,
  the single hand-maintained source, the same rule-4 shape applied to skills instead of personas —
  are copied verbatim into `.claude/skills/<name>/SKILL.md`. A generated `/counsel` command
  (`.claude/commands/counsel.md`) wraps Socrates, Diogenes, and Plato into one invocation that
  runs Socrates first on an open decision, the other two on a proposed shape, and synthesizes
  their verdicts; a generated `/gate` command (`.claude/commands/gate.md`) thin-invokes the
  installed `gate` skill.
- **Cursor, Codex, Gemini (`--cursor`/`--codex`/`--gemini`)** — best-effort, same posture the
  provider lanes already take with unverified CLIs: each tool's repo-level custom-command (or
  closest equivalent) convention was checked against that tool's own current official docs
  before implementing, not assumed from Claude Code parity. Where a tool has no repo-level
  command convention at all, `install.sh` says so and skips it rather than inventing one — see
  the flag's own comment block in `install.sh`, and the verification matrix below for what was
  checked against which source, per tool.

<details>
<summary>Per-tool editor/CLI install matrix (verified vs. best-effort)</summary>

| Tool | What's generated | Status |
|---|---|---|
| **Claude Code** (`--claude`) | All five personas copied verbatim into `.claude/agents/`; the four canonical skills (`gate`, `counsel`, `spec-driven`, `design-contract`) copied verbatim into `.claude/skills/<name>/`; a generated `/counsel` command (`.claude/commands/counsel.md`) that runs Socrates first, then Diogenes + Plato, and synthesizes the verdicts; a generated `/gate` command (`.claude/commands/gate.md`) that thin-invokes the `gate` skill. | **Verified, first-class.** The personas are already this format; skills follow the documented [Skills](https://code.claude.com/docs/en/skills) `SKILL.md` convention (`.claude/skills/<name>/SKILL.md`, project or user scope); `/counsel` and `/gate` follow the documented [slash-command](https://docs.claude.com/en/docs/claude-code/slash-commands) convention. |
| **Cursor** (`--cursor`) | All five personas as native subagents, `.cursor/agents/*.md` (frontmatter adapted to Cursor's schema). | **Verified against current official docs** ([cursor.com/docs/subagents](https://cursor.com/docs/subagents), Cursor 2.4+). Best-effort: not integration-tested against a live Cursor install in this repo's CI. |
| **Codex CLI** (`--codex`) | All five personas as Codex Skills, `.agents/skills/<name>/SKILL.md`. | **Verified against current official docs** ([developers.openai.com/codex/skills](https://developers.openai.com/codex/skills)). Codex has no repo-level "custom command" convention, so Skills is used instead of inventing one. Best-effort: not integration-tested against a live Codex install. |
| **Gemini CLI** (`--gemini`) | All five personas as custom commands, `.gemini/commands/<name>.toml`. | **Verified against official docs** ([custom-commands.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/custom-commands.md)). Best-effort: not integration-tested against a live Gemini CLI install. |

Claude's `/counsel` is the only generated synthesis command — for the other tools, invoke the
counsel personas individually and reason across their verdicts yourself.

</details>

## Combined PR comment

Every gate run posts exactly one comment: a bold signal line (🟢 clean pass / 🟡 review notes /
🟠 NOT GATED, fail-closed / 🔴 blocked) with a one-sentence plain-language read on what that
means for the merge, a verdict table (one row per agent — a docs-only skip or a same-run
failure shows up as its own loud row, never silently dropped), then a findings fold: human-
readable per-agent sections — an identity line (agent, reviewed head SHA, verdict), the agent's
own one-line summary, an overridden-verdict notice if the blocker invariant fired, and
itemized findings (severity badge, `file:line`, the issue, the concrete failure scenario) —
forced open on red/orange, collapsed otherwise. The raw per-agent verdict JSON still ships,
nested inside that fold as its own collapsed block, so the machine-readable form is never lost,
just no longer the primary read. `pantheon.render` is the one implementation of this — invoked
by `pantheon gate` directly and by `action/lib/combine_verdicts.sh` (the published action's
renderer), so the CLI surface and the published-action surface read identically by construction,
not by hand-kept-in-sync wording. Every workflow-file install method (Way A, Way C) is a thin
caller of the published action, so it inherits this identical rendering rather than reaching it
partially — the vendored `action/review.yml` used to be a separate, partial-reach render path
(a hand-synced inline comment-build step that called the real `sanitize_inline` for escaping but
assembled its own plainer table shape) until issue #36 deleted it.

## House rules are pluggable

Artemis and Apollo check "house rules" as blockers — but every team's rules differ. The gate
passes the target repo's `REVIEW_RULES.md` (path configurable) into the prompt context; agents
treat each listed rule as a blocker-class check. Ships with `REVIEW_RULES.example.md`
(no secrets in diffs, no direct commits to the default branch, tests updated with behavior).

## Configuration

`gate.conf` in the target repo root (simple `key=value`, all optional) — **CLI surface only**; the
Action doesn't read it (see "Surface differences" below). `install.sh` does not install it —
CLI-surface users copy `gate.conf.example` themselves (see [docs/CLI.md](docs/CLI.md#gateconf)).

```
provider=claude          # lane in pantheon.providers
model=                   # lane-specific model id; empty = lane default
base_branch=main         # merge base for the review diff
rules_file=REVIEW_RULES.md
spec_file=DESIGN.md      # governing spec, Apollo-only context; only-if-exists; empty disables
agents=artemis apollo    # panel for the standard gate
execution=readonly       # readonly (default) or trusted — see "Security posture"
```

## Security posture

This section describes current-state behavior only — the exec-surface matrix, the
read→provenance matrix, tier definitions, the validation surface, and this project's honest
limits. Fix-round history (the adversarial-review findings that shaped these rules) lives in git
history, not here — a contract describes what's true now, not how it got that way.

- **PR metadata validation.** PR number (`^[0-9]+$`), branch names (`^[A-Za-z0-9._/-]+$`), and
  head/base SHA (hex) are validated before any of them touch a prompt or a shell command on
  every surface — the CLI (`pantheon.cli`) and the published action (`action.yml`), which every
  workflow-file install method inherits. Unsafe metadata → UNVERIFIED, not a crash.
- Model output is never interpolated into shell (`run:`) directly — it travels via files and
  env vars.
- **Base-SHA-pinned context file reads.** `REVIEW_RULES.md` and the spec file (`DESIGN.md` by
  default) are read via `git show <base-sha>:<path>` — the PR's BASE commit — never from the
  checked-out working tree, on every surface. This closes a fork-PR instruction-injection class:
  on a fork PR, the working tree at review time can hold the PR author's own edits to those
  files, and a rules/spec file read from there would let whoever opened the PR inject content
  straight into the reviewing agents' prompts (e.g. a house "rule" that tells the reviewer to
  wave everything through). A file the PR itself adds or edits only on its head is never read
  for this purpose; when it's absent at the base commit, every surface falls back to omitting it
  — a loud "not present at base — not applied" note for the always-on house-rules file, the same
  pre-existing silent skip as when it's absent entirely for the only-if-exists spec file.
- **The general rule (issue #6's class).** Any file that shapes what the gate *does* — not just
  what it judges by — must be read from trusted provenance before use. "Trusted provenance" is
  one of exactly two things, never a third: the PR's **base ref** (`git show $BASE_SHA:<path>`)
  for a file living in the target repo, or **the action's own checkout**
  (`$ACTION_PATH`/`github.action_path`) for a file shipped with review-pantheon itself — this
  closes the class where a fork PR could rewrite the reviewer's own instructions or
  verdict-grading code, not just the content it's being judged on (see `agents/*.md`'s "Untrusted
  data, not instructions" for the parallel rule on judgment content).

  **Read → provenance matrix, every surface, current state** (✅ = base-pinned or
  action's-own-checkout, i.e. trusted provenance; ⚠️ = judgment content, not gate behavior, kept
  as a documented exception; — = not applicable to that surface):

  | File read | CLI (`pantheon gate`) | Published action (`action.yml`) |
  |---|---|---|
  | Personas (`agents/*.md`) | ✅ review-pantheon's own installed copy, never the target repo's | ✅ `$ACTION_PATH/agents` by default; ✅ base-pinned into `$RUNNER_TEMP` when `personas_path` is set |
  | Verdict decider (`pantheon.verdict`) | ✅ this repo's own installed package | ✅ `$ACTION_PATH/pantheon/verdict.py` |
  | Read-only git wrapper (`pantheon.execution`) | ✅ this repo's own installed package | ✅ `$ACTION_PATH/pantheon/execution.py` |
  | House rules / spec (`REVIEW_RULES.md` / `DESIGN.md`) | ✅ base-pinned (`git show $BASE_SHA:path`) | ✅ base-pinned (`git show $BASE_SHA:path`) |
  | `gate.conf`'s `execution=`/`provider=`/`rules_file=`/`spec_file=`/`agents=` keys | ✅ base-pinned (all five, one `git show`+parse) | — (no `gate.conf`; these are explicit inputs, operator-typed, not PR content) |
  | `gate.conf`'s `model=`/`base_branch=` keys | ⚠️ working-tree-sourced — neither affects tool-execution breadth or which file is trusted as a judgment boundary (`model` only picks which model an already-scoped provider uses; `base_branch` is a fallback only ever consulted when `gh pr view` itself doesn't report a `baseRefName`) | — |
  | `.review-gate-state.json` (follow-up-mode `reviewed_sha`) | ⚠️ working-tree-sourced (see "Honest limit" below) | — |
  | Prompt-builder code (`pantheon.cli`, `action/lib/build_prompt.sh`, `action/lib/combine_verdicts.sh`) | ✅ this repo's own installed package | ✅ `$ACTION_PATH/...` |
  | The diff / file contents under review | untrusted **by design** — this is the data the gate exists to evaluate; never treated as instructions (`agents/*.md`'s "Untrusted data, not instructions") | same |

  Every workflow-file install method that lands in a target repo (`install.sh`'s Way A,
  `examples/review-gate.yml`'s Way C) is a thin caller of the published action above, not a
  separate surface — issue #36 deleted the vendored `action/review.yml` reimplementation that
  used to have its own row here (base-pinning everything into `$RUNNER_TEMP` itself, since a
  target repo's own checkout is untrusted PR content). That surface's whole reason to exist —
  duplicating this provenance discipline a second time in bash — is gone with it.

  **A tracked symlink needs its own resolution, not a bare `git show`.** Git stores a tracked
  symlink as a mode-120000 blob whose "content" IS the link-target string, so a bare
  `git show $BASE_SHA:path` on a symlinked path returns a pathname, not the target file's
  content. Every base-pinned read this section's matrix marks ✅ routes through
  `pantheon.basepin.base_pinned_read` instead: it detects the mode-120000 case via
  `git ls-tree`, resolves and bounds the symlink chain (32-hop cap, refuses any resolution
  escaping the repo root or using an absolute target — loud, never a silent fallback to the
  working tree), and only then `git show`'s the resolved in-repo path at BASE. Its two failure
  modes are distinguished by return code on purpose — 2 is ordinary absence (an only-if-exists
  file like `DESIGN.md` falls back to "not applied"), 1 is REFUSED (an escaping or over-deep
  chain) and is never folded into that same silent path, so a hostile symlink can't be mistaken
  for mere absence. Fixtures: `tests/test-base-pinned-read-python.sh`,
  `tests/test-prompt-assembly-python.sh`.

  **Honest limit on the sweep.** `.review-gate-state.json` (CLI-surface-only — see "Follow-up
  mode" below; git-ignored only via the `install.sh`/Way-A path, see
  [CLI.md](docs/CLI.md#the-state--follow-up-model) for the other paths) is read from the target
  repo's working tree to decide the incremental diff range for a follow-up review. In the
  specific scenario where a maintainer runs `gh pr checkout <n>` before invoking `pantheon gate`
  (the same local-review habit that motivated base-pinning `gate.conf`'s `execution=` key), a PR
  that force-adds a crafted `.review-gate-state.json` could in principle narrow the diff range
  Artemis is shown. Left open rather than base-pinned here: it requires a visibly unusual act
  (committing a normally-ignored — where it IS ignored — dotfile) that a reviewing agent, or a
  human skimming the file list, is likely to flag on its own, it only affects the CLI surface's
  human-operated incremental mode (not the fail-closed-by-default CI gate), and base-pinning it
  would need to special-case follow-up mode's whole "what changed since I last looked" premise.
  Tracked as a known, accepted gap rather than silently unswept.
- The consumer's own checkout step (`examples/review-gate.yml`'s `actions/checkout@v4` — the
  Action itself has no checkout step of its own to configure this on) is expected to set
  `persist-credentials: false`. The Action fails loud (not skip) when its token secret is absent
  on same-repo runs — the one documented exception is a fork PR: GitHub withholds `secrets.*`
  from a fork-originated `pull_request` run, so the Action detects that case specifically and
  exits 0 with a NOT-GATED notice instead of failing (`action.yml`'s "Assert exactly one auth
  input is set" step; disclosed in SECURITY.md/SETUP.md, not a silent skip of the general rule).
  It pins `anthropics/claude-code-action` to a full commit
  SHA — `d40ddef4c030e508327d6e35a9c45f3368482c50` (v1.0.195) — read directly from that
  release's own `action.yml`, not assumed or copied from an older version's docs (a moving
  tag, or an unpinned `uses:`, is the thing to avoid here). If you re-pin to a newer release
  yourself, that's step one of the install checklist (`install.sh`'s printed output and the
  README quickstart) — the verification step there is "confirm the pinned SHA matches a release
  you trust," not "guess the interface," since the interface itself is now grounded (see
  "Published action" below).
- The published action passes the workflow token to `claude-code-action` explicitly
  (`github_token: ${{ inputs.github_token }}`), so consumers never need to grant
  `id-token: write` — that permission is only needed for claude-code-action's internal
  OIDC-token-exchange fallback, which it skips entirely once a `github_token` input is supplied.
- **Credential redaction at render time — closes the render's own link in a three-link chain,
  honestly, not completely.** `anthropics/claude-code-action`'s own pinned source copies its
  entire `process.env` — the workflow token included — into the SDK options for the process that
  runs the reviewer model (deleting only two OIDC-related vars first); the reviewer model then
  reads untrusted PR content. Neither of those first two links is something this repo controls.
  The third link — rendering that model's verdict fields into the PR comment we post — is: even
  if a compromised reviewer emits a credential in a `file`/`issue`/`scenario`/`summary` field,
  `pantheon.render.redact_paths` (the module's single redaction chokepoint, extended — see that
  function's own docstring) strips it before the comment is ever posted, in both the
  human-readable sections and the machine tail (the raw-JSON echo, this control's highest-risk
  surface since it prints model output verbatim). Two passes: literal env-configured credential
  VALUES the RENDERER's own process can see (`GITHUB_TOKEN`/`GH_TOKEN`/`GH_ENTERPRISE_TOKEN`,
  `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, the AWS/OpenAI/Gemini/Google/Cursor keys — every
  opaque-credential entry on `pantheon.providers._PROVIDER_ENV_PASSTHROUGH_KEYS`, plus
  `GH_TOKEN`/`GITHUB_TOKEN`/`GH_ENTERPRISE_TOKEN` from `pantheon.cli`'s own git/gh allowlist — a
  mechanical test, `test_every_credential_shaped_forwarded_env_key_is_redacted`, enforces that
  every credential-shaped name on either real allowlist is on this redaction list too, so this
  can't silently drift out of sync the way `GH_ENTERPRISE_TOKEN`'s own omission did — Codex P1,
  PR #75), and known credential-SHAPED prefixes (`ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`/`github_pat_`,
  `sk-ant-`) for a token this process's own env never held at all.

  **This literal-value pass has an unstated precondition worth naming: it can only redact a value
  present in the RENDERING process's OWN environment — nothing guarantees that's a superset of
  what the REVIEWING process's environment held.** The published action's own composite-action
  steps are a concrete instance: each `Run <agent>` step hands the reviewer model
  `${{ inputs.github_token }}`, but the separate "Build and post combined comment" step that
  renders and posts the result only received `${{ github.token }}` — identical under the default
  setup, which is why this went unnoticed, but a consumer workflow that overrides the
  `github_token` input (a GitHub App installation token, a PAT, a GHES token) hands the reviewer a
  DIFFERENT token than the render step could see, and the shape-based pass doesn't cover every
  legacy/GHES/App token format either. Fixed by forwarding the reviewer's own token into that
  step's environment as a dedicated, REDACTION-ONLY variable
  (`PANTHEON_REVIEWER_GITHUB_TOKEN` — see `action.yml`'s "Build and post combined comment" step
  and `pantheon.render._CREDENTIAL_ENV_KEYS`'s own comment) purely so the literal pass can see it —
  never used to authenticate anything itself (Codex P1, PR #75).

  **The honest limit, restated precisely: literal redaction covers credential VALUES the
  renderer's own process can see (now including the reviewer's actual token, forwarded
  redaction-only, not just this repo's own git/gh credential); shape redaction covers
  credential-SHAPED formats this module knows about. Neither pass can catch a credential the
  model transforms** — split across characters, base64-encoded, paraphrased, or otherwise never
  appearing verbatim/shape-matched in the rendered text. That's a real, disclosed gap, not a
  claim of completeness; the mitigation this control provides is closing the links in the chain
  that were ours to close, not eliminating the class.
- **Tiered tool execution — read-only by default.** Every provider invocation's tool set is
  scoped by an `execution` setting: `readonly` (the default — `gate.conf`'s `execution=`, the
  CLI's `--execution` flag, or `action.yml`'s `execution` input) restricts Bash to exactly one
  Claude Code permission-rule prefix — a fixed invocation of `pantheon.execution`'s read-only git
  wrapper — with Read/Grep/Glob left unrestricted (already read-only by nature). `trusted`
  restores full Bash, the pre-existing v1 behavior. Reviewing a fork PR's diff means reviewing
  100%-attacker-controlled content; an agent that prompt injection can steer into running an
  arbitrary shell command is a code-execution primitive, not a review gate, so `readonly` is the
  default on every surface that invokes a provider — `trusted` is an explicit, documented opt-in
  for own-repo/trusted-author use only, never for reviewing a fork PR you don't control.
  - **The allowlist is only half of it: the built-in bypass is denied too.** Claude Code
    auto-approves a small built-in set of read commands — `ls`, `cat`, `echo`, `pwd`, `head`,
    `tail`, `grep`, `find`, `wc`, `which`, `diff`, `stat`, `du`, `cd`, and read-only forms of
    `git` — *before* `--allowedTools` is consulted, in every permission mode including `dontAsk`.
    Under `readonly` that is a second path to the checkout that never reaches the wrapper's argv
    validation. `pantheon.execution.disallowed_tools_for()` emits a deny rule per entry in
    `DENIED_BUILTIN_BASH_COMMANDS`, and deny beats allow in Claude Code's own precedence, so each
    of those commands is forced back through a permission decision that `readonly`'s allowlist
    then fails closed on. `git` is denied deliberately, which forces every git read through the
    wrapper; the wrapper is invoked by its own absolute path, never a bareword `git`, so the two
    prefixes are disjoint by construction and a fixture asserts no deny entry shadows the
    wrapper's own allow entry. Both surfaces read this list from that one function —
    `action.yml` shells out to `pantheon/execution.py disallowed-tools <tier>` rather than
    duplicating it in YAML. `trusted` emits no deny list; full Bash is that tier's explicit opt-in.
    The rule shape is the trailing-wildcard form only (`Bash(cmd *)`), verified empirically with a
    negative control rather than read off the docs: with no deny rule a bare `pwd` runs, and under
    `Bash(pwd *)` it is refused — so the wildcard form already covers the zero-argument
    invocation and an exact-match companion entry would be dead weight.
  - **Only `pull_request` is permitted, enforced at runtime.** `action.yml`'s first step hard-fails
    (exit 1, no `if:`, before any checkout-dependent work or model invocation) unless
    `github.event_name` is exactly `pull_request`. This is an allowlist by design: an earlier
    draft named the two obviously-dangerous triggers, and review pointed out that
    `pull_request_review_comment` and `pull_request_review` also run from the base repository
    with secrets while carrying a populated `github.event.pull_request` payload — so they passed
    a blacklist. Enumerating unsafe events means being wrong whenever a new one appears; every
    step here reads the PR number and base/head SHAs from `github.event.pull_request`, so that
    context is the only one this action is built for. This is deliberately NOT the same path as the fork-PR NOT-GATED exit, which
    remains a legitimate exit-0 skip: an ordinary `pull_request` run from a fork has no secrets to
    protect (GitHub withholds them), so review is impossible rather than unsafe. This step covers
    the opposite case — a run that *does* hold secrets over content it should not. See
    SECURITY.md's "Fork pull requests cannot be gated by this action" for why the `workflow_run`
    shape this refuses is not a working path here regardless of the trigger question.
  - The CLI surface's wrapper ships as part of the `pantheon` package and is resolved via its
    installed console script (`pantheon-git-readonly`) — `pantheon.cli._wrapper_invocation()`
    resolves that script's own absolute path via `pantheon.execution.resolve_console_script`,
    never `python -m`, so the invocation is immune to a checkout-directory shadow attack.
    `action.yml` reads `pantheon/execution.py` directly from its own checkout
    (`github.action_path`, no vendoring needed — that checkout is review-pantheon's own trusted
    tree, never the reviewed PR's), invoked by its own absolute path with `python3`, same
    shadow-safety property without relying on an installed console script. Every workflow-file
    install method (Way A, Way C) inherits this directly, since both are thin callers of
    `action.yml` — there is no vendored copy of the wrapper in a target repo to protect any more.
    (Before issue #36, the vendored `action/review.yml` DID copy `pantheon/execution.py` into the
    target repo, which needed its own base-pinned resolution step to close the same shadow class
    from a different angle — that whole mechanism is gone with the file it protected.) A Way-A
    installer who genuinely needs `trusted` uncomments the `execution: trusted` line the
    generated thin caller already ships, commented out — a one-line edit, not a wrapper-vendoring
    concern any more.
  - Every runtime's generated per-run prompt tells the agent to call the wrapper in place of raw
    `git` when `readonly` is active (`pantheon.execution.execution_context_note`, templated into
    every prompt-builder) — the persona files themselves stay install-agnostic (rule 4) and can't
    embed a path that differs per install, so the per-run context block is where that
    substitution is told.
  - Codex, Gemini, and Cursor's provider lanes have no equivalent tool-scoping mechanism in
    their own CLIs as of v1, so this tiering currently applies to the Claude lane — the only
    integration-tested one — across both surfaces that invoke it (the CLI, the Action); that gap
    is disclosed, not silently assumed closed.
  - **What the wrapper closes today, in full: `pantheon/execution.py`'s own module docstring**
    is the single canonical enumeration (every git config key, attribute, or environment
    variable that names an executable or a write target, checked against git's own docs for
    reachability from the four allowlisted subcommands with no explicit model-supplied flag —
    vector → neutralization → verification status). Read that module directly rather than
    duplicating the table here.
- **Provider processes launch from a neutral cwd, never the repo checkout — the CLI (Python)
  lane.** *(It is a config-discovery boundary, NOT a read boundary: `Read`/`Grep`/`Glob` are not
  path-scoped and the prompt deliberately hands the agent the checkout's absolute path to reach
  the repo with. Reading it as a read confinement is the wrong inference and SECURITY.md once
  made it.)* (The Action surface gets the identical protection through a DIFFERENT mechanism,
  since a `uses:` step can't be cwd-relocated — see "The Action surface closes the identical
  vector too" below.) `--allowedTools`/the read-only wrapper scope what a provider CLI's *tool
  calls* can do, but a provider CLI's own STARTUP also auto-discovers repo-local configuration
  from its current working directory — entirely before any tool call, entirely outside
  `--allowedTools`'s reach: a PR-committed `.mcp.json` (Claude Code auto-loads and SPAWNS every
  listed MCP server — arbitrary command execution, not a scoped tool call), a PR-committed
  `.claude/settings.json` (hooks that fire on tool events, including an ALLOWED `Read`), or
  `CLAUDE.md`-style project-memory files (PR-controlled prompt content injected before this
  repo's own persona framing ever runs). Closed with three layers, none alone sufficient:
  1. `pantheon.cli` creates a scratch directory it owns (never the checkout, never anywhere
     inside it) and passes it as every provider's own `cwd` (`pantheon.providers`' `neutral_cwd`
     parameter) — nothing repo-local for a provider's own startup-time scan to find. The agent
     still reaches repo content exclusively through the readonly git wrapper (told the real
     repo root via a fixed `--repo-root` literal baked into its own Bash-tool permission prefix
     — see `pantheon.cli._wrapper_invocation`) and explicit `Read`/`Grep`/`Glob` calls against
     the repo root's own advertised absolute path (the prompt's Run-context block).
  2. **`--bare` is DROPPED on every credential path, not passed at all** — an earlier version of
     this lane passed it conditionally (present only when an explicit
     `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` credential was set), but it broke
     `--json-schema`-driven structured output (issue #26 item 3), so it was removed entirely; see
     `pantheon.providers._claude`'s own docstring for the full history and evidence. The neutral
     `cwd` above was always the PRIMARY, unconditional control this whole vector relies on — see
     that docstring for why dropping `--bare` doesn't reopen it. Codex/Gemini/Cursor have no
     documented equivalent flag as of this writing — a disclosed, honest residual exposure for
     those three best-effort lanes, narrowed (nothing repo-local in a neutral cwd) but not
     eliminated, not silently treated as closed.
  3. `pantheon.providers._PROVIDER_ENV_PASSTHROUGH_KEYS` (the explicit env allowlist every
     provider subprocess receives) classifies every allowlisted key as PATH-SHAPED or not.
     `HOME` is never read from ambient env at all — resolved via
     `pantheon.execution.real_home_dir()` (the POSIX passwd database, `pwd.getpwuid`,
     un-redirectable by any environment variable, shared by the readonly git wrapper's own env
     construction). Every other PATH-SHAPED key (`CLAUDE_CONFIG_DIR`, the four `XDG_*` dirs,
     `TMPDIR`, `GOOGLE_APPLICATION_CREDENTIALS`) is validated
     (`pantheon.providers._safe_path_env_value`) to resolve OUTSIDE the repo root/cwd before
     being forwarded — a value that resolves inside either is dropped (never forwarded, loudly),
     regardless of how it got set; the CLI's own default takes over instead. A genuinely
     legitimate override (an operator's real, non-repo `CLAUDE_CONFIG_DIR` for a second account)
     still passes the check and is forwarded unchanged. Fixture proof: `tests/test_providers.py`'s
     `test_claude_env_never_forwards_a_claude_config_dir_pointed_inside_the_repo_root`/
     `test_claude_env_still_forwards_a_legitimate_claude_config_dir`.
  - `execution=trusted` roots the provider's cwd at the real repo root (`ctx.repo_root`) instead
    of the neutral scratch dir — trusted mode is an explicit opt-in for content the operator
    already trusts, never a fork PR, and already grants unrestricted Bash, so neutral-cwd
    protects nothing additional there, and the bare `git diff`/`git show`/`git log` commands
    trusted-mode instructions rely on need a real cwd to work from. Verified in both directions:
    `tests/test_providers.py`'s `test_claude_cwd_stays_neutral_regardless_of_credential_presence`
    and `tests/test_cli_helpers.py`'s paired
    `test_run_agent_uses_neutral_cwd_under_readonly_execution`/
    `test_run_agent_uses_repo_root_as_cwd_under_trusted_execution` both prove the readonly
    tier's neutral-cwd protection holds independently of the trusted-tier behavior.
  - **The Action surface closes the identical vector too.** `action.yml` (the published
    composite action — the only Action surface since issue #36 deleted the vendored,
    no-config-surface `action/review.yml`) invokes `claude-code-action` with cwd at the
    checked-out PR's own working tree — a `uses:` step has no working-directory override the way
    this repo's own shell steps do, so the neutral-cwd relocation the CLI lane uses is not
    available here. It doesn't pass `--bare` either (it empirically breaks
    `--json-schema`-driven `structured_output` on this Action lane — confirmed via a live
    self-hosted-gate failure). It closes the vector with ZERO workspace mutation of this repo's
    own instead: `anthropics/claude-code-action`'s own pinned source (`src/entrypoints/run.ts`,
    the exact SHA this surface trusts) already restores
    `.claude`/`.mcp.json`/`.claude.json`/`.gitmodules`/`.ripgreprc`/`CLAUDE.md`/`CLAUDE.local.md`/
    `.husky` from the PR's base branch, unconditionally, for every PR-triggered run — before the
    CLI's own startup ever reads any of them. Confirmed firing live in this repo's own
    self-check log (`Restoring .claude, .mcp.json, .claude.json, .gitmodules, .ripgreprc,
    CLAUDE.md, CLAUDE.local.md, .husky from origin/dev (PR head is untrusted)`). It contains no
    hand-rolled scrub step of its own — that shape was tried and reverted (a workspace-mutating
    step is destructive to a consuming repo's own tracked `.claude/`/`.mcp.json`/`CLAUDE.md`
    content, the opposite of this action's zero-footprint promise) in favor of relying entirely
    on the upstream action's own native protection.

    Fixtures (`tests/test-action-refs.sh`): `--bare` asserted ABSENT; no step named "Scrub Claude
    auto-discovery surface" exists — and, checked more broadly than just that one step name, the
    file contains no LIVE (non-comment) recursive `rm` targeting `.mcp.json`/`.claude`/`CLAUDE.md`
    anywhere at all (the actual invariant that matters: adopter content must never be deleted by
    this repo's own code), mutation-tested live before relying on it. Honest limit of what's locally
    reproducible, stated plainly: this repo cannot live-verify `claude-code-action`'s own
    `restoreConfigFromBase` behavior against a real GitHub Actions runner from its own CI (can't
    integration-test the published action until this repo is public — see "Published action"
    section); that rests on the pinned source itself AND this repo's own live self-check run's
    console output, the same evidentiary bar every other flag/mechanism claim in this section
    already holds to.
- **Every `gate.conf` key that shapes gate BEHAVIOR is base-pinned, not just `execution=`.**
  `provider=`/`rules_file=`/`spec_file=`/`agents=` resolve from the PR's BASE commit only
  (`pantheon.cli._load_base_pinned_gate_conf` — one `git show`+parse for all five keys alongside
  `execution=`), the identical mechanism and identical `gh pr checkout <n>`-before-invoking-the-CLI
  trust boundary `execution=`'s own base-pinning closes: a working-tree-sourced `provider=` could
  point at any known lane, silently swapping WHICH agent CLI's own judgment gates the merge; a
  working-tree-sourced `rules_file=`/`spec_file=` could redirect either key at a path absent at
  base, silently downgrading the base-pinned CONTENT read's own loud "not present" fallback into
  a full bypass of the real house rules/spec without ever touching their trusted text; a
  working-tree-sourced `agents=` could swap the enforcing twin panel for a weaker or
  non-blocking list. `model=`/`base_branch=` remain working-tree-sourced — neither affects
  tool-execution breadth or which file is trusted as a judgment boundary — see the "Read →
  provenance matrix" table above for the current split. An explicit `--provider`/`--agents` CLI
  flag still wins, exactly like `--execution` already does over its own base-pinned default —
  this closes PR-controlled CONFIGURATION, never an operator's own explicit, interactively-typed
  choice. The read itself is routed through `pantheon.basepin.base_pinned_read` (symlink-safe),
  not a bare `git show`: a tracked SYMLINK at `gate.conf` (a legitimate pattern — pointing at a
  shared `config/gate.conf`, say) would have a bare `git show` return the link-target pathname
  text instead of content, silently reverting every one of these five keys to its compiled-in
  default.
- **`PR_TITLE`/`BASE_REF` are fenced with the same randomized-marker treatment file content
  gets, on both surfaces** (`pantheon.cli`'s prompt builder, `action/lib/build_prompt.sh`'s
  "Build prompt" step) — these two PR-event-context values are interpolated into surrounding
  prose, not embedded raw: `PR_TITLE` specifically is PR-author-controlled data, and both get the
  identical fence-and-label treatment base-pinned file content gets, at a smaller scale.
- **Honest limit on all of the above.** None of this — metadata validation, base-SHA pinning,
  randomized data-block fences, verdict schema/type validation, the blocker invariant,
  untrusted-data persona framing (every persona is told explicitly that everything it reads is
  data, not instructions, and that a directive found inside it is itself a reportable finding —
  see `agents/*.md`'s "Untrusted data, not instructions"), or default-readonly execution —
  eliminates the risk of a schema-valid, deceptive verdict from an agent that injected content
  has fully compromised. Together they raise the bar and make an attempt more visible (an
  injection attempt is itself a flagged finding, not a silent verdict flip) rather than making
  one impossible. Cross-review by a second independent agent (Artemis vs. Apollo) is the
  mitigation against any one agent being fooled — not a guarantee against it.

## Follow-up mode (CLI surface only)

Re-reviewing a PR after new commits reviews `last_reviewed_sha..head`, and the prompt tells the
agent to read its own prior PR comment instead of re-auditing from scratch. Reviewed SHAs are
tracked in `.review-gate-state.json` (bootstraps empty; git-ignored only via the `install.sh`
Way-A path — see [CLI.md](docs/CLI.md#the-state--follow-up-model) for the other install paths),
written by `pantheon.state.update_state()` **only for a green or yellow overall outcome** — a red
or UNVERIFIED result (a transient provider timeout, a malformed model response, anything that
didn't actually gate the PR) leaves the file untouched, so the next run retries from the last
SUCCESSFULLY recorded SHA (the full PR only if there was never one) instead of treating a failed
run as if it had reviewed anything — see `tests/test-state-persistence-python.sh` for the fixture
proving both directions. This is a CLI-only feature, kept deliberately: the Action re-reviews the
full diff on every push already (a fresh runner, no persisted state between runs, and GitHub's own
UI shows the diff since your last review anyway), but a human running `pantheon gate` repeatedly
against the same long-lived PR would otherwise burn a full review's worth of tokens on every
incremental commit. The token-cost problem it solves is real for the CLI surface and doesn't
exist for the Action.

## Review modes: `--pr` and `--branch`

The CLI reviews two things, and which one is a required, mutually-exclusive choice.

`--pr <n>` reviews a pull request and posts the verdict as a comment. `--branch [BASE]` reviews
the branch you are standing on **before any PR exists**, and prints the verdict instead. The
second exists because the PR is the most expensive place to debug — every round costs CI minutes,
a re-review, and comment ceremony — so the same twins run against the local diff first and the PR
opens hardened.

Only three things differ. Everything else is the same code path:

| | `--pr` | `--branch` |
|---|---|---|
| Base branch from | `gh pr view` → `baseRefName` | operator-typed `--branch BASE`, else `refs/remotes/origin/HEAD`, else `main` — **never** the reviewed tree's `gate.conf`, which would let the branch pick its own policy anchor |
| Requires a PR / `gh` / network | yes | no — local git only, works offline and pre-push |
| Verdict destination | PR comment via `gh pr comment` | stdout |
| Exit code | 0 green/yellow, 1 otherwise (`--dry-run` always 0) | identical |
| Follow-up state | records `reviewed_sha`, dedupes an unchanged head | none — a pre-PR run is always deliberate |

**`base_sha` anchors to the base branch TIP on both lanes.** This is load-bearing and is the one
place a naive implementation goes wrong: `base_sha` is what every base-pinned read resolves
against — `gate.conf`'s `execution=`/`provider=`/`agents=`, `REVIEW_RULES.md`, the spec, the
personas. Anchoring it to the merge-base instead would gate a branch cut *before* the base
tightened its policy under the **stale, weaker** policy — a branch old enough to predate
`execution=readonly` would launch its agents with full trusted Bash. Note the honest limit:
`--branch` never fetches, so this is the LOCAL `origin/BASE` as of your last fetch — run
`git fetch` first if the base has moved. The diff still uses
merge-base semantics (three-dot), so a review covers what the branch changed rather than what the
base moved on to. Same construction on both lanes.

Two fail-closed refusals are specific to `--branch`:

- **`HEAD` equals the merge-base** — nothing to review; commit first.
- **`origin/BASE` missing locally** — fetch it or name the right base. It never silently diffs
  against a different base.

Honest limit: "this gate reads commits, not the dirty tree" describes the DIFF only. Agents
receive the repo root and can `Read`/`Grep` the working tree directly, so an uncommitted edit can
influence a verdict stamped with a `head_sha` that does not contain it. `--branch` warns loudly
when the tree is dirty rather than refusing, since reviewing mid-edit is sometimes deliberate.

## Surface differences

The CLI and the Action share personas and the verdict-decision rule, but they are not
identical tools. Differences are intentional, not oversights:

| | CLI (`pantheon gate`) | GitHub Action (`action.yml`) |
|---|---|---|
| Follow-up mode | Yes — incremental diff since last reviewed SHA (see above). | No — re-reviews the full diff on every push; no state persisted between runs. |
| Configuration | `gate.conf` (provider, model, base branch, rules file, agent list, execution tier). | Explicit `with:` inputs (`agents`, `personas_path`, `rules_file`, `spec_file`, `model`, `execution`) — operator-typed in the consuming workflow, never PR content; every workflow-file install method (Way A, Way C) inherits this same input surface, since both are thin callers of this one file. |
| Provider choice | Pluggable lane (`--provider`, `pantheon.providers`); Claude is the only integration-tested one. | Claude only, via `anthropics/claude-code-action`. |
| Draft handling | Detects `isDraft` via `gh pr view`; exits 0, prints `DRAFT — not reviewed, nothing posted` to stdout, posts nothing. | Job-level `if: github.event.pull_request.draft == false` skips the run entirely; nothing posted. Same outcome (no review, no comment), different mechanism. |
| Rules/spec file provenance | Base-SHA-pinned (`git show <base-sha>:<path>`) — see "Security posture" above. | Base-SHA-pinned into `$RUNNER_TEMP` — the "Build prompt" step (`action/lib/build_prompt.sh`) resolves rules/spec CONTENT the same way the "Resolve gate scripts (base-pinned)" step resolves the persona/pantheon-verdict trio. |
| Persona / verdict-decider provenance | N/A — always this repo's own installed `agents/` and `pantheon` package; the target repo never supplies these on the CLI surface. | The published `action.yml` reads `$ACTION_PATH/agents` and `$ACTION_PATH/pantheon/verdict.py` by default (this repo's own trusted checkout), base-pinned into `$RUNNER_TEMP` when `personas_path` opts into reading from the target repo instead. |
| Provider startup config-discovery protection | Neutral cwd (a scratch directory `pantheon.cli` owns, never the checkout) — three layers, see "Security posture" above. `--bare` is DROPPED entirely, on every credential path — it broke `--json-schema`-driven structured output, so the neutral cwd is the sole, unconditional control (see `pantheon.providers._claude`'s own docstring). | No cwd relocation available (a `uses:` step can't take a working-directory override), and NO `--bare` either (empirically breaks `--json-schema`/`structured_output` on this Action lane). Closes the vector with ZERO workspace mutation of this repo's own instead: `anthropics/claude-code-action`'s own pinned source (`src/entrypoints/run.ts`, the exact SHA this surface trusts) already restores `.claude`/`.mcp.json`/`CLAUDE.md`/etc. from the PR's base branch, unconditionally, before the CLI's own startup ever reads them — confirmed firing live in this repo's own self-check log. See "Security posture" above, "The Action surface closes the identical vector too", for the full writeup. |

## Published action

`action.yml` at the repo root is the **one** Action surface, alongside the CLI — a composite
GitHub Action a target repo consumes with a `uses: G-Schumacher44/review-pantheon@<ref>`
reference and nothing else — zero implementation files land in that repo. It reads everything it
needs (personas, the `pantheon` package's verdict-decision, sanitizer, and read-only-git
modules, `action/lib/*.sh`) from its own checkout at `github.action_path`, the copy GitHub
Actions pulls for the `uses:` reference. `examples/review-gate.yml` (Way C) is the whole
consumer-side install for that reference alone — copy it to `.github/workflows/review-gate.yml`
and wire one secret. `install.sh`'s Way A generates a comparably thin `uses:` caller of this same
file, just pinned to a full commit SHA instead of the floating `v1` tag, plus personas and
`REVIEW_RULES.md` landing in the target repo's own history — see "Layout" below and issue #36.
Before that issue, Way A vendored a full second implementation (`action/review.yml`) instead of
calling this file; that duplicate is gone.

- **Bundled personas, overridable.** `agents/*.md` in this repo is read by default
  (`github.action_path/agents`); a target repo can point `personas_path` at its own directory
  instead (e.g. a repo-local fork of a persona) without forking this repo.
- **`agents` input, same fixed five.** Same panel DESIGN.md defines everywhere else —
  `artemis apollo socrates diogenes plato` — default `"artemis apollo"`, the standard gate.
- **Sequential, not matrix — a real tradeoff, not an oversight.** A **composite action cannot use
  `strategy`/`matrix` at all** — that's a job-level-only GitHub Actions concept, verified against
  GitHub's own composite-action docs, not assumed — so `action.yml` runs every enabled agent
  sequentially in one job instead of as parallel matrix legs. (Before issue #36, the vendored
  `action/review.yml` ran Artemis and Apollo as two matrix legs in parallel, passing results
  between jobs via upload/download-artifact — a real job-level workflow can do that; a composite
  action structurally cannot, which is exactly why that duplicate implementation existed in the
  first place.) The payoff of the sequential shape is simplicity: no artifact round-trip, no
  separate job, one `uses:` line for the consumer; the cost is wall-clock (N agents run one after
  another). Given this surface exists specifically for the simplest possible install, that
  tradeoff was made on purpose.
- **The `anthropics/claude-code-action` pin is now real**, not a placeholder — see the
  "Security posture" section above for the SHA, the release, and where it was verified.
- **Fail-closed still applies.** Every agent step in `action.yml` runs with
  `continue-on-error: true` (so a provider failure or a red/unverified verdict never halts the
  action before it can post a comment and report the result), and the action's own final step
  fails the job on red or unverified — same posture as the CLI's exit code, just phrased for a
  composite action's constraints (no `if: always()` chains needed when nothing upstream is
  allowed to hard-fail in the first place — see `action.yml`'s own header comment for the
  composite-action mechanics this relies on and what was verified about them, including that
  `steps.<id>.outcome` inside a composite action was historically broken and has since been
  fixed upstream).

**Honest limitation:** this action can't be integration-tested end-to-end — a real `uses:
G-Schumacher44/review-pantheon@v1` invocation against a real PR — until this repo is public on
GitHub (a private repo's actions aren't resolvable via a bare `owner/repo@ref` reference from
another repo without extra token plumbing this project doesn't want to require). Until then,
`.github/workflows/ci.yml`'s `composite-action-self-check` job covers what CAN be verified
without that: `action.yml` and `examples/*.yml` parse as YAML, every file `action.yml`
references under `github.action_path` actually exists, and the embedded/added shell scripts
pass `bash -n` and shellcheck.

## Deliberately absent

- No fleet/multi-repo sweep — the gate runs on one repo, from that repo. Loop it yourself.
- No third-party reviewer integration (e.g. bot-review aggregation) — extension point, not core.
- No auto-merge, ever. The gate posts a verdict; a human merges.
- No write access needed beyond posting one PR comment — true of the gate/action itself. This
  repo's own maintenance CI is the one deliberate exception: the `publish-wiki` job pushes to the
  wiki repo under `contents: write` on every push to dev (see the `sync-wiki.py` Layout entry
  below) — that's this repo's docs-publishing job, not the shipped gate.
- No review of draft PRs, on either surface — see "Surface differences" above for how each
  surface enforces that.
- **No `workflow_run` fork-PR gating.** The two-stage pattern (a secretless `pull_request` job
  uploads the diff as an artifact; a trusted `workflow_run` job reviews it) is GitHub's documented
  answer to gating fork PRs, but it does not work here and the action refuses that trigger outright.
  Two independent reasons: `action.yml` declares no `pr_number` / `base_sha` / `head_sha` inputs —
  every step reads them from `github.event.pull_request.*`, which is absent under `workflow_run`,
  and GitHub documents `workflow_run.pull_requests` as empty for fork-originated PRs — and the gate
  requires `git diff <base>...<head>` to resolve, so the fork's commit objects must be fetched into
  the runner regardless of whether its tree is checked out. Restoring the path would take explicit
  `pr_number`/`base_sha`/`head_sha` inputs plus a diff-only resolution that never fetches fork
  commits. SECURITY.md's "Fork pull requests" section states the operational consequence.

## Layout

```
pantheon/                  the CLI — `pantheon gate`/`pantheon counsel`, stdlib-only,
                           pipx/pip-installable (pyproject.toml). Module map:
                             cli.py        argv parsing, prompt assembly, run orchestration
                             providers.py  per-lane argv/env construction (claude/codex/gemini/
                                           cursor), neutral-cwd + env-passthrough hardening
                             execution.py  tiered tool-execution policy + the argv-validating
                                           read-only git wrapper (readonly default, trusted
                                           opt-in) — also the `pantheon-git-readonly` console
                                           script's own entry point
                             basepin.py    symlink-safe base-pinned file reads
                             verdict.py    the ONE verdict-decision implementation, called by
                                           the CLI and the Action surface
                             render.py     the combined-PR-comment renderer
                             jqjson.py     the one jq-compatible JSON parse/serialize boundary
                             state.py      follow-up-mode state-file read/write
agents/                    five canonical personas (the single source of truth), plus
                           __init__.py — a packaging-only marker (no code, no re-exports) so
                           setuptools ships this directory as `pantheon.agents` in the wheel
                           (pyproject.toml's package-dir remap); invisible to every consumer
                           that reads the *.md files directly (install.sh, bootstrap.sh,
                           action.yml) — see the file's own header comment
skills/                    four canonical Claude Code skills (gate, counsel, spec-driven,
                           design-contract) — the single hand-maintained source, same shape as
                           agents/ under rule 4; install.sh --claude copies them verbatim into
                           .claude/skills/<name>/SKILL.md, never regenerated
action/lib/                shared shell helpers for action.yml (build_prompt.sh,
                           combine_verdicts.sh) — combine_verdicts.sh invokes `pantheon.render`
                           by its own absolute path (relative to this action's own checkout,
                           safe because the published action ships this whole repo). Before
                           issue #36, the vendored action/review.yml kept its own prompt-build
                           and comment-post logic inline and hand-synced instead of calling
                           these — that duplicate is gone, and this is now the only place that
                           logic lives for the Action surface.
action.yml                 the published composite action (see "Published action" above) —
                           the whole install for a target repo via Way C is
                           examples/review-gate.yml; install.sh's Way A generates a
                           comparably thin SHA-pinned caller of this same file
examples/review-gate.yml   the consumer stub for action.yml; the entire footprint of
                           the published-action surface in a target repo
tests/                     15 bash fixture-test scripts (black-box against the CLI, or unit
                           tests for install.sh/bootstrap.sh/release.yml's own logic) plus the
                           pytest files (tests/test_*.py) — tests/README.md is the canonical,
                           complete list (verified against `git ls-tree -r tests/`; CI asserts the
                           two stay in sync). Don't re-list them here — that's exactly the
                           forked-inventory shape rule 5 exists to prevent.
install.sh                 idempotent installer into a target repo (refuses to clobber
                           customized files); does not install gate.conf; --claude/--cursor/
                           --codex/--gemini generate per-tool projections of agents/*.md for
                           in-session use (see "Generated per-tool projections" above)
bootstrap.sh                user-level, repo-independent CLI install (Way B) — a single
                           self-contained script (no shared lib, deliberately, since the
                           curl|bash install path fetches it alone); installs the `pantheon`
                           package into a venv under --prefix; --version vX.Y.Z pins the
                           remote-fetch path to a tagged, checksum-verified GitHub Release
                           instead of dev's current HEAD (see RELEASING.md and
                           .github/workflows/release.yml below)
sync-wiki.py                regenerates the GitHub wiki as a read-only projection of the gated
                           docs (PAGE_MAP); ci.yml's publish-wiki job (push-to-dev only,
                           `contents: write`) re-renders it after every push to dev — hand edits
                           to the wiki are overwritten on the next sync
.github/workflows/release.yml  tag-push (`v*.*.*`, strict-semver-validated) release gate: re-
                           runs ci.yml's lint-and-test suite pinned at the tag, builds the
                           versioned surface tarball + SHA256SUMS and publishes both as a
                           GitHub Release, then publishes the sdist/wheel to PyPI via the
                           trusted-publisher OIDC exchange (publish-pypi job, `id-token: write`,
                           gated on the Release step succeeding)
RELEASING.md                the operator's release ceremony — dev green, dev->main promotion
                           PR, tagging main, moving the v1 major tag, post-release verification
docs/                      anything that doesn't fit above
```
