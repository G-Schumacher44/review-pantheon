# Python CLI port — the v2 spec

This document is to the port what [DESIGN.md](../DESIGN.md) is to the gate itself: the contract,
not a suggestion. It's what [CONTRIBUTING.md](../CONTRIBUTING.md)'s "Scope" section points at when
it calls the Python CLI a planned v2 track — read this before opening a PR toward it. Everything
below is operator-decided and stated as decided, not as options to re-litigate per-PR.

**Status of this PR: spec only.** This PR ships a `pyproject.toml` skeleton, this document, and two
small doc updates ([docs/README.md](README.md)'s index, [CONTRIBUTING.md](../CONTRIBUTING.md)'s v2
line). It ships **zero** port code — no `pantheon/` package directory, no importable module. Real
modules land starting with the slice plan's Slice 2, below.

The bash v1 CLI is not going anywhere because of this PR. [CONTRIBUTING.md](../CONTRIBUTING.md)'s
framing stands unchanged until parity: "a separate surface from the current bash implementation,
not a rewrite-in-place" — until the slice plan's exit bar is cleared and Slice 5 actually retires
it.

## 1. Packaging

- **Package name:** `pantheon`.
- **stdlib-only. No third-party runtime dependency, ever.** This is a hard constraint, not a
  default to relax later — the same "hard constraint, not an oversight" framing
  [CONTRIBUTING.md](../CONTRIBUTING.md) already applies to bash v1's own design. The stdlib modules
  this port leans on: `json`, `subprocess`, `argparse`, `hashlib`, `urllib`, `os`, `sys` — plus
  whatever else ships in the standard library as the port needs it. A dependency listed in
  `pyproject.toml`'s `[project.dependencies]` is a spec violation, not a judgment call for whoever's
  writing that slice.
- **Python ≥3.9.**
- **Console entry point** via `pyproject.toml`'s `[project.scripts]`: `pantheon = "pantheon.cli:main"`.
- **pipx-installable, sdist-friendly.** No compiled extensions, no build-time codegen, no
  platform-specific wheels required — a plain sdist/wheel pair from a stdlib-only package is
  sufficient. This is also why the build backend choice (this PR's skeleton uses `setuptools`, a
  build-time-only dependency, never installed for the end user) doesn't compromise the stdlib-only
  claim, which is about *runtime* dependencies.
- **`pyproject.toml` skeleton committed in this PR** (name, metadata, entry point, marked
  pre-release via `Development Status :: 2 - Pre-Alpha`). It references `pantheon.cli:main`, a
  module that doesn't exist yet — that's expected for a skeleton; the package directory arrives in
  Slice 2. Don't try to `pip install .` against this PR and expect it to succeed.

## 2. CLI surface

- **`pantheon gate --pr N [...]`** — every flag [docs/CLI.md](CLI.md) documents today, unchanged
  in name and meaning:

  | Flag | Semantics (byte-compatible with docs/CLI.md) |
  |---|---|
  | `--pr <number>` | Required. Digits only, fails closed before any network call — same validation, same error posture. |
  | `--provider <lane>` | Provider lane name; unknown lane fails fast. Default resolution order unchanged: flag → `gate.conf`'s `provider=` → `claude`. |
  | `--agents "a b c"` | Space-separated; each name validated against the same fixed five (`artemis apollo diogenes plato socrates`); empty resolved list is a hard error. |
  | `--execution <tier>` | `readonly` (default) or `trusted`; same resolution order and the same base-pinned re-read of `gate.conf`'s `execution=` key when no `--execution` flag is given (see [CLI.md](CLI.md#gateconf) — this key stays base-pinned, not working-tree-sourced, for the same reason it is today). |
  | `--dry-run` | Builds prompts, prints the would-be comment, calls no provider, posts nothing, records no `reviewed_sha`. Same `.review-gate-state.json` bootstrap caveat carries over. |
  | `-h`, `--help` | Prints usage, exits 0. |

  `gate.conf`'s keys, defaults, and precedence rules (including the `execution=` base-pinning and
  the known `provider=` gap tracked as
  [issue #13](https://github.com/G-Schumacher44/review-pantheon/issues/13)) carry over unchanged —
  this port does not silently fix or relitigate that issue as a side effect of the rewrite.

- **`pantheon counsel [...]`** — the counsel-agent path CLI.md's ["Counsel
  run"](CLI.md#worked-examples) example already documents as `review-gate --agents "socrates
  diogenes plato"`. `pantheon counsel` is sugar for exactly that: `pantheon gate` with the agent
  list defaulted to the counsel three, everything else (flags, `gate.conf`, provider selection,
  execution tiering) identical to `gate`. It must preserve the property CLI.md states explicitly
  today: *"the 'counsel, not gate' distinction is a usage convention, not a code path"* —
  `pantheon counsel` is not allowed to become a second, hardened code path that treats counsel
  agents differently at the decision layer. It's a friendlier spelling of an `--agents` list, not a
  new enforcement mode.

- **A thin `review-gate` compat shim** ships alongside `pantheon` during the transition (Slices 2
  through 4): a console-script entry point that argparse-forwards every argument to `pantheon
  gate`, prints a one-line deprecation note to stderr, and exits with the same code `pantheon gate`
  would. It exists so nothing that scripts against the `review-gate` binary name breaks mid-port.
  Removed at Slice 5, alongside the rest of the bash surface.

- Flag/config semantics are byte-compatible with [docs/CLI.md](CLI.md) throughout — if the Python
  CLI and that doc disagree on a flag's behavior once Slice 4 lands, that's a bug in the port, not
  a doc that needs updating to match (mirrors [DESIGN.md](../DESIGN.md) rule 5, applied to this
  surface).

## 3. One runtime endgame

Today there are two runtimes implementing the same verdict-decision rule
([DESIGN.md](../DESIGN.md)'s "Two runtimes, one rule": `cli/lib/verdict.sh` for the CLI,
`action/decide_verdict.py` for the Action) and two renderer call sites sharing one bash
implementation (`cli/lib/render_comment.sh`, sourced by both `cli/review-gate` and
`action/lib/combine_verdicts.sh`).

On parity, this collapses to one runtime:

- **The bash CLI freezes, then retires.** `cli/review-gate`, `cli/lib/*.sh`, and
  `cli/providers/*.sh` are removed at Slice 5, not before.
- **`action/decide_verdict.py` is absorbed into the package.** The Action lanes
  (`action.yml`'s composite steps, `action/review.yml`'s decide step) call the package's verdict
  module instead of the standalone `action/decide_verdict.py` file. `action/decide_verdict.py`
  itself is retired at Slice 5, same as the bash CLI files.
- **Render/verdict logic is single-sourced in Python.** `cli/lib/render_comment.sh` and
  `action/lib/combine_verdicts.sh`'s sourcing of it collapse into one module, called from both
  `pantheon gate`'s comment-posting path and the Action's comment-build step.
- **[DESIGN.md](../DESIGN.md) itself is out of scope for this PR.** It's the gate's contract, not
  the port's — its "Two runtimes, one rule" section, its Layout section, and its Published-action
  table all need a follow-up edit once Slice 5 actually collapses to one runtime. That edit is
  tracked as part of Slice 5's exit bar below, not attempted here.

## 4. Migration exam

**The existing bash fixture suites are the acceptance spec for this port — not a separate test
plan written from scratch.** They get parameterized by CLI binary via a `PANTHEON_CLI` env var (or
equivalent indirection where a suite currently hardcodes a path) — default `PANTHEON_CLI=review-gate`
(today's binary, or the Slice-2-through-4 compat shim), settable to the installed `pantheon`
binary. A suite that passes against both binaries, unmodified in what it asserts, is the proof of
parity this port needs. **Every suite below must pass unchanged against the Python binary before
any bash file it covers is retired** — that's the literal exit bar for every slice, not just a
description of the plan.

Not every suite gets there by simple parameterization, though — several are *bash-internal*: they
`source` a `cli/lib/*.sh` file directly, or extract a function verbatim out of `cli/review-gate`'s
own text (the `$FUNCS_FILE` pattern `test-state-persistence.sh` and `test-prompt-assembly.sh`
both use), rather than exercising the CLI as a black box. Those need a **black-box equivalent**
written against the Python package before the bash file they source can retire — sourcing a `.py`
file the way these suites source a `.sh` file is not the right shape for that equivalent test, even
where the underlying assertions carry over unchanged.

| Suite | Shape today | Port disposition |
|---|---|---|
| `tests/test-verdict-decision.sh` | Bash-internal — sources `cli/lib/verdict.sh` **and** execs `action/decide_verdict.py` to cross-check both runtimes against the same fixtures. | Needs a black-box equivalent against `pantheon`'s verdict module. Its whole premise (diff two runtimes) collapses once there's one Python implementation — repurpose as a straight fixture test at Slice 2, then simplify away the cross-runtime-diff assertion at Slice 5 once the bash decider is retired (nothing left to diff against). |
| `tests/test-base-pinned-read.sh` | Bash-internal — sources `cli/lib/pantheon-base-pin.sh` directly. | Needs a black-box/Python-native equivalent against the basepin module. Slice 3 exit bar. |
| `tests/test-render-comment.sh` | Bash-internal — sources `cli/lib/render_comment.sh` directly. | Needs a black-box/Python-native equivalent against the render module. Slice 2 exit bar. |
| `tests/test-install.sh` | Black-box — invokes `install.sh` directly, no sourcing. | Applies as-is; unaffected by this port. `install.sh`'s own fate is an open item (§9), not decided here. |
| `tests/test-prompt-assembly.sh` | Bash-internal — extracts `build_prompt()` verbatim from `cli/review-gate` via `$FUNCS_FILE`, then sources `cli/lib/execution.sh` and `cli/lib/pantheon-base-pin.sh` to exercise it. | Needs a black-box equivalent against `pantheon.cli`'s prompt-assembly path (which leans on the `execution` and `basepin` modules — see §6). The largest single migration in the exam: prompt assembly today lives inline in `cli/review-gate`, not in a separately named function file. Slice 3/4 exit bar (basepin/execution land in Slice 3; the full assembly path is only whole once `cli.py` lands in Slice 4). |
| `tests/test-state-persistence.sh` | Bash-internal — extracts `update_review_gate_state()` verbatim from `cli/review-gate` via `$FUNCS_FILE`. | Needs a black-box equivalent against the `state` module. Slice 4 exit bar. |
| `tests/test-git-readonly-wrapper.sh` | **Already black-box in shape** — invokes `cli/lib/pantheon-git-readonly.sh` as a subprocess with real argv (`"$WRAPPER" "$@"`), never sources it. | Needs *adaptation*, not pure reuse: the behavioral assertions (the full EXEC/WRITE-SURFACE MATRIX — every row) must all still be provable, but the invocation shape changes, because Python's `execution` module doesn't need a standalone wrapper *executable* the way bash does (see §5's "structure, not string-discipline" point) — it may expose a small subcommand (`python -m pantheon.execution wrapper diff <range>`) purely to keep this fixture's black-box shape, or the fixture may need to shift to asserting the module's argv-construction function directly. Either way: every matrix row's live-fire assertion carries over, unmodified in what it proves. Slice 3 exit bar. |
| `tests/test-execution-tier.sh` | **Mixed.** Part C sources `cli/lib/execution.sh` directly *and* greps `cli/review-gate`'s own source text for bash-specific strings (e.g. `grep -qF 'source ".../execution.sh"'`). Other parts invoke `review-gate --execution bogus-tier --pr 1` as a real subprocess (black-box). | The bash-source-grep assertions don't translate — they check bash wiring that won't exist in Python — and must be dropped or rewritten against however `cli.py` wires `execution` in. The black-box behavioral assertions (readonly default, trusted opt-in, fail-closed on an unrecognized tier before any `gh` call) translate directly via `PANTHEON_CLI`. Slice 3 (execution module) / Slice 4 (full CLI wiring) exit bar. |
| `tests/test-action-refs.sh` | Black-box — validates every `github.action_path` reference in `action.yml` resolves, plus SHA-pin checks. No sourcing, no CLI invocation. | Applies as-is through Slice 4. Needs a Slice 5 update once `action.yml` stops referencing `action/decide_verdict.py` directly and calls the package instead (§3) — that reference-resolution check must follow the file it's now checking. |
| `tests/test-setup-smoke.sh` | Mostly black-box (runs in `Dockerfile.smoke`; installs via `install.sh` and `bootstrap.sh`, then invokes `review-gate --help`/`--dry-run` through the bootstrap prefix, including through real symlinks) — but Stage 4a derives its expected `cli/lib/*.sh` file list by **grepping `cli/review-gate`'s own source** for `PANTHEON_ROOT/cli/lib/<file>` references. | The Stage 4a bash-source-grep is bash-specific and must be rewritten (there's no `PANTHEON_ROOT/cli/lib/<file>` string pattern in a Python package) or dropped once the CLI internals move to Python. The rest (install/bootstrap/`--help`/`--dry-run` through real and symlinked prefixes) applies as-is via `PANTHEON_CLI`. Slice 4 (parity run) / Slice 5 (bootstrap installs the package — see §8) exit bar. |
| `tests/test-bootstrap-release.sh` | Bash-internal **to `bootstrap.sh` itself** — sources `bootstrap.sh` to unit-test its URL-builder and checksum-verify functions. | **Unaffected by this port, full stop.** `bootstrap.sh` stays bash (§8); this suite tests only its own logic, with zero dependency on the CLI's implementation language. Applies as-is through every slice; only grows new fixtures at Slice 5 when `bootstrap.sh` learns to install the package. |
| `tests/test-bootstrap-release-e2e.sh` | Black-box — a real stubbed-`curl` checksum-verified fetch through extraction and a working `install.sh` run, then invokes `review-gate --help` through the bootstrap prefix (including via real and relative symlinks). | Applies as-is through Slice 4 (bootstrap still vendors the bash CLI + `cli/lib` + `cli/providers` into its prefix). Needs a Slice 5 update once `bootstrap.sh`'s install step becomes a pip/pipx install of the package instead of vendoring bash files into a prefix directory — the prefix layout this suite asserts on changes shape at that point. |
| `tests/test-release-tag-gates.sh` | Black-box — validates `.github/workflows/release.yml`'s tag-gate logic (strict-semver, `origin/main`-ancestry). No sourcing, no CLI invocation of any kind. | Applies as-is, unaffected — entirely orthogonal to the CLI/Action surface this port touches. |

**Net count going into Slice 2:** 4 suites already fully black-box and portable by
parameterization alone (`test-install.sh`, `test-action-refs.sh`\*, `test-release-tag-gates.sh`,
`test-bootstrap-release.sh`) — \*`test-action-refs.sh` needs its Slice-5 update, everything else
about it is stable now. The remaining 9 need a black-box equivalent, an adaptation, or both, as
detailed per-row above; none get silently skipped.

## 5. Security core carries over by contract

Every mechanical protection [DESIGN.md](../DESIGN.md)'s "Security posture" section describes
carries over **by contract, not by aspiration** — a slice that lands without its equivalent closure
does not meet that slice's exit bar, full stop.

- **Typed argv allowlists per subcommand.** The same enumeration discipline CLI.md's flag table
  already describes — provider name checked against `cli/providers/`'s contents, agent names
  checked against the fixed five, execution tier checked against exactly `readonly`/`trusted` —
  expressed as `argparse` `choices=` or an equivalent explicit check, never regex-on-a-string
  parsing standing in for a real enumeration.
- **Constructed clean env, never inherited.** Every `git`/`gh`/provider-CLI invocation goes through
  `subprocess.run(argv, env=<explicit dict>, shell=False)` — an explicitly constructed environment
  every time, never `os.environ` passed through implicitly.
- **Python's subprocess model replaces bash's string-discipline with structure.** Bash v1's
  read-only tier works by *forcing* a list of flags and env vars onto every wrapped git call
  (`--no-ext-diff`, `-c core.fsmonitor=false`, `GIT_PAGER=cat`, etc. — enumerated in full in
  `cli/lib/pantheon-git-readonly.sh`'s own header) and by refusing any argument that looks like a
  flag, because a prefix-matched `Bash(git diff *)` permission rule has no understanding of git's
  own argument grammar. An argv **list** passed to `subprocess.run(..., shell=False)` is never
  re-interpreted by a shell at all — the whole class of prefix-match/flag-injection findings
  DESIGN.md's EXEC/WRITE-SURFACE MATRIX enumerates is closed by construction, not by enumerating
  and force-neutralizing each vector one at a time. That's a strictly stronger guarantee, but it
  does not excuse skipping verification: **every wrapper fixture must still pass** — every row in
  the matrix needs an equivalent, provable closure in the Python `execution` module (§4's
  `test-git-readonly-wrapper.sh` row), including the structural range-verification the bash wrapper
  does today (`git rev-parse --verify --quiet <side>^{commit}` on both sides of a diff range, not
  just a `..`-substring check) and the exactly-one-positional-argument rule for `diff`.
- **Base-pinned reads with symlink resolution.** The Python `basepin` module must replicate
  `pantheon-base-pin.sh`'s exact contract: the return-code distinction between ordinary absence
  (2) and REFUSED (1, never silently folded into absence), the 32-hop cycle cap, repo-root-escape
  refusal, absolute-target refusal, and the component-at-a-time walk that catches an
  intermediate symlinked *directory*, not just a symlinked leaf file. `test-base-pinned-read.sh`
  is the acceptance fixture (§4).
- **Fail-closed everywhere.** Carries over as a property of every module below, not just the
  verdict decider — a missing, empty, unparseable, or type-mismatched signal degrades toward the
  safer failure in every module that produces one, the same rule
  [CONTRIBUTING.md](../CONTRIBUTING.md) already states for the bash implementation.
- **JSON boundary: one module, catch-all posture, jq-output parity.** Every JSON parse and every
  JSON serialize anywhere in this port goes through `pantheon/jqjson.py` — never a direct call to
  Python's own `json.loads`/`json.dumps` from any other module. This is operator-decided policy,
  not a style preference, learned the hard way on Slice 2: `pantheon/verdict.py` and
  `pantheon/render.py` shipped three separate rounds of the same class of divergence — Python's
  `json` module accepting the non-standard `NaN`/`Infinity`/`-Infinity` JSON-extension tokens and
  keeping them as literal floats where jq coerces them; a lone UTF-16 surrogate that `json.loads`
  accepts but real jq rejects at parse time; a >4300-digit integer raising a bare `ValueError` on
  Python 3.11+ that `except json.JSONDecodeError` doesn't catch; a numeric literal like `1e400`
  overflowing Python's IEEE double to `inf` where jq's arbitrary-precision number handling keeps
  it exact — each found and patched as a one-off, one review round at a time, which never
  converged. jq's real parse-success/parse-failure boundary is not shaped like Python's exception
  hierarchy; enumerating that vocabulary is the anti-pattern this rule exists to stop repeating.
  `pantheon.jqjson.loads` raises exactly one exception type (`JqParseError`) for ANY parse
  failure, deliberately, and `pantheon.jqjson.dumps` forces `allow_nan=False` as a fail-loud
  backstop. The module owns a second boundary too, found immediately after the first landed:
  Python-VALUE-to-DISPLAY-TEXT — `pantheon.jqjson.jq_text` (jq `-r`'s raw-output stringification
  of a parsed scalar, not Python's own `str()`/f-string interpolation) and `pantheon.jqjson.subst`
  (bash's own `$(...)` command-substitution trailing-newline strip, a plain-bash semantic
  applied wherever a caller's bash counterpart captured a jq extraction that way before an
  emptiness check or final interpolation) — both bash-semantics shims live in this one module
  alongside the parse/serialize half, not a second file. Every module below that touches JSON at
  all names `pantheon.jqjson` as a dependency in its own entry; `tests/test-json-boundary.sh` is
  the acceptance fixture — a mechanical (not reviewed-by-eye) assertion that no other module
  reaches past either boundary.

## 6. Module layout

```
pantheon/cli.py          argparse entry point; `gate`/`counsel` subcommands; gate.conf parsing;
                          PR-metadata validation and fetch (branch/SHA regex checks, docs-only
                          detection); prompt assembly (persona + run-context block); the
                          run_agent loop; wires execution/basepin/providers/verdict/render/state
                          together. Replaces: cli/review-gate (the orchestration parts not
                          covered by a more specific module below).
                          Fixture suites: test-prompt-assembly.sh, test-execution-tier.sh,
                          test-setup-smoke.sh, test-bootstrap-release-e2e.sh, test-install.sh
                          (indirectly, via install.sh's own black-box shape).

pantheon/jqjson.py        The one jq-compatible JSON parse/serialize boundary — see §5's "JSON
                          boundary" bullet for why this exists as its own module. Every other
                          module that parses or serializes JSON (verdict.py, render.py today;
                          any future module that reads/writes JSON) depends on this one, never on
                          Python's json module directly.
                          Fixture suite: test-json-boundary.sh (a mechanical no-bare-json-call
                          assertion, not a fixture-value suite like its siblings) plus regression
                          fixtures folded into test-verdict-decision-python.sh and
                          test-render-comment-python.sh (the two current consumers' own suites).

pantheon/verdict.py       Trailing-JSON extraction (parse-anchored suffix scan), the five-agent
                          verdict vocabulary, type-strict validation of the invariant-read
                          surface, and the blocker invariant. Replaces: cli/lib/verdict.sh AND
                          action/decide_verdict.py — this is the module that fulfills §3's "one
                          runtime, one rule." Depends on pantheon/jqjson.py for all JSON parsing.
                          Fixture suite: test-verdict-decision.sh (needs the black-box
                          equivalent per §4).

pantheon/render.py        The combined-PR-comment renderer: signal line, verdict table, findings
                          fold, display-field sanitization (DESIGN.md's "Validation surface" —
                          the deliberately-not-schema-validated fields get sanitized here, at
                          render time, same division of responsibility as today). Replaces:
                          cli/lib/render_comment.sh AND action/lib/combine_verdicts.sh's sourcing
                          of it. Depends on pantheon/jqjson.py for all JSON parsing/serializing.
                          Fixture suite: test-render-comment.sh (needs the black-box equivalent
                          per §4).

pantheon/execution.py     Tiered tool-execution policy (readonly default, trusted opt-in) AND
                          the argv-validating read-only git call construction — subcommand
                          allowlist (diff/show/log/status), no-flags-of-any-kind rule, the
                          structural revision-range verification for `diff`, and the full forced
                          clean-environment construction (no-ext-diff, no-textconv,
                          no-fsmonitor, no-pager, no-editor, no-gpg, no-optional-locks,
                          no-lazy-fetch). Replaces: cli/lib/execution.sh AND
                          cli/lib/pantheon-git-readonly.sh — merged into one module because in
                          Python the tiering decision and the safe-call construction are the same
                          structural concern (§5), not two files coordinating through a permission
                          string.
                          Fixture suites: test-git-readonly-wrapper.sh, test-execution-tier.sh
                          (both need adaptation per §4).

pantheon/basepin.py        Symlink-safe base-SHA-pinned file reads: mode-120000 detection via
                          `git ls-tree`, component-at-a-time walk, target-relative-to-its-own-
                          directory resolution, repo-root-escape and absolute-target refusal,
                          32-hop cap, the ordinary-absence-vs-REFUSED return-code contract.
                          Replaces: cli/lib/pantheon-base-pin.sh.
                          Fixture suite: test-base-pinned-read.sh (needs the black-box/Python-
                          native equivalent per §4).

pantheon/providers.py     One function per provider lane — `provider_run(model, prompt_file) ->
                          str`, same contract as today (prints/returns the agent's raw output,
                          raises/returns nonzero on failure) — for claude, codex, gemini, cursor.
                          Replaces: cli/providers/claude.sh, codex.sh, gemini.sh, cursor.sh.
                          Fixture suites: none today — no test-providers.sh exists in the bash
                          suite either (see §9's open item; this is a pre-existing coverage gap,
                          not one the port introduces or is obligated to close).

pantheon/state.py         Follow-up-mode state: `.review-gate-state.json` read/write, the
                          green/yellow-only recording rule, ancestry-based (not just existence-
                          based) ancestor checking for force-push detection. Replaces: the
                          `update_review_gate_state()` function and the SEEN_SHA/ancestry logic
                          currently inline in cli/review-gate.
                          Fixture suite: test-state-persistence.sh (needs the black-box
                          equivalent per §4).
```

## 7. Slice plan

Each slice's exit bar is the same shape: **the fixture suites that row-map to what it ships turn
green against the Python binary, per §4's table — not "code merged," not "looks right."**

- **Slice 2 — verdict + render.** Ships `pantheon/verdict.py`, `pantheon/render.py`. Exit bar:
  `test-verdict-decision.sh` and `test-render-comment.sh` green against Python, per their §4
  dispositions (black-box equivalents, not sourced-bash reuse).
- **Slice 3 — execution + basepin.** Ships `pantheon/execution.py`, `pantheon/basepin.py`. Exit
  bar: `test-git-readonly-wrapper.sh`, `test-execution-tier.sh` (its behavioral portion),
  `test-base-pinned-read.sh` green against Python, with every EXEC/WRITE-SURFACE MATRIX row
  provably closed (§5).
- **Slice 4 — cli/providers/state + full parity run.** Ships `pantheon/cli.py`,
  `pantheon/providers.py`, `pantheon/state.py`; `pantheon gate` and `pantheon counsel` functional
  end to end; the `review-gate` compat shim lands here. Exit bar: the **full** suite list from §4
  green against `PANTHEON_CLI=pantheon`, except the rows §4 explicitly names as Slice-5-only
  (`test-action-refs.sh`'s Action-absorption check, `test-bootstrap-release-e2e.sh`'s
  bash-vendoring assumption, `test-setup-smoke.sh`'s Stage 4a bash-grep check) — those stay
  passing against the *old* binary/assumptions until Slice 5 updates them, named here so they're
  not silently deferred.
- **Slice 5 — packaging + switchover.** Fills in `pyproject.toml` for real (from this PR's
  skeleton); `bootstrap.sh` learns to install the package (§8); docs flip
  ([CLI.md](CLI.md)/[DESIGN.md](../DESIGN.md)/[README.md](../README.md) updated to describe the
  Python CLI as current, including DESIGN.md's "Two runtimes, one rule" and Layout sections per
  §3); bash retirement (`cli/review-gate`, `cli/lib/*.sh`, `cli/providers/*.sh`, the `review-gate`
  compat shim, and `action/decide_verdict.py` all removed). Exit bar: the entire suite list (§4's
  13 plus whatever Slices 2–4 added) green with **zero** bash CLI surface remaining, and
  [DESIGN.md](../DESIGN.md) rule 5 ("docs match code") re-verified as part of this slice's own
  closing check, not assumed.

## 8. `bootstrap.sh` stays bash

`bootstrap.sh` remains a single self-contained bash script — the single-file `curl|bash` install
constraint is real and doesn't change: a Python bootstrapper would itself need to bootstrap a
Python interpreter and package manager before it could install anything, which defeats the point
of a zero-dependency one-liner install. It learns to install the `pantheon` package at Slice 5
(pip/pipx into its prefix, replacing today's vendor-`cli/lib`-and-`cli/providers`-into-a-prefix
step). `test-bootstrap-release.sh` (unit-level, sources `bootstrap.sh` directly) is entirely
unaffected by this port — see §4's row for why. `test-bootstrap-release-e2e.sh` needs its
Slice-5 update once the install step's shape actually changes.

## 9. Open items (not resolved by this spec)

- **`install.sh`'s own fate.** Way A vendors personas, `action/review.yml`, `decide_verdict.py`,
  and `cli/lib/pantheon-git-readonly.sh` into a target repo for the Action lane
  ([DESIGN.md](../DESIGN.md)'s "Layout" section). None of the six operator-decided constraints
  above address what `install.sh` does once the files it vendors move into a Python package —
  that's a follow-up decision, needed before Slice 5 can retire the files it currently vendors,
  not assumed or pre-decided here.
- **Provider lanes beyond Claude have no dedicated fixture suite today.** `codex.sh`, `gemini.sh`,
  and `cursor.sh` are "best-effort" per [DESIGN.md](../DESIGN.md) and CLI.md, and there is no
  `test-providers.sh` in the current 13-suite list exercising any of the four lanes' `provider_run`
  contract directly. `pantheon/providers.py` inherits this as a pre-existing gap, not a
  requirement newly introduced by the port — but it shouldn't quietly read as "tested" either;
  flagged here so it isn't lost.
- **DESIGN.md's own edits are deferred to Slice 5**, per §3 and §7 — this PR does not touch
  DESIGN.md.

## Non-goals of this spec

- No behavior change to bash v1 anywhere in this document — every "byte-compatible"/"unchanged"
  claim above is a constraint on the port, not a proposal to alter today's CLI or Action surface.
- No opinion on distribution beyond pipx/pip (no Homebrew formula, no Docker image) — out of
  scope until Slice 5 at the earliest, and not decided here.
- No relaxation of any [DESIGN.md](../DESIGN.md) hard rule — the port implements the same
  contract in a different language; it does not get to renegotiate the contract along the way.
