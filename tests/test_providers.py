"""tests/test_providers.py — pytest unit layer for pantheon.providers' argv-construction and
PATH-resolution seams (docs/PYTHON-PORT.md section 4's port slice 4 deliverable).

pantheon.providers has NO dedicated black-box fixture suite (docs/PYTHON-PORT.md §9's disclosed
pre-existing gap — no test-providers.sh for the bash lanes either), so this file is the ONLY
coverage its argv-construction and CLI-resolution logic gets, not a duplication of anything else.
Every test here monkeypatches `providers._resolve_cli` and/or `subprocess.run` so it never
actually shells out to a real claude/codex/gemini/cursor-agent CLI — it asserts on the exact argv
this module WOULD have invoked, on `ProviderError`'s fail-closed behavior (CLI absent, nonzero
exit, timeout), and on `_filtered_path`'s checkout-relative-PATH-entry filtering (the fix for a
finding from this repo's own self-hosted gate on this port's own PR: an earlier version resolved
provider CLIs via the ambient, unfiltered PATH).
"""

from __future__ import annotations

import os
import subprocess

import pytest

from pantheon import providers


@pytest.fixture()
def prompt_file(tmp_path):
    path = tmp_path / "artemis.prompt.md"
    path.write_text("the assembled prompt text\n")
    return str(path)


def _fake_resolve_present(name: str, resolved_path: str = "/usr/bin"):
    def _resolve(candidate: str) -> str | None:
        return f"{resolved_path}/{candidate}" if candidate == name else None

    return _resolve


def test_claude_argv_shape(monkeypatch, prompt_file) -> None:
    captured: dict = {}

    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        captured["kwargs"] = kwargs
        return subprocess.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    out = providers.provider_run("claude", "sonnet", prompt_file, "Read,Grep,Glob,Bash(/wrap *)")

    assert out == '{"ok":true}'
    argv = captured["argv"]
    assert argv[0] == "/usr/bin/claude"
    assert "-p" in argv
    assert "the assembled prompt text\n" in argv
    assert "--allowedTools" in argv
    assert argv[argv.index("--allowedTools") + 1] == "Read,Grep,Glob,Bash(/wrap *)"
    assert "--permission-mode" in argv
    assert argv[argv.index("--permission-mode") + 1] == "dontAsk"
    assert "--model" in argv
    assert argv[argv.index("--model") + 1] == "sonnet"
    # Every call must pass an EXPLICIT env — never an implicit ambient inherit (docs/PYTHON-PORT.md
    # §5's "constructed clean env, never inherited" rule).
    assert captured["kwargs"]["env"] is not None
    assert captured["kwargs"]["shell"] is False


def test_claude_omits_model_flag_when_empty(monkeypatch, prompt_file) -> None:
    captured: dict = {}
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    providers.provider_run("claude", "", prompt_file, "")
    assert "--model" not in captured["argv"]


def test_claude_falls_back_to_default_allowed_tools_when_empty(monkeypatch, prompt_file) -> None:
    captured: dict = {}
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    providers.provider_run("claude", "", prompt_file, "")
    tools = captured["argv"][captured["argv"].index("--allowedTools") + 1]
    assert tools == providers.default_allowed_tools()
    assert "pantheon.execution wrapper" in tools


def test_codex_pipes_prompt_via_stdin(monkeypatch, prompt_file) -> None:
    captured: dict = {}
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("codex"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        captured["input"] = kwargs.get("input")
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    providers.provider_run("codex", "o3", prompt_file, "")
    assert captured["argv"] == ["/usr/bin/codex", "exec", "--model", "o3", "-"]
    assert captured["input"] == "the assembled prompt text\n"


def test_gemini_argv_shape(monkeypatch, prompt_file) -> None:
    captured: dict = {}
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("gemini"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    providers.provider_run("gemini", "gemini-pro", prompt_file, "")
    assert captured["argv"][0] == "/usr/bin/gemini"
    assert "-p" in captured["argv"]
    assert "-m" in captured["argv"]
    assert captured["argv"][captured["argv"].index("-m") + 1] == "gemini-pro"


def test_cursor_argv_shape(monkeypatch, prompt_file) -> None:
    captured: dict = {}
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("cursor-agent"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    providers.provider_run("cursor", "grok", prompt_file, "")
    assert captured["argv"][0] == "/usr/bin/cursor-agent"
    assert "--model" in captured["argv"]
    assert captured["argv"][captured["argv"].index("--model") + 1] == "grok"


def test_unknown_provider_raises_before_touching_the_filesystem(prompt_file) -> None:
    with pytest.raises(providers.ProviderError, match="unknown provider lane 'bogus'"):
        providers.provider_run("bogus", "", prompt_file, "")


def test_cli_not_resolvable_raises_provider_error(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", lambda name: None)
    with pytest.raises(providers.ProviderError, match="'claude' CLI not found on PATH"):
        providers.provider_run("claude", "", prompt_file, "")


def test_nonzero_exit_raises_provider_error_with_output(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))

    def fake_run(argv, **kwargs):
        return subprocess.CompletedProcess(argv, 2, stdout="partial output before failure", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    with pytest.raises(providers.ProviderError) as exc_info:
        providers.provider_run("claude", "", prompt_file, "")
    assert exc_info.value.output == "partial output before failure"


def test_timeout_raises_provider_error(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))

    def fake_run(argv, **kwargs):
        raise subprocess.TimeoutExpired(cmd=argv, timeout=1, output="partial")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    with pytest.raises(providers.ProviderError, match="timed out"):
        providers.provider_run("claude", "", prompt_file, "", timeout=1)


# ---------------------------------------------------------------------------------------------
# _filtered_path() / _resolve_cli() — the PATH-hijack fix itself (a finding from this repo's own
# self-hosted gate on this port's own PR): a hostile PR checkout that widens PATH to include a
# repository-controlled directory must never have that directory's executable resolved, even
# though it may be a syntactically valid, absolute PATH entry.
# ---------------------------------------------------------------------------------------------


def test_filtered_path_drops_entries_inside_the_current_working_directory(monkeypatch, tmp_path) -> None:
    real_bin = tmp_path / "real" / "bin"
    real_bin.mkdir(parents=True)
    checkout_bin = tmp_path / "checkout" / "bin"
    checkout_bin.mkdir(parents=True)

    monkeypatch.chdir(tmp_path / "checkout")
    monkeypatch.setenv("PATH", f"{checkout_bin}{os.pathsep}{real_bin}")

    filtered = providers._filtered_path().split(os.pathsep)
    assert str(real_bin) in filtered
    assert str(checkout_bin) not in filtered


def test_filtered_path_drops_relative_entries(monkeypatch, tmp_path) -> None:
    real_bin = tmp_path / "real" / "bin"
    real_bin.mkdir(parents=True)
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    monkeypatch.chdir(checkout)
    monkeypatch.setenv("PATH", f"./bin{os.pathsep}{real_bin}")

    filtered = providers._filtered_path().split(os.pathsep)
    assert "./bin" not in filtered
    assert str(real_bin) in filtered


def test_resolve_cli_does_not_find_an_executable_planted_in_the_checkout(monkeypatch, tmp_path) -> None:
    checkout = tmp_path / "checkout"
    checkout_bin = checkout / "bin"
    checkout_bin.mkdir(parents=True)
    impostor = checkout_bin / "claude"
    impostor.write_text("#!/bin/sh\necho pwned\n")
    impostor.chmod(0o755)

    real_dir = tmp_path / "real"
    real_dir.mkdir()

    monkeypatch.chdir(checkout)
    monkeypatch.setenv("PATH", f"{checkout_bin}{os.pathsep}{real_dir}")

    # The impostor is a real, executable file that a bare `shutil.which("claude")` (ambient PATH)
    # WOULD have resolved to — proving this fixture is live, not vacuously passing.
    import shutil

    assert shutil.which("claude") == str(impostor)

    # _resolve_cli must never return it — no real "claude" exists in the trusted (non-checkout)
    # portion of PATH here, so resolution correctly fails closed to None instead of the impostor.
    assert providers._resolve_cli("claude") is None
