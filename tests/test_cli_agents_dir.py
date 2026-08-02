"""tests/test_cli_agents_dir.py — pytest unit layer for pantheon.cli._agents_dir() (port slice
5's packaging fix, a Codex review finding on this port's own PR).

A real, non-editable `pip`/`pipx` install of the pantheon package carried NO persona files at
all before this fix: pyproject.toml packaged only `pantheon*`, but _agents_dir() resolved
`agents/` as a SIBLING of this module's own installed location on disk (`Path(__file__).
resolve().parent.parent / "agents"`) -- true for a dev checkout (where pantheon/ and agents/ are
siblings), never for a real site-packages install (where pantheon/cli.py's __file__ lives inside
site-packages/pantheon/, with nothing else installed alongside it). Fixed via pyproject.toml's
package-dir remap (pantheon.agents -> agents) plus an importlib.resources-based loader here,
with the dev-checkout sibling-directory lookup kept as a fallback.

This file covers the FALLBACK-selection logic directly (mocked); the real, end-to-end proof
against an actual built wheel lives in tests/test-bootstrap-release-e2e.sh (a real `pip install`
into a scratch venv, run from a neutral cwd with no source checkout nearby) and was verified
manually (a real `python -m build` + `pip install` of the built wheel, proven failing against
the pre-fix `_agents_dir()` body, then passing again after restoring the fix) before landing
this PR -- see that suite's own "Persona resolution from the REAL, non-editable venv install"
section for the regression fixture.
"""

from __future__ import annotations

from pathlib import Path

import pantheon.cli as cli_module


def test_agents_dir_prefers_installed_package_data(monkeypatch, tmp_path) -> None:
    # A fake "pantheon.agents" package-data resource, standing in for a real installed wheel's
    # pantheon/agents/ directory.
    installed_agents = tmp_path / "site-packages" / "pantheon" / "agents"
    installed_agents.mkdir(parents=True)
    (installed_agents / "artemis.md").write_text("installed artemis\n")

    class _FakeTraversable:
        def __init__(self, path: Path) -> None:
            self._path = path

        def __str__(self) -> str:
            return str(self._path)

        def is_dir(self) -> bool:
            return self._path.is_dir()

    def _fake_files(package: str):
        assert package == "pantheon.agents"
        return _FakeTraversable(installed_agents)

    monkeypatch.setattr(cli_module.importlib.resources, "files", _fake_files)

    result = cli_module._agents_dir()

    assert result == installed_agents
    assert (result / "artemis.md").read_text() == "installed artemis\n"


def test_agents_dir_falls_back_to_dev_checkout_layout_when_not_installed(monkeypatch) -> None:
    # The dev-checkout / PYTHONPATH shape this repo's own test suite runs under -- pantheon.agents
    # is not a real, importable package (no install at all), so importlib.resources.files() must
    # raise, and _agents_dir() must fall back to the sibling-directory Path computation, never
    # propagate the exception.
    def _raise_not_found(package: str):
        raise ModuleNotFoundError(f"No module named '{package}'")

    monkeypatch.setattr(cli_module.importlib.resources, "files", _raise_not_found)

    result = cli_module._agents_dir()

    assert result == Path(cli_module.__file__).resolve().parent.parent / "agents"


def test_agents_dir_falls_back_when_installed_resource_is_not_a_real_directory(monkeypatch, tmp_path) -> None:
    # Belt-and-braces: even if "pantheon.agents" DOES import successfully but its resolved
    # resource doesn't correspond to a real directory on disk (an edge case this function
    # doesn't assume can't happen), fall back rather than returning a bogus path.
    class _FakeTraversable:
        def __str__(self) -> str:
            return str(tmp_path / "does-not-exist")

        def is_dir(self) -> bool:
            return False

    monkeypatch.setattr(cli_module.importlib.resources, "files", lambda package: _FakeTraversable())

    result = cli_module._agents_dir()

    assert result == Path(cli_module.__file__).resolve().parent.parent / "agents"


def test_agents_dir_live_installed_or_dev_checkout_always_finds_all_five_personas() -> None:
    # Live (non-mocked): whichever branch this test environment actually resolves through (an
    # editable/real install with pantheon.agents importable, or this repo's own dev-checkout
    # PYTHONPATH shape), the result must be a real directory holding all five personas -- the
    # property that actually matters to a caller, independent of which branch got there.
    result = cli_module._agents_dir()
    assert result.is_dir()
    for persona in ("artemis", "apollo", "diogenes", "plato", "socrates"):
        assert (result / f"{persona}.md").is_file(), f"missing {persona}.md in resolved agents dir {result}"
