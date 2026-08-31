# Test map

Two layers, each a standalone fixture test — no runner orchestration needed. This file is the
canonical, complete list of both; CI's sync-check (`.github/workflows/ci.yml`) asserts every row and
both prose counts against `git ls-tree -r tests/` on every PR, so a drift between a table and the
actual tree fails closed instead of rotting silently. DESIGN.md's "Layout" section points here
rather than re-listing, per DESIGN.md rule 5.

## Bash fixture suites

Black-box tests against the CLI, or unit tests for `install.sh` / `bootstrap.sh` / `release.yml`'s
own logic. Each is a self-contained script (16 files; verified against `git ls-tree -r tests/*.sh`):

| Script | Covers |
|---|---|
| `tests/test-verdict-decision-python.sh` | `pantheon.verdict` — the verdict-decision rule (schema validation, the blocker invariant, per-agent vocabulary mapping), driven via `python3 -m pantheon.verdict` as a real subprocess. |
| `tests/test-base-pinned-read-python.sh` | `pantheon.basepin` — base-SHA-pinned reads, including the symlink-resolution and trailing-slash edge cases. Drives `python -m pantheon.basepin` as a real subprocess. |
| `tests/test-render-comment-python.sh` | `pantheon.render` — the combined-PR-comment renderer, driven via `python3 -m pantheon.render` as a real subprocess. |
| `tests/test-json-boundary.sh` | `pantheon/jqjson.py`, the single jq-compatible JSON parse/serialize boundary — a mechanical assertion that `pantheon/verdict.py` and `pantheon/render.py` route every JSON parse/serialize through it, never Python's `json` module directly. |
| `tests/test-install.sh` | `install.sh`'s editor/CLI projection targets and its gate-file install (personas, the generated thin-caller workflow — including the GENERATED-marker refresh/skip ownership contract). |
| `tests/test-prompt-assembly-python.sh` | `pantheon.cli`'s prompt-assembly path — `_strip_frontmatter`/fence-id unit coverage, a real tokened `pantheon gate --dry-run` run (conditional on `gh`/network), and `_build_prompt()`'s base-SHA-pinning/apollo-spec-gating/fence-collision fixtures against real local git repos. |
| `tests/test-state-persistence-python.sh` | `pantheon.state` — `update_state()`'s follow-up-mode scenarios (driven via `python -m pantheon.state update ...`), plus `load_state`/`reviewed_sha_for`/`is_ancestor` coverage. |
| `tests/test-git-readonly-wrapper.sh` | `pantheon.execution`'s read-only git wrapper (the argv-validating, EXEC/WRITE-SURFACE-MATRIX-driven `python -m pantheon.execution wrapper ...` CLI entry point) — every hostile-shape/live-fire negative-control fixture. |
| `tests/test-execution-tier-python.sh` | `pantheon.execution`'s tier-resolution functions and structural hardening guards, plus a real `pantheon gate --execution bogus-tier` invocation, `--permission-mode dontAsk` in `pantheon/providers.py`, and `pantheon.cli`'s `execution=` base-pinning. |
| `tests/test-action-lib-execution-note.sh` | `action/lib/build_prompt.sh`'s `pantheon_execution_context_note()` and its `action/lib/execution_context_note.py` driver — proves the driver resolves the trusted `pantheon.execution` module by absolute path, immune to a cwd-shadow-import attack, plus a full `build_prompt.sh` integration run. |
| `tests/test-action-refs.sh` | Every `github.action_path` reference in `action.yml` resolves, plus SHA-pin checks. |
| `tests/test-setup-smoke.sh` | Clean-machine setup story — runs inside `Dockerfile.smoke` in CI, see CONTRIBUTING.md's container-verify section. |
| `tests/test-bootstrap-release.sh` | `bootstrap.sh`'s `--version`/release-fetch, unit-level: URL builders, checksum verify (happy + mismatch), offline flag validation. |
| `tests/test-bootstrap-release-e2e.sh` | The same `--version` path, integration-level: a real stubbed-`curl` checksum-verified fetch through extraction and a working `install.sh` run, plus the `pantheon` package venv installing and running from the fetched prefix. |
| `tests/test-release-tag-gates.sh` | `.github/workflows/release.yml`'s two tag gates: strict-semver validation and the `origin/main`-ancestry check. |
| `tests/test-counsel-mode-fail-closed.sh` | `action/lib/combine_verdicts.sh`'s `mode: counsel` carve-out (issue #95) — the negative control proving it exits 0 on a fully-failed panel and on a red verdict alike, the advisory banner appears exactly once, and gate-mode (`MODE` unset) output is byte-for-byte unchanged. |

Run one, or the ones relevant to your change:

```bash
bash tests/test-verdict-decision-python.sh
```

## Pytest unit layer

Collected via `pyproject.toml`'s `[tool.pytest.ini_options]` (`tests/test_*.py` only — never the
black-box `tests/test-*.sh` suites above). Scope policy, binding: pure-function seams and
`pantheon/jqjson.py`'s own edge-case matrix (non-standard constants, overflow/underflow numbers,
excess-precision decimals, trailing-zero-formatted decimals, lone surrogates, the `_RawBigNumber`
placeholder-collision-avoidance guarantee) plus pure-function seams no black-box suite drives
directly (argv/PATH/environment construction, temp-file placement, `gate.conf` parsing,
console-script resolution, and similar). **No 1:1 duplication of the black-box exams** — a pytest
file that would just re-run scenarios a `tests/test-*-python.sh` suite already covers as a black box
doesn't get written; each file's own docstring states what black-box coverage it complements, not
repeats (13 files, `tests/test_*.py`; verified against `git ls-tree -r tests/test_*.py`):

| Script | Covers |
|---|---|
| `tests/test_action_guard.py` | `tests/check_action_expressions.py` itself — one planted violation per YAML syntax form (block-scalar `run:`, single-line `run:`, `pull_request_target`, missing `env:` binding) plus the clean counterparts. The guard is CI's only enforcement of three SECURITY.md claims, so it needs a test that proves it can fail. |
| `tests/test_cli_agents_dir.py` | `pantheon.cli._agents_dir()`'s fallback-selection logic (mocked) — persona resolution from a real, non-editable `pip`/`pipx` install vs. a dev-checkout sibling directory. |
| `tests/test_cli_helpers.py` | `pantheon.cli`'s pure-function seams no black-box suite drives directly — `_parse_conf_text` (the `gate.conf` key=value parser) — plus `_build_prompt`'s per-mode header shape and `_resolve_branch_context` against real git fixtures (both fail-closed refusals, the base-tip policy anchor, detached HEAD, dirty-tree warning). |
| `tests/test_counsel_mode.py` | `action.yml`'s `mode: counsel` wiring (issue #95) — the `mode` input's default, that `Enforce gate result` is the only step gated off in counsel mode, the never-fails `Counsel result` step, the gate/counsel agent-selection carve-outs, and the `continue-on-error` carve-out on the steps between auth and the combine step. |
| `tests/test_docs_pin_drift.py` | `action.yml`'s upstream `claude-code-action` full-SHA pin vs. the pin SECURITY.md and DESIGN.md restate in prose — every doc naming a pin must name the LIVE one. The same hand-restated-value drift class as `tests/test_security_md_denied_commands.py`. |
| `tests/test_execution.py` | `pantheon.execution.resolve_console_script`, the shared function behind both `pantheon.cli`'s and `pantheon.providers`' own console-script resolution. |
| `tests/test_jqjson.py` | `pantheon.jqjson`'s four functions directly and in isolation, parametrized across the JSON-boundary edge-case matrix. |
| `tests/test_providers.py` | `pantheon.providers`' argv-construction, PATH-resolution, environment-construction, and timeout/process-group seams — the only coverage this module has, since no black-box suite drives it. |
| `tests/test_render.py` | `pantheon.render`'s `_redact_repo_root_in_value` (the DATA-level repo-root redactor) and `_machine_tail_text`'s redact-before-serialize ordering — direct pure-function coverage for the two helpers a black-box round-trip through the CLI shim (`tests/test-render-comment-python.sh`) would obscure. |
| `tests/test_security_md_denied_commands.py` | `SECURITY.md`'s "built-in read commands" section's prose list of denied command names vs. the live `pantheon.execution.DENIED_BUILTIN_BASH_COMMANDS` constant — both directions (an addition or removal on either side is a drift). The same hand-restated-list class as `tests/test_action_guard.py`'s `check_env_bindings` coverage. |
| `tests/test_state.py` | `pantheon.state`'s cross-filesystem write safety — where `update_state()`'s temp file gets created, so a cross-device rename (`OSError(EXDEV)`) can never happen. |
| `tests/test_verdict.py` | `pantheon.verdict.emit_github_output`'s `$GITHUB_OUTPUT` side effect. |
| `tests/test_workflow_shape.py` | The consumer-facing workflow shape as an enforced control: plain `pull_request` trigger, no `pull_request_target`/`workflow_run`, least-privilege permissions, `persist-credentials: false`, and action.yml's upstream pin being a full commit SHA. |

```bash
pytest -q
```
