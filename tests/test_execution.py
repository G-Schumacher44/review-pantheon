"""tests/test_execution.py — pytest unit layer for pantheon.execution.resolve_console_script
(docs/PYTHON-PORT.md section 4's port slice 4 deliverable).

resolve_console_script is shared by pantheon.cli's _wrapper_invocation() and
pantheon.providers' default_allowed_tools() (both covered by their own dedicated tests already —
tests/test_cli_helpers.py, tests/test_providers.py) — this file covers the shared function
itself directly, once, rather than duplicating the same fixture shape in both call sites' test
files.

History: an EARLIER version of this function also consulted
``sysconfig.get_path("scripts", scheme=f"{os.name}_user")`` to additionally support
``pip install --user`` (sys.executable stays the system interpreter under --user while console
scripts land in a separate per-user directory). A Codex review finding on this port's own PR
caught the resulting hole: that scheme resolves through ``PYTHONUSERBASE``, an ordinary
environment variable a hostile launcher can point anywhere -- including AT the checked-out PR's
own tree, letting a PR-committed ``bin/pantheon-git-readonly`` be resolved as if it were the
real, trusted-installed console script. Fixed by resolving ONLY at
``os.path.dirname(sys.executable)`` -- a single, environment-immune location, matching
TRUSTED_GIT_DIRS's own "no config knob to widen this list" posture. See
pantheon/execution.py's resolve_console_script docstring for the full rationale.
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


def test_never_consults_sysconfig_or_site_at_all(monkeypatch, tmp_path) -> None:
    # Structural proof of the fix: resolve_console_script must not call sysconfig.get_path (or
    # anything else routed through sysconfig/site) under any circumstance -- a legitimate script
    # sitting in what WOULD have been the per-user scripts directory is never found, because that
    # directory is never even consulted.
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    monkeypatch.setattr(execution.sys, "executable", str(empty_bin / "python3"))

    def _fail_if_called(*args, **kwargs):
        raise AssertionError("resolve_console_script must never call sysconfig.get_path")

    monkeypatch.setattr("sysconfig.get_path", _fail_if_called)

    user_scripts = tmp_path / "user-scripts"
    user_scripts.mkdir()
    script = user_scripts / "my-console-script"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)

    assert execution.resolve_console_script("my-console-script") is None


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
