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


_OVERFLOW_NUMBER_RE = re.compile(r"^(-?(?:0|[1-9]\d*)(?:\.\d+)?)([eE][+-]?\d+)$")


def _canonicalize_overflow_number(text: str) -> str:
    """jq's own canonical print form for a number whose magnitude overflowed Python's IEEE
    double during parsing — verified live against real jq for every case this covers: uppercase
    ``E``, an explicit ``+`` on a positive (or sign-absent) exponent, mantissa digits preserved
    exactly as given. A plain integer/decimal with no exponent notation at all (no ``e``/``E`` in
    the source) is returned unchanged — jq preserves those verbatim too, and this function is
    only ever called on text that already parsed as a syntactically valid JSON number, so the
    only shape needing normalization is the exponent-notation one."""
    m = _OVERFLOW_NUMBER_RE.match(text)
    if not m:
        return text
    mantissa, exponent = m.group(1), m.group(2)
    exp_digits = exponent[1:]  # drop the leading e/E
    if exp_digits[0] not in "+-":
        exp_digits = "+" + exp_digits
    return f"{mantissa}E{exp_digits}"


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
    """``json.loads``'s ``parse_float`` hook — ordinary in-range numbers behave exactly like the
    default (``float(text)``); a magnitude that overflows a double's representable range (e.g.
    ``1e400``) is preserved as a :class:`_RawBigNumber` instead of silently becoming
    ``float('inf')`` (see that class's docstring)."""
    value = float(text)
    if value in (float("inf"), float("-inf")):
        return _RawBigNumber(_canonicalize_overflow_number(text))
    return value


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
    """bash's ``$(...)`` command-substitution semantics: strip trailing newlines from ``text`` —
    ALL of them, not just one, and ONLY newlines (no other trailing whitespace is touched; this
    is POSIX/bash's own documented ``$(...)`` behavior, nothing to do with jq itself). Every jq
    extraction either runtime's bash implementation ever performs is captured through exactly
    this mechanism (``var="$(jq -r '...' <<<"$json")"``), so a jq-extracted value that itself
    ends in a newline — or a display field this port's own ``jq_text`` stringified into text
    ending in one — is ALREADY missing those trailing newlines by the time bash's own variable
    holds it, before that variable is ever compared (an emptiness check) or interpolated again.
    A caller applies this at exactly the sites whose bash counterpart used ``$(...)`` before
    such a check or interpolation — not universally, since plenty of values this port reads
    (an agent's stated ``verdict``, its ``top`` fallback text) come from a bash counterpart that
    reads an env var DIRECTLY (``${!var:-default}``), never through ``$(...)``, and so were never
    subject to this stripping in the first place. A non-``str`` input is returned unchanged —
    safe to call defensively on a value that might not have gone through :func:`jq_text` yet."""
    if not isinstance(text, str):
        return text
    return text.rstrip("\n")


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
        value = json.loads(text, parse_constant=_parse_constant, parse_float=_parse_float)
        _verify_utf8(value)
    except Exception as e:  # deliberate catch-all — see this function's own docstring
        raise JqParseError(str(e)) from e
    return value


def _prepare_for_dump(value: Any, raw_registry: dict) -> Any:
    """Recursively walks ``value``, replacing every :data:`NAN` sentinel with ``None`` (which
    ``json.dumps`` then serializes as ordinary JSON ``null`` — matching jq's own NaN print form)
    and every :class:`_RawBigNumber` with a unique placeholder token registered in
    ``raw_registry``, so :func:`dumps` can splice the raw numeral text back in UNQUOTED after
    ``json.dumps`` runs (there is no supported way to make the stdlib encoder emit an arbitrary
    unquoted token directly — the ``default`` hook's return value is itself re-encoded, not
    spliced in raw). The placeholder uses Private-Use-Area code points (U+E000 range), which
    ``json.dumps(..., ensure_ascii=False)`` never escapes and which no legitimate model output is
    remotely likely to contain, so the later string-replace pass can't collide with real content."""
    if value is NAN:
        return None
    if isinstance(value, _RawBigNumber):
        token = f"jqjson-raw-{len(raw_registry)}"
        raw_registry[token] = str(value)
        return token
    if isinstance(value, dict):
        return {k: _prepare_for_dump(v, raw_registry) for k, v in value.items()}
    if isinstance(value, list):
        return [_prepare_for_dump(v, raw_registry) for v in value]
    return value


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
    ``json.dumps`` kwarg surface."""
    raw_registry: dict = {}
    prepared = _prepare_for_dump(obj, raw_registry)
    text = json.dumps(prepared, indent=indent, ensure_ascii=ensure_ascii, allow_nan=False)
    for token, raw in raw_registry.items():
        text = text.replace(f'"{token}"', raw)
    return text
