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
        # Exponent-notation numbers — canonicalized (uppercase E, explicit + on the exponent),
        # mantissa preserved exactly as given.
        ("1e2", "1E+2"),
        ("1.0e2", "1.0E+2"),
        ("1E10", "1E+10"),
        ("1.5E10", "1.5E+10"),
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
