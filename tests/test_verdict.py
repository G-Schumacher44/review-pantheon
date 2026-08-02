"""tests/test_verdict.py — pytest unit layer for pantheon.verdict.emit_github_output (port
slice 5, docs/PYTHON-PORT.md section 3's decide_verdict.py absorption).

decide()/extract_last_json()/the full decision pipeline are already covered end to end by the
black-box bash suite (tests/test-verdict-decision-python.sh, driven via
`python3 -m pantheon.verdict <agent> <raw-file>`) — this file covers only what that suite can't
cheaply express: the $GITHUB_OUTPUT side effect emit_github_output() adds at this slice, needed
to make `python3 -m pantheon.verdict` a drop-in replacement for action/decide_verdict.py's own
identically-named function at both of the Action's call sites (action.yml's composite steps,
action/review.yml's vendored decide step — both read steps.<id>.outputs.* downstream).
"""

from __future__ import annotations

from pantheon import jqjson, verdict


def test_emit_github_output_is_a_noop_without_the_env_var(monkeypatch, tmp_path) -> None:
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    decision = verdict.decide(
        "artemis", '{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"ok"}'
    )
    # Must not raise, and must not create a file anywhere -- nothing to check beyond "didn't blow
    # up", since there is no path to write to.
    verdict.emit_github_output(decision)


def test_emit_github_output_writes_every_expected_key(monkeypatch, tmp_path) -> None:
    gh_out = tmp_path / "github_output.txt"
    monkeypatch.setenv("GITHUB_OUTPUT", str(gh_out))

    raw = (
        '{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":true,'
        '"findings":[{"severity":"blocker","issue":"bad thing","file":"a.py","line":1,"scenario":"x"}],'
        '"summary":"needs fixes"}'
    )
    decision = verdict.decide("artemis", raw)
    assert decision["color"] == "red"  # blocker invariant fired despite FIX_FIRST -> yellow-ish verdict word
    assert decision["invariant_fired"] is True

    verdict.emit_github_output(decision)

    content = gh_out.read_text(encoding="utf-8")
    assert "color=red\n" in content
    assert "verdict=FIX_FIRST\n" in content
    assert "invariant_fired=true\n" in content
    assert "summary<<pantheon_" in content
    assert "needs fixes" in content
    assert "top_finding<<pantheon_" in content
    assert "blocker: bad thing (a.py:1)" in content
    assert "findings_json<<pantheon_" in content
    assert "reason<<pantheon_" in content
    assert "forcing red regardless of stated verdict" in content

    # findings_json is a single, jq-compatible JSON document embedded between its own delimiter
    # lines -- prove it round-trips via the SAME boundary module the rest of this port uses.
    lines = content.splitlines()
    start = lines.index("findings_json<<pantheon_" + content.split("findings_json<<pantheon_", 1)[1].split("\n", 1)[0])
    delim = lines[start][len("findings_json<<") :]
    end = lines.index(delim, start + 1)
    embedded_json = "\n".join(lines[start + 1 : end])
    parsed = jqjson.loads(embedded_json)
    assert parsed["agent"] == "artemis"
    assert parsed["has_blocker"] is True


def test_emit_github_output_appends_rather_than_overwrites(monkeypatch, tmp_path) -> None:
    gh_out = tmp_path / "github_output.txt"
    gh_out.write_text("existing_key=existing_value\n", encoding="utf-8")
    monkeypatch.setenv("GITHUB_OUTPUT", str(gh_out))

    decision = verdict.decide(
        "apollo", '{"agent":"apollo","verdict":"ACCEPT","has_blocker":false,"findings":[],"summary":"ok"}'
    )
    verdict.emit_github_output(decision)

    content = gh_out.read_text(encoding="utf-8")
    assert content.startswith("existing_key=existing_value\n")
    assert "color=green\n" in content
