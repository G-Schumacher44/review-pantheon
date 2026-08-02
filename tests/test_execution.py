"""tests/test_execution.py — pytest unit layer for pantheon.execution.resolve_console_script
(docs/PYTHON-PORT.md section 4's port slice 4 deliverable; issue #21 P1's fixtures land in the
"pip install --user layout" section below, port slice 5).

resolve_console_script is shared by pantheon.cli's _wrapper_invocation() and
pantheon.providers' default_allowed_tools() (both covered by their own dedicated tests already —
tests/test_cli_helpers.py, tests/test_providers.py) — this file covers the shared function
itself directly, once, rather than duplicating the same fixture shape in both call sites' test
files.

History (three rounds):
  1. An EARLIER version of this function consulted
     ``sysconfig.get_path("scripts", scheme=f"{os.name}_user")`` to support
     ``pip install --user`` (sys.executable stays the system interpreter under --user while
     console scripts land in a separate per-user directory). A Codex review finding on this
     port's own PR caught the resulting hole: that scheme resolves through ``PYTHONUSERBASE``,
     an ordinary environment variable a hostile launcher can point anywhere -- including AT the
     checked-out PR's own tree, letting a PR-committed ``bin/pantheon-git-readonly`` be resolved
     as if it were the real, trusted-installed console script.
  2. Fixed by resolving ONLY at ``os.path.dirname(sys.executable)`` -- a single,
     environment-immune location, matching TRUSTED_GIT_DIRS's own "no config knob to widen this
     list" posture. This closed the hole but reopened issue #21 P1: EVERY real
     ``pip install --user`` layout (a layout slice 5's packaging work makes real, not
     hypothetical) now resolved to ``None``, and callers' own fallback -- unprotected
     ``python -m pantheon.execution wrapper``, run with a hostile checkout as cwd -- silently
     re-exposed the exact shadow vector round 1 closed.
  3. Issue #21 P1 (slice 5, this file's "pip install --user layout" section below): resolves
     safely instead of falling back -- a SECOND fixed lookup location,
     ``_default_user_scripts_dir()``'s ``bin`` subdirectory, computed from HOME by a formula
     that never reads PYTHONUSERBASE (or any other env var), so it finds a genuine
     ``pip install --user`` layout without reopening round 1's hole.

See pantheon/execution.py's resolve_console_script AND _default_user_scripts_dir docstrings for
the full rationale.
"""

from __future__ import annotations

import os
import subprocess
import sys

import pytest

from pantheon import execution


def test_resolves_a_script_next_to_sys_executable(monkeypatch, tmp_path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    script = bin_dir / "my-console-script"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)
    monkeypatch.setattr(execution.sys, "executable", str(bin_dir / "python3"))

    assert execution.resolve_console_script("my-console-script") == str(script)


def test_returns_none_when_not_found_anywhere(monkeypatch, tmp_path) -> None:
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    monkeypatch.setattr(execution.sys, "executable", str(empty_bin / "python3"))

    assert execution.resolve_console_script("nonexistent-script") is None


def test_never_consults_sysconfig_get_path(monkeypatch, tmp_path) -> None:
    # Structural proof of the round-1 fix, still true after issue #21 P1's round-3 fix:
    # resolve_console_script must never call sysconfig.get_path (the PYTHONUSERBASE-driven,
    # env-redirectable lookup the vulnerability history above describes) under any circumstance.
    # A legitimate script sitting in an ARBITRARY directory that is neither of the two fixed
    # locations this function now checks (sys.executable-adjacent, or _default_user_scripts_dir's
    # HOME-derived default) is still never found -- proving the fix isn't "search everywhere",
    # it's "search exactly two fixed, environment-immune locations".
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    monkeypatch.setattr(execution.sys, "executable", str(empty_bin / "python3"))
    monkeypatch.setattr(execution.os.path, "expanduser", lambda p: str(tmp_path / "not-home"))

    def _fail_if_called(*args, **kwargs):
        raise AssertionError("resolve_console_script must never call sysconfig.get_path")

    monkeypatch.setattr("sysconfig.get_path", _fail_if_called)

    user_scripts = tmp_path / "user-scripts"
    user_scripts.mkdir()
    script = user_scripts / "my-console-script"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)

    assert execution.resolve_console_script("my-console-script") is None


# ---------------------------------------------------------------------------------------------
# pip install --user layout — issue #21 P1 (docs/PYTHON-PORT.md's port slice 5): the console
# script isn't adjacent to sys.executable (pip install --user's own separate per-user scripts
# directory, e.g. ~/.local/bin) — this must now resolve SAFELY via _default_user_scripts_dir's
# HOME-derived, PYTHONUSERBASE-blind computation, not fall back to the unsafe
# `python -m pantheon.execution wrapper` form. Proven failing pre-fix: reverting
# resolve_console_script to its pre-#21 body (adjacent-to-sys.executable check only, no
# _default_user_scripts_dir fallback) makes
# test_resolves_a_pip_install_user_layout_via_the_default_user_base FAIL (returns None instead of
# the expected path) -- verified locally by temporarily reverting pantheon/execution.py and
# re-running this file; restored before committing.
# ---------------------------------------------------------------------------------------------


def test_default_user_scripts_dir_never_reads_pythonuserbase(monkeypatch, tmp_path) -> None:
    # Regression guard for round 1's own vulnerability, on the NEW lookup this fix adds: setting
    # PYTHONUSERBASE to a hostile directory must have NO effect on the computed default -- the
    # whole point of computing it from HOME instead of consulting the env var.
    monkeypatch.setenv("PYTHONUSERBASE", "/hostile/checkout")
    fake_home = tmp_path / "real-home"
    fake_home.mkdir()
    monkeypatch.setattr(execution.os.path, "expanduser", lambda p: str(fake_home) if p == "~" else p)
    monkeypatch.setattr(execution.sysconfig, "get_config_var", lambda name: None)

    result = execution._default_user_scripts_dir()

    assert result == str(fake_home / ".local")
    assert "/hostile/checkout" not in (result or "")


def test_resolves_a_pip_install_user_layout_via_the_default_user_base(monkeypatch, tmp_path) -> None:
    # The layout issue #21 P1 names explicitly: sys.executable is the system interpreter (no
    # console script adjacent to it), but a real `pip install --user` placed the console script
    # at the DEFAULT per-user base's bin/ subdirectory.
    fake_home = tmp_path / "home"
    user_bin = fake_home / ".local" / "bin"
    user_bin.mkdir(parents=True)
    script = user_bin / "pantheon-git-readonly"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)

    system_python_dir = tmp_path / "usr-bin"
    system_python_dir.mkdir()
    monkeypatch.setattr(execution.sys, "executable", str(system_python_dir / "python3"))
    monkeypatch.setattr(execution.os.path, "expanduser", lambda p: str(fake_home) if p == "~" else p)
    monkeypatch.setattr(execution.sysconfig, "get_config_var", lambda name: None)

    assert execution.resolve_console_script("pantheon-git-readonly") == str(script)


def test_user_install_layout_does_not_fall_back_to_the_unsafe_form(monkeypatch, tmp_path) -> None:
    # End-to-end proof that the caller-visible symptom issue #21 P1 describes is gone: with a
    # real --user-style layout present, resolve_console_script returns the REAL script, not None
    # -- so a caller (pantheon.cli._wrapper_invocation / pantheon.providers.default_allowed_tools)
    # never reaches its own "fall back to python -m pantheon.execution wrapper" branch at all for
    # this layout.
    fake_home = tmp_path / "home"
    user_bin = fake_home / ".local" / "bin"
    user_bin.mkdir(parents=True)
    script = user_bin / "pantheon-git-readonly"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)

    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    monkeypatch.setattr(execution.sys, "executable", str(empty_bin / "python3"))
    monkeypatch.setattr(execution.os.path, "expanduser", lambda p: str(fake_home) if p == "~" else p)
    monkeypatch.setattr(execution.sysconfig, "get_config_var", lambda name: None)

    result = execution.resolve_console_script("pantheon-git-readonly")
    assert result is not None
    assert result == str(script)


def test_default_user_scripts_dir_none_on_non_posix(monkeypatch) -> None:
    monkeypatch.setattr(execution.os, "name", "nt")
    assert execution._default_user_scripts_dir() is None


def test_default_user_scripts_dir_none_when_home_unresolvable(monkeypatch):
    monkeypatch.setattr(execution.os.path, "expanduser", lambda p: "~")
    assert execution._default_user_scripts_dir() is None


def test_default_user_scripts_dir_macos_framework_build(monkeypatch, tmp_path) -> None:
    fake_home = tmp_path / "home"
    fake_home.mkdir()
    monkeypatch.setattr(execution.os.path, "expanduser", lambda p: str(fake_home) if p == "~" else p)
    monkeypatch.setattr(execution.sys, "platform", "darwin")
    monkeypatch.setattr(
        execution.sysconfig, "get_config_var", lambda name: "Python" if name == "PYTHONFRAMEWORK" else None
    )

    result = execution._default_user_scripts_dir()

    major, minor = sys.version_info.major, sys.version_info.minor
    assert result == str(fake_home / "Library" / "Python" / f"{major}.{minor}")


def test_pythonuserbase_hijack_is_not_followed_live(tmp_path) -> None:
    # Live, non-mocked reproduction of the exact finding: a hostile launcher exports
    # PYTHONUSERBASE pointed at a directory it fully controls (standing in for "the checked-out
    # PR's own tree") containing a marker script matching the real console-script's name.
    #
    # First proves the vulnerability is REAL by using raw sysconfig resolution directly (the
    # mechanism the pre-fix code used) to confirm it WOULD find the hijacked script -- this half
    # fails closed (skips) if this Python's own sysconfig doesn't behave as documented, so the
    # second assertion is never trusted on a false premise.
    #
    # Then proves the FIX: pantheon.execution.resolve_console_script, run in a subprocess that
    # inherits the identical hijacked PYTHONUSERBASE, never returns the hijacked script's path.
    hostile_base = tmp_path / "hostile-checkout"
    hostile_scripts_dir = hostile_base / "bin"
    hostile_scripts_dir.mkdir(parents=True)
    marker_script = hostile_scripts_dir / "pantheon-git-readonly"
    marker_script.write_text("#!/bin/sh\necho HIJACKED\n")
    marker_script.chmod(0o755)

    hijack_env = dict(os.environ)
    hijack_env["PYTHONUSERBASE"] = str(hostile_base)

    raw = subprocess.run(
        [
            sys.executable,
            "-c",
            "import sysconfig, os; print(sysconfig.get_path('scripts', scheme=f'{os.name}_user'))",
        ],
        env=hijack_env,
        capture_output=True,
        text=True,
    )
    if raw.returncode != 0 or raw.stdout.strip() != str(hostile_scripts_dir):
        pytest.skip(
            "this Python's sysconfig user-scheme resolution doesn't match the assumed shape "
            f"(rc={raw.returncode}, stdout={raw.stdout!r}) -- vulnerability precondition unmet, "
            "the fix assertion below would be untrustworthy"
        )

    fixed = subprocess.run(
        [
            sys.executable,
            "-c",
            "from pantheon import execution; print(execution.resolve_console_script('pantheon-git-readonly'))",
        ],
        env=hijack_env,
        capture_output=True,
        text=True,
    )
    assert fixed.returncode == 0
    assert fixed.stdout.strip() != str(marker_script)
    assert "HIJACKED" not in fixed.stdout


def test_live_resolution_of_the_actually_installed_pantheon_git_readonly_script() -> None:
    # Live (non-mocked): this test's own venv has `pantheon-git-readonly` installed (this repo's
    # own pip install -e . as part of the dev/CI setup) -- proves the real function, unmocked,
    # actually finds the real installed script via the real sys.executable-adjacent path.
    expected = os.path.join(os.path.dirname(sys.executable), "pantheon-git-readonly")
    if not (os.path.isfile(expected) and os.access(expected, os.X_OK)):
        pytest.skip("pantheon-git-readonly is not installed in this test environment")
    assert execution.resolve_console_script("pantheon-git-readonly") == expected


# ---------------------------------------------------------------------------------------------
# _forced_env() — the Python-family defensive clear (companion fix to resolve_console_script's
# own hardening above): PYTHONUSERBASE/PYTHONPATH/PYTHONHOME/PYTHONSTARTUP force-cleared,
# PYTHONNOUSERSITE=1 set, in every subprocess env this module constructs.
# ---------------------------------------------------------------------------------------------


def test_forced_env_force_clears_the_python_family_defensively(monkeypatch) -> None:
    monkeypatch.setenv("PYTHONUSERBASE", "/hostile/checkout")
    monkeypatch.setenv("PYTHONPATH", "/hostile/checkout/evil")
    monkeypatch.setenv("PYTHONHOME", "/hostile/checkout")
    monkeypatch.setenv("PYTHONSTARTUP", "/hostile/checkout/payload.py")

    env = execution._forced_env()

    assert env["PYTHONUSERBASE"] == ""
    assert env["PYTHONPATH"] == ""
    assert env["PYTHONHOME"] == ""
    assert env["PYTHONSTARTUP"] == ""
    assert env["PYTHONNOUSERSITE"] == "1"
