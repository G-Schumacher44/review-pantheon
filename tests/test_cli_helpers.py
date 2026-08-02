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

from pantheon.cli import GateConfig, _load_working_tree_gate_conf, _parse_conf_text


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
