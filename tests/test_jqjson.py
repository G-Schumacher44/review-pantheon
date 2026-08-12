"""tests/test_jqjson.py — pytest unit layer for pantheon.jqjson's own matrix (this port's
slice-4 deliverable: "pytest unit layer for the jqjson matrix + pure-function
seams ONLY — no 1:1 duplication of the black-box exams").

This module is deliberately NOT a re-run of tests/test-json-boundary.sh (the mechanical
no-bare-json-call assertion) or tests/test-verdict-decision-python.sh /
tests/test-render-comment-python.sh's own regression fixtures for this boundary (both already
cover jqjson's behavior AS OBSERVED THROUGH pantheon.verdict/pantheon.render's decision/render
output). This file tests pantheon.jqjson's own four functions DIRECTLY and in isolation — the
fast, in-process unit layer those black-box subprocess-driven exams can't cheaply be — parametrized
across the exact edge-case matrix this port's slice-5 "JSON boundary" work and this
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
    # on the identical input, the exact divergence this fix closes. Skips (rather than asserting
    # a hardcoded depth must fail) when the live jq's own budget doesn't match this module's
    # pinned _JQ_MAX_PARSE_DEPTH — see this module's own docstring and
    # test_depth_cost_ratio_matches_real_jq_live_bisected below for why a dev box's jq build can
    # legitimately disagree with this repo's CI-pinned constant on the ABSOLUTE number while still
    # agreeing on the algorithm.
    import shutil
    import subprocess

    jq_bin = shutil.which("jq")
    if jq_bin is None:
        pytest.skip("jq not installed in this environment — cannot cross-check live")

    deep = _nested_array_json(300)
    result = subprocess.run([jq_bin, "-c", "."], input=deep, capture_output=True, text=True)
    if result.returncode == 0:
        pytest.skip(
            "this jq build's own array-nesting budget is deeper than 300 levels (a newer jq "
            "than this repo's CI-pinned jq-1.7 — see test_depth_cost_ratio_matches_real_jq_live_"
            "bisected for the build-agnostic ratio proof instead)"
        )
    assert "depth limit" in result.stderr.lower()

    with pytest.raises(jqjson.JqParseError, match="depth limit"):
        jqjson.loads(deep)


# ---------------------------------------------------------------------------------------------
# Object/array depth-COST parity (issue #26 P1) — jq's own recursive-descent parser does not
# spend the same share of its parse-depth budget per bracket TYPE: entering an object recurses
# once for the object's own frame and again to parse that key's value, while an array level costs
# a single frame — so a ~129-level-deep PURE OBJECT document (`{"a":{"a":{...}}}`) passed this
# module's pre-fix flat 1-unit-per-bracket scanner (129 < 256) while real jq already rejects it.
# _JQ_OBJECT_DEPTH_COST/_JQ_ARRAY_DEPTH_COST fix this; these tests are the direct, in-process
# proof of the ratio, plus a live cross-check against the actual jq binary when one is present —
# bisected rather than hardcoded to one jq version's own absolute cap, since that cap (256 vs.
# jq-1.7's shipped value, confirmed against a real jq-1.8.2 build to differ) is not itself the
# invariant under test; the OBJECT:ARRAY COST RATIO is.
# ---------------------------------------------------------------------------------------------


def _nested_object_json(depth: int) -> str:
    return '{"a":' * depth + "1" + "}" * depth


def test_loads_object_only_nesting_cap_is_half_the_array_only_cap() -> None:
    # _JQ_MAX_PARSE_DEPTH (256) is spent at _JQ_ARRAY_DEPTH_COST (1) per array level and
    # _JQ_OBJECT_DEPTH_COST (2) per object level — so the deepest OBJECT-only document this
    # module still accepts is exactly half the deepest ARRAY-only document it accepts.
    from pantheon.jqjson import _JQ_MAX_PARSE_DEPTH, _JQ_OBJECT_DEPTH_COST

    object_cap = _JQ_MAX_PARSE_DEPTH // _JQ_OBJECT_DEPTH_COST
    jqjson.loads(_nested_object_json(object_cap))  # must not raise
    with pytest.raises(jqjson.JqParseError, match="depth limit"):
        jqjson.loads(_nested_object_json(object_cap + 1))


def test_loads_rejects_a_129_level_object_nesting_that_the_pre_fix_flat_scanner_accepted() -> None:
    # The exact reproduction shape from issue #26's own report: a ~129-object-deep document. A
    # flat 1-unit-per-bracket scanner (129 < 256) would accept this; the weighted scanner (129 *
    # _JQ_OBJECT_DEPTH_COST(2) = 258 > 256) correctly refuses it, matching real jq.
    with pytest.raises(jqjson.JqParseError, match="depth limit"):
        jqjson.loads(_nested_object_json(129))


# Shared live-jq bisection helpers — one copy, used by BOTH live-bisection cross-checks below (the
# pure object:array ratio test and issue #30's mixed-nesting additivity test). Factored out rather
# than duplicated per test so a future change to the jq invocation (the timeout below was added
# exactly this way) lands in one place instead of silently diverging between two copies.
def _require_jq() -> str:
    """The jq binary path, or a loud skip when jq is absent — the shared front door every live
    cross-check against a real jq binary goes through."""
    import shutil

    jq_bin = shutil.which("jq")
    if jq_bin is None:
        pytest.skip("jq not installed in this environment — cannot cross-check live")
    return jq_bin


def _jq_accepts(jq_bin: str, doc: str) -> bool:
    import subprocess

    # timeout bounds a hung/misbehaving jq so a live-bisection test can never block the suite
    # indefinitely — generous (30s) since a single parse of even a 20000-deep document is instant.
    result = subprocess.run([jq_bin, "-c", "."], input=doc, capture_output=True, text=True, timeout=30)
    return result.returncode == 0


def _bisect_last_ok(jq_bin: str, builder, lo_ok: int, hi_fail: int) -> int:
    # Largest N in (lo_ok, hi_fail) real jq still accepts builder(N) for — assumes builder is
    # monotonic (accepted below the boundary, refused at/above it), which every nesting builder is.
    while hi_fail - lo_ok > 1:
        mid = (lo_ok + hi_fail) // 2
        if _jq_accepts(jq_bin, builder(mid)):
            lo_ok = mid
        else:
            hi_fail = mid
    return lo_ok


def test_depth_cost_ratio_matches_real_jq_live_bisected() -> None:
    # Live, bisected cross-check against the actual jq binary — deliberately does NOT assume any
    # one absolute cap (jq-1.7 vs. a newer jq build can differ there; confirmed live: jq-1.7 in
    # this repo's own Dockerfile.smoke Ubuntu 24.04 image caps pure array nesting at exactly 256
    # and pure object nesting at exactly 128 — a 2:1 ratio; a local jq-1.8.2 build caps them at
    # 10000/5000 respectively — same 2:1 ratio, different absolute budget). What this module's
    # own cost weighting must match is the RATIO, not any one jq version's own absolute number.
    jq_bin = _require_jq()

    # Upper bisection bound large enough for a generous real-world jq build (verified live up to
    # 20000 against jq-1.8.2 during this fix's own investigation) without being so large the
    # bisection itself becomes slow.
    array_cap = _bisect_last_ok(jq_bin, _nested_array_json, 1, 20000)
    object_cap = _bisect_last_ok(jq_bin, _nested_object_json, 1, 20000)

    assert array_cap >= 2, f"suspiciously shallow real-jq array cap ({array_cap}) — is jq actually installed correctly?"
    # The 2:1 ratio itself is what this module's _JQ_OBJECT_DEPTH_COST/_JQ_ARRAY_DEPTH_COST encode
    # — assert it holds against whatever jq build is actually present, not a hardcoded number.
    # (Confirmed live, this fix's own investigation: jq-1.7 in this repo's Dockerfile.smoke image
    # -> 256/128; a local jq-1.8.2 build -> 10000/5000 — different absolute budgets, same ratio.)
    assert object_cap == array_cap // 2, (
        f"real jq's object-only cap ({object_cap}) is not half its array-only cap ({array_cap}) "
        "on this jq build — the 2:1 cost ratio this module's weighting assumes may not hold here"
    )

    # This module's OWN absolute cap (_JQ_MAX_PARSE_DEPTH = 256) is pinned to this repo's actual
    # CI jq (jq-1.7, Dockerfile.smoke's Ubuntu 24.04 image — verified live, matches array_cap ==
    # 256 exactly), not to whatever jq build happens to be on the machine running this test — a
    # dev box's newer jq (this fix's own local jq-1.8.2, budget 10000) genuinely disagrees on the
    # ABSOLUTE number, by design (see this module's own docstring on _JQ_MAX_PARSE_DEPTH). Only
    # cross-check the boundary directly when the live jq's own budget happens to match this
    # module's pinned constant.
    if array_cap == jqjson._JQ_MAX_PARSE_DEPTH:
        jqjson.loads(_nested_array_json(array_cap))
        with pytest.raises(jqjson.JqParseError, match="depth limit"):
            jqjson.loads(_nested_array_json(array_cap + 1))
        jqjson.loads(_nested_object_json(object_cap))
        with pytest.raises(jqjson.JqParseError, match="depth limit"):
            jqjson.loads(_nested_object_json(object_cap + 1))


# ---------------------------------------------------------------------------------------------
# MIXED object/array depth-cost parity (issue #30) — the pure-case work above (issue #26 P1)
# pinned jq's 2:1 object:array per-level cost live-bisected ONLY for pure-object and pure-array
# nesting; it left the ADDITIVITY of that model across MIXED documents (`{"a":[{"b":[...]}]}`
# shapes) asserted-by-construction in _check_depth_limit's own running-sum scanner but never
# pinned against a real jq binary. This section closes that coverage hole. Live-bisected against
# a real jq binary during this fix (jq-1.8.2, budget 10000/5000; the additive prediction matched
# jq's actual mixed boundary EXACTLY on every pattern):
#
#     pattern         repeating unit          unit cost (2·objs + 1·arrs)   jq cap      predicted
#     alt obj-outer   {"a":[ ... ]}           2+1 = 3                       3333        10000//3
#     alt arr-outer   [{"a": ... }]           2+1 = 3                       3333        10000//3
#     object-heavy    {"a":{"b":[ ... ]}}     2+2+1 = 5                     2000        10000//5
#     array-heavy     [[{"a": ... }]]         2+1+1 = 4                     2500        10000//4
#
# So jq charges mixed nesting the SAME additive per-level cost as pure nesting: the parse-depth
# budget consumed at the deepest point is exactly the sum of each enclosing bracket's own weight
# along that path — NO cross-type interaction, no different accounting when the types alternate.
# The model in pantheon.jqjson already matches; these fixtures pin it so the additivity claim
# fails loudly if _check_depth_limit ever drifts (verified as a genuine failure via a negative
# control — an off-by-one in either per-bracket cost breaks the exact-boundary assertions below).
# ---------------------------------------------------------------------------------------------


def _mixed_alt_obj_outer(units: int) -> str:
    # Alternating object-then-array, object outermost: `{"a":[{"a":[ ... ]}]}`. Each unit is one
    # object level (cost 2) wrapping one array level (cost 1) — additive cost 3 per unit.
    return '{"a":[' * units + "1" + "]}" * units


def _mixed_alt_arr_outer(units: int) -> str:
    # Same alternation, array outermost: `[{"a":[{"a": ... }]}]`. Additive cost 3 per unit — the
    # outer/inner ordering must not change the total, since additivity has no cross-type term.
    return '[{"a":' * units + "1" + "}]" * units


def _mixed_object_heavy(units: int) -> str:
    # Two object levels per one array level: `{"a":{"b":[ ... ]}}`. Additive cost 2+2+1 = 5.
    return '{"a":{"b":[' * units + "1" + "]}}" * units


def _mixed_array_heavy(units: int) -> str:
    # Two array levels per one object level: `[[{"a": ... }]]`. Additive cost 1+1+2 = 4.
    return '[[{"a":' * units + "1" + "}]]" * units


# (builder, additive unit cost in jq budget units) — the cost each repeating unit spends, derived
# purely from this module's own _JQ_OBJECT_DEPTH_COST/_JQ_ARRAY_DEPTH_COST weights, NOT hardcoded.
def _mixed_patterns() -> list:
    from pantheon.jqjson import _JQ_ARRAY_DEPTH_COST as A
    from pantheon.jqjson import _JQ_OBJECT_DEPTH_COST as O

    return [
        ("alt_obj_outer", _mixed_alt_obj_outer, O + A),
        ("alt_arr_outer", _mixed_alt_arr_outer, O + A),
        ("object_heavy", _mixed_object_heavy, 2 * O + A),
        ("array_heavy", _mixed_array_heavy, O + 2 * A),
    ]


def test_mixed_nesting_depth_cost_is_additive_in_process() -> None:
    # Version-INDEPENDENT: pins _check_depth_limit's own boundary for each mixed pattern against
    # the additive prediction (budget // unit_cost), at this module's own fixed _JQ_MAX_PARSE_DEPTH
    # (256). This is the fixture the issue asked for: it fails if the running-sum scanner ever
    # stops treating mixed nesting as the plain sum of per-bracket costs along the deepest path.
    from pantheon.jqjson import _JQ_MAX_PARSE_DEPTH as CAP

    for _name, builder, unit_cost in _mixed_patterns():
        predicted_cap = CAP // unit_cost
        # Deepest document still accepted: exactly predicted_cap units.
        jqjson.loads(builder(predicted_cap))  # must not raise
        # One unit past the additive boundary must be refused — same rc=5 class as pure nesting.
        with pytest.raises(jqjson.JqParseError, match="depth limit"):
            jqjson.loads(builder(predicted_cap + 1))


def test_mixed_nesting_depth_cost_matches_real_jq_live_bisected() -> None:
    # Live, bisected cross-check against the actual jq binary — the empirical half of issue #30's
    # deliverable. Mirrors test_depth_cost_ratio_matches_real_jq_live_bisected exactly: bisect real
    # jq's own boundary for each mixed pattern, and assert it matches the ADDITIVE prediction
    # derived from real jq's OWN pure-array budget (never a hardcoded absolute, so it holds across
    # jq builds — jq-1.7 caps array nesting at 256, a local jq-1.8.2 at 10000, both additive).
    jq_bin = _require_jq()

    # Real jq's own per-level budget in ARRAY units (1 unit per array level), bisected live — the
    # denominator the additive prediction divides by. Upper bound generous for a large jq build
    # (verified live to 20000 on jq-1.8.2) without making the bisection slow.
    budget = _bisect_last_ok(jq_bin, _nested_array_json, 1, 20000)
    assert budget >= 6, f"suspiciously shallow real-jq array budget ({budget}) — is jq actually installed correctly?"

    for name, builder, unit_cost in _mixed_patterns():
        jq_cap = _bisect_last_ok(jq_bin, builder, 1, budget + 1)
        predicted = budget // unit_cost
        assert jq_cap == predicted, (
            f"real jq's mixed-nesting cap for {name} ({jq_cap}) does not match the additive "
            f"prediction (budget {budget} // unit_cost {unit_cost} = {predicted}) — jq charges "
            "mixed nesting DIFFERENTLY from the sum of its pure per-bracket costs on this jq build"
        )

    # When the live jq's own budget happens to match this module's pinned constant (jq-1.7 in CI),
    # also cross-check this module's OWN boundary directly against the live one — the same
    # conditional the pure-case bisection test uses (a newer dev-box jq legitimately disagrees on
    # the ABSOLUTE number while agreeing on the additive algorithm).
    if budget == jqjson._JQ_MAX_PARSE_DEPTH:
        for _name, builder, unit_cost in _mixed_patterns():
            cap = budget // unit_cost
            jqjson.loads(builder(cap))
            with pytest.raises(jqjson.JqParseError, match="depth limit"):
                jqjson.loads(builder(cap + 1))


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
