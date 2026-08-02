"""tests/test_providers.py — pytest unit layer for pantheon.providers' argv-construction seams
(docs/PYTHON-PORT.md section 4's port slice 4 deliverable).

pantheon.providers has NO dedicated black-box fixture suite (docs/PYTHON-PORT.md §9's disclosed
pre-existing gap — no test-providers.sh for the bash lanes either), so this file is the ONLY
coverage its argv-construction logic gets, not a duplication of anything else. Every test here
monkeypatches shutil.which and subprocess.run so it never actually shells out to a real
claude/codex/gemini/cursor-agent CLI — it asserts on the exact argv this module WOULD have
invoked, and on ProviderError's fail-closed behavior (CLI absent, nonzero exit, timeout).
"""

from __future__ import annotations

import subprocess

import pytest

from pantheon import providers


@pytest.fixture()
def prompt_file(tmp_path):
    path = tmp_path / "artemis.prompt.md"
    path.write_text("the assembled prompt text\n")
    return str(path)


def _fake_which_present(name: str) -> None:
    def _which(candidate: str) -> str | None:
        return f"/usr/bin/{candidate}" if candidate == name else None

    return _which


def test_claude_argv_shape(monkeypatch, prompt_file) -> None:
    captured: dict = {}

    monkeypatch.setattr(providers.shutil, "which", _fake_which_present("claude"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, stdout='{"ok":true}', stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    out = providers.provider_run("claude", "sonnet", prompt_file, "Read,Grep,Glob,Bash(/wrap *)")

    assert out == '{"ok":true}'
    argv = captured["argv"]
    assert argv[0] == "claude"
    assert "-p" in argv
    assert "the assembled prompt text\n" in argv
    assert "--allowedTools" in argv
    assert argv[argv.index("--allowedTools") + 1] == "Read,Grep,Glob,Bash(/wrap *)"
    assert "--permission-mode" in argv
    assert argv[argv.index("--permission-mode") + 1] == "dontAsk"
    assert "--model" in argv
    assert argv[argv.index("--model") + 1] == "sonnet"


def test_claude_omits_model_flag_when_empty(monkeypatch, prompt_file) -> None:
    captured: dict = {}
    monkeypatch.setattr(providers.shutil, "which", _fake_which_present("claude"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    providers.provider_run("claude", "", prompt_file, "")
    assert "--model" not in captured["argv"]


def test_claude_falls_back_to_default_allowed_tools_when_empty(monkeypatch, prompt_file) -> None:
    captured: dict = {}
    monkeypatch.setattr(providers.shutil, "which", _fake_which_present("claude"))

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
    monkeypatch.setattr(providers.shutil, "which", _fake_which_present("codex"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        captured["input"] = kwargs.get("input")
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    providers.provider_run("codex", "o3", prompt_file, "")
    assert captured["argv"] == ["codex", "exec", "--model", "o3", "-"]
    assert captured["input"] == "the assembled prompt text\n"


def test_gemini_argv_shape(monkeypatch, prompt_file) -> None:
    captured: dict = {}
    monkeypatch.setattr(providers.shutil, "which", _fake_which_present("gemini"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    providers.provider_run("gemini", "gemini-pro", prompt_file, "")
    assert captured["argv"][0] == "gemini"
    assert "-p" in captured["argv"]
    assert "-m" in captured["argv"]
    assert captured["argv"][captured["argv"].index("-m") + 1] == "gemini-pro"


def test_cursor_argv_shape(monkeypatch, prompt_file) -> None:
    captured: dict = {}
    monkeypatch.setattr(providers.shutil, "which", _fake_which_present("cursor-agent"))

    def fake_run(argv, **kwargs):
        captured["argv"] = argv
        return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    providers.provider_run("cursor", "grok", prompt_file, "")
    assert captured["argv"][0] == "cursor-agent"
    assert "--model" in captured["argv"]
    assert captured["argv"][captured["argv"].index("--model") + 1] == "grok"


def test_unknown_provider_raises_before_touching_the_filesystem(prompt_file) -> None:
    with pytest.raises(providers.ProviderError, match="unknown provider lane 'bogus'"):
        providers.provider_run("bogus", "", prompt_file, "")


def test_cli_not_on_path_raises_provider_error(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers.shutil, "which", lambda name: None)
    with pytest.raises(providers.ProviderError, match="'claude' CLI not found on PATH"):
        providers.provider_run("claude", "", prompt_file, "")


def test_nonzero_exit_raises_provider_error_with_output(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers.shutil, "which", _fake_which_present("claude"))

    def fake_run(argv, **kwargs):
        return subprocess.CompletedProcess(argv, 2, stdout="partial output before failure", stderr="")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    with pytest.raises(providers.ProviderError) as exc_info:
        providers.provider_run("claude", "", prompt_file, "")
    assert exc_info.value.output == "partial output before failure"


def test_timeout_raises_provider_error(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers.shutil, "which", _fake_which_present("claude"))

    def fake_run(argv, **kwargs):
        raise subprocess.TimeoutExpired(cmd=argv, timeout=1, output="partial")

    monkeypatch.setattr(providers.subprocess, "run", fake_run)

    with pytest.raises(providers.ProviderError, match="timed out"):
        providers.provider_run("claude", "", prompt_file, "", timeout=1)
