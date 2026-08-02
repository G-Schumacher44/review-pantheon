"""tests/test_jqjson.py — pytest unit layer for pantheon.jqjson's own matrix (docs/PYTHON-PORT.md
section 4's port slice 4 deliverable: "pytest unit layer for the jqjson matrix + pure-function
seams ONLY — no 1:1 duplication of the black-box exams").

This module is deliberately NOT a re-run of tests/test-json-boundary.sh (the mechanical
no-bare-json-call assertion) or tests/test-verdict-decision-python.sh /
tests/test-render-comment-python.sh's own regression fixtures for this boundary (both already
cover jqjson's behavior AS OBSERVED THROUGH pantheon.verdict/pantheon.render's decision/render
output). This file tests pantheon.jqjson's own four functions DIRECTLY and in isolation — the
fast, in-process unit layer those black-box subprocess-driven exams can't cheaply be — parametrized
across the exact edge-case matrix docs/PYTHON-PORT.md section 5's "JSON boundary" bullet and this
module's own docstring enumerate: non-standard constants, overflow/underflow numbers, excess-
precision decimals, trailing-zero-formatted decimals (issue #19), lone surrogates, and the
_RawBigNumber placeholder-collision-avoidance guarantee.

Run via `pytest` (wired into pyproject.toml's [tool.pytest.ini_options], collected from
tests/test_*.py only — never the tests/test-*.sh black-box exam suites).
"""

from __future__ import annotations

import math

import pytest

from pantheon import jqjson

# ---------------------------------------------------------------------------------------------
# loads()/dumps() round-trip matrix — every case here was verified live against real jq (jq-1.7.1)
# while landing pantheon/jqjson.py; see that module's own docstring for the live-verification
# narrative behind each class of case.
# ---------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "expected_display"),
    [
        # Ordinary, exactly-representable decimals — unaffected by the RawBigNumber machinery.
        ("0.1", "0.1"),
        ("5.0", "5.0"),
        ("100.0", "100.0"),
        # Trailing-zero-formatted decimals (issue #19: "preserve jq formatting for representable
        # decimals") — jq preserves the literal surface text byte-for-byte, never normalizing
        # away a trailing zero the way Python's repr(float(...)) would.
        ("1.50", "1.50"),
        ("0.10", "0.10"),
        ("2.00", "2.00"),
        ("3.140", "3.140"),
        ("-1.50", "-1.50"),
        ("123.4500", "123.4500"),
        # Exponent-notation numbers — General Decimal Arithmetic's to-scientific-string algorithm
        # (what jq's decNumber and Python's decimal.Decimal both implement — see
        # _canonicalize_number_text's own docstring): scientific form when the exponent is
        # positive or the adjusted exponent is < -6, plain decimal otherwise, with the mantissa
        # RENORMALIZED (not simply preserved) when it does print in scientific form.
        ("1e2", "1E+2"),
        ("1.0e2", "1.0E+2"),
        ("1E10", "1E+10"),
        ("1.5E10", "1.5E+10"),
        # Codex review finding on this port's own PR (jqjson.py:213): the earlier
        # mantissa-preserved-verbatim canonicalizer got these wrong — real jq renormalizes the
        # mantissa and/or switches to plain decimal notation for these exact shapes.
        ("1e-01", "0.1"),
        ("10e-1", "1.0"),
        ("1.2300e+02", "123.00"),
        ("10e2", "1.0E+3"),
        ("1e-4", "0.0001"),
        ("1e-5", "0.00001"),
        ("2e-7", "2E-7"),
        # Overflow/underflow — jq's arbitrary-precision decimal handling never loses the literal.
        ("1e400", "1E+400"),
        ("-1e400", "-1E+400"),
        ("1e-400", "1E-400"),
        # Excess significant digits (more than a double can hold exactly) — preserved verbatim.
        ("1.234567890123456789", "1.234567890123456789"),
    ],
)
def test_number_round_trip_matches_jq(text: str, expected_display: str) -> None:
    parsed = jqjson.loads(f'{{"x":{text}}}')["x"]
    assert jqjson.jq_text(parsed) == expected_display


def test_nan_constant_parses_and_displays_as_null() -> None:
    parsed = jqjson.loads('{"x":NaN}')["x"]
    assert parsed is jqjson.NAN
    assert jqjson.jq_text(parsed) == "null"


def test_infinity_constants_coerce_to_max_double() -> None:
    parsed = jqjson.loads('{"a":Infinity,"b":-Infinity}')
    assert parsed["a"] == 1.7976931348623157e308
    assert parsed["b"] == -1.7976931348623157e308


def test_lone_surrogate_is_a_parse_error() -> None:
    # Real jq rejects a lone (unpaired) UTF-16 surrogate at parse time; json.loads alone accepts
    # it. pantheon.jqjson.loads must reject it too, matching jq's real behavior.
    with pytest.raises(jqjson.JqParseError):
        jqjson.loads('{"x":"\\ud800"}')


def test_pathologically_long_integer_is_a_parse_error_not_a_crash() -> None:
    # Python 3.11+'s int-string-conversion digit limit raises a bare ValueError (not
    # json.JSONDecodeError) for an integer with more than ~4300 digits anywhere in the source
    # text — loads() must fold this into the same single JqParseError type, never let it escape
    # as an uncaught ValueError.
    huge_int = "9" * 5000
    with pytest.raises(jqjson.JqParseError):
        jqjson.loads(f'{{"x":{huge_int}}}')


def test_syntax_error_is_a_parse_error() -> None:
    with pytest.raises(jqjson.JqParseError):
        jqjson.loads("{not valid json")


# ---------------------------------------------------------------------------------------------
# jq_text() — the DISPLAY-TEXT half of the boundary.
# ---------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("already a string", "already a string"),
        (None, "null"),
        (True, "true"),
        (False, "false"),
    ],
)
def test_jq_text_scalar_forms(value: object, expected: str) -> None:
    assert jqjson.jq_text(value) == expected


def test_jq_text_diverges_from_python_str_for_bool_and_none() -> None:
    # The exact divergence this module exists to close — caught live on this port's own PR.
    assert str(None) == "None"
    assert jqjson.jq_text(None) == "null"
    assert str(True) == "True"
    assert jqjson.jq_text(True) == "true"


def test_jq_text_container_uses_dumps_not_repr() -> None:
    value = {"x": 1}
    # Python's own repr uses single-quoted keys; jq_text must route through this module's own
    # dumps() (double-quoted, JSON-shaped) instead.
    assert repr(value) == "{'x': 1}"
    assert jqjson.jq_text(value) == jqjson.dumps(value, indent=2, ensure_ascii=False)
    assert "'" not in jqjson.jq_text(value)


# ---------------------------------------------------------------------------------------------
# subst() — bash's $(...) command-substitution semantics: strip ALL trailing newlines AND every
# NUL byte, nothing else.
# ---------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("no newline", "no newline"),
        ("one trailing newline\n", "one trailing newline"),
        ("multiple trailing newlines\n\n\n", "multiple trailing newlines"),
        ("internal\nnewline stays", "internal\nnewline stays"),
        ("has a nul\x00 byte", "has a nul byte"),
        ("nul\x00 and trailing\n", "nul and trailing"),
        ("only c0 controls survive: \x01\x07\x1b", "only c0 controls survive: \x01\x07\x1b"),
    ],
)
def test_subst(text: str, expected: str) -> None:
    assert jqjson.subst(text) == expected


def test_subst_passes_through_non_str_unchanged() -> None:
    # Defensive: safe to call on a value that hasn't been through jq_text yet.
    assert jqjson.subst(None) is None  # type: ignore[arg-type]
    assert jqjson.subst(42) == 42  # type: ignore[arg-type]


# ---------------------------------------------------------------------------------------------
# dumps() — the placeholder-collision-avoidance guarantee (issue #19's third item, cherry-picked
# earlier this slice): a payload whose genuine content happens to contain an OLDER, deterministic
# placeholder's exact text must not be corrupted by a re-run of the mechanism.
# ---------------------------------------------------------------------------------------------


def test_dumps_overflow_number_round_trips_through_display() -> None:
    parsed = jqjson.loads('{"x":1e400}')
    text = jqjson.dumps(parsed)
    assert '"x":1E+400' in text.replace(" ", "")
    # Re-parsing the dumped text must itself succeed and preserve the value again.
    reparsed = jqjson.loads(text)
    assert jqjson.jq_text(reparsed["x"]) == "1E+400"


def test_dumps_does_not_corrupt_content_matching_an_old_deterministic_placeholder() -> None:
    # The exact regression this module's dumps() closed: a payload whose own genuine string
    # content equals the text an EARLIER, deterministic-token version of this mechanism would
    # have used as its placeholder.
    poison = "jqjson-raw-0"
    value = {"real_field": poison, "overflow_field": jqjson.loads('{"x":1e400}')["x"]}
    text = jqjson.dumps(value)
    reparsed = jqjson.loads(text)
    assert reparsed["real_field"] == poison
    assert jqjson.jq_text(reparsed["overflow_field"]) == "1E+400"


def test_dumps_forces_allow_nan_false_as_a_fail_loud_backstop() -> None:
    with pytest.raises(ValueError):
        jqjson.dumps({"x": math.nan})


def test_dumps_nan_sentinel_serializes_as_null() -> None:
    text = jqjson.dumps({"x": jqjson.NAN})
    assert jqjson.loads(text)["x"] is None


# ---------------------------------------------------------------------------------------------
# _check_depth_limit() / loads() depth cap — CRITICAL-4, an adversarial-review finding: real jq
# caps object/array nesting at 256 levels ("Exceeds depth limit for parsing", rc=5, verified live
# against jq-1.7.1 below); pantheon.jqjson had no equivalent cap at all pre-fix, so a
# pathologically deep display-type field in a verdict payload parsed clean here while real jq's
# own bash pipeline would already have failed closed to UNVERIFIED on the identical input — a
# genuine decision-color divergence (UNVERIFIED -> green). Live pre-fix reproduction: reverting
# loads() to skip _check_depth_limit() makes test_loads_rejects_nesting_deeper_than_jqs_256_level_cap
# below FAIL (the 300-deep payload parses clean instead of raising) — verified locally before
# landing this fix.
# ---------------------------------------------------------------------------------------------


def _nested_array_json(depth: int) -> str:
    return "[" * depth + "1" + "]" * depth


def test_loads_rejects_nesting_deeper_than_jqs_256_level_cap() -> None:
    # 300 levels — the adversarial reviewer's own reproduction depth, chosen to sit safely past
    # jq's real 256-level cap without relying on an exact-boundary off-by-one.
    with pytest.raises(jqjson.JqParseError, match="depth limit"):
        jqjson.loads(_nested_array_json(300))


def test_loads_accepts_nesting_at_exactly_jqs_256_level_cap() -> None:
    # The cap must not be off-by-one in the OTHER direction either — exactly 256 levels is the
    # deepest real jq still parses successfully (verified live below).
    jqjson.loads(_nested_array_json(256))


def test_loads_rejects_nesting_one_level_past_the_cap() -> None:
    with pytest.raises(jqjson.JqParseError, match="depth limit"):
        jqjson.loads(_nested_array_json(257))


def test_loads_depth_scan_ignores_brace_characters_inside_string_literals() -> None:
    # A string VALUE that merely contains many '{'/'[' characters as literal text must never
    # count toward structural nesting depth — only real object/array nesting does.
    payload = '{"x": "' + "{[" * 300 + '"}'
    parsed = jqjson.loads(payload)  # must not raise
    assert parsed["x"] == "{[" * 300


def test_loads_depth_scan_handles_escaped_quotes_inside_strings() -> None:
    # A string containing an escaped quote followed by many brackets must still be treated as
    # string content, not accidentally exit the string early and start counting the brackets that
    # follow as real structure.
    payload = '{"x": "a\\"' + "[" * 300 + '"}'
    parsed = jqjson.loads(payload)
    assert parsed["x"] == 'a"' + "[" * 300


def test_depth_limit_matches_real_jq_live() -> None:
    # Live cross-check against the actual jq binary, when available — proves this module's cap
    # isn't just an arbitrary internal constant but genuinely matches real jq's own rc=5 refusal
    # on the identical input, the exact divergence this fix closes.
    import shutil
    import subprocess

    jq_bin = shutil.which("jq")
    if jq_bin is None:
        pytest.skip("jq not installed in this environment — cannot cross-check live")

    deep = _nested_array_json(300)
    result = subprocess.run([jq_bin, "-c", "."], input=deep, capture_output=True, text=True)
    assert result.returncode != 0
    assert "depth limit" in result.stderr.lower()

    with pytest.raises(jqjson.JqParseError, match="depth limit"):
        jqjson.loads(deep)


# ---------------------------------------------------------------------------------------------
# dumps() single-pass placeholder splice — a medium finding from the same adversarial review,
# live-reproduced pre-fix: 8000 overflow numbers in one payload took ~2.1s to serialize (an
# earlier version called text.replace() once PER placeholder, each call rescanning the whole,
# already-serialized text — O(N) full-text scans of an O(N)-length string, quadratic overall).
# ---------------------------------------------------------------------------------------------


def test_dumps_handles_thousands_of_overflow_numbers_without_quadratic_blowup() -> None:
    import time

    huge = {f"k{i}": jqjson.loads(f'{{"x":1e{400 + (i % 50)}}}')["x"] for i in range(8000)}
    start = time.perf_counter()
    text = jqjson.dumps(huge)
    elapsed = time.perf_counter() - start

    # Generous ceiling: the pre-fix reproduction measured ~2.1s for this exact shape; the
    # single-pass fix should complete in a small fraction of that. 1.0s leaves ample CI-noise
    # margin while still being a real, meaningful regression guard against the O(N^2) shape
    # returning.
    assert elapsed < 1.0, f"dumps() took {elapsed:.2f}s for 8000 overflow numbers — quadratic regression?"

    # Correctness, not just speed: every value must still round-trip.
    reparsed = jqjson.loads(text)
    assert reparsed["k0"] is not None
    assert jqjson.jq_text(reparsed["k7999"]) == jqjson.jq_text(huge["k7999"])
