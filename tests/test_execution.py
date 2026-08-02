"""tests/test_execution.py — pytest unit layer for pantheon.execution.resolve_console_script
(docs/PYTHON-PORT.md section 4's port slice 4 deliverable).

resolve_console_script is shared by pantheon.cli's _wrapper_invocation() and
pantheon.providers' default_allowed_tools() (both covered by their own dedicated tests already —
tests/test_cli_helpers.py, tests/test_providers.py) — this file covers the shared function
itself directly, once, rather than duplicating the same fixture shape in both call sites' test
files. A Codex review finding on this port's own PR: an earlier version of both call sites only
checked `os.path.dirname(sys.executable)`, missing `pip install --user` entirely (sys.executable
stays the system interpreter under --user while console scripts land in a separate per-user
directory).
"""

from __future__ import annotations

import os

from pantheon import execution


def test_resolves_a_script_next_to_sys_executable(monkeypatch, tmp_path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    script = bin_dir / "my-console-script"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)
    monkeypatch.setattr(execution.sys, "executable", str(bin_dir / "python3"))

    assert execution.resolve_console_script("my-console-script") == str(script)


def test_resolves_a_script_in_the_per_user_scripts_directory_when_absent_next_to_sys_executable(
    monkeypatch, tmp_path
) -> None:
    # The exact --user-install shape the finding named: sys.executable lives in one directory
    # (simulating the system interpreter), the console script lives in a COMPLETELY SEPARATE
    # per-user scripts directory that has nothing to do with sys.executable's own location.
    system_bin = tmp_path / "system-bin"
    system_bin.mkdir()
    monkeypatch.setattr(execution.sys, "executable", str(system_bin / "python3"))

    user_scripts = tmp_path / "user-scripts"
    user_scripts.mkdir()
    script = user_scripts / "my-console-script"
    script.write_text("#!/bin/sh\n")
    script.chmod(0o755)
    monkeypatch.setattr(execution.sysconfig, "get_path", lambda name, scheme=None: str(user_scripts))

    assert execution.resolve_console_script("my-console-script") == str(script)


def test_prefers_the_sys_executable_directory_when_the_script_exists_in_both(monkeypatch, tmp_path) -> None:
    primary_bin = tmp_path / "primary-bin"
    primary_bin.mkdir()
    primary_script = primary_bin / "my-console-script"
    primary_script.write_text("#!/bin/sh\n")
    primary_script.chmod(0o755)
    monkeypatch.setattr(execution.sys, "executable", str(primary_bin / "python3"))

    user_scripts = tmp_path / "user-scripts"
    user_scripts.mkdir()
    (user_scripts / "my-console-script").write_text("#!/bin/sh\n")
    (user_scripts / "my-console-script").chmod(0o755)
    monkeypatch.setattr(execution.sysconfig, "get_path", lambda name, scheme=None: str(user_scripts))

    assert execution.resolve_console_script("my-console-script") == str(primary_script)


def test_returns_none_when_not_found_anywhere(monkeypatch, tmp_path) -> None:
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    monkeypatch.setattr(execution.sys, "executable", str(empty_bin / "python3"))
    empty_user = tmp_path / "empty-user-scripts"
    empty_user.mkdir()
    monkeypatch.setattr(execution.sysconfig, "get_path", lambda name, scheme=None: str(empty_user))

    assert execution.resolve_console_script("nonexistent-script") is None


def test_returns_none_never_raises_when_the_user_scheme_is_unavailable(monkeypatch, tmp_path) -> None:
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    monkeypatch.setattr(execution.sys, "executable", str(empty_bin / "python3"))

    def _raise(name, scheme=None):
        raise KeyError(scheme)

    monkeypatch.setattr(execution.sysconfig, "get_path", _raise)

    # Must not raise -- falls back to just the sys.executable-adjacent check.
    assert execution.resolve_console_script("nonexistent-script") is None


def test_live_resolution_of_the_actually_installed_pantheon_git_readonly_script() -> None:
    # Live (non-mocked): this test's own venv has `pantheon-git-readonly` installed (this repo's
    # own pip install -e . as part of the dev/CI setup) -- proves the real function, unmocked,
    # actually finds the real installed script via the real sys.executable-adjacent path.
    import sys

    expected = os.path.join(os.path.dirname(sys.executable), "pantheon-git-readonly")
    if not (os.path.isfile(expected) and os.access(expected, os.X_OK)):
        import pytest

        pytest.skip("pantheon-git-readonly is not installed in this test environment")
    assert execution.resolve_console_script("pantheon-git-readonly") == expected
