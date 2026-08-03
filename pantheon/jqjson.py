"""pantheon.jqjson — the single jq-compatible JSON parse/serialize boundary.

Three straight review-gate rounds on docs/PYTHON-PORT.md's Slice 2 (pantheon/verdict.py,
pantheon/render.py) found real, reproducible divergences between Python's ``json`` module and
real jq, one instance at a time: a JSON boolean stringifying as Python's Title-case ``True``
instead of jq's lowercase ``true``; the non-standard ``NaN``/``Infinity``/``-Infinity`` JSON-
extension tokens surviving as literal Python floats instead of jq's own coercion; a lone UTF-16
surrogate that real jq rejects at parse time but ``json.loads`` accepts; a >4300-digit integer
raising a bare ``ValueError`` (Python 3.11+'s int-string-conversion digit limit, not
``json.JSONDecodeError``) that an ``except json.JSONDecodeError`` guard doesn't catch; a numeric
literal like ``1e400`` that overflows Python's IEEE double to ``inf`` while jq's own arbitrary-
precision number handling keeps it as the literal (canonicalized) number ``1E+400``.

Patching each of these as a one-off, once found, is exactly the anti-pattern that produced three
rounds of the same class of finding — enumerating Python's specific failure-mode vocabulary one
exception type or one non-standard token at a time never converges, because jq's real semantic
for "can I parse this" is simply "anything I can't parse = reject," not a Python-shaped list of
named exception classes. This module is the structural fix: the ONE place every JSON parse and
every JSON serialize in this port goes through, so this port's own tests can assert — mechanically,
not by review — that no other file reaches past it to call ``json.loads``/``json.dumps`` directly.

This module owns TWO boundaries, not just one — a fourth review round found the first three
fixes (constant coercion, UTF-8 validity, overflow-number preservation) closed the JSON
TEXT<->Python-VALUE boundary, but left a second, related boundary wide open: Python-VALUE-to-
DISPLAY-TEXT. Real jq's ``-r`` (raw-output) stringification of a parsed scalar (``null`` ->
``"null"``, a boolean -> its lowercase spelling, a number via jq's own formatting) is not the
same operation as Python's default ``str()``/f-string interpolation of that same value (``None``
-> the literal text ``"None"``, ``True`` -> ``"True"``, a dict -> its Python ``repr()``) — and
every jq extraction bash's own runtime ever performs happens inside a ``$(...)`` command
substitution, which strips ALL trailing newlines from whatever text results, a plain-bash
semantic with nothing to do with jq itself. Four functions, not two:

  loads(text)                                    -> a Python value, jq-parse-compatible
  dumps(obj, *, indent=None, ensure_ascii=False)  -> str, jq-serialize-compatible
  jq_text(value)                                  -> str, jq -r's raw-output stringification
  subst(text)                                     -> str, bash's $(...) trailing-newline strip

``loads`` raises exactly one exception type, :class:`JqParseError`, for ANY failure — parse
error, a non-standard-constant edge case, a digit-limit overflow, a lone surrogate, a stack
depth limit, anything — never a Python-specific exception type a caller might reasonably not
know to catch. Every caller (``pantheon.verdict``'s ``decide()``, ``pantheon.render``'s
``_agent_data_from_env``/``_machine_tail_text``) treats a caught :class:`JqParseError` exactly
the way it already treated ``json.JSONDecodeError`` before this module existed: fail closed —
UNVERIFIED for a decision, ``{}``/raw-text-fallback for a display value.

``jq_text``/``subst`` close the second boundary the same way: every place either module
interpolates a parsed JSON scalar into human-readable text goes through ``jq_text`` instead of
a bare f-string/``str()``; every place a caller's bash counterpart captured a jq extraction via
``$(...)`` before an emptiness check or final interpolation applies ``subst`` to the result —
``tests/test-json-boundary.sh`` extends its mechanical assertion to cover both.
"""

from __future__ import annotations

import json
import re
import secrets
from decimal import Decimal
from typing import Any

__all__ = ["JqParseError", "JqNaN", "loads", "dumps", "jq_text", "subst"]


class JqParseError(Exception):
    """The one exception :func:`loads` ever raises. Deliberately a single, catch-all type — see
    this module's docstring for why enumerating Python's specific failure-mode vocabulary
    (``json.JSONDecodeError`` for a syntax error, a bare ``ValueError`` for an integer past
    Python's digit-conversion limit, a ``UnicodeEncodeError``-shaped rejection for a lone
    surrogate, a ``RecursionError`` for pathological nesting depth, ...) is the anti-pattern this
    module exists to close, not a list to keep growing. The original Python exception, if any,
    is chained via ``raise ... from e`` — available to a caller that wants it for logging, never
    required for correct fail-closed behavior."""


class JqNaN:
    """Sentinel for jq's own NaN handling — deliberately NOT Python's ``None``. jq's parser
    accepts the non-standard ``NaN`` JSON-extension token (same as Python's ``json`` module) but
    represents it internally as a value that always PRINTS as the text ``null`` wherever jq
    finally serializes/interpolates it (a jq-implementation quirk — NaN has no representable
    value in JSON's own number grammar), while critically NOT behaving like an actual JSON null
    for jq's own truthiness/``//`` (alternative) operator — verified live against real jq:
    ``echo '{"summary":NaN}' | jq -r '.summary // empty'`` prints the text ``null`` (proof ``//``
    did NOT fire; a genuine null there would print nothing at all, since null is one of the two
    falsy values ``//`` checks). Mapping jq's NaN to Python's actual ``None`` would get this
    backwards: a caller's own ``// default``-equivalent fallback logic (e.g.
    ``pantheon.render``'s ``_or_default``) already, correctly, treats a real ``None`` as
    "substitute the default" — exactly the behavior a genuine JSON null gets in jq, and exactly
    the behavior jq's own NaN handling does NOT get.

    This sentinel's ``__str__``/``__repr__`` return ``"null"`` — matching jq's print form
    wherever a caller stringifies a value via ordinary ``str()``/f-string interpolation (e.g.
    ``pantheon.verdict``'s ``top_finding_of``) — while remaining a distinct, non-``None``,
    non-``False`` object everywhere else, so a caller's own identity/type checks (``is None``,
    ``isinstance(x, str)``, jq-``//``-equivalent truthiness) see it exactly as jq's own type
    system would.

    A singleton — use the pre-built :data:`NAN` instance, never construct a second one; every
    check in this module and its callers that matters (``is _JQ_NAN`` style identity checks)
    relies on there being exactly one."""

    __slots__ = ()

    def __repr__(self) -> str:
        return "null"

    def __str__(self) -> str:
        return "null"


NAN = JqNaN()

# Wraps every dumps()-generated placeholder token (see _prepare_for_dump) on both sides --
# code points no legitimate model output or file content this port parses is expected to
# contain, belt-and-braces on top of the token's own salt-derived collision-freedom guarantee
# (_generate_dump_salt). A module-level chr(0xE000) constant, not a literal character embedded
# in source, so this file's own bytes stay unambiguous in any editor/diff tool regardless of
# how it renders an invisible Private-Use-Area code point.
_PUA_WRAP = chr(0xE000)

# jq's max/min IEEE-754 double — what jq's parser coerces the non-standard Infinity/-Infinity
# JSON-extension TOKENS to (verified live against real jq: 1.7.1 local, 1.7 in the exact Ubuntu
# 24.04/Dockerfile.smoke CI environment). An ordinary, truthy JSON number in jq's own type
# system, unlike NaN — a plain Python float is the correct, direct equivalent, no sentinel
# needed for these two.
_JQ_MAX_DOUBLE = 1.7976931348623157e308


class _RawBigNumber(str):
    """A JSON number literal whose magnitude overflows Python's IEEE double — ``float()`` would
    silently give ``+-inf``, losing the original value entirely — preserved as jq's own
    canonicalized print text instead. jq's number handling is arbitrary-precision decimal (its
    ``decNumber``-based number type), not IEEE double: verified live against real jq, a literal
    like ``1e400`` prints back out as ``1E+400`` (uppercase E, explicit ``+`` on the exponent,
    mantissa digits preserved as given) — genuinely a different, still-finite number, not
    ``+Infinity``. A plain, un-exponent-notation huge integer (e.g. 400 digits typed out longhand,
    no ``e``/``E``) is preserved byte-for-byte verbatim, no canonicalization needed — jq keeps
    those as-is too.

    Behaves as an ordinary ``str`` everywhere in a caller's own display logic (a ``str``
    subclass) — this class only needs special handling in :func:`dumps`, so its raw numeral text
    can be spliced back in UNQUOTED rather than re-serialized as a quoted JSON string."""

    __slots__ = ()


def _canonicalize_number_text(text: str) -> str:
    """jq's own canonical print form for a number preserved as raw text (whether because its
    magnitude overflowed a double's representable range, or because a double simply can't
    represent it exactly — see :func:`_parse_float`).

    Routes through ``decimal.Decimal``'s own ``__str__`` — NOT a hand-rolled regex-based
    canonicalizer (an earlier version of this function was exactly that: preserve the mantissa
    verbatim, only reformat the exponent's case/sign). That earlier version was WRONG for a real
    class of input, caught live by this repo's own self-hosted gate: jq's number type is the
    General Decimal Arithmetic specification's decimal (``decNumber`` in C, the same spec
    Python's ``decimal`` module implements), and that spec's "to-scientific-string" conversion
    does NOT simply preserve the source mantissa — it renormalizes it, and it sometimes prints
    PLAIN decimal notation instead of scientific at all, based on the number's ADJUSTED EXPONENT
    (``exponent + len(coefficient_digits) - 1``): plain notation when the exponent is <=0 and the
    adjusted exponent is >=-6, scientific otherwise. Verified live against real jq (jq-1.7.1) for
    the exact cases that exposed the old regex-only approach's gap: ``1e-01`` prints ``0.1`` (not
    ``1E-1``), ``10e-1`` prints ``1.0`` (not ``10E-1``), ``1.2300e+02`` prints ``123.00`` (not
    ``1.2300E+2``), ``10e2`` prints ``1.0E+3`` (mantissa RENORMALIZED from "10" to "1.0", exponent
    shifted from 2 to 3 — not "10E+2"), while ``1e2``/``1.0e2``/``1e20``/``1.5e3``/``2e-7`` still
    print in scientific form as before. Python's ``decimal.Decimal(text)`` constructor preserves
    ``text``'s exact value (no precision loss, no context-precision rounding — that only applies
    to ARITHMETIC results, never to construction-from-string or to ``str()`` of the constructed
    value), and its ``__str__`` implements this exact same General-Decimal-Arithmetic
    to-scientific-string algorithm — confirmed to match every case above, byte for byte, so this
    function is now a thin wrapper rather than a second, independently-maintained
    reimplementation of a spec Python's stdlib already gets right."""
    return str(Decimal(text))


def _parse_constant(name: str) -> Any:
    """``json.loads``'s ``parse_constant`` hook — see :class:`JqNaN` for the NaN case; Infinity/
    -Infinity coerce directly to jq's max/min double (see ``_JQ_MAX_DOUBLE`` above)."""
    if name == "NaN":
        return NAN
    if name == "Infinity":
        return _JQ_MAX_DOUBLE
    if name == "-Infinity":
        return -_JQ_MAX_DOUBLE
    raise ValueError(f"unexpected JSON constant: {name}")  # pragma: no cover — json's own grammar


def _parse_float(text: str) -> Any:
    """``json.loads``'s ``parse_float`` hook. jq's own number handling is arbitrary-precision
    decimal (its ``decNumber``-based number type), not IEEE double — verified live against real
    jq: a magnitude that overflows a double's representable range (``1e400`` -> Python's bare
    ``float()`` silently gives ``+inf``) prints back as the still-finite, exact ``1E+400``; a
    magnitude too SMALL to represent (``1e-400`` -> Python's bare ``float()`` silently
    UNDERFLOWS to ``0.0``) prints back as the still-nonzero, exact ``1E-400``; a literal with more
    significant digits than a double can hold exactly (``1.234567890123456789``, 19 significant
    digits — a double has roughly 17) prints back completely unchanged, digit for digit, where
    Python's own float round-trip would silently round it to ``1.2345678901234567``; and — a gap
    in an earlier version of this function, issue #19's "preserve jq formatting for representable
    decimals" item — a literal whose VALUE round-trips through ``float()`` exactly fine but whose
    SURFACE TEXT doesn't (trailing zeros: ``1.50``, ``0.10``, ``2.00``, ``3.140`` — verified live
    against real jq, which preserves every one of these byte-for-byte, never normalizing away a
    trailing zero the way Python's ``repr(float("1.50"))`` ("1.5") silently does). jq never lost
    fidelity converting the literal to a fixed-precision binary float in the first place, because
    it never converts at all — every one of these gets the identical fix: preserve the exact
    source text (canonicalized only for exponent notation — see :func:`_canonicalize_number_text`)
    as a :class:`_RawBigNumber` instead of the lossy ``float()`` value, whenever ``float()``'s own
    canonical text form does NOT byte-for-byte match the (exponent-canonicalized) source text.

    "Does not byte-for-byte match" is a TEXT comparison, not a decimal-VALUE comparison — an
    even earlier version of this function compared :class:`decimal.Decimal` VALUES instead
    (``Decimal(text) != Decimal(repr(value))``), which is exactly why the trailing-zero class
    above slipped through: ``Decimal("1.50") == Decimal("1.5")`` is ``True`` (equal as VALUES),
    even though jq's own printed TEXT for the two differs. Comparing
    :func:`_canonicalize_number_text`'s output against ``repr(value)`` directly (both plain
    strings) strictly subsumes what the value-based check caught (an overflow, or a literal with
    more significant digits than a double preserves, still produces two different strings here
    too) while ALSO catching the trailing-zero/formatting-only class the value-based check was
    blind to. An ordinary literal whose canonical text already matches Python's own ``repr()``
    (e.g. ``0.1`` -> ``repr(0.1) == "0.1"``, ``100.0`` -> ``repr(100.0) == "100.0"``, both
    confirmed live against real jq's identical output) is completely unaffected: this only ever
    fires for a literal where the two texts genuinely diverge. No separate inf/-inf special case
    is needed here (an earlier version had one): ``repr(float("1e400"))`` is the text ``"inf"``,
    which never equals ``_canonicalize_number_text``'s always-finite output, so an overflowing
    literal already falls into the general "texts diverge -> preserve" branch on its own."""
    value = float(text)
    canonical = _canonicalize_number_text(text)
    if canonical != repr(value):
        return _RawBigNumber(canonical)
    return value


_JQ_MAX_PARSE_DEPTH = 256

# jq's own parser does NOT spend one depth-budget "unit" per bracket uniformly — issue #26 P1
# (fresh evidence on top of the finding that first produced _JQ_MAX_PARSE_DEPTH): a document
# ~129 levels deep of PURE OBJECT nesting (`{"a":{"a":{...}}}`) parsed clean through this
# module's pre-fix scanner (129 < 256) while real jq REJECTS it — jq's recursive-descent parser
# recurses once to enter an object's own frame and AGAIN to parse that key's value, so each
# object level spends 2 units of jq's shared parse-depth budget; an array level spends only 1
# (jq's array-value recursion is a single frame). Verified live, bisected exactly against a real
# jq binary: pure `[`-nesting parses cleanly up to depth D and fails at D+1; pure `{"a":`-nesting
# parses cleanly up to exactly D/2 and fails at D/2 + 1 -- confirmed on two different jq builds
# (jq-1.8.2, where D=10000) with the identical 2:1 ratio holding both times, which is what
# license this port to treat the ratio as a stable property of jq's OWN parser structure rather
# than a version-specific coincidence. This repo's own CI runs jq-1.7.1 (Ubuntu 24.04's apt
# package, Dockerfile.smoke) -- the PRE-existing `_JQ_MAX_PARSE_DEPTH = 256` constant was already
# verified live against that exact binary for ARRAY-only nesting (a 300-level `[`-nesting
# document fails, matching a budget of 256 array units); this fix keeps that constant AND that
# verification UNCHANGED, and adds the missing per-bracket-type WEIGHT on top of it, so an
# object-only document's own effective cap becomes 256 / 2 = 128 -- exactly matching the ~129
# reproduction that exposed this gap.
_JQ_OBJECT_DEPTH_COST = 2
_JQ_ARRAY_DEPTH_COST = 1


def _check_depth_limit(text: str) -> None:
    """Raises :class:`JqParseError` if `text` contains object/array nesting deep enough to exceed
    jq's own shared parse-depth budget (:data:`_JQ_MAX_PARSE_DEPTH`), weighting each `{` as
    :data:`_JQ_OBJECT_DEPTH_COST` and each `[` as :data:`_JQ_ARRAY_DEPTH_COST` -- see this
    constant's own comment for the live bisection proving that 2:1 ratio. Tracks depth
    character-by-character, skipping the CONTENTS of JSON string literals (respecting `\\"`
    escapes) so a string value that merely CONTAINS many `{`/`[` characters as literal text never
    counts toward nesting depth -- only real structural nesting does. Deliberately independent of
    :func:`loads`'s own `json.loads` call: this scan raises (or doesn't) entirely on its own, and
    is *always* run before `json.loads` ever sees the text, so a pathologically deep document
    never reaches the stdlib parser at all in either the success or failure case."""
    depth = 0
    in_string = False
    escaped = False
    for ch in text:
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += _JQ_OBJECT_DEPTH_COST
            if depth > _JQ_MAX_PARSE_DEPTH:
                raise JqParseError(
                    f"Exceeds depth limit for parsing (jq's own shared parse-depth budget is "
                    f"{_JQ_MAX_PARSE_DEPTH} units, verified live against real jq: rc=5, 'Exceeds "
                    f"depth limit for parsing'; each '{{' costs {_JQ_OBJECT_DEPTH_COST} units)"
                )
        elif ch == "[":
            depth += _JQ_ARRAY_DEPTH_COST
            if depth > _JQ_MAX_PARSE_DEPTH:
                raise JqParseError(
                    f"Exceeds depth limit for parsing (jq's own shared parse-depth budget is "
                    f"{_JQ_MAX_PARSE_DEPTH} units, verified live against real jq: rc=5, 'Exceeds "
                    f"depth limit for parsing'; each '[' costs {_JQ_ARRAY_DEPTH_COST} unit)"
                )
        elif ch == "}":
            depth -= _JQ_OBJECT_DEPTH_COST
        elif ch == "]":
            depth -= _JQ_ARRAY_DEPTH_COST


def _verify_utf8(value: Any) -> None:
    """Recursively verifies every string in a parsed value tree encodes to strict UTF-8 — a
    lone (unpaired) UTF-16 surrogate code point (reachable via a JSON ``\\ud800``-style escape)
    parses successfully at the ``json.loads`` layer (Python accepts it as a valid, if unusual,
    Unicode string) but is NOT a standalone-valid Unicode scalar value, and real jq rejects it at
    parse time — verified live: bash's own ``extract_last_json``/``_pantheon_single_json``
    returns an EMPTY candidate for a verdict object containing one (jq's parser fails on it), the
    same "no parseable JSON object found" outcome as any other malformed input. Left unhandled,
    Python's more permissive acceptance let a lone surrogate in an unvalidated display field
    (e.g. ``summary``) reach a GREEN decision where bash's real pipeline would have already
    failed closed to UNVERIFIED before ever reaching the vocabulary lookup — a genuine decision-
    color divergence, not just a display-text one. Raises the same :class:`JqParseError` any
    other parse failure would, keeping the boundary a single failure type throughout."""
    if isinstance(value, str):
        value.encode("utf-8", errors="strict")
    elif isinstance(value, dict):
        for k, v in value.items():
            _verify_utf8(k)
            _verify_utf8(v)
    elif isinstance(value, list):
        for v in value:
            _verify_utf8(v)


def jq_text(value: Any) -> str:
    """jq -r's raw-output stringification of a parsed JSON scalar — the DISPLAY-TEXT half of
    this module's boundary, not the parse/serialize half. jq's ``-r`` mode prints a string
    unquoted, a JSON boolean as its own lowercase spelling (``true``/``false``), a JSON ``null``
    as the literal text ``null``, and any number (including a :class:`_RawBigNumber`-preserved
    overflow literal or the :data:`NAN` sentinel — verified live to already print as ``null``
    via its own ``__str__``) via this module's own :func:`dumps` — one source, so any future
    dumps-side jq-compat fix (a new overflow shape, say) applies to display text automatically
    too, rather than needing a second copy of the same judgment call.

    Python's own default stringification of these same values diverges in exactly the ways this
    port's own gate found live: ``str(None) == "None"`` (not jq's ``"null"``),
    ``str(True) == "True"`` (not jq's ``"true"``), ``str({"x": 1}) == "{'x': 1}"`` (Python
    ``repr``-style single quotes, not JSON's double-quoted, jq-pretty-printed form). Every place
    either ``pantheon.verdict`` or ``pantheon.render`` interpolates a parsed JSON scalar into
    human-readable text — a finding's severity/file/line/issue/scenario, a verdict's summary —
    routes through this function instead of a bare f-string/``str()`` call; a caller-constructed
    Python string that ISN'T sourced from parsed JSON (e.g. this port's own literal prose) never
    needs to."""
    if isinstance(value, str):
        return value
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is NAN:
        return str(value)
    # Numbers (plain int/float, or a _RawBigNumber-preserved overflow literal) and containers
    # (dict/list) all route through this module's own dumps() — one source for jq-compatible
    # number/overflow formatting, matching jq -r's own fallback for a non-string value: for
    # anything that isn't a string, -r mode falls back to jq's DEFAULT pretty-printer (2-space
    # indent, raw UTF-8) — verified live, not jq's compact form and not a bare str()/repr().
    return dumps(value, indent=2, ensure_ascii=False)


def subst(text: str) -> str:
    """bash's ``$(...)`` command-substitution semantics — TWO effects, both applied here, both
    with nothing to do with jq itself (they're plain-bash properties of capturing a subprocess's
    stdout this way):

      1. ALL trailing newlines are stripped (POSIX/bash's own documented ``$(...)`` behavior).
      2. Every NUL byte anywhere in the captured text is dropped, not just trailing ones — bash
         represents its variables as C strings internally and simply cannot hold a NUL at all;
         verified live (bash itself prints "ignored null byte in input" the moment a NUL reaches
         a command substitution). Critically, this happens BEFORE bash's own variable holds the
         value at all — meaning it happens before ANY comparison against that variable, not just
         before final display. Caught live on this PR: a severity of ``"blocker\\x00"`` correctly
         matches bash's ``case "blocker" in blocker) ...`` (NUL already gone by comparison time)
         but was still failing this module's own ``==`` comparisons before this fix, because the
         NUL-stripping this module already had (``pantheon.render.sanitize_inline``) only ran at
         final DISPLAY time, after the comparison had already happened and already failed.

    Every jq extraction either runtime's bash implementation ever performs is captured through
    exactly this mechanism (``var="$(jq -r '...' <<<"$json")"``), so a jq-extracted value — or a
    display field this port's own ``jq_text`` stringified — is ALREADY missing its trailing
    newlines AND any embedded NUL by the time bash's own variable holds it, before that variable
    is ever compared (an emptiness check, a vocabulary/severity match) or interpolated again.
    A caller applies this at exactly the sites whose bash counterpart used ``$(...)`` before
    such a check or interpolation — not universally, since plenty of values this port reads (an
    agent's stated ``verdict`` field's OWN identity in some contexts, its ``top`` fallback text)
    come from a bash counterpart that reads an env var DIRECTLY (``${!var:-default}``), never
    through ``$(...)``, and so were never subject to this stripping in the first place. A
    non-``str`` input is returned unchanged — safe to call defensively on a value that might not
    have gone through :func:`jq_text` yet."""
    if not isinstance(text, str):
        return text
    return text.replace("\x00", "").rstrip("\n")


def loads(text: str) -> Any:
    """Parse ``text`` the way jq would: jq-compatible constant coercion (:data:`NAN`,
    Infinity/-Infinity), jq-compatible overflow-number preservation (:class:`_RawBigNumber`),
    and a post-parse UTF-8 validity walk (see :func:`_verify_utf8`) — then, deliberately, a
    catch-ALL: any exception anywhere in that pipeline (a syntax error, the overflow/constant
    hooks above raising, a bare ``ValueError`` from Python 3.11+'s integer-digit-conversion
    limit on a pathologically long integer literal, a lone surrogate failing the UTF-8 walk, a
    ``RecursionError`` on pathological nesting depth, anything at all) becomes exactly one
    :class:`JqParseError`. This is a deliberate design choice, not an oversight: jq's real
    parse-success/parse-failure boundary is not shaped like Python's exception hierarchy, and
    three straight rounds of this repo's own review gate finding one more Python-specific
    failure mode this port's ``except json.JSONDecodeError`` guards didn't catch is the concrete
    proof enumerating that vocabulary doesn't converge. A known, accepted consequence: an input
    jq itself WOULD accept via its own arbitrary-precision integer handling (a >4300-digit
    integer in an unvalidated field, say) still becomes UNVERIFIED here rather than parsing
    through the way bash's pipeline would — a narrow, deliberate crash-safety/simplicity
    trade-off for a pathological-input class no legitimate agent output would ever produce, not
    a decision-parity gap this module tries to close."""
    try:
        _check_depth_limit(text)
        value = json.loads(text, parse_constant=_parse_constant, parse_float=_parse_float)
        _verify_utf8(value)
    except JqParseError:
        # Already the right shape (e.g. _check_depth_limit's own raise) — re-raise unchanged
        # rather than wrapping it a second time through the catch-all below.
        raise
    except Exception as e:  # deliberate catch-all — see this function's own docstring
        raise JqParseError(str(e)) from e
    return value


def _collect_strings(value: Any, out: list) -> None:
    """Recursively collects every string in ``value`` (dict keys included) into ``out`` --
    used by :func:`_generate_dump_salt` to verify a generated placeholder salt collides with
    nothing already present in the tree being serialized, before any token derived from it is
    ever used."""
    if isinstance(value, str):
        out.append(value)
    elif isinstance(value, dict):
        for k, v in value.items():
            _collect_strings(k, out)
            _collect_strings(v, out)
    elif isinstance(value, list):
        for v in value:
            _collect_strings(v, out)


def _generate_dump_salt(existing_strings: list) -> str:
    """Generates ONE per-:func:`dumps`-call salt (128 bits of ``secrets``-module cryptographic
    randomness) that is PROVABLY absent from every string already in the tree -- not merely
    "unlikely to collide". An earlier version of this mechanism (``_make_unique_token``, since
    removed) generated a FRESH random token, independently, per :class:`_RawBigNumber` value,
    checking EACH one against ``existing_strings`` individually -- correct, but a CRITICAL-
    adjacent (medium) finding from an adversarial review caught the cost: with N overflow
    numbers in one payload, that's N separate O(len(existing_strings)) scans, quadratic overall
    (live-reproduced pre-fix: 8000 overflow numbers took ~2.1s, dominated by this collision
    check, not just the splice pass -- see :func:`dumps`'s own docstring for that half of the
    same fix).

    This function closes it structurally: check the SALT for collision-freedom exactly ONCE per
    call, then :func:`_prepare_for_dump` derives every token from ``salt`` plus a cheap
    incrementing counter with NO further collision check needed -- if ``salt`` itself does not
    appear ANYWHERE in ``existing_strings``, no string containing ``salt`` as a substring (which
    is exactly what every derived token is, by construction: ``salt`` is always its prefix) can
    appear there either, so checking the shared prefix once proves every suffix-decorated
    derivative is equally collision-free, without re-checking each one. Since this is a public
    open-source repo, the salt's exact text is readable by anyone, including whoever is crafting
    the untrusted model output this module parses -- a payload that deliberately contains the
    literal placeholder string as genuine content (e.g. an ``.issue`` field equal to a
    placeholder's own text) would otherwise have its own content silently corrupted into an
    unrelated preserved number by :func:`dumps`'s later splice pass, since that pass has no way
    to distinguish "the placeholder I inserted" from "identical text the model happened to
    submit" -- the randomness-plus-verification here is what rules that out, exactly like the
    finding demanded ("use a collision-proof encoding strategy rather than assuming the
    placeholder cannot occur")."""
    while True:
        candidate = secrets.token_hex(16)
        if not any(candidate in s for s in existing_strings):
            return candidate


def _prepare_for_dump(value: Any, raw_registry: dict, salt: str, counter: list) -> Any:
    """Recursively walks ``value``, replacing every :data:`NAN` sentinel with ``None`` (which
    ``json.dumps`` then serializes as ordinary JSON ``null`` -- matching jq's own NaN print form)
    and every :class:`_RawBigNumber` with a unique placeholder token registered in
    ``raw_registry``, so :func:`dumps` can splice the raw numeral text back in UNQUOTED after
    ``json.dumps`` runs (there is no supported way to make the stdlib encoder emit an arbitrary
    unquoted token directly -- the ``default`` hook's return value is itself re-encoded, not
    spliced in raw). Each token is ``salt`` (verified collision-free ONCE by
    :func:`_generate_dump_salt`, never re-checked per token -- see that function's own docstring
    for why that's still a provable guarantee) plus a cheap, per-call-unique hex counter -- O(1)
    per :class:`_RawBigNumber` value, no per-token scan of the tree's other strings. ``counter``
    is a one-element list (a mutable cell every recursive call shares and increments), not a
    plain int, since Python closures/recursive calls can't rebind an outer int in place.
    Identical PUA-wrapping (U+E000, code points no legitimate model output or file content this
    port parses is expected to contain -- belt-and-braces on top of the salt's own
    cryptographic-randomness guarantee) as the earlier per-token mechanism this replaces; see
    :func:`dumps`'s own docstring for how its splice pass accounts for the wrapper's
    ``ensure_ascii``-dependent quoted form."""
    if value is NAN:
        return None
    if isinstance(value, _RawBigNumber):
        counter[0] += 1
        token = f"{_PUA_WRAP}jqjson-raw-{salt}-{counter[0]:x}{_PUA_WRAP}"
        raw_registry[token] = str(value)
        return token
    if isinstance(value, dict):
        return {k: _prepare_for_dump(v, raw_registry, salt, counter) for k, v in value.items()}
    if isinstance(value, list):
        return [_prepare_for_dump(v, raw_registry, salt, counter) for v in value]
    return value


# The hex-digit CORE of a placeholder token (see _prepare_for_dump) -- plain ASCII, quoted
# identically under both `ensure_ascii` modes. `dumps` builds a per-call pattern anchored to that
# call's own SALT (never a fixed, cross-call constant -- the salt itself is what proves
# collision-freedom, so the search pattern must be specific to it), with the counter suffix
# captured as part of a GROUP so `_splice` can reconstruct the exact original token text (PUA
# wrapper included) to look up in `raw_registry`.


def dumps(obj: Any, *, indent: int | None = None, ensure_ascii: bool = False) -> str:
    """Serialize ``obj`` the way jq's own pretty-printer (``indent`` given) or compact printer
    (``indent=None``) would: :data:`NAN`/:class:`_RawBigNumber` sentinels round-trip back to
    their jq-compatible printed form (see :func:`_prepare_for_dump`), and ``allow_nan=False`` is
    always forced — not as the primary fix (a value already went through :func:`loads`'s
    coercion, or a caller-constructed sentinel, by the time it reaches here; there should be no
    raw ``float('nan')``/``float('inf')`` left to encode) but as a deliberate fail-LOUD backstop:
    if one somehow reaches this point anyway (a caller built a tree by hand, bypassing
    :func:`loads` entirely), raising here is strictly safer than silently emitting the invalid,
    non-standard ``NaN``/``Infinity`` token real jq would never produce — the exact class of bug
    this whole module exists to close, not something to risk reintroducing quietly.

    Shape parameters are deliberately limited to ``indent``/``ensure_ascii`` — the two knobs this
    port's actual call sites need (``pantheon.render``'s 2-space/raw-UTF-8 pretty machine tail,
    ``pantheon.verdict``'s compact single-line CLI decision output), not the full
    ``json.dumps`` kwarg surface.

    The placeholder-splice pass (see :func:`_prepare_for_dump`) needs each token's OWN
    properly-escaped quoted form to find it in ``text`` -- a token is
    ``jqjson-raw-<salt>-<counter>`` (see :func:`_prepare_for_dump`'s own docstring for the
    PUA-wrapper rationale), and that wrapper IS non-ASCII, so its escaped form genuinely DIFFERS
    between ``ensure_ascii=True`` (a 6-character escape sequence) and ``ensure_ascii=False`` (raw
    UTF-8 bytes) -- this function can't get away with one hardcoded pattern for both modes the
    way a plain-ASCII-only token could. It resolves that ONE escaped form ONCE per call (a single
    ``json.dumps("", ensure_ascii=ensure_ascii)`` -- cheap, fixed-size, independent of how many
    placeholders exist) and builds ONE regex from it, anchored to THIS call's own salt (never a
    fixed cross-call constant -- the salt is what :func:`_generate_dump_salt` proved
    collision-free), with the counter suffix captured as a group so :func:`_splice` can
    reconstruct each match's original (unescaped) token text to look up in ``raw_registry``,
    regardless of which ``ensure_ascii`` form produced the match text it's looking at.

    **Single-pass splice, not one ``str.replace()`` per placeholder -- a CRITICAL-adjacent
    (medium) finding from an adversarial review, live-reproduced pre-fix: 8000 overflow numbers
    in one payload took ~2.1s to serialize.** An earlier version of this function called
    ``json.dumps(token, ...)`` AND ``text.replace()`` once PER registry entry, each ``replace()``
    call re-scanning the ENTIRE (already-serialized) text from the start -- with N placeholders
    in a text whose own length grows with N, that's O(N) full-text scans of an O(N)-length
    string, quadratic in the number of overflow/big-number values a single verdict payload can
    carry, entirely attacker-influenceable (a hostile agent response, or -- worse -- a hostile
    PR's own crafted content reaching this path via ``pantheon.verdict``'s fail-closed handling
    of arbitrary model output). That earlier version's OWN token-generation step
    (``_make_unique_token``, since removed) was independently quadratic too -- see
    :func:`_generate_dump_salt`'s own docstring for that half of the same fix. The single
    ``.sub()`` call below is ONE linear pass over ``text`` regardless of how many placeholders it
    contains -- each match is resolved via a single dict lookup in ``raw_registry`` (O(1) per
    match, same total work, just done in one pass instead of N passes)."""
    raw_registry: dict = {}
    existing_strings: list = []
    _collect_strings(obj, existing_strings)
    salt = _generate_dump_salt(existing_strings)
    prepared = _prepare_for_dump(obj, raw_registry, salt, [0])
    text = json.dumps(prepared, indent=indent, ensure_ascii=ensure_ascii, allow_nan=False)
    if not raw_registry:
        return text

    pua_escaped = json.dumps(_PUA_WRAP, ensure_ascii=ensure_ascii)[1:-1]  # strip wrapping quotes
    token_core_re = rf"jqjson-raw-{re.escape(salt)}-[0-9a-f]+"
    pattern = re.compile('"' + re.escape(pua_escaped) + f"({token_core_re})" + re.escape(pua_escaped) + '"')

    def _splice(match: re.Match[str]) -> str:
        token = f"{_PUA_WRAP}{match.group(1)}{_PUA_WRAP}"
        return raw_registry.get(token, match.group(0))

    return pattern.sub(_splice, text)
