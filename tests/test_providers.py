"""tests/test_providers.py — pytest unit layer for pantheon.providers' argv-construction,
PATH-resolution, environment-construction, and timeout/process-group seams.

pantheon.providers has NO dedicated black-box fixture suite (a disclosed, pre-existing gap — the
retired bash lanes never had a test-providers.sh either), so this file is the ONLY
coverage its argv-construction/CLI-resolution/env-construction logic gets, not a duplication of
anything else. Every test here monkeypatches `providers._resolve_cli` and/or
`providers.subprocess.Popen` so it never actually shells out to a real
claude/codex/gemini/cursor-agent CLI — it asserts on the exact argv/env/cwd this module WOULD
have invoked, on `ProviderError`'s fail-closed behavior (CLI absent, nonzero exit, timeout), on
`_filtered_path`'s repo-root-aware checkout-relative-PATH-entry filtering, on `_provider_env`'s
allowlist (never a blanket `os.environ` copy), and on `_terminate_group` firing on a timeout.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

from pantheon import execution, jqjson, providers, verdict

REPO_ROOT = Path(__file__).resolve().parent.parent


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
    bytes here too, matching the real contract this fake stands in for.

    `stderr` (default "") is the SECOND element `communicate()` returns — real production code
    (`_run()`) only ever consults it when it passed `merge_stderr=False` (`_claude()`'s own
    call); every other lane's call site force-empties it regardless of what this fake returns
    here, matching a real `stderr=subprocess.STDOUT` Popen call (whose `communicate()` always
    returns `None` for the second element) closely enough for that path's own tests, which never
    inspect it."""

    def __init__(
        self,
        argv,
        returncode: int = 0,
        stdout: str = "",
        stderr: str = "",
        raise_timeout_once: bool = False,
        leftover_after_timeout: str = "",
        leftover_stderr_after_timeout: str = "",
    ) -> None:
        self.argv = argv
        self.pid = 4242
        self.returncode = returncode
        self._stdout = stdout.encode("utf-8")
        self._stderr = stderr.encode("utf-8")
        self._raise_timeout_once = raise_timeout_once
        self._leftover_after_timeout = leftover_after_timeout.encode("utf-8")
        self._leftover_stderr_after_timeout = leftover_stderr_after_timeout.encode("utf-8")
        self.communicate_calls = 0

    def communicate(self, input=None, timeout=None):  # noqa: A002 - matches subprocess.Popen's own signature
        self.communicate_calls += 1
        if self._raise_timeout_once and self.communicate_calls == 1:
            raise subprocess.TimeoutExpired(cmd=self.argv, timeout=timeout)
        if self._raise_timeout_once:
            return self._leftover_after_timeout, self._leftover_stderr_after_timeout
        return self._stdout, self._stderr


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
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
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


# ---------------------------------------------------------------------------------------------
# --bare is DROPPED entirely (issue #26 item 3 — see pantheon.providers._claude's own docstring
# for the full history: was conditional on an explicit credential for a time, removed once this
# lane also started passing --json-schema, because this repo's own committed history already
# shows that flag pair breaking structured_output on the sibling Action lane, and re-verifying
# compatibility on THIS lane's own invocation shape needed a credential unavailable in the
# environment the removal was authored in). These fixtures lock in "never present, regardless of
# credential" — the inverse of what this section used to assert.
# ---------------------------------------------------------------------------------------------


def test_claude_argv_never_includes_bare_with_explicit_api_key_present(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test-123")
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "")
    assert "--bare" not in captured["argv"]


def test_claude_argv_never_includes_bare_with_explicit_oauth_token_present(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.setenv("CLAUDE_CODE_OAUTH_TOKEN", "oauth-test-456")
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "")
    assert "--bare" not in captured["argv"]


def test_claude_argv_never_includes_bare_with_no_credential_present(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "")
    assert "--bare" not in captured["argv"]


def test_claude_cwd_stays_neutral_regardless_of_credential_presence(monkeypatch, prompt_file) -> None:
    # The neutral cwd (CRITICAL-1's own PRIMARY, unconditional control) never depended on --bare
    # in the first place, and --bare is gone entirely now -- proven here by checking the actual
    # Popen cwd kwarg regardless of whether a credential env var happens to be set.
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    captured = _install_fake_popen(monkeypatch)
    providers.provider_run("claude", "", prompt_file, "", repo_root="/some/repo/root", neutral_cwd="/some/scratch/dir")
    assert captured["kwargs"]["cwd"] == "/some/scratch/dir"
    assert captured["kwargs"]["cwd"] != "/some/repo/root"


# ---------------------------------------------------------------------------------------------
# CLAUDE_CONFIG_DIR reopening CRITICAL-1 through the provider's ENV (adversarial review, round 6,
# Codex P1) -- the containment property (pantheon.providers._safe_path_env_value) is independent
# of --bare and stays proven here regardless of credential presence, now that --bare itself is
# gone (issue #26 item 3).
# ---------------------------------------------------------------------------------------------


def test_claude_env_never_forwards_a_claude_config_dir_pointed_inside_the_repo_root(
    monkeypatch, prompt_file, tmp_path
) -> None:
    # An attacker sets CLAUDE_CONFIG_DIR (via ANY mechanism that can influence this process's
    # ambient env before it runs -- a repo-local .envrc, an environment-setting CI step reading
    # repo content) to a directory inside the checkout containing a marker MCP-server/hook
    # config. That marker directory's PATH must never reach the subprocess env at all -- if it
    # did, Claude Code's own normal startup would load it (config/MCP/hook auto-discovery happens
    # before --allowedTools's reach).
    repo_root = tmp_path / "checkout"
    repo_root.mkdir()
    marker_config_dir = repo_root / ".claude-hijacked"
    marker_config_dir.mkdir()
    (marker_config_dir / "settings.json").write_text('{"hooks": {"marker": "FIRED"}}')

    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test-123")
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(marker_config_dir))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run(
        "claude", "", prompt_file, "", repo_root=str(repo_root), neutral_cwd=str(tmp_path / "scratch")
    )

    assert "--bare" not in captured["argv"]
    env = captured["kwargs"]["env"]
    assert "CLAUDE_CONFIG_DIR" not in env, "the marker config directory's path must never reach the subprocess env"


def test_claude_env_still_forwards_a_legitimate_claude_config_dir(monkeypatch, prompt_file, tmp_path) -> None:
    # Regression guard -- "don't re-break what you just fixed": a real local multi-account
    # CLAUDE_CONFIG_DIR override that resolves OUTSIDE any trusted root must still reach the
    # subprocess env.
    repo_root = tmp_path / "checkout"
    repo_root.mkdir()
    legitimate_config_dir = tmp_path / "not-the-checkout" / ".claude-alt-account"
    legitimate_config_dir.mkdir(parents=True)

    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("CLAUDE_CODE_OAUTH_TOKEN", raising=False)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(legitimate_config_dir))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run(
        "claude", "", prompt_file, "", repo_root=str(repo_root), neutral_cwd=str(tmp_path / "scratch")
    )

    assert "--bare" not in captured["argv"]
    env = captured["kwargs"]["env"]
    assert env["CLAUDE_CONFIG_DIR"] == str(legitimate_config_dir)


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
    assert tools.endswith("wrapper *)")

    # `default_allowed_tools()` has TWO legitimate shapes and this test must hold for both, or a
    # bare `git clone && pytest` (no `pip install -e .` yet) fails on a correctly-behaving tree:
    #   - package installed  -> the hardened `pantheon-git-readonly` console script
    #   - not installed      -> a documented, loudly-warned fallback to `python -m
    #                           pantheon.execution wrapper`, which does NOT close the
    #                           checkout-directory-shadowing vector
    # Asserting only the installed form made a real environment difference look like a defect.
    # Branch instead of skipping: skipping would drop the routing assertion entirely in the
    # environment where the WEAKER path is the one in use, which is where it matters most.
    # Sibling guards (test_execution.py:376, and two more in this file) use pytest.skip because
    # those tests exercise the installed script itself and have nothing to assert without it.
    if execution.resolve_console_script(providers._WRAPPER_SCRIPT_NAME) is not None:
        assert providers._WRAPPER_SCRIPT_NAME in tools
    else:
        assert "-m pantheon.execution wrapper" in tools


# ---------------------------------------------------------------------------------------------
# --json-schema / --output-format json enforcement (issue #26 item 3) — the CLI lane used to
# invoke `claude -p ...` and merely hope the model's raw text ended with a trailing JSON object,
# relying entirely on pantheon.verdict's own extraction fallback. Confirmed live (this fix's own
# investigation): with --json-schema and --output-format json, stdout is one JSON envelope
# carrying a `structured_output` key. These fixtures prove both the new argv shape AND the
# envelope-to-plain-verdict-text unwrapping (_extract_structured_output).
# ---------------------------------------------------------------------------------------------


def test_claude_argv_includes_json_schema_and_output_format(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "")
    argv = captured["argv"]
    assert "--output-format" in argv
    assert argv[argv.index("--output-format") + 1] == "json"
    assert "--json-schema" in argv
    assert argv[argv.index("--json-schema") + 1] == providers.VERDICT_JSON_SCHEMA


def test_claude_unwraps_structured_output_from_the_envelope(monkeypatch, prompt_file) -> None:
    envelope = (
        '{"type":"result","subtype":"success","is_error":false,'
        '"result":"{\\"agent\\":\\"artemis\\"}",'
        '"structured_output":{"agent":"artemis","verdict":"SHIP","has_blocker":false,'
        '"findings":[],"summary":"looks fine"}}'
    )
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    _install_fake_popen(monkeypatch, stdout=envelope)

    out = providers.provider_run("claude", "", prompt_file, "")

    parsed = jqjson.loads(out)
    assert parsed == {
        "agent": "artemis",
        "verdict": "SHIP",
        "has_blocker": False,
        "findings": [],
        "summary": "looks fine",
    }


def test_claude_falls_back_to_envelope_text_when_structured_output_missing(monkeypatch, prompt_file) -> None:
    # Schema validation failed on the CLI's own side (e.g. is_error: true) -- no
    # `structured_output` key at all. Must fall back to the raw envelope text unchanged, not
    # raise -- pantheon.verdict.decide()'s own required-keys check then lands on UNVERIFIED
    # ("verdict JSON missing required keys"), the same fail-closed posture every other malformed
    # provider output already gets.
    envelope = (
        '{"type":"result","is_error":true,'
        '"result":"--json-schema was provided but Claude did not return structured_output."}'
    )
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    _install_fake_popen(monkeypatch, stdout=envelope)

    out = providers.provider_run("claude", "", prompt_file, "")
    assert out == envelope


def test_claude_falls_back_to_raw_text_when_envelope_itself_is_not_json(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    _install_fake_popen(monkeypatch, stdout="not json at all")

    out = providers.provider_run("claude", "", prompt_file, "")
    assert out == "not json at all"


def test_extract_structured_output_unit() -> None:
    assert providers._extract_structured_output('{"structured_output":{"a":1}}') == jqjson.dumps({"a": 1})
    assert providers._extract_structured_output('{"no_such_key":true}') == '{"no_such_key":true}'
    assert providers._extract_structured_output("not json") == "not json"
    assert providers._extract_structured_output("[1,2,3]") == "[1,2,3]"


def test_extract_structured_output_isolates_the_envelope_from_leading_noise() -> None:
    # A leading warning/diagnostic line (from a MERGED stream, or a stray banner some CLI
    # version might print to stdout) must not defeat the extraction -- verdict.extract_last_json
    # is a rightmost-parseable-JSON-suffix scan, so leading noise is naturally skipped.
    noisy = 'npm warn deprecated something\n{"structured_output":{"agent":"artemis","verdict":"SHIP"}}'
    out = providers._extract_structured_output(noisy)
    assert jqjson.loads(out) == {"agent": "artemis", "verdict": "SHIP"}


# ---------------------------------------------------------------------------------------------
# Streams captured SEPARATELY on the claude lane (_run's own merge_stderr=False) — a live Codex
# review finding (P2) on this PR: a stderr diagnostic landing AFTER the JSON envelope on a
# MERGED stream defeats verdict.extract_last_json's own trailing scan (which requires nothing
# after the JSON object's own closing brace), discarding a valid verdict. Fixed by never merging
# this lane's streams at all -- these fixtures prove both the wiring (the real Popen kwarg) and
# the end-to-end behavior (a real trailing-stderr-noise scenario, verdict still parses).
# ---------------------------------------------------------------------------------------------


def test_claude_popen_uses_separate_stderr_pipe_not_merged(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "")

    assert captured["kwargs"]["stderr"] is subprocess.PIPE
    assert captured["kwargs"]["stderr"] is not subprocess.STDOUT


def test_other_lanes_still_merge_stdout_and_stderr(monkeypatch, prompt_file) -> None:
    # Regression-direction guard: merge_stderr=False is a claude-lane-ONLY opt-in -- every other
    # lane keeps the ORIGINAL merged-stream contract (bash-parity, this module's own default).
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("codex"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("codex", "", prompt_file, "")

    assert captured["kwargs"]["stderr"] is subprocess.STDOUT


def test_claude_verdict_survives_a_trailing_stderr_warning_after_the_json_envelope(monkeypatch, prompt_file) -> None:
    # THE exact scenario the Codex finding named: a successful invocation whose stderr emits a
    # warning AFTER the valid JSON envelope was already written to stdout. With streams captured
    # separately, that stderr content never reaches `envelope_text` at all -- the verdict must
    # still parse and decide, not silently degrade to UNVERIFIED.
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    envelope = jqjson.dumps(
        {
            "type": "result",
            "is_error": False,
            "structured_output": {
                "agent": "artemis",
                "verdict": "SHIP",
                "has_blocker": False,
                "findings": [],
                "summary": "clean",
            },
        }
    )
    _install_fake_popen(monkeypatch, stdout=envelope, stderr="warning: some harmless deprecation notice\n")

    out = providers.provider_run("claude", "", prompt_file, "")

    parsed = jqjson.loads(out)
    assert parsed["agent"] == "artemis"
    assert parsed["verdict"] == "SHIP"

    decision = verdict.decide("artemis", out)
    assert decision["color"] == "green"
    assert decision["reason"] == ""


def test_codex_pipes_prompt_via_stdin(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("codex"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("codex", "o3", prompt_file, "")
    assert captured["argv"] == ["/usr/bin/codex", "exec", "--skip-git-repo-check", "--model", "o3", "-"]
    # stdin is piped (not inherited) whenever input_text is given — Popen's own stdin= kwarg,
    # not an `input=` kwarg (that belongs to communicate(), not Popen's constructor).
    assert captured["kwargs"]["stdin"] == subprocess.PIPE


def test_codex_argv_always_includes_skip_git_repo_check(monkeypatch, prompt_file) -> None:
    # A live Codex-review finding (P1) on this PR's own security round: `codex exec` refuses to
    # run at all outside a git repository unless this flag is passed — and this lane now ALWAYS
    # launches from a neutral, deliberately-not-a-git-repo scratch cwd (CRITICAL-1's own fix), so
    # omitting this flag would silently turn every codex-configured gate run into UNVERIFIED.
    # Checked with no model given too, to prove the flag isn't accidentally coupled to --model.
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("codex"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("codex", "", prompt_file, "")
    assert "--skip-git-repo-check" in captured["argv"]
    assert captured["argv"].index("--skip-git-repo-check") == captured["argv"].index("exec") + 1


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
# Provider process cwd + repo_root/neutral_cwd threading. A Codex finding originally added
# cwd=repo_root here (neither provider_run() nor _run() supplied any cwd, so a launched provider
# inherited whatever directory the gate process happened to be running from instead of the repo
# root — cli/review-gate's own cd "$REPO_ROOT" posture). A CRITICAL fix from a LATER adversarial
# review reversed that specific choice: cwd=repo_root let a provider's own startup-time
# config/MCP/hooks auto-discovery reach the PR's own checkout entirely outside --allowedTools's
# reach (a fake-claude-binary PoC confirmed it would auto-load a PR-committed .mcp.json and fire a
# PR-committed hook on an ALLOWED Read call) — see this module's own docstring for the full
# finding. cwd is now neutral_cwd (a scratch directory pantheon.cli creates and owns); repo_root
# is still threaded through, but only for PATH-filtering (_filtered_path) and readonly-wrapper
# resolution, never as the launched process's own working directory.
# ---------------------------------------------------------------------------------------------


def test_provider_run_uses_neutral_cwd_never_repo_root_as_the_launched_process_cwd(monkeypatch, prompt_file) -> None:
    # The CRITICAL-1 fix, live-proved: even when repo_root IS given (as pantheon.cli always
    # gives it, for PATH-filtering/wrapper resolution), the launched process's own cwd must be
    # neutral_cwd, never repo_root — repo_root must never leak into the Popen cwd kwarg again.
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "", repo_root="/some/repo/root", neutral_cwd="/some/scratch/dir")
    assert captured["kwargs"]["cwd"] == "/some/scratch/dir"
    assert captured["kwargs"]["cwd"] != "/some/repo/root"


def test_provider_run_cwd_is_none_when_neither_repo_root_nor_neutral_cwd_given(monkeypatch, prompt_file) -> None:
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "")
    assert captured["kwargs"]["cwd"] is None


def test_provider_run_cwd_is_none_when_only_repo_root_given_no_neutral_cwd(monkeypatch, prompt_file) -> None:
    # Regression guard for the OLD (pre-CRITICAL-1) behavior: repo_root alone, with no
    # neutral_cwd, must NOT fall back to using repo_root as cwd — that would silently reopen the
    # exact vulnerability this fix closes for any caller that forgot to pass neutral_cwd.
    monkeypatch.setattr(providers, "_resolve_cli", _fake_resolve_present("claude"))
    captured = _install_fake_popen(monkeypatch)

    providers.provider_run("claude", "", prompt_file, "", repo_root="/some/repo/root")
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

    monkeypatch.setattr(providers.os, "killpg", lambda pgid, sig: calls.append(("killpg", pgid, sig)))

    providers._terminate_group(_Proc())

    assert ("killpg", 999, providers.signal.SIGTERM) in calls
    assert ("killpg", 999, providers.signal.SIGKILL) in calls
    # SIGTERM must be sent before SIGKILL (graceful-then-forced, mirrors cli/review-gate's own
    # run_with_timeout fallback).
    term_index = calls.index(("killpg", 999, providers.signal.SIGTERM))
    kill_index = calls.index(("killpg", 999, providers.signal.SIGKILL))
    assert term_index < kill_index


def test_terminate_group_sends_sigkill_even_when_the_leader_exits_promptly(monkeypatch) -> None:
    # The exact gap a Codex review finding caught, live-reproduced (see
    # test_terminate_group_kills_a_child_that_survives_the_leaders_prompt_exit below for the
    # real-subprocess version): the LEADER can exit within the grace period (proc.wait()
    # returns normally, no TimeoutExpired) while one of its own spawned children ignores or
    # delays SIGTERM and is still alive. An earlier version of _terminate_group only sent
    # SIGKILL from inside the `except TimeoutExpired` branch, so a leader that exited "on time"
    # skipped the SIGKILL step entirely, leaving that descendant running. SIGKILL must fire
    # UNCONDITIONALLY after the grace period, not only when the leader itself timed out.
    calls: list = []

    class _Proc:
        pid = 999

        def wait(self, timeout=None):
            calls.append(("wait", timeout))
            return 0  # the leader exits promptly -- NOT a TimeoutExpired

    monkeypatch.setattr(providers.os, "killpg", lambda pgid, sig: calls.append(("killpg", pgid, sig)))

    providers._terminate_group(_Proc())

    assert ("killpg", 999, providers.signal.SIGTERM) in calls
    assert ("killpg", 999, providers.signal.SIGKILL) in calls


def test_terminate_group_kills_a_child_that_survives_the_leaders_prompt_exit(tmp_path) -> None:
    # Live (non-mocked) repro of the exact scenario the finding named: a fake provider whose
    # LEADER exits promptly on SIGTERM (the default disposition, untrapped) while its own
    # spawned CHILD explicitly ignores SIGTERM (`trap '' TERM`) and keeps sleeping. Proves the
    # child does NOT survive -- SIGKILL (unblockable, unlike SIGTERM) reaches it via the
    # unconditional killpg() this fix added.
    marker = tmp_path / "child-survived-sigterm"
    script = tmp_path / "fake-provider.sh"
    script.write_text(f"#!/bin/sh\n( trap '' TERM; sleep 4; touch {marker} ) &\nCHILD_PID=$!\nwait \"$CHILD_PID\"\n")
    script.chmod(0o755)

    proc = subprocess.Popen(
        [str(script)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        proc.communicate(timeout=1)
        raise AssertionError("expected TimeoutExpired -- the fixture script runs longer than 1s")
    except subprocess.TimeoutExpired:
        providers._terminate_group(proc)

    assert not marker.exists(), "child that ignored SIGTERM survived past _terminate_group()"


def test_terminate_group_is_a_noop_when_the_whole_group_already_exited(monkeypatch) -> None:
    # The whole process GROUP being fully gone by the time we signal it (every member already
    # exited) surfaces as killpg raising ProcessLookupError -- must not propagate, and (unlike
    # the stale pre-fix shape this test used to assert) must still ATTEMPT both signals rather
    # than bailing out early on a lookup failure.
    signals_attempted: list = []

    def _raise_lookup_error(pgid, sig):
        signals_attempted.append(sig)
        raise ProcessLookupError()

    monkeypatch.setattr(providers.os, "killpg", _raise_lookup_error)

    class _Proc:
        pid = 999

        def wait(self, timeout=None):
            raise subprocess.TimeoutExpired(cmd=["x"], timeout=timeout)

    # Must not raise — mirrors bash's own `2>/dev/null || true` posture for the identical race.
    providers._terminate_group(_Proc())

    assert signals_attempted == [providers.signal.SIGTERM, providers.signal.SIGKILL]


def test_terminate_group_kills_a_descendant_that_outlives_its_fully_reaped_leader(tmp_path) -> None:
    # Live (non-mocked) repro of THIS finding's exact precondition: the leader exits almost
    # immediately and is fully reaped by proc.wait() -- not merely a zombie -- while a background
    # descendant it spawned keeps running well past that. Proves os.getpgid(proc.pid) raises
    # ProcessLookupError at this point (the exact failure mode the finding named), yet
    # _terminate_group -- which never calls os.getpgid, using proc.pid directly as the process
    # group ID fixed at spawn time by start_new_session=True -- still reaches and kills the
    # surviving descendant.
    marker = tmp_path / "descendant-survived-reaped-leader"
    script = tmp_path / "fast-exit-leader.sh"
    script.write_text(f"#!/bin/sh\n( sleep 5; touch {marker} ) &\nexit 0\n")
    script.chmod(0o755)

    proc = subprocess.Popen(
        [str(script)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    proc.wait(timeout=2)  # the leader exits almost immediately and is fully reaped right here

    with pytest.raises(ProcessLookupError):
        os.getpgid(proc.pid)  # precondition: the exact lookup failure the finding named

    providers._terminate_group(proc)

    assert not marker.exists(), "descendant that outlived its (fully reaped) leader survived _terminate_group()"


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
    # PYTHONPATH is present but FORCE-CLEARED (never the injected payload) -- part of the
    # Python-family defensive clear, not a bare "never forwarded" allowlist omission (see
    # _PROVIDER_PYTHON_ENV_DEFENSIVE_CLEAR's own comment).
    assert env["PYTHONPATH"] == ""
    assert "LD_PRELOAD" not in env


def test_provider_env_forwards_only_the_explicit_allowlist(monkeypatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test-123")
    monkeypatch.setenv("SOME_RANDOM_VAR_NOT_ON_THE_ALLOWLIST", "should-not-appear")

    env = providers._provider_env()

    assert env["ANTHROPIC_API_KEY"] == "sk-test-123"
    assert "SOME_RANDOM_VAR_NOT_ON_THE_ALLOWLIST" not in env
    # Never a blanket copy — every key present must come from the explicit allowlist, PATH (set
    # by _provider_env itself from _filtered_path), or the Python-family defensive-clear keys.
    allowed = (
        set(providers._PROVIDER_ENV_PASSTHROUGH_KEYS) | {"PATH"} | set(providers._PROVIDER_PYTHON_ENV_DEFENSIVE_CLEAR)
    )
    assert set(env) <= allowed


def test_provider_env_force_clears_the_python_family_defensively(monkeypatch) -> None:
    # A Codex review finding on this port's own PR, companion to
    # pantheon.execution.resolve_console_script's own fix: PYTHONUSERBASE (among this whole
    # family) is exactly the env var that let a hostile launcher redirect console-script
    # resolution at a checked-out PR's own tree. Proves every one of these is force-cleared to a
    # safe value regardless of what the ambient environment set them to.
    monkeypatch.setenv("PYTHONUSERBASE", "/hostile/checkout")
    monkeypatch.setenv("PYTHONHOME", "/hostile/checkout")
    monkeypatch.setenv("PYTHONSTARTUP", "/hostile/checkout/payload.py")

    env = providers._provider_env()

    assert env["PYTHONUSERBASE"] == ""
    assert env["PYTHONHOME"] == ""
    assert env["PYTHONSTARTUP"] == ""
    assert env["PYTHONNOUSERSITE"] == "1"


def test_provider_env_forwards_proxy_vars_both_cases(monkeypatch) -> None:
    # A Codex review finding on this port's own PR: dropping proxy vars from THIS allowlist
    # (pantheon.cli's own git/gh env already carried the identical fix) let metadata/fetch
    # succeed behind a corporate proxy while every provider's own network call still failed,
    # reading UNVERIFIED for no visible reason.
    monkeypatch.setenv("HTTP_PROXY", "http://proxy.example:8080")
    monkeypatch.setenv("https_proxy", "https://proxy.example:8443")

    env = providers._provider_env()

    assert env["HTTP_PROXY"] == "http://proxy.example:8080"
    assert env["https_proxy"] == "https://proxy.example:8443"


def test_provider_env_path_is_always_filtered_never_ambient(monkeypatch, tmp_path) -> None:
    checkout = tmp_path / "checkout"
    checkout.mkdir()
    monkeypatch.chdir(checkout)
    monkeypatch.setenv("PATH", f"{checkout}{os.pathsep}/usr/bin")

    env = providers._provider_env()
    assert str(checkout) not in env["PATH"].split(os.pathsep)
    assert "/usr/bin" in env["PATH"].split(os.pathsep)


# ---------------------------------------------------------------------------------------------
# _provider_env() -- round 6, Codex P1: CRITICAL-1 reopened through the provider's ENV (not its
# cwd, already closed). HOME is never read from ambient env; CLAUDE_CONFIG_DIR and every other
# PATH-SHAPED key in _PATH_SHAPED_ENV_KEYS is dropped when it resolves inside a trusted root
# (cwd or repo_root), forwarded unchanged otherwise.
# ---------------------------------------------------------------------------------------------


def test_provider_env_home_is_never_read_from_ambient_env(monkeypatch, tmp_path) -> None:
    hijacked_home = tmp_path / "hostile-checkout-home"
    hijacked_home.mkdir()
    monkeypatch.setenv("HOME", str(hijacked_home))

    env = providers._provider_env()

    assert env.get("HOME") != str(hijacked_home)
    # Whatever HOME IS, it must be the real passwd-database resolution -- the same source
    # pantheon.execution.real_home_dir() (and pantheon.execution's own git-wrapper env) already
    # uses, never the ambient value this test just hijacked.
    real_home = execution.real_home_dir()
    if real_home:
        assert env["HOME"] == real_home
    else:
        assert "HOME" not in env


def test_provider_env_drops_claude_config_dir_pointed_inside_the_repo_root(monkeypatch, tmp_path) -> None:
    repo_root = tmp_path / "checkout"
    repo_root.mkdir()
    hostile_config_dir = repo_root / ".claude-hijack"
    hostile_config_dir.mkdir()
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(hostile_config_dir))

    env = providers._provider_env(repo_root=str(repo_root))

    assert "CLAUDE_CONFIG_DIR" not in env


def test_provider_env_drops_claude_config_dir_pointed_at_the_cwd(monkeypatch, tmp_path) -> None:
    cwd = tmp_path / "cwd"
    cwd.mkdir()
    monkeypatch.chdir(cwd)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(cwd))

    env = providers._provider_env()

    assert "CLAUDE_CONFIG_DIR" not in env


def test_provider_env_forwards_claude_config_dir_when_it_resolves_outside_every_trusted_root(
    monkeypatch, tmp_path
) -> None:
    repo_root = tmp_path / "checkout"
    repo_root.mkdir()
    legitimate_config_dir = tmp_path / "not-the-checkout" / ".claude-alt-account"
    legitimate_config_dir.mkdir(parents=True)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(legitimate_config_dir))

    env = providers._provider_env(repo_root=str(repo_root))

    assert env["CLAUDE_CONFIG_DIR"] == str(legitimate_config_dir)


def test_provider_env_drops_every_path_shaped_key_pointed_inside_the_repo_root(monkeypatch, tmp_path) -> None:
    repo_root = tmp_path / "checkout"
    repo_root.mkdir()
    for key in sorted(providers._PATH_SHAPED_ENV_KEYS):
        hostile_dir = repo_root / f"hijack-{key.lower()}"
        hostile_dir.mkdir()
        monkeypatch.setenv(key, str(hostile_dir))

    env = providers._provider_env(repo_root=str(repo_root))

    for key in providers._PATH_SHAPED_ENV_KEYS:
        assert key not in env, f"{key} should have been dropped (resolves inside repo_root)"


def test_provider_env_symlink_resolved_path_shaped_value_still_caught(monkeypatch, tmp_path) -> None:
    # The containment check is realpath-based (follows symlinks), not a raw string-prefix
    # comparison -- a value that only LOOKS like it's outside the checkout, but symlinks back
    # inside it, must still be caught.
    repo_root = tmp_path / "checkout"
    repo_root.mkdir()
    real_hostile_dir = repo_root / "real-hostile-config"
    real_hostile_dir.mkdir()
    outside_symlink = tmp_path / "looks-legitimate"
    outside_symlink.symlink_to(real_hostile_dir)
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(outside_symlink))

    env = providers._provider_env(repo_root=str(repo_root))

    assert "CLAUDE_CONFIG_DIR" not in env


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


# ---------------------------------------------------------------------------------------------
# Readonly-tier end-to-end proof (issue #26 item 2) — "a fixture that proves the FEATURE works,
# not just that attacks are refused: a readonly-tier run that produces a parseable verdict end
# to end. This is the test whose absence caused the whole problem." Before this fix, this repo's
# own CI never dogfooded the shipped default: the self-check job runs `execution: trusted` (no
# wrapper at all), and every other fixture in this file/tests/test-git-readonly-wrapper.sh proves
# either "the wrapper refuses hostile input" or "argv construction looks right" — never that the
# WHOLE chain (prompt -> provider -> a real Bash-tool-shaped wrapper call against a real repo ->
# a schema-shaped verdict -> pantheon.verdict.decide()) produces a real, non-UNVERIFIED decision.
#
# Fixture-level, not a live Anthropic model call (this repo's own posture: no metered API key,
# `claude` here is a stand-in the same way every other test in this file replaces the real CLI
# with `_resolve_cli`/`Popen` fakes) — but everything AROUND that one stand-in is genuinely real:
# a real two-commit git repo, the REAL installed `pantheon-git-readonly` console script (skips if
# not installed), a real `execution.build_readonly_argv`/`run_readonly_wrapper` subprocess call
# reading real `git diff --stat` output (deliverable 1's own safe-flag allowlist), the real
# `pantheon.cli._build_prompt` (deliverable 7's cwd fix), and the real
# `pantheon.verdict.decide()` decision function (deliverable 4's schema-envelope unwrapping).
# ---------------------------------------------------------------------------------------------


def test_readonly_tier_end_to_end_produces_a_parseable_verdict(tmp_path, monkeypatch) -> None:
    import json
    import subprocess

    from pantheon import cli as cli_module
    from pantheon import verdict

    wrapper_script = execution.resolve_console_script("pantheon-git-readonly")
    if wrapper_script is None:
        pytest.skip("pantheon-git-readonly console script is not installed in this test environment")

    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "test"], cwd=repo, check=True)
    (repo / "f.txt").write_text("one\ntwo\nthree\n")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "first"], cwd=repo, check=True)
    (repo / "f.txt").write_text("one\ntwo\nthree\nfour\nfive\n")
    subprocess.run(["git", "commit", "-q", "-am", "second"], cwd=repo, check=True)
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=True
    ).stdout.strip()
    parent = subprocess.run(
        ["git", "rev-parse", "HEAD~1"], cwd=repo, capture_output=True, text=True, check=True
    ).stdout.strip()
    diff_range = f"{parent}...{head}"

    neutral_cwd = tmp_path / "neutral-scratch"
    neutral_cwd.mkdir()
    workdir = tmp_path / "workdir"
    workdir.mkdir()

    ctx = cli_module.GateContext(
        repo_root=str(repo),
        pr_number="1",
        pr_title="test pr",
        diff_range=diff_range,
        base_ref="main",
        base_sha=parent,
        execution_tier="readonly",
        rules_file="",
        spec_file="",
    )
    prompt_file = cli_module._build_prompt(ctx, "artemis", str(workdir), str(neutral_cwd))
    prompt_text = Path(prompt_file).read_text(encoding="utf-8")

    # Deliverable 7's own fix, proved here as a side effect of this same end-to-end chain: the
    # prompt states the REAL cwd (the neutral scratch dir), never the false "you are in the
    # repo's working tree" claim that (per issue #26's own report) likely compounded the
    # wrapper's flag refusals.
    assert str(neutral_cwd) in prompt_text
    assert "NOT the target repo's working tree" in prompt_text

    # A fake "claude" standing in for the model: parses the SAME Run-context lines a real agent
    # reads, then ACTUALLY invokes the real readonly wrapper -- exactly the Bash-tool call a real
    # agent makes under `Bash(<wrapper> wrapper --repo-root <root> *)` -- with a safe flag from
    # deliverable 1's own allowlist (`--stat`), before emitting a --json-schema-shaped envelope
    # (deliverable 4).
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    fake_claude = fake_bin / "claude"
    fake_claude.write_text(
        "#!/usr/bin/env python3\n"
        "import json, re, subprocess, sys\n"
        "argv = sys.argv[1:]\n"
        "prompt = argv[argv.index('-p') + 1]\n"
        "repo_root = re.search(r'Repo root \\(absolute path[^)]*\\): (\\S+)', prompt).group(1)\n"
        "diff_range = re.search(r'Diff range \\(read-only git refs, already fetched\\): (\\S+)', prompt).group(1)\n"
        f"wrapper = {wrapper_script!r}\n"
        "result = subprocess.run(\n"
        "    [wrapper, 'wrapper', '--repo-root', repo_root, 'diff', '--stat', diff_range],\n"
        "    capture_output=True, text=True,\n"
        ")\n"
        "assert result.returncode == 0, ('wrapper failed: ' + result.stdout + result.stderr)\n"
        "stat_output = result.stdout.strip()\n"
        "assert 'f.txt' in stat_output, ('no f.txt in wrapper --stat output: ' + stat_output)\n"
        "f_txt_line = [line for line in stat_output.splitlines() if 'f.txt' in line][0]\n"
        "verdict_obj = {\n"
        "    'agent': 'artemis',\n"
        "    'verdict': 'FIX_FIRST',\n"
        "    'has_blocker': False,\n"
        "    'findings': [{\n"
        "        'severity': 'should_fix',\n"
        "        'file': 'f.txt',\n"
        "        'line': 4,\n"
        "        'issue': 'grew via the readonly wrapper --stat flag',\n"
        "        'scenario': 'issue #26 end-to-end proof',\n"
        "    }],\n"
        "    'summary': 'readonly wrapper --stat output: ' + f_txt_line,\n"
        "}\n"
        "envelope = {\n"
        "    'type': 'result', 'is_error': False,\n"
        "    'result': json.dumps(verdict_obj),\n"
        "    'structured_output': verdict_obj,\n"
        "}\n"
        "print(json.dumps(envelope))\n"
    )
    fake_claude.chmod(0o755)

    monkeypatch.setattr(
        providers,
        "_resolve_cli",
        lambda name, repo_root=None: str(fake_claude) if name == "claude" else None,
    )

    wrapper_invocation = f"{wrapper_script} wrapper --repo-root {repo}"
    allowed_tools = execution.allowed_tools_for("readonly", wrapper_invocation)

    raw_output = providers.provider_run(
        "claude",
        "",
        prompt_file,
        allowed_tools,
        timeout=30,
        repo_root=str(repo),
        neutral_cwd=str(neutral_cwd),
    )

    # provider_run's own return value is already the unwrapped, schema-validated verdict text
    # (deliverable 4's _extract_structured_output) -- parseable on its own, not just buried
    # inside a provider envelope.
    parsed_raw = json.loads(raw_output)
    assert parsed_raw["agent"] == "artemis"

    decision = verdict.decide("artemis", raw_output)

    # THE proof: a readonly-tier run produces a real, PARSEABLE, non-UNVERIFIED verdict -- not
    # the 3x UNVERIFIED issue #26 reported live.
    assert decision["color"] == "yellow", decision
    assert decision["verdict"] == "FIX_FIRST"
    assert decision["invariant_fired"] is False
    assert decision["reason"] == ""
    # The verdict content reflects REAL data that flowed through the readonly wrapper's own
    # --stat flag against the real repo (not a canned string unrelated to the actual diff).
    assert "f.txt" in decision["verdict_json"]["summary"]


def test_verdict_json_schema_stays_byte_identical_across_ALL_THREE_surfaces() -> None:
    """VERDICT_JSON_SCHEMA promises byte-identity with every surface that enforces a schema.
    Nothing enforced it until this test (a live self-hosted-gate finding, artemis @ PR #28).

    THREE copies, not two -- and the third is why this test enumerates its own targets instead of
    grepping for a variable name. `action.yml` assigns `JSON_SCHEMA='...'`, but `action/review.yml`
    embeds the schema INLINE as `--json-schema '...'` with no variable at all. A search for the
    NAME finds two copies and reports the third absent; only a search for the CONTENT finds all
    three. That is exactly how the third copy drifted a full revision behind (Codex, PR #28) after
    the first two were fixed together.

    Compares raw TEXT, not parsed-and-re-serialized JSON: the claim is byte-identity, and a parsed
    comparison would pass while the surfaces disagreed on key order -- the drift a reader diffing
    them by eye is being promised is absent.
    """
    surfaces = {
        "action.yml": r"JSON_SCHEMA='([^']*)'",
        "action/review.yml": r"--json-schema '(\{[^']*\})'",
    }

    for relpath, pattern in surfaces.items():
        text = (REPO_ROOT / relpath).read_text(encoding="utf-8")
        matches = re.findall(pattern, text)
        # Fail loudly if the extraction anchor drifts, rather than vacuously passing on zero found.
        assert len(matches) == 1, (
            f"expected exactly one schema occurrence in {relpath}, found {len(matches)} -- the "
            "extraction anchor drifted; fix this test's regex, do not delete the check"
        )
        assert matches[0] == providers.VERDICT_JSON_SCHEMA, (
            f"{relpath} has DRIFTED from pantheon.providers.VERDICT_JSON_SCHEMA -- that surface "
            "would enforce a different verdict shape than the others. Update every copy together, "
            "or drop the byte-identity claim."
        )


def test_verdict_schema_is_never_stricter_than_the_decider() -> None:
    """The provider schema must not reject a verdict `pantheon.verdict.decide()` ACCEPTS.

    A schema stricter than the decider fails closed in the WRONG direction: a real, reviewable
    verdict is rejected before the decider ever sees it and surfaces as UNVERIFIED / NOT GATED.
    A live Codex review on PR #28 caught exactly that -- `line` typed `integer` and all five
    display fields `required`, while DESIGN.md's "The display surface -- deliberately NOT
    schema-validated" section reserves those fields for the render layer, which coerces a
    non-numeric or absent `.line` to "?".

    Pinned structurally rather than by running a JSON-Schema validator: this package is
    stdlib-only by design, so there is no validator to call. These assertions compare the schema's
    own constraint surface against the decider's, which is the property that actually matters.
    """
    schema = json.loads(providers.VERDICT_JSON_SCHEMA)

    # The decision surface: exactly the keys decide() demands, no more.
    assert set(schema["required"]) == set(verdict.REQUIRED_KEYS)

    props = schema["properties"]
    # Strict where decide() branches -- these types are what the blocker invariant relies on.
    assert props["has_blocker"]["type"] == "boolean"
    assert props["verdict"]["type"] == "string"
    assert props["agent"]["type"] == "string"
    assert props["findings"]["type"] == "array"

    item = props["findings"]["items"]
    # severity is the only findings field decide() reads, so it is the only one required.
    assert item["required"] == ["severity"], (
        "findings items must require ONLY severity -- requiring a display field rejects verdicts "
        "decide() accepts (see this test's docstring)"
    )
    assert item["properties"]["severity"]["type"] == "string"

    # UNCONSTRAINED on every display field. decide() accepts ANY JSON type there (verified
    # directly in the companion test below -- objects, arrays, booleans and numbers all come back
    # green), so permitting only string+null would still be stricter than the decider. An earlier
    # revision of this very test asserted merely that "null" was allowed, which passed against a
    # string|null schema that was still too strict -- the assertion was weaker than the guarantee
    # it claimed to pin. Enumerate every JSON type explicitly so that cannot recur.
    every_json_type = {"string", "number", "boolean", "object", "array", "null"}
    for field in ("file", "line", "issue", "scenario"):
        assert every_json_type <= set(item["properties"][field]["type"]), (
            f"findings[].{field} is constrained more tightly than decide() -- a verdict the "
            "binding contract accepts would be rejected as UNVERIFIED"
        )
    assert every_json_type <= set(props["summary"]["type"])


def test_decider_really_does_accept_the_loose_shape_the_schema_now_permits() -> None:
    """Companion to the test above: proves the leniency being permitted is REAL, not assumed.

    Without this, the schema could be loosened toward a decider behavior nobody verified -- the
    two tests together pin both halves (schema permits it AND decide() accepts it), so neither
    can drift into the gap alone.
    """
    # Every JSON type the schema now permits in a display field, proven accepted -- not assumed.
    for label, finding, summary in [
        ("string line", {"severity": "note", "line": "section X"}, None),
        ("object file", {"severity": "note", "file": {"a": 1}}, None),
        ("array issue", {"severity": "note", "issue": [1, 2]}, None),
        ("boolean scenario", {"severity": "note", "scenario": True}, None),
        ("number file", {"severity": "note", "file": 42}, None),
        ("object summary", {"severity": "note"}, {"nested": "obj"}),
        ("display fields absent entirely", {"severity": "note"}, "ok"),
    ]:
        loose = json.dumps(
            {
                "agent": "artemis",
                "verdict": "SHIP",
                "has_blocker": False,
                "findings": [finding],
                "summary": summary,
            }
        )

        decision = verdict.decide("artemis", loose)

        assert decision["color"] == "green", (label, decision)
        assert decision["verdict"] == "SHIP", label
        assert decision["invariant_fired"] is False, label
