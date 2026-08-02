"""tests/test_cli_helpers.py — pytest unit layer for pantheon.cli's pure-function seams that
neither tests/test-prompt-assembly-python.sh nor tests/test-execution-tier-python.sh already
exercise (docs/PYTHON-PORT.md section 4's port slice 4 deliverable: "no 1:1 duplication of the
black-box exams").

Scope: `_parse_conf_text` (the gate.conf key=value parser) — no black-box suite drives this
function directly today (it's exercised only indirectly, through a real gate.conf on disk, by
the -python.sh suites' base-pinning/execution-tier fixtures). `_strip_frontmatter` and
`_fence_id_for` already have dedicated coverage in tests/test-prompt-assembly-python.sh's Part
P1 — not duplicated here.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pantheon.cli as cli_module
from pantheon.cli import (
    GateConfig,
    _load_working_tree_gate_conf,
    _parse_conf_text,
    _strip_frontmatter,
    _wrapper_invocation,
)


def test_parse_conf_text_basic_keys() -> None:
    text = "provider=codex\nmodel=o3\nagents=artemis apollo\n"
    assert _parse_conf_text(text) == {
        "provider": "codex",
        "model": "o3",
        "agents": "artemis apollo",
    }


def test_parse_conf_text_skips_comments_and_blank_lines() -> None:
    text = "# a comment\n\nprovider=claude\n  # indented comment is not a key= line either\n"
    assert _parse_conf_text(text) == {"provider": "claude"}


def test_parse_conf_text_skips_uppercase_keys() -> None:
    # Bash's own regex is `^[a-z_]+=` — lowercase only. An uppercase (or mixed-case) key is
    # silently skipped, matching bash's own `[[ "$cfg_line" =~ ^[a-z_]+= ]] || continue`.
    text = "PROVIDER=codex\nprovider=claude\n"
    assert _parse_conf_text(text) == {"provider": "claude"}


def test_parse_conf_text_splits_on_first_equals_only() -> None:
    # bash's ${cfg_line#*=} strips only up to the FIRST '=' — a value containing its own '='
    # characters must survive intact.
    text = "rules_file=path=with=equals.md\n"
    assert _parse_conf_text(text) == {"rules_file": "path=with=equals.md"}


def test_parse_conf_text_empty_value() -> None:
    # gate.conf's own documented way to disable spec_file: `spec_file=` (empty right-hand side).
    text = "spec_file=\n"
    assert _parse_conf_text(text) == {"spec_file": ""}


def test_parse_conf_text_ignores_lines_with_no_equals_sign() -> None:
    text = "not_a_conf_line_at_all\nprovider=claude\n"
    assert _parse_conf_text(text) == {"provider": "claude"}


def test_load_working_tree_gate_conf_defaults_when_absent(tmp_path) -> None:
    cfg = _load_working_tree_gate_conf(str(tmp_path))
    assert cfg == GateConfig()


def test_load_working_tree_gate_conf_reads_present_keys(tmp_path) -> None:
    (tmp_path / "gate.conf").write_text(
        "provider=codex\nmodel=o3\nbase_branch=trunk\nrules_file=RULES.md\n"
        "spec_file=SPEC.md\nagents=artemis apollo diogenes\n"
    )
    cfg = _load_working_tree_gate_conf(str(tmp_path))
    assert cfg.provider == "codex"
    assert cfg.model == "o3"
    assert cfg.base_branch == "trunk"
    assert cfg.rules_file == "RULES.md"
    assert cfg.spec_file == "SPEC.md"
    assert cfg.agents == "artemis apollo diogenes"


def test_load_working_tree_gate_conf_partial_overrides_leave_the_rest_default(tmp_path) -> None:
    (tmp_path / "gate.conf").write_text("provider=gemini\n")
    cfg = _load_working_tree_gate_conf(str(tmp_path))
    assert cfg.provider == "gemini"
    assert cfg.model == GateConfig().model
    assert cfg.base_branch == GateConfig().base_branch
    assert cfg.rules_file == GateConfig().rules_file
    assert cfg.spec_file == GateConfig().spec_file
    assert cfg.agents == GateConfig().agents


def test_load_working_tree_gate_conf_does_not_read_execution_key(tmp_path) -> None:
    # execution= is deliberately NOT read from the working tree by this helper — it's
    # base-pinned instead, via _resolve_execution_from_base(). GateConfig has no `execution`
    # field at all, so there's nothing for a working-tree gate.conf's execution= line to
    # populate here even if present.
    (tmp_path / "gate.conf").write_text("execution=trusted\nprovider=claude\n")
    cfg = _load_working_tree_gate_conf(str(tmp_path))
    assert not hasattr(cfg, "execution")
    assert cfg.provider == "claude"


# ---------------------------------------------------------------------------------------------
# _wrapper_invocation() — the module-shadowing fix, round 3 (mirrors
# tests/test_providers.py's identical coverage for pantheon.providers' own
# default_allowed_tools()/_WRAPPER_SCRIPT_NAME — same mechanism, same rationale, both modules
# fixed together since both compute this string independently).
# ---------------------------------------------------------------------------------------------


def test_wrapper_invocation_resolves_the_installed_console_script(monkeypatch, tmp_path) -> None:
    fake_bin_dir = tmp_path / "bin"
    fake_bin_dir.mkdir()
    fake_script = fake_bin_dir / cli_module._WRAPPER_SCRIPT_NAME
    fake_script.write_text("#!/bin/sh\n")
    fake_script.chmod(0o755)
    monkeypatch.setattr(cli_module.sys, "executable", str(fake_bin_dir / "python3"))

    invocation = _wrapper_invocation()
    assert invocation == f"{fake_script} wrapper"
    assert " -m " not in invocation
    assert " -I " not in invocation


def test_wrapper_invocation_falls_back_loudly_when_console_script_missing(monkeypatch, tmp_path, capsys) -> None:
    empty_bin_dir = tmp_path / "empty-bin"
    empty_bin_dir.mkdir()
    monkeypatch.setattr(cli_module.sys, "executable", str(empty_bin_dir / "python3"))

    invocation = _wrapper_invocation()
    assert invocation == f"{empty_bin_dir / 'python3'} -m pantheon.execution wrapper"
    captured_stderr = capsys.readouterr().err
    assert cli_module._WRAPPER_SCRIPT_NAME in captured_stderr
    assert "not installed" in captured_stderr


# ---------------------------------------------------------------------------------------------
# _cli_env() — two Codex review findings on this port's own PR (7th wave), both on the SAME
# constructed environment: (1) proxy transport vars were dropped entirely, breaking `gh`/`git
# fetch` behind a corporate proxy; (2) HOME was forwarded bare, letting a hostile launcher
# environment's `~/.gitconfig` set `core.sshCommand` (shell-interpreted, execution-capable) and
# have `git fetch` run it — the same class GIT_SSH_COMMAND's own exclusion (see that key's
# comment above _CLI_ENV_PASSTHROUGH_KEYS) already guards, reachable through a second door.
# ---------------------------------------------------------------------------------------------


def test_cli_env_forwards_both_cases_of_proxy_vars(monkeypatch) -> None:
    monkeypatch.setenv("HTTP_PROXY", "http://proxy.example:8080")
    monkeypatch.setenv("HTTPS_PROXY", "https://proxy.example:8443")
    monkeypatch.setenv("NO_PROXY", "localhost,127.0.0.1")
    monkeypatch.setenv("http_proxy", "http://proxy.example:8080")
    monkeypatch.setenv("https_proxy", "https://proxy.example:8443")
    monkeypatch.setenv("no_proxy", "localhost,127.0.0.1")

    env = cli_module._cli_env()

    assert env["HTTP_PROXY"] == "http://proxy.example:8080"
    assert env["HTTPS_PROXY"] == "https://proxy.example:8443"
    assert env["NO_PROXY"] == "localhost,127.0.0.1"
    assert env["http_proxy"] == "http://proxy.example:8080"
    assert env["https_proxy"] == "https://proxy.example:8443"
    assert env["no_proxy"] == "localhost,127.0.0.1"


_ALL_PROXY_KEYS = (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "all_proxy",
)


def test_cli_env_omits_proxy_vars_when_unset(monkeypatch) -> None:
    for key in _ALL_PROXY_KEYS:
        monkeypatch.delenv(key, raising=False)

    env = cli_module._cli_env()

    for key in _ALL_PROXY_KEYS:
        assert key not in env


def test_cli_env_forces_git_config_global_and_system_to_dev_null(monkeypatch) -> None:
    monkeypatch.setenv("HOME", "/some/hostile/checkout")

    env = cli_module._cli_env()

    assert env["GIT_CONFIG_GLOBAL"] == "/dev/null"
    assert env["GIT_CONFIG_SYSTEM"] == "/dev/null"
    # HOME itself is still forwarded (gh's own credential lookup depends on it) — only git's
    # config-file reads of that HOME are what get closed off.
    assert env["HOME"] == "/some/hostile/checkout"


def test_cli_env_git_config_overrides_close_the_core_sshcommand_injection_live(tmp_path, monkeypatch) -> None:
    # Live, non-mocked reproduction: a hostile HOME whose ~/.gitconfig sets core.sshCommand to a
    # marker-writing command. Without GIT_CONFIG_GLOBAL/SYSTEM pinned to /dev/null, `git config
    # --get core.sshCommand` under that HOME prints the injected command; with _cli_env()'s
    # overrides applied, git reads no global/system config at all and the key resolves to nothing.
    hostile_home = tmp_path / "hostile-home"
    hostile_home.mkdir()
    marker = tmp_path / "pwned"
    gitconfig = hostile_home / ".gitconfig"
    gitconfig.write_text(f"[core]\n\tsshCommand = touch {marker}\n")

    baseline_env = dict(os.environ)
    baseline_env["HOME"] = str(hostile_home)
    baseline = subprocess.run(
        ["git", "config", "--get", "core.sshCommand"],
        env=baseline_env,
        capture_output=True,
        text=True,
    )
    assert baseline.returncode == 0
    assert "touch" in baseline.stdout

    monkeypatch.setenv("HOME", str(hostile_home))
    hardened_env = cli_module._cli_env()
    hardened_env["PATH"] = os.environ.get("PATH", "")  # real PATH so the real git resolves here

    hardened = subprocess.run(
        ["git", "config", "--get", "core.sshCommand"],
        env=hardened_env,
        capture_output=True,
        text=True,
    )
    assert hardened.returncode != 0
    assert hardened.stdout == ""
    assert not marker.exists()


# ---------------------------------------------------------------------------------------------
# UTF-8-explicit file I/O — a Codex review finding on this port's own PR (7th wave): under a
# non-UTF-8 locale (`LC_ALL=C` with UTF-8 mode off), Python's `open()` without an explicit
# `encoding=` falls back to `locale.getpreferredencoding(False)` (often ascii/latin-1), so a
# non-ASCII PR title or a non-ASCII house-rules/persona file would raise UnicodeEncodeError on
# write, or silently mis-decode on read. Every file this module writes/reads for prompt/comment
# assembly now pins `encoding="utf-8"` explicitly (reads add `errors="replace"` to stay
# fail-open on a genuinely malformed byte, matching this module's other defensive reads).
# ---------------------------------------------------------------------------------------------


def test_load_working_tree_gate_conf_round_trips_non_ascii_bytes_regardless_of_content(tmp_path) -> None:
    # gate.conf itself only has ASCII keys, but this proves the read path is UTF-8-explicit, not
    # locale-dependent, by writing raw UTF-8 bytes for a value and reading them back correctly.
    repo_root = tmp_path
    (repo_root / "gate.conf").write_bytes("rules_file=règles/日本語.md\n".encode())

    cfg = _load_working_tree_gate_conf(str(repo_root))

    assert cfg.rules_file == "règles/日本語.md"


def test_strip_frontmatter_reads_non_ascii_persona_content_as_utf8(tmp_path) -> None:
    persona = tmp_path / "artemis.md"
    persona.write_bytes("---\nname: artemis\n---\n# Персона — 説明\n".encode())

    body = _strip_frontmatter(Path(persona))

    assert "Персона" in body
    assert "説明" in body


def test_build_prompt_writes_non_ascii_pr_title_as_utf8_bytes_on_disk(tmp_path, monkeypatch) -> None:
    # Live proof (no locale mocking needed): write via the real code path, then read the file
    # back as RAW BYTES (bypassing Python's own default-encoding open()) and confirm those bytes
    # are the genuine UTF-8 encoding of the non-ASCII title — not mangled, not raised on write.
    agents_dir = tmp_path / "agents"
    agents_dir.mkdir()
    (agents_dir / "artemis.md").write_text("---\nname: artemis\n---\nBody.\n", encoding="utf-8")
    monkeypatch.setattr(cli_module, "_agents_dir", lambda: agents_dir)
    monkeypatch.setattr(cli_module, "_base_pinned_text", lambda ctx, path: (None, False))

    workdir = tmp_path / "workdir"
    workdir.mkdir()
    ctx = cli_module.GateContext(
        repo_root=str(tmp_path),
        pr_number="42",
        pr_title="Fïx encödïng — 日本語のタイトル",
        diff_range="deadbeef...cafebabe",
        base_ref="main",
        base_sha="deadbeef",
        execution_tier="readonly",
        rules_file="RULES.md",
        spec_file="",
    )

    prompt_path = cli_module._build_prompt(ctx, "artemis", str(workdir))

    raw_bytes = Path(prompt_path).read_bytes()
    assert "Fïx encödïng — 日本語のタイトル".encode() in raw_bytes
    # Confirms the write used UTF-8, not the platform/locale default: decoding as UTF-8 succeeds
    # and round-trips exactly, which a mis-encoded (e.g. latin-1-mangled) write would not.
    assert "Fïx encödïng — 日本語のタイトル" in raw_bytes.decode("utf-8")
