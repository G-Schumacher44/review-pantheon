"""tests/test_action_guard.py — the guard's own guard.

``tests/check_action_expressions.py`` is the mechanical enforcement behind three claims this repo
makes in SECURITY.md and in CI: no double-quoted literals inside ``${{ }}``, no ``${{ }}``
interpolated into a ``run:`` script, and no ``pull_request_target`` anywhere. Until this file
existed, **nothing asserted the guard could fail** — narrow one regex and CI stays green forever
with zero coverage, which is precisely the green-by-construction shape the guard was written to
prevent.

That is not hypothetical here. The first version of ``_run_block_spans`` matched only block
scalars (``run: |``), so a single-line ``run: echo "${{ ... }}"`` was never scanned — and the
guard printed "clean" over six live interpolations in ``action.yml``. A planted-violation fixture
would have caught it on day one. Hence one positive case per syntax form, not one per rule.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_action_expressions as guard  # noqa: E402


def _write(tmp_path: Path, body: str) -> Path:
    path = tmp_path / "candidate.yml"
    path.write_text(body, encoding="utf-8")
    return path


# --------------------------------------------------------------------------------------------
# ${{ }} interpolated into a run: script — BOTH YAML spellings must be caught.
# --------------------------------------------------------------------------------------------


# Every YAML spelling of `run:`, each carrying the SAME planted interpolation. A table, not
# hand-picked examples: the guard is a regex approximating a YAML parser, so its blind spots are
# exactly the spellings nobody thought to type. `run: |-` shipped unscanned for one commit because
# the suite had a `|` case and a single-line case and nothing in between — adding a spelling must
# be a row here, not a fresh test someone remembers to write.
RUN_SPELLINGS = [
    "|",  # plain block scalar
    "|-",  # strip chomping — the commonest spelling in real workflows
    "|+",  # keep chomping
    ">",  # folded
    ">-",  # folded + strip
    ">+",  # folded + keep
    "|2",  # explicit indentation indicator
    "|2-",  # indentation + chomping
    "| # trailing comment",
]


@pytest.mark.parametrize("indicator", RUN_SPELLINGS)
def test_flags_interpolation_in_every_block_scalar_spelling(tmp_path: Path, indicator: str) -> None:
    """A block-scalar header must never be mistaken for a single-line command.

    When it is, the recorded span is the header line alone and the body — where the interpolation
    actually lives — is walked past unscanned, so the guard reports "clean" on a live finding.
    """
    path = _write(
        tmp_path,
        f"jobs:\n  a:\n    steps:\n      - name: x\n        run: {indicator}\n"
        '          echo "${{ steps.decide.outputs.top_finding }}"\n',
    )
    findings = guard.check(path)
    assert any("run: block" in f for f in findings), (indicator, findings)


def test_flags_interpolation_in_a_SINGLE_LINE_run(tmp_path: Path) -> None:
    """The blind spot that shipped first: identical risk, different YAML spelling.

    An earlier `_run_block_spans` matched only block scalars, so this form was invisible and the
    guard reported "clean" over six real interpolations in action.yml.
    """
    path = _write(
        tmp_path,
        'jobs:\n  a:\n    steps:\n      - name: x\n        run: echo "${{ steps.decide.outputs.top_finding }}"\n',
    )
    findings = guard.check(path)
    assert any("run: block" in f for f in findings), findings


def test_allows_a_safe_context_in_a_run(tmp_path: Path) -> None:
    """matrix.* is workflow-authored, not model- or PR-controlled — must not be flagged."""
    path = _write(
        tmp_path,
        'jobs:\n  a:\n    steps:\n      - name: x\n        run: echo "${{ matrix.agent }}"\n',
    )
    assert guard.check(path) == []


def test_allows_interpolation_OUTSIDE_a_run_block(tmp_path: Path) -> None:
    """`env:` is exactly where these values are supposed to go — flagging it would be backwards."""
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        env:\n"
        "          TOP: ${{ steps.decide.outputs.top_finding }}\n"
        '        run: echo "$TOP"\n',
    )
    assert guard.check(path) == []


# --------------------------------------------------------------------------------------------
# Double-quoted literal inside an expression — invalid grammar, workflow never runs.
# --------------------------------------------------------------------------------------------


def test_flags_double_quoted_literal_in_an_expression(tmp_path: Path) -> None:
    path = _write(tmp_path, 'jobs:\n  a:\n    x: ${{ inputs.y || "fallback" }}\n')
    assert any("double-quoted literal" in f for f in guard.check(path))


def test_allows_the_single_quoted_form(tmp_path: Path) -> None:
    path = _write(tmp_path, "jobs:\n  a:\n    x: ${{ inputs.y || 'fallback' }}\n")
    assert guard.check(path) == []


# --------------------------------------------------------------------------------------------
# pull_request_target — use is fatal, mention is documentation.
# --------------------------------------------------------------------------------------------


def test_flags_pull_request_target_as_a_trigger(tmp_path: Path) -> None:
    path = _write(tmp_path, "on:\n  pull_request_target:\n    types: [opened]\n")
    assert any("FORBIDDEN" in f for f in guard.check_no_pull_request_target(path))


def test_does_not_flag_pull_request_target_in_a_comment(tmp_path: Path) -> None:
    """This repo's own warnings say the word repeatedly; they must not trip the check.

    Safe to skip comments HERE precisely because YAML/bash comments are inert — unlike the
    `${{ }}` rule above, which deliberately does not skip them, since expression substitution
    happens before bash parses and a newline in the value escapes the comment.
    """
    path = _write(
        tmp_path,
        "# NEVER use pull_request_target — see SECURITY.md\non:\n  pull_request:\n",
    )
    assert guard.check_no_pull_request_target(path) == []


# --------------------------------------------------------------------------------------------
# Per-step env bindings — a var read without its binding expands to the empty string.
# --------------------------------------------------------------------------------------------


def test_flags_a_step_reading_ACTION_PATH_without_binding_it(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        'jobs:\n  a:\n    steps:\n      - name: x\n        run: bash "$ACTION_PATH/lib/y.sh"\n',
    )
    assert any("does not bind" in f for f in guard.check_env_bindings(path))


def test_allows_a_step_that_binds_what_it_reads(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        env:\n"
        "          ACTION_PATH: ${{ github.action_path }}\n"
        '        run: bash "$ACTION_PATH/lib/y.sh"\n',
    )
    assert guard.check_env_bindings(path) == []


# --------------------------------------------------------------------------------------------
# The live surfaces must actually be clean — this is the assertion CI depends on.
# --------------------------------------------------------------------------------------------


@pytest.mark.parametrize("target", guard.TARGETS)
def test_the_shipped_action_surfaces_are_clean(target: str) -> None:
    path = guard.REPO_ROOT / target
    assert path.exists(), target
    findings = guard.check(path) + guard.check_env_bindings(path) + guard.check_no_pull_request_target(path)
    assert findings == [], findings
