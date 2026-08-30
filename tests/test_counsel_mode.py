"""action.yml's `mode: counsel` wiring (issue #95) — a structural companion to
tests/test-counsel-mode-fail-closed.sh (which drives action/lib/combine_verdicts.sh as a real
subprocess) and tests/test_workflow_shape.py (which guards the consumer-facing trigger/permissions
shape of examples/review-gate.yml and install.sh's Way A, neither of which this input touches).

This file asserts the properties a live GitHub Actions run can't be exercised for outside a real
runner: that the `mode` input defaults to "gate" (so every existing consumer is unaffected), that
gate mode's own enforcing step is the ONLY thing gated off in counsel mode, and that counsel mode
gets its own never-fails step instead — the fail-closed carve-out DESIGN.md's "counsel mode"
section states in prose, pinned here as parseable structure.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _action() -> str:
    return (ROOT / "action.yml").read_text(encoding="utf-8")


def _steps(action: str) -> list[str]:
    return re.split(r"^\s+-\s+(?=uses:|name:)", action, flags=re.M)


def _step_named(action: str, name: str) -> str:
    steps = [st for st in _steps(action) if re.search(rf"^\s*name:\s*{re.escape(name)}\s*$", st, re.M)]
    assert len(steps) == 1, f"action.yml: expected exactly one {name!r} step, found {len(steps)}"
    return steps[0]


def test_mode_input_defaults_to_gate() -> None:
    action = _action()
    block = re.search(r"^  mode:\s*$(.*?)(?=^  [A-Za-z_]+:\s*$|\Z)", action, re.M | re.S)
    assert block, "action.yml: no top-level 'mode:' input found"
    assert re.search(r'^\s*default:\s*"gate"\s*$', block.group(1), re.M), (
        "action.yml: the 'mode' input must default to \"gate\" — every existing consumer omits "
        "this input entirely, so a different default would silently change their behavior"
    )


def test_enforce_gate_result_is_skipped_in_counsel_mode() -> None:
    step = _step_named(_action(), "Enforce gate result")
    if_line = re.search(r"^\s*if:\s*(.*)$", step, re.M)
    assert if_line, "action.yml: 'Enforce gate result' step has no if: condition"
    assert "inputs.mode != 'counsel'" in if_line.group(1), (
        "action.yml: 'Enforce gate result' — the ONLY step in this file that can fail the job on "
        "a red/unverified color — must be gated off in counsel mode, or the fail-closed carve-out "
        "does not exist: " + if_line.group(1)
    )
    # This step's own body must stay capable of hard-failing gate mode — the carve-out belongs on
    # the `if:` line (whether this step runs at all), never inside the script itself.
    assert "exit 1" in step, (
        "action.yml: 'Enforce gate result' no longer hard-fails on red/unverified — gate mode's "
        "own enforcement must be untouched by this input's addition"
    )


def test_counsel_result_step_never_fails() -> None:
    action = _action()
    step = _step_named(action, "Counsel result (advisory — never fails this job)")
    if_line = re.search(r"^\s*if:\s*(.*)$", step, re.M)
    assert if_line and "inputs.mode == 'counsel'" in if_line.group(1), (
        "action.yml: the counsel-result step must be gated on inputs.mode == 'counsel'"
    )
    assert re.search(r"^\s*continue-on-error:\s*true\s*$", step, re.M), (
        "action.yml: the counsel-result step must set continue-on-error: true — belt-and-"
        "suspenders alongside its own unconditional exit 0"
    )
    # The run script's LAST non-blank line must be a bare, unconditional `exit 0` — not inside an
    # if/case branch, which would reopen exactly the "counsel can fail" gap this step exists to
    # close.
    run_block = re.search(r"^\s*run:\s*\|\s*$(.*?)(?=\Z)", step, re.M | re.S)
    assert run_block, "action.yml: the counsel-result step has no 'run: |' block"
    body_lines = [ln for ln in run_block.group(1).splitlines() if ln.strip()]
    assert body_lines and body_lines[-1].strip() == "exit 0", (
        f"action.yml: the counsel-result step's run script must end in a bare 'exit 0', found: "
        f"{body_lines[-1] if body_lines else '(empty)'!r}"
    )


def test_gate_only_agents_skip_counsel_mode() -> None:
    """artemis/apollo never run under mode: counsel — counsel always forces socrates/diogenes/
    plato regardless of the `agents` input (mirrors pantheon.cli's COUNSEL_AGENTS)."""
    action = _action()
    for agent in ("artemis", "apollo"):
        step = _step_named(action, f"Build prompt ({agent})")
        if_line = re.search(r"^\s*if:\s*(.*)$", step, re.M)
        assert if_line and "inputs.mode != 'counsel'" in if_line.group(1), (
            f"action.yml: 'Build prompt ({agent})' must be gated off in counsel mode: "
            f"{if_line.group(1) if if_line else '(missing if:)'}"
        )


def test_counsel_agents_run_in_counsel_mode_regardless_of_agents_input() -> None:
    action = _action()
    for agent in ("socrates", "diogenes", "plato"):
        step = _step_named(action, f"Build prompt ({agent})")
        if_line = re.search(r"^\s*if:\s*(.*)$", step, re.M)
        assert if_line and "inputs.mode == 'counsel'" in if_line.group(1), (
            f"action.yml: 'Build prompt ({agent})' must run whenever mode is counsel, even if "
            f"the 'agents' input never names it: {if_line.group(1) if if_line else '(missing if:)'}"
        )


def test_combine_step_forces_counsel_agents_and_passes_mode() -> None:
    step = _step_named(_action(), "Build and post combined comment")
    assert "inputs.mode == 'counsel' && 'socrates diogenes plato'" in step, (
        "action.yml: the combine step's AGENTS env must force the counsel trio in counsel mode, "
        "ignoring the 'agents' input — mirrors pantheon.cli's COUNSEL_AGENTS forcing"
    )
    assert re.search(r"^\s*MODE:\s*\$\{\{\s*inputs\.mode\s*\}\}\s*$", step, re.M), (
        "action.yml: the combine step must forward MODE: ${{ inputs.mode }} to "
        "combine_verdicts.sh, or the advisory banner can never be selected"
    )


def test_trigger_step_only_allows_workflow_dispatch_for_counsel_mode() -> None:
    """The literal-`pull_request_target`-ban itself is tests/check_action_expressions.py's job
    (it already correctly exempts comment-only lines, which this file's own explanatory comments
    rely on) — not re-checked here to avoid a second, less careful copy of that rule."""
    step = _step_named(_action(), "Require an allowed trigger")
    assert 'EVENT_NAME" = "workflow_dispatch"' in step and 'MODE" = "counsel"' in step, (
        "action.yml: the trigger-allowlist step must condition its workflow_dispatch allowance on mode == 'counsel'"
    )


def test_combine_verdicts_sh_gates_the_banner_on_mode() -> None:
    script = (ROOT / "action" / "lib" / "combine_verdicts.sh").read_text(encoding="utf-8")
    assert "MODE:-gate" in script and "counsel" in script, (
        "action/lib/combine_verdicts.sh: expected a MODE-gated branch selecting the counsel advisory banner"
    )
    assert "advisory, not a gate" in script


def test_resolve_step_and_counsel_build_prompts_degrade_instead_of_failing() -> None:
    """The steps between auth and the combine step that can genuinely error (a refused
    base-pinned read, a missing persona) must not be able to fail the whole job in counsel mode —
    only the trigger/auth checks stay hard, deliberately (see this file's module docstring)."""
    action = _action()
    resolve = _step_named(action, "Resolve gate configuration")
    assert re.search(r"^\s*continue-on-error:\s*\$\{\{\s*inputs\.mode == 'counsel'\s*\}\}\s*$", resolve, re.M), (
        "action.yml: 'Resolve gate configuration' must set continue-on-error: ${{ inputs.mode == 'counsel' }}"
    )
    for agent in ("socrates", "diogenes", "plato"):
        step = _step_named(action, f"Build prompt ({agent})")
        assert re.search(r"^\s*continue-on-error:\s*\$\{\{\s*inputs\.mode == 'counsel'\s*\}\}\s*$", step, re.M), (
            f"action.yml: 'Build prompt ({agent})' must set continue-on-error: ${{{{ inputs.mode == 'counsel' }}}}"
        )


def test_counsel_agent_launch_gated_on_setup_success() -> None:
    """Codex P1 (PR #98): under the continue-on-error carve-out above, a step that fails partway
    through can still have written SOME of its outputs before erroring — a launch condition that
    only checks auth would fire the provider on that partial/stale prompt/claude_args instead of
    degrading to UNVERIFIED. Each counsel agent's 'Run <agent>' step must additionally require the
    config-resolution step's own resolve_ok flag AND that agent's own build-prompt step's build_ok
    flag, both literally 'true' — flags each step writes only as its OWN LAST output line, so a
    `set -euo pipefail` failure anywhere earlier in that same script leaves the flag unset."""
    action = _action()
    resolve = _step_named(action, "Resolve gate configuration")
    assert re.search(r'^\s*echo "resolve_ok=true" >> "\$GITHUB_OUTPUT"\s*$', resolve, re.M), (
        "action.yml: 'Resolve gate configuration' must write resolve_ok=true as its own last "
        "output line, so a continue-on-error failure under counsel mode never looks like success "
        "to a downstream step's if: condition"
    )
    for agent in ("socrates", "diogenes", "plato"):
        build_step = _step_named(action, f"Build prompt ({agent})")
        assert re.search(r'^\s*echo "build_ok=true" >> "\$GITHUB_OUTPUT"\s*$', build_step, re.M), (
            f"action.yml: 'Build prompt ({agent})' must write build_ok=true as its own last output line"
        )
        run_step = _step_named(action, f"Run {agent}")
        if_line = re.search(r"^\s*if:\s*(.*)$", run_step, re.M)
        assert if_line, f"action.yml: 'Run {agent}' has no if: condition"
        assert "steps.resolve.outputs.resolve_ok == 'true'" in if_line.group(1), (
            f"action.yml: 'Run {agent}' must require steps.resolve.outputs.resolve_ok == 'true' "
            f"before launching the provider — auth succeeding is not enough: {if_line.group(1)}"
        )
        assert f"steps.build-prompt-{agent}.outputs.build_ok == 'true'" in if_line.group(1), (
            f"action.yml: 'Run {agent}' must require its own build-prompt step's build_ok == "
            f"'true' before launching the provider: {if_line.group(1)}"
        )


def test_workflow_dispatch_default_branch_resolution_is_robust() -> None:
    """Codex P2 (PR #98): `refs/remotes/origin/HEAD` is an OPTIONAL git ref (git's own docs say
    so), not guaranteed by `fetch-depth: 0` — a hardcoded 'main' fallback would silently review the
    wrong ref in a repo whose default branch is anything else. Resolution must prefer
    `github.event.repository.default_branch` (the same `github` context every other step in this
    file already reads), fall back to `origin/HEAD` then `git remote show origin`, and fail loud —
    never guess "main" — if every source comes up empty."""
    step = _step_named(_action(), "Resolve workflow_dispatch context (counsel mode)")
    assert re.search(
        r"^\s*REPO_DEFAULT_BRANCH:\s*\$\{\{\s*github\.event\.repository\.default_branch\s*\}\}\s*$",
        step,
        re.M,
    ), (
        "action.yml: the wd-context step must bind REPO_DEFAULT_BRANCH from "
        "github.event.repository.default_branch in its own env:"
    )
    assert "git remote show origin" in step, (
        "action.yml: the wd-context step must fall back to querying the remote directly "
        "('git remote show origin') when both github.event.repository.default_branch and "
        "refs/remotes/origin/HEAD are empty"
    )
    assert 'DEFAULT_BRANCH="main"' not in step, (
        "action.yml: the wd-context step must not silently default to 'main' when no source "
        "resolves the default branch — that reviews the wrong ref for any repo whose default "
        "branch isn't literally 'main'"
    )
    assert "could not resolve this repository's default branch" in step, (
        "action.yml: the wd-context step must fail loud with a clear ::error:: message when the "
        "default branch cannot be resolved from any source, rather than guessing"
    )
