# Contributing

## Ground rules

- **PRs only.** `dev` is the base branch and is ruleset-protected; `main` is the release branch.
  Nobody pushes to `main` directly — its ruleset admits no bypass at all. `dev` is PR-only too,
  with an admin bypass retained as the maintainer's emergency hatch (a few commits from before
  the ruleset landed went straight to `dev`; `git log` shows them).
- **This repo reviews its own PRs with the same panel it ships, then a human decides.** CI's
  `composite-action-self-check` job runs a live self-test of `action.yml` against this repo's own
  PRs (Artemis + Apollo, `execution: trusted` — this repo reviewing its own PRs from its own
  checkout is exactly the own-repo/trusted-author case that tier is documented for) — **when it
  runs.** That live-test step is fail-soft by design, not a required check: it only fires on a
  `pull_request` event with the token secret present, and is a no-op skip notice otherwise (see
  `.github/workflows/ci.yml`'s own comments on that job). So the honest claim is two-layered: any
  verdict the twins DO post is fail-closed (a missing or unparseable one reads `UNVERIFIED`, never
  green — DESIGN.md rule 2), but CI passing does not by itself guarantee a twin review ran at all.
  A human still reads and decides either way; the gate informs that decision when present, it
  never replaces it.
- **Findings get fixed or tracked — never silently dropped.** Address a finding in the same PR, or
  open an issue for it and resolve the review thread pointing at that issue number. A review
  thread left unresolved with nothing linked is the one state this repo doesn't allow.

## Dev setup

```bash
git clone https://github.com/G-Schumacher44/review-pantheon.git
cd review-pantheon
```

Prerequisites (bash, git, jq, gh, python3, one provider CLI): see
[docs/SETUP.md](docs/SETUP.md#prerequisites) for the full table and what each one gates.

Run the suites — each is a standalone fixture test, no runner needed. **This table is the
canonical, complete list of the bash fixture suites (15 files; verified against `git ls-tree -r tests/*.sh`)**
— DESIGN.md's "Layout" section points here instead of re-listing them, see DESIGN.md rule 5 on
the two staying in sync. A separate pytest unit layer (8 files, `tests/test_*.py`; verified
against `git ls-tree -r tests/*.py`) is its own documented category below — CI's sync-check
(`.github/workflows/ci.yml`) asserts both tables' rows AND both prose counts against
`git ls-tree -r tests/` on every PR, so a drift between either number and the actual tree fails
closed instead of rotting silently:

| Script | Covers |
|---|---|
| `tests/test-verdict-decision-python.sh` | `pantheon.verdict` — the verdict-decision rule (schema validation, the blocker invariant, per-agent vocabulary mapping), driven via `python3 -m pantheon.verdict` as a real subprocess. |
| `tests/test-base-pinned-read-python.sh` | `pantheon.basepin` — base-SHA-pinned reads, including the symlink-resolution edge case and issue #10's trailing-slash class. Drives `python -m pantheon.basepin` as a real subprocess. |
| `tests/test-render-comment-python.sh` | `pantheon.render` — the combined-PR-comment renderer, driven via `python3 -m pantheon.render` as a real subprocess. |
| `tests/test-json-boundary.sh` | `pantheon/jqjson.py`, the single jq-compatible JSON parse/serialize boundary — a mechanical assertion that `pantheon/verdict.py` and `pantheon/render.py` route every JSON parse/serialize through it, never Python's `json` module directly. |
| `tests/test-install.sh` | `install.sh`'s editor/CLI projection targets and its gate-file vendoring (personas, the vendored `pantheon` package, the workflow). |
| `tests/test-prompt-assembly-python.sh` | `pantheon.cli`'s prompt-assembly path — `_strip_frontmatter`/fence-id unit coverage, a real tokened `pantheon gate --dry-run` run (conditional on `gh`/network), and `_build_prompt()`'s base-SHA-pinning/apollo-spec-gating/fence-collision fixtures against real local git repos. |
| `tests/test-state-persistence-python.sh` | `pantheon.state` — `update_state()`'s follow-up-mode scenarios (driven via `python -m pantheon.state update ...`), plus `load_state`/`reviewed_sha_for`/`is_ancestor` coverage. |
| `tests/test-git-readonly-wrapper.sh` | `pantheon.execution`'s read-only git wrapper (the argv-validating, EXEC/WRITE-SURFACE-MATRIX-driven `python -m pantheon.execution wrapper ...` CLI entry point) — every hostile-shape/live-fire negative-control fixture. |
| `tests/test-execution-tier-python.sh` | `pantheon.execution`'s tier-resolution functions and structural hardening guards, plus a real `pantheon gate --execution bogus-tier` invocation, `--permission-mode dontAsk` in `pantheon/providers.py`, and `pantheon.cli`'s `execution=` base-pinning. |
| `tests/test-action-lib-execution-note.sh` | `action/lib/build_prompt.sh`'s `pantheon_execution_context_note()` and its `action/lib/execution_context_note.py` driver — proves the driver resolves the trusted `pantheon.execution` module by absolute path, immune to a cwd-shadow-import attack, plus a full `build_prompt.sh` integration run. |
| `tests/test-action-refs.sh` | Every `github.action_path` reference in `action.yml` resolves, plus SHA-pin checks. |
| `tests/test-setup-smoke.sh` | Clean-machine setup story — runs inside `Dockerfile.smoke` in CI, see below. |
| `tests/test-bootstrap-release.sh` | `bootstrap.sh`'s `--version`/release-fetch, unit-level: URL builders, checksum verify (happy + mismatch), offline flag validation. |
| `tests/test-bootstrap-release-e2e.sh` | The same `--version` path, integration-level: a real stubbed-`curl` checksum-verified fetch through extraction and a working `install.sh` run, plus the `pantheon` package venv installing and running from the fetched prefix. |
| `tests/test-release-tag-gates.sh` | `.github/workflows/release.yml`'s two tag gates: strict-semver validation and the `origin/main`-ancestry check. |

```bash
bash tests/test-verdict-decision-python.sh
# ...repeat per script, or run the ones relevant to your change
```

**Pytest unit layer (8 files, `tests/test_*.py`; verified against `git ls-tree -r tests/*.py`).**
Collected via `pyproject.toml`'s `[tool.pytest.ini_options]` (`tests/test_*.py` only — never the
black-box `tests/test-*.sh` suites above). Scope policy, binding: pure-function seams and
`pantheon/jqjson.py`'s own edge-case matrix (non-standard constants, overflow/underflow numbers,
excess-precision decimals, trailing-zero-formatted decimals, lone surrogates, the
`_RawBigNumber` placeholder-collision-avoidance guarantee) plus pure-function seams no black-box
suite drives directly (argv/PATH/environment construction, temp-file placement, `gate.conf`
parsing, console-script resolution, and similar). **No 1:1 duplication of the black-box exams** —
a pytest file that would just re-run scenarios a `tests/test-*-python.sh` suite already covers as
a black box doesn't get written; each file's own docstring states exactly what black-box coverage
it complements, not repeats. This table is the canonical, up-to-date file list and per-file scope
— DESIGN.md rule 5 applies here too.

| Script | Covers |
|---|---|
| `tests/test_cli_agents_dir.py` | `pantheon.cli._agents_dir()`'s fallback-selection logic (mocked) — persona resolution from a real, non-editable `pip`/`pipx` install vs. a dev-checkout sibling directory. |
| `tests/test_cli_helpers.py` | `pantheon.cli`'s pure-function seams no black-box suite drives directly — `_parse_conf_text` (the `gate.conf` key=value parser). |
| `tests/test_execution.py` | `pantheon.execution.resolve_console_script`, the shared function behind both `pantheon.cli`'s and `pantheon.providers`' own console-script resolution. |
| `tests/test_jqjson.py` | `pantheon.jqjson`'s four functions directly and in isolation, parametrized across the JSON-boundary edge-case matrix. |
| `tests/test_providers.py` | `pantheon.providers`' argv-construction, PATH-resolution, environment-construction, and timeout/process-group seams — the ONLY coverage this module has (no black-box `test-providers.sh` exists either; a disclosed pre-existing gap, closed at this layer). |
| `tests/test_render.py` | `pantheon.render`'s `_redact_repo_root_in_value` (the DATA-level repo-root redactor) and `_machine_tail_text`'s redact-before-serialize ordering — direct pure-function coverage for the two helpers a black-box round-trip through the CLI shim (`tests/test-render-comment-python.sh`) would obscure. |
| `tests/test_state.py` | `pantheon.state`'s cross-filesystem write safety — where `update_state()`'s temp file gets created, so a cross-device rename (`OSError(EXDEV)`) can never happen. |
| `tests/test_verdict.py` | `pantheon.verdict.emit_github_output`'s `$GITHUB_OUTPUT` side effect. |

```bash
pytest -q
```

**Shellcheck.** CI runs `shellcheck` repo-wide against every `*.sh` file — run it locally before
pushing, same invocation `.github/workflows/ci.yml` uses:

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 shellcheck
```

**Container-verify for shell-heavy changes.** `Dockerfile.smoke` exists because this repo's
day-to-day development is macOS and the setup story targets Linux CI too — GNU coreutils
behavior doesn't always round-trip. "Passes on my Mac" is not a pass for anything touching
`install.sh`, `bootstrap.sh`, or the provider lanes. Build and run it before pushing:

```bash
docker build -f Dockerfile.smoke -t review-pantheon-smoke .
docker run --rm review-pantheon-smoke
```

## Design constraints

`DESIGN.md` is the contract, not a suggestion — read it before changing anything under `agents/`,
`pantheon/`, or `action/`. A few rules bite contributors most often:

- **Fail-closed everywhere.** A missing, empty, or unparseable verdict (or, more generally, any
  gate-behavior signal) must degrade toward the safer failure, never toward a silent pass.
- **One canonical persona per agent.** `agents/<name>.md` is the only hand-maintained copy; both
  runners load and template that file. A persona is never inlined or forked per-runtime.
- **Docs match code — rule 5.** If `DESIGN.md` and an implementation disagree, that's a bug in one
  of them. Fix the divergence in the same PR that introduced it; don't leave the doc stale.
- **Fix-round history goes in git, never the contract.** `DESIGN.md` (and any doc authored from
  `docs/DESIGN.template.md`) describes current-state behavior only — no "Round N", "first
  attempt", "the fix was X", "previously we Y" narrative. A PR's own diff and commit history are
  the changelog; a contract that accumulates its own fix history becomes unreadable and eventually
  unmaintained. CI's doc-lint step (`.github/workflows/ci.yml`) fails the build if `DESIGN.md`
  contains one of those markers — see that step's own comment for the exact pattern.
- **Base-pinned provenance for anything the gate reads that shapes its own behavior** (personas,
  the verdict decider, the read-only git wrapper, house-rules/spec files) — read from the PR's
  base commit or this repo's own trusted checkout, per DESIGN.md's read-provenance matrix,
  including its disclosed exceptions (the vendored `action/review.yml` workflow reads
  house-rules/spec content from the checked-out working tree instead — a documented, narrower
  exception, not a precedent to extend). See DESIGN.md's ["Security
  posture"](DESIGN.md#security-posture) for the full matrix and why.
- **Every new fixture must be shown failing against the pre-fix code.** A test that was never red
  proves nothing about the fix it's supposed to cover — this repo's own fixture tests follow that
  pattern (see `tests/test-git-readonly-wrapper.sh`'s negative-control fixtures for a worked
  example) and reviewers will ask for it.

## Scope

See the [issues list](https://github.com/G-Schumacher44/review-pantheon/issues) for open work and
known gaps. `pantheon` (the Python package, stdlib-only) is the CLI, full stop — there is no other
runtime and no deprecation window. New work targets `pantheon/`.

## License

MIT. Contributions are accepted under the same license as the rest of the repo — see
[LICENSE](LICENSE).
