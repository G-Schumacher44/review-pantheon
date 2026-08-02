"""tests/test_render.py — fast pytest-level unit coverage for pantheon.render's pure helpers.

Most of pantheon.render's coverage lives in the black-box shell suites
(tests/test-render-comment-python.sh, mirroring tests/test-render-comment.sh's bash-parity
fixtures — see that file's own header for why). This file adds direct unit coverage for two
pure, easily-isolated helpers where a black-box round-trip through the CLI shim would obscure
the actual invariant under test: _redact_repo_root_in_value (the DATA-level redaction primitive)
and _machine_tail_text's ordering fix (redact-before-serialize, not after) — an adversarial
review, round-4 finding: redacting the OUTPUT of jqjson.dumps() can desync from repo_root's own
raw text the moment repo_root contains a JSON-escapable character (a literal '"' or '\\'), since
dumps() has already escaped those characters by the time a post-hoc string-level redact runs.
See pantheon.render._redact_repo_root_in_value's and _machine_tail_text's own docstrings for the
full rationale; tests/test-render-comment-python.sh's "repo-root-redaction-ordering-bug" fixture
covers the same fix end-to-end through the full render_comment() pipeline.
"""

from __future__ import annotations

from pantheon import render


def test_redact_repo_root_in_value_redacts_string_leaves_in_a_nested_structure() -> None:
    root = "/Users/alice/dev/review-pantheon"
    value = {
        "file": root + "/src/gate.sh",
        "nested": {"issue": "see " + root, "list": [root, "unrelated", {"deep": root}]},
        "number": 42,
        "flag": True,
        "nothing": None,
    }
    redacted = render._redact_repo_root_in_value(value, root)
    assert redacted["file"] == "<repo>/src/gate.sh"
    assert redacted["nested"]["issue"] == "see <repo>"
    assert redacted["nested"]["list"] == ["<repo>", "unrelated", {"deep": "<repo>"}]
    assert redacted["number"] == 42
    assert redacted["flag"] is True
    assert redacted["nothing"] is None


def test_redact_repo_root_in_value_redacts_dict_keys_too() -> None:
    root = "/Users/alice/dev/review-pantheon"
    value = {root: "value under a repo-root-bearing key"}
    redacted = render._redact_repo_root_in_value(value, root)
    assert redacted == {"<repo>": "value under a repo-root-bearing key"}


def test_redact_repo_root_in_value_is_a_noop_when_repo_root_is_falsy() -> None:
    value = {"file": "/Users/alice/dev/review-pantheon/src/gate.sh"}
    assert render._redact_repo_root_in_value(value, None) == value
    assert render._redact_repo_root_in_value(value, "") == value


def test_machine_tail_text_redacts_repo_root_containing_json_escapable_characters() -> None:
    # The ordering bug this test exists for: redacting the OUTPUT of jqjson.dumps() (which
    # JSON-escapes '"'/'\\') against repo_root's own RAW, unescaped text silently stops matching
    # the moment repo_root contains either character — a real path shape (a POSIX dir name can
    # legally hold a '"'; Git Bash on Windows checks out under paths containing a '\\').
    root = '/Users/mal"icious\\user/dev/review-pantheon'
    raw_text = '{"file": "' + root.replace("\\", "\\\\").replace('"', '\\"') + '/gate.sh"}'
    result = render._machine_tail_text(raw_text, root)
    assert root not in result
    assert "<repo>/gate.sh" in result


def test_machine_tail_text_redacts_repo_root_in_the_raw_text_fallback_path_too() -> None:
    # Invalid JSON -> the raw-text-fallback branch, which never goes through jqjson.dumps() at
    # all -- redact_repo_root runs directly on raw_text there, a single (already-correct) step.
    root = "/Users/alice/dev/review-pantheon"
    raw_text = "not valid json, but mentions " + root
    result = render._machine_tail_text(raw_text, root)
    assert root not in result
    assert "<repo>" in result


def test_machine_tail_text_is_a_noop_when_repo_root_is_none() -> None:
    raw_text = '{"file": "/Users/alice/dev/review-pantheon/gate.sh"}'
    result = render._machine_tail_text(raw_text, None)
    assert "/Users/alice/dev/review-pantheon" in result
