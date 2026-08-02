"""tests/test_providers.py — pytest unit layer for pantheon.providers' argv-construction,
PATH-resolution, environment-construction, and timeout/process-group seams
(docs/PYTHON-PORT.md section 4's port slice 4 deliverable).

pantheon.providers has NO dedicated black-box fixture suite (docs/PYTHON-PORT.md §9's disclosed
pre-existing gap — no test-providers.sh for the bash lanes either), so this file is the ONLY
coverage its argv-construction/CLI-resolution/env-construction logic gets, not a duplication of
anything else. Every test here monkeypatches `providers._resolve_cli` and/or
`providers.subprocess.Popen` so it never actually shells out to a real
claude/codex/gemini/cursor-agent CLI — it asserts on the exact argv/env/cwd this module WOULD
have invoked, on `ProviderError`'s fail-closed behavior (CLI absent, nonzero exit, timeout), on
`_filtered_path`'s repo-root-aware checkout-relative-PATH-entry filtering, on `_provider_env`'s
allowlist (never a blanket `os.environ` copy), and on `_terminate_group` firing on a timeout.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from pantheon import providers


@pytest.fixture()
def prompt_file(tmp_path):
    path = tmp_path / "artemis.prompt.md"
    path.write_text("the assembled prompt text\n")
    return str(path)


def _fake_resolve_present(name: str, resolved_path: str = "/usr/bin"):
    def _resolve(candidate: str, repo_root: str | None = None) -> str | None:
        return f"{resolved_path}/{candidate}" if candidate == name else None

    return _resolve


class _FakeProc:
    """A minimal stand-in for `subprocess.Popen` — captures the argv/kwargs it was constructed
    with, and lets a test script what `communicate()` does (return output, or raise
    `TimeoutExpired` once and then return leftover output on retry, mirroring the real
    post-kill `communicate()` call `_run()` makes). `_run()` runs Popen in BINARY mode (no
    `text=True` — see that function's own docstring for why), so `communicate()` must return
    bytes here too, matching the real contract this fake stands in for."""

    def __init__(
        self,
        argv,
        returncode: int = 0,
        stdout: str = "",
        raise_timeout_once: bool = False,
        leftover_after_timeout: str = "",
    ) -> None:
        self.argv = argv
        self.pid = 4242
        self.returncode = returncode
        self._stdout = stdout.encode("utf-8")
        self._raise_timeout_once = raise_timeout_once
        self._leftover_after_timeout = leftover_after_timeout.encode("utf-8")
        self.communicate_calls = 0

    def communicate(self, input=None, timeout=None):  # noqa: A002 - matches subprocess.Popen's own signature
        self.communicate_calls += 1
        if self._raise_timeout_once and self.communicate_calls == 1:
            raise subprocess.TimeoutExpired(cmd=self.argv, timeout=timeout)
        if self._raise_timeout_once:
            return self._leftover_after_timeout, None
        return self._stdout, None


def _install_fake_popen(monkeypatch, **fake_proc_kwargs):
    captured: dict = {}

    def fake_popen(argv, **kwargs):
        captured["argv"] = argv
        captured["kwargs"] = kwargs
        proc = _FakeProc(argv, **fake_proc_kwargs)
        captured["proc"] = proc
        return proc

    monkeypatch.setattr(providers.subprocess, "Popen", fake_popen)
    return captured


def test_claude_argv_shape(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch, stdout='{"ok":true}')

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
    # §5's "constructed clean env, never inherited" rule) — and start its own session/process
    # group (so a timeout can reach the whole group, not just this one PID).
    assert captured["kwargs"]["env"] is not None
    assert captured["kwargs"]["shell"] is False
    assert captured["kwargs"]["start_new_session"] is True


def test_claude_omits_model_flag_when_empty(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "")
    assert "--model" not in captured["argv"]


def test_claude_falls_back_to_default_allowed_tools_when_empty(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "")
    tools = captured["argv"][captured["argv"].index("--allowedTools") + 1]
    assert tools == providers.default_allowed_tools()
    assert providers._WRAPPER_SCRIPT_NAME in tools
    assert tools.endswith("wrapper *)")


def test_codex_pipes_prompt_via_stdin(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("codex"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("codex", "o3", prompt_file, "")
    assert captured["argv"] == ["/usr/bin/codex", "exec", "--model", "o3", "-"]
    # stdin is piped (not inherited) whenever input_text is given — Popen's own stdin= kwarg,
    # not an `input=` kwarg (that belongs to communicate(), not Popen's constructor).
    assert captured["kwargs"]["stdin"] == subprocess.PIPE


def test_gemini_argv_shape(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("gemini"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("gemini", "gemini-pro", prompt_file, "")
    assert captured["argv"][0] == "/usr/bin/gemini"
    assert "-p" in captured["argv"]
    assert "-m" in captured["argv"]
    assert captured["argv"][captured["argv"].index("-m") + 1] == "gemini-pro"


def test_cursor_argv_shape(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("cursor-agent"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("cursor", "grok", prompt_file, "")
    assert captured["argv"][0] == "/usr/bin/cursor-agent"
    assert "--model" in captured["argv"]
    assert captured["argv"][captured["argv"].index("--model") + 1] == "grok"


def test_unknown_provider_raises_before_touching_the_filesystem(prompt_file) -> None:
    with pytest.raises(providers.ProviderError, match="unknown provider lane 'bogus'"):
        providers.provider_run("bogus", "", prompt_file, "")


def test_cli_not_resolvable_raises_provider_error(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", lambda name, repo_root=None: None)
    with pytest.raises(providers.ProviderError, match="'claude' CLI not found on PATH"):
        providers.provider_run("claude", "", prompt_file, "")


def test_nonzero_exit_raises_provider_error_with_output(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    _install_fake_popen(monkeypatch, returncode=2, stdout="partial output before failure")

    with pytest.raises(providers.ProviderError) as exc_info:
        providers.provider_run("claude", "", prompt_file, "")
    assert exc_info.value.output == "partial output before failure"


# ---------------------------------------------------------------------------------------------
# Provider process cwd + repo_root threading (a Codex finding: neither provider_run() nor _run()
# supplied cwd, so a launched provider inherited whatever directory the gate process happened to
# be running from instead of the repo root — cli/review-gate's own cd "$REPO_ROOT" posture).
# ---------------------------------------------------------------------------------------------


def test_provider_run_passes_repo_root_as_cwd(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "", repo_root="/some/repo/root")
    assert captured["kwargs"]["cwd"] == "/some/repo/root"


def test_provider_run_cwd_is_none_when_repo_root_not_given(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "")
    assert captured["kwargs"]["cwd"] is None


# ---------------------------------------------------------------------------------------------
# Timeout -> _terminate_group() (a Codex finding: subprocess.run(..., timeout=...) only kills the
# direct child, leaving any tool subprocesses a provider spawned running past the timeout).
# ---------------------------------------------------------------------------------------------


def test_timeout_calls_terminate_group_and_raises_provider_error(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(
        monkeypatch, raise_timeout_once=True, leftover_after_timeout="partial before timeout"
    )

    terminate_calls: list = []
    monkeypatch.setattr(providers, "_terminate_group", lambda proc: terminate_calls.append(proc))

    with pytest.raises(providers.ProviderError, match="timed out") as exc_info:
        providers.provider_run("claude", "", prompt_file, "", timeout=1)

    assert len(terminate_calls) == 1
    assert terminate_calls[0] is captured["proc"]
    assert exc_info.value.output == "partial before timeout"


def test_terminate_group_sends_sigterm_then_sigkill_on_the_whole_group(monkeypatch) -> None:
    calls: list = []

    class _Proc:
        pid = 999

        def wait(self, timeout=None):
            calls.append(("wait", timeout))
            raise subprocess.TimeoutExpired(cmd=["x"], timeout=timeout)

    monkeypatch.setattr(providers.os, "getpgid", lambda pid: 999)
    monkeypatch.setattr(providers.os, "killpg", lambda pgid, sig: calls.append(("killpg", pgid, sig)))

    providers._terminate_group(_Proc())

    assert ("killpg", 999, providers.signal.SIGTERM) in calls
    assert ("killpg", 999, providers.signal.SIGKILL) in calls
    # SIGTERM must be sent before SIGKILL (graceful-then-forced, mirrors cli/review-gate's own
    # run_with_timeout fallback).
    term_index = calls.index(("killpg", 999, providers.signal.SIGTERM))
    kill_index = calls.index(("killpg", 999, providers.signal.SIGKILL))
    assert term_index < kill_index


def test_terminate_group_is_a_noop_when_the_process_already_exited(monkeypatch) -> None:
    def _raise_lookup_error(pid):
        raise ProcessLookupError()

    monkeypatch.setattr(providers.os, "getpgid", _raise_lookup_error)

    class _Proc:
        pid = 999

    # Must not raise — a process that already exited between the timeout and this call is not
    # an error (mirrors bash's own `2>/dev/null || true` posture for the identical race).
    providers._terminate_group(_Proc())


# ---------------------------------------------------------------------------------------------
# _provider_env() — the allowlist fix (a Codex finding: an earlier version began from a full
# dict(os.environ) copy, only overriding PATH — an execution-bearing variable like NODE_OPTIONS
# or PYTHONPATH would still reach a matching provider CLI's own runtime even with PATH filtered
# and shell=False).
# ---------------------------------------------------------------------------------------------


def test_provider_env_does_not_forward_execution_bearing_variables(monkeypatch) -> None:
    monkeypatch.setenv("NODE_OPTIONS", "--require=/repo/payload.js")
    monkeypatch.setenv("PYTHONPATH", "/repo/evil")
    monkeypatch.setenv("LD_PRELOAD", "/repo/evil.so")

    env = providers._provider_env()

    assert "NODE_OPTIONS" not in env
    assert "PYTHONPATH" not in env
    assert "LD_PRELOAD" not in env


def test_provider_env_forwards_only_the_explicit_allowlist(monkeypatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test-123")
    monkeypatch.setenv("SOME_RANDOM_VAR_NOT_ON_THE_ALLOWLIST", "should-not-appear")

    env = providers._provider_env()

    assert env["ANTHROPIC_API_KEY"] == "sk-test-123"
    assert "SOME_RANDOM_VAR_NOT_ON_THE_ALLOWLIST" not in env
    # Never a blanket copy — every key present must come from the explicit allowlist (plus PATH,
    # which _provider_env sets itself from _filtered_path).
    assert set(env) - {"PATH"} <= set(providers._PROVIDER_ENV_PASSTHROUGH_KEYS)


def test_provider_env_path_is_always_filtered_never_ambient(monkeypatch, tmp_path) -> None:
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    monkeypatch.chdir(checkout)
    monkeypatch.setenv("PATH", f"{checkout}{os.pathsep}/usr/bin")

    env = providers._provider_env()
    assert str(checkout) not in env["PATH"].split(os.pathsep)
    assert "/usr/bin" in env["PATH"].split(os.pathsep)


# ---------------------------------------------------------------------------------------------
# default_allowed_tools() / the console-script wrapper resolution -- the module-shadowing fix,
# round 3 (a Codex finding across two review waves). Round 1 (`-I` isolated mode on a
# `python -m pantheon.execution wrapper` invocation) closed the shadow but broke `pip install
# --user` (round 2's fresh evidence: `-I` also disables user-site-packages). Round 3 resolves
# the INSTALLED `pantheon-git-readonly` console script's own absolute path instead -- immune to
# the shadow by construction (its own generated launcher's sys.path[0] is its own install
# directory, never the caller's cwd), with no `-I`-style collateral restriction.
# ---------------------------------------------------------------------------------------------


def test_default_allowed_tools_resolves_the_installed_console_script(monkeypatch, tmp_path) -> None:
    fake_bin_dir = tmp_path / "bin"
    fake_bin_dir.mkdir()
    fake_script = fake_bin_dir / providers._WRAPPER_SCRIPT_NAME
    fake_script.write_text("#!/bin/sh\n")
    fake_script.chmod(0o755)
    monkeypatch.setattr(providers.sys, "executable", str(fake_bin_dir / "python3"))

    tools = providers.default_allowed_tools()
    assert str(fake_script) in tools
    assert tools.endswith(f"{fake_script} wrapper *)")
    # No `-I`/`-m`/`python` invocation shape at all when the console script resolves -- it's
    # invoked directly as its own executable.
    assert " -m " not in tools
    assert " -I " not in tools


def test_default_allowed_tools_falls_back_loudly_when_console_script_missing(monkeypatch, tmp_path, capsys) -> None:
    empty_bin_dir = tmp_path / "empty-bin"
    empty_bin_dir.mkdir()
    monkeypatch.setattr(providers.sys, "executable", str(empty_bin_dir / "python3"))

    tools = providers.default_allowed_tools()
    assert "pantheon.execution wrapper" in tools
    captured_stderr = capsys.readouterr().err
    assert providers._WRAPPER_SCRIPT_NAME in captured_stderr
    assert "not installed" in captured_stderr


def test_console_script_wrapper_is_not_shadowed_by_a_hostile_checkout(tmp_path) -> None:
    # Live (non-mocked) repro against the REAL installed console script (whatever venv this test
    # itself runs under): a hostile checkout with its own same-named pantheon/execution.py, run
    # from that checkout's own directory (mirrors _run()'s cwd=repo_root), must never have that
    # file imported -- proving the fix (a console script's own sys.path[0] is its own install
    # directory) closes the exact vector -I once did, without needing -I's own collateral damage.
    installed_script = Path(sys.executable).parent / providers._WRAPPER_SCRIPT_NAME
    if not installed_script.is_file():
        pytest.skip(f"{installed_script} is not installed in this test environment")

    hostile = tmp_path / "hostile-checkout"
    (hostile / "pantheon").mkdir(parents=True)
    (hostile / "pantheon" / "__init__.py").write_text("")
    (hostile / "pantheon" / "execution.py").write_text("print('IMPOSTOR-RAN')\n")

    result = subprocess.run(
        [str(installed_script), "wrapper", "status"],
        cwd=str(hostile),
        env={"PATH": os.environ.get("PATH", "")},
        capture_output=True,
        text=True,
    )
    assert "IMPOSTOR-RAN" not in result.stdout


# ---------------------------------------------------------------------------------------------
# _run()'s binary-mode decoding -- a Codex finding (third review wave): strict text-mode
# decoding raised an uncaught UnicodeDecodeError on non-UTF-8 provider output, escaping past both
# ProviderError and GateError.
# ---------------------------------------------------------------------------------------------


def test_run_decodes_invalid_utf8_defensively_instead_of_raising(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))

    class _InvalidUtf8Proc(_FakeProc):
        def communicate(self, input=None, timeout=None):  # noqa: A002
            return b"before-invalid \xff\xfe after-invalid\n", None

    def fake_popen(argv, **kwargs):
        return _InvalidUtf8Proc(argv)

    monkeypatch.setattr(providers.subprocess, "Popen", fake_popen)

    # Must not raise UnicodeDecodeError -- the whole point of this fixture.
    out = providers.provider_run("claude", "", prompt_file, "")
    assert "before-invalid" in out
    assert "after-invalid" in out


# ---------------------------------------------------------------------------------------------
# _filtered_path() / _resolve_cli() — the PATH-hijack fix itself (a finding from this repo's own
# self-hosted gate on this port's own PR, extended by a follow-up Codex finding): a hostile PR
# checkout that widens PATH to include a repository-controlled directory must never have that
# directory's executable resolved, even though it may be a syntactically valid, absolute PATH
# entry — and this must hold EVEN WHEN the gate is launched from a nested directory inside the
# repo (cwd != repo root).
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


def test_filtered_path_drops_repo_root_entries_when_launched_from_a_nested_directory(monkeypatch, tmp_path) -> None:
    # The exact gap a follow-up Codex finding caught: repo_root's own bin/ is NOT beneath
    # os.getcwd() when the gate is launched from a nested subdirectory (repo/src), so a
    # cwd-only filter (round 1's fix) let it straight through.
    repo_root = tmp_path / "repo"
    repo_bin = repo_root / "bin"
    repo_bin.mkdir(parents=True)
    nested_cwd = repo_root / "src"
    nested_cwd.mkdir()
    real_bin = tmp_path / "real" / "bin"
    real_bin.mkdir(parents=True)

    monkeypatch.chdir(nested_cwd)
    monkeypatch.setenv("PATH", f"{repo_bin}{os.pathsep}{real_bin}")

    # Without repo_root, the nested cwd's own filter doesn't catch repo_bin (not beneath cwd).
    cwd_only_filtered = providers._filtered_path().split(os.pathsep)
    assert str(repo_bin) in cwd_only_filtered

    # WITH repo_root passed through, repo_bin is correctly excluded.
    repo_root_filtered = providers._filtered_path(str(repo_root)).split(os.pathsep)
    assert str(repo_bin) not in repo_root_filtered
    assert str(real_bin) in repo_root_filtered


def test_resolve_cli_does_not_find_an_executable_planted_in_a_nested_repo_bin(monkeypatch, tmp_path) -> None:
    repo_root = tmp_path / "repo"
    repo_bin = repo_root / "bin"
    repo_bin.mkdir(parents=True)
    impostor = repo_bin / "claude"
    impostor.write_text("#!/bin/sh\necho pwned\n")
    impostor.chmod(0o755)

    nested_cwd = repo_root / "src"
    nested_cwd.mkdir()
    real_dir = tmp_path / "real"
    real_dir.mkdir()

    monkeypatch.chdir(nested_cwd)
    monkeypatch.setenv("PATH", f"{repo_bin}{os.pathsep}{real_dir}")

    # The impostor is a real, executable file that a bare `shutil.which("claude")` (ambient PATH)
    # WOULD have resolved to — proving this fixture is live, not vacuously passing.
    import shutil

    assert shutil.which("claude") == str(impostor)

    # _resolve_cli(name, repo_root) must never return it.
    assert providers._resolve_cli("claude", str(repo_root)) is None
