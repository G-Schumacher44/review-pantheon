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


def test_flags_a_step_reading_an_unbound_var_with_no_hardcoded_name(tmp_path: Path) -> None:
    """Derived, not a hand-restated allowlist (issue #78): a var this suite never names must
    still be caught, since a hardcoded name tuple is exactly the drift class that let 57 of
    action.yml's 59 bound vars go unchecked."""
    path = _write(
        tmp_path,
        'jobs:\n  a:\n    steps:\n      - name: x\n        run: echo "$TOTALLY_UNRELATED_VAR"\n',
    )
    findings = guard.check_env_bindings(path)
    assert any("TOTALLY_UNRELATED_VAR" in f for f in findings), findings


def test_allows_shell_builtin_and_positional_vars_unbound(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        '          echo "$HOME $PATH $PWD $TMPDIR $RANDOM $1 $2 $? $@ $#"\n',
    )
    assert guard.check_env_bindings(path) == []


def test_flags_a_length_of_expansion_on_an_unbound_var(tmp_path: Path) -> None:
    """``${#UNBOUND}`` (length-of) is a PREFIX operator on UNBOUND, not a read of the permitted
    special parameter ``#`` (argument count) — the brace matcher must record UNBOUND as the read,
    not stop at the prefix and let the real variable go unchecked (Codex finding, PR #82 line 74)."""
    path = _write(
        tmp_path,
        'jobs:\n  a:\n    steps:\n      - name: x\n        run: echo "${#SOME_UNBOUND_VAR}"\n',
    )
    findings = guard.check_env_bindings(path)
    assert any("SOME_UNBOUND_VAR" in f for f in findings), findings


def test_flags_an_indirect_expansion_on_an_unbound_var(tmp_path: Path) -> None:
    """``${!UNBOUND}`` (indirection) is the same prefix-operator shape as ``${#UNBOUND}`` — same
    fix, same finding."""
    path = _write(
        tmp_path,
        'jobs:\n  a:\n    steps:\n      - name: x\n        run: echo "${!SOME_UNBOUND_VAR}"\n',
    )
    findings = guard.check_env_bindings(path)
    assert any("SOME_UNBOUND_VAR" in f for f in findings), findings


def test_allows_bare_arg_count_and_last_bg_pid_braced_forms(tmp_path: Path) -> None:
    """``${#}`` (argument count) and ``${!}`` (last background PID) ARE the permitted special
    parameters themselves, not a prefix on a missing variable — the optional-prefix regex must
    backtrack to the bare-special reading when no variable-shaped token follows the prefix char."""
    path = _write(
        tmp_path,
        'jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n          echo "${#} ${!}"\n',
    )
    assert guard.check_env_bindings(path) == []


def test_allows_runner_provided_vars_unbound(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        '          echo "x" >> "$GITHUB_OUTPUT"\n'
        '          echo "$RUNNER_TEMP $CI"\n',
    )
    assert guard.check_env_bindings(path) == []


def test_allows_a_var_the_script_assigns_itself(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        "          LOCAL_VAR=hello\n"
        '          echo "$LOCAL_VAR"\n',
    )
    assert guard.check_env_bindings(path) == []


def test_allows_a_for_loop_variable(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        "          for item in a b c; do\n"
        '            echo "$item"\n'
        "          done\n",
    )
    assert guard.check_env_bindings(path) == []


def test_flags_unbound_github_token(tmp_path: Path) -> None:
    """``GITHUB_TOKEN`` is NOT one of the runner's default env vars (unlike ``GITHUB_OUTPUT`` /
    ``GITHUB_STEP_SUMMARY`` / etc.) — a step reading it must bind it explicitly via its own
    ``env:``. A prior version of this guard wildcarded every ``GITHUB_*`` name as pre-bound,
    which silently exempted exactly this case (Codex finding, PR #82)."""
    path = _write(
        tmp_path,
        'jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n          echo "token is $GITHUB_TOKEN"\n',
    )
    findings = guard.check_env_bindings(path)
    assert any("GITHUB_TOKEN" in f for f in findings), findings


def test_does_not_flag_a_var_named_like_prose_containing_read(tmp_path: Path) -> None:
    """An unanchored ``read`` regex would match the word "read" anywhere in a step's script —
    including inside a comment or an echoed string — and misattribute whatever follows it as a
    locally-defined variable, hiding a genuinely unbound var with that name (Artemis finding,
    PR #82)."""
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        "          # this value is read exactly once, by ONCE\n"
        '          echo "$ONCE"\n',
    )
    findings = guard.check_env_bindings(path)
    assert any("ONCE" in f for f in findings), findings


def test_allows_a_read_loop_variable(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        '          while IFS= read -r line; do echo "$line"; done <<< "$x"\n',
    )
    findings = guard.check_env_bindings(path)
    assert not any("$line" in f for f in findings), findings


def test_does_not_flag_a_var_inside_a_single_quoted_heredoc(tmp_path: Path) -> None:
    """A single-quoted heredoc delimiter (``<<'EOF'``) disables ALL expansion in its body — bash
    never touches ``$UNBOUND`` there, so it must not be treated as a read requiring a binding."""
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        "          cat <<'EOF'\n"
        "          this is $UNBOUND_IN_HEREDOC literal text\n"
        "          EOF\n",
    )
    assert guard.check_env_bindings(path) == []


def test_flags_a_var_inside_an_unquoted_heredoc(tmp_path: Path) -> None:
    """The counterpart: an UNQUOTED heredoc delimiter (``<<EOF``) DOES expand its body, so a read
    there is real and must still require a binding."""
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        "          cat <<EOF\n"
        "          this is $UNBOUND_IN_HEREDOC expanded\n"
        "          EOF\n",
    )
    findings = guard.check_env_bindings(path)
    assert any("UNBOUND_IN_HEREDOC" in f for f in findings), findings


def test_flags_a_length_of_expansion_on_an_unbound_var_inside_an_unquoted_heredoc(tmp_path: Path) -> None:
    """The heredoc-body scanner must resolve ``${#VAR}``/``${!VAR}`` prefix operators the same way
    the main scanner does — an earlier fix added the prefix backtrack to ``_BRACE_VAR`` (used by
    the normal ``run:`` text path) but the heredoc branch kept its own separate variable regex, so
    ``${#UNBOUND}`` inside an expanding heredoc still matched the permitted special parameter ``#``
    alone and the real read of UNBOUND went unchecked (Codex finding, PR #82, round 2)."""
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        "          cat <<EOF\n"
        "          length is ${#SOME_UNBOUND_VAR}\n"
        "          EOF\n",
    )
    findings = guard.check_env_bindings(path)
    assert any("SOME_UNBOUND_VAR" in f for f in findings), findings


def test_flags_an_indirect_expansion_on_an_unbound_var_inside_an_unquoted_heredoc(tmp_path: Path) -> None:
    """Same defect class as the length-of case above, for the ``${!VAR}`` indirection prefix."""
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        "          cat <<EOF\n"
        "          value is ${!SOME_UNBOUND_VAR}\n"
        "          EOF\n",
    )
    findings = guard.check_env_bindings(path)
    assert any("SOME_UNBOUND_VAR" in f for f in findings), findings


def test_allows_bare_arg_count_and_last_bg_pid_braced_forms_inside_an_unquoted_heredoc(tmp_path: Path) -> None:
    """``${#}``/``${!}`` are the permitted special parameters themselves, not a prefix on a missing
    variable — the heredoc scanner must backtrack to the bare-special reading exactly like the main
    scanner does, whether the match comes from the shared ``_match_var`` helper or not."""
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n"
        "          cat <<EOF\n"
        "          ${#} ${!}\n"
        "          EOF\n",
    )
    assert guard.check_env_bindings(path) == []


def test_does_not_flag_an_escaped_dollar(tmp_path: Path) -> None:
    path = _write(
        tmp_path,
        'jobs:\n  a:\n    steps:\n      - name: x\n        run: echo "price is \\$UNBOUND_VAR"\n',
    )
    assert guard.check_env_bindings(path) == []


def test_does_not_flag_an_awk_field_reference_in_a_single_quoted_program(tmp_path: Path) -> None:
    """``awk '{print $1}'`` — bash never expands ``$1`` inside the single-quoted awk program; it
    is a field reference the awk subprocess reads literally, not a bash variable read."""
    path = _write(
        tmp_path,
        "jobs:\n  a:\n    steps:\n      - name: x\n        run: |\n          echo \"a b\" | awk '{print $1, $2}'\n",
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
