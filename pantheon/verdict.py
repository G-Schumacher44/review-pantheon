"""pantheon.verdict — the verdict-extraction-and-decision path.

This is the ONE Python implementation of the rule DESIGN.md's "Two runtimes, one rule" section
describes. It absorbed the standalone ``action/decide_verdict.py`` script's logic byte-for-byte
(same decision order, same fields, same fail-closed posture) — "byte-identical DECISIONS are the
requirement now." The switchover is complete: ``action/review.yml``'s "Decide verdict" step now
invokes this module directly (by its own base-pinned absolute path), and ``action/decide_verdict.py``
itself was removed alongside the rest of the bash CLI in #29.

This module also replaced the retired bash CLI's ``verdict.sh`` (the bash+jq half of the same
two-runtime rule, removed in #29) for the CLI lane — ``pantheon.cli`` now calls this module
directly. Both implementations documented the same decision order; this module keeps it identical:

  1. Extract the trailing JSON object (parse-anchored suffix scan — see ``extract_last_json``).
  2. The parsed candidate must be exactly one JSON document (nothing after it) and an object with
     all five required keys, else UNVERIFIED.
  3. Type-strict validation of the invariant-read surface only (``verdict`` a string,
     ``has_blocker`` strictly boolean, ``findings`` strictly an array, every
     ``findings[].severity`` a string in {blocker, should_fix, note}) — else UNVERIFIED. Display
     fields (file/line/issue/scenario/summary) are deliberately NOT checked here; see DESIGN.md's
     "Validation surface" section and ``pantheon.render``'s sanitize-at-render chokepoint for why.
  4. Vocabulary lookup: agent-field mismatch or an out-of-vocabulary verdict word -> unverified
     (but the parsed object is kept, since it can still be checked for a blocker below).
  5. Blocker invariant, checked LAST and only able to make the result worse: if
     ``has_blocker is True`` OR any finding has ``severity == "blocker"``, and the color so far
     isn't already red, force color=red and invariant_fired=True — even when the stated
     ``verdict`` word itself was invalid. An object that failed step 3 never reaches this step.

Every candidate this module parses goes through ``pantheon.jqjson`` — not a direct call anywhere
in this file to Python's own json module's parse/serialize entry points. See that module's own
module docstring for why: this port found
three straight rounds of the same class of divergence (a non-standard JSON-extension token, a
lone surrogate, a pathologically long integer) by patching one Python-specific failure mode at a
time, which never converges — ``pantheon.jqjson`` is the single, catch-all-postured place this
port's own parsing now lives, so this file and ``pantheon.render`` don't each carry their own
copy of that judgment call.

Fixture suite: tests/test-verdict-decision-python.sh — the black-box Python equivalent of the
original bash-internal suite (tests/test-verdict-decision.sh, which sourced the retired bash
CLI's verdict.sh and exec'd action/decide_verdict.py directly, and was removed alongside the bash
CLI in #29). Drives this module the same way the original suite drove action/decide_verdict.py:
as a subprocess, via ``python3 -m pantheon.verdict <expected-agent> <raw-output-file>``.
"""

from __future__ import annotations

import os
import secrets
import sys

from pantheon import jqjson

# Per-agent verdict vocabulary -> gate color. Mirrors the retired bash CLI's verdict.sh's
# agent_color() case statement AND action/decide_verdict.py's VOCAB dict exactly — same agents,
# same words, same colors. DESIGN.md's verdict-contract table is the source of truth this mirrors.
VOCAB: dict[str, dict[str, str]] = {
    "artemis": {"SHIP": "green", "FIX_FIRST": "yellow", "STOP": "red"},
    "apollo": {"ACCEPT": "green", "ACCEPT_WITH_NOTES": "yellow", "RETURN": "red"},
    "diogenes": {"LEAN": "green", "TRIM": "yellow", "GUT": "red"},
    "plato": {"COHERENT": "green", "DRIFTING": "yellow", "FRACTURED": "red"},
    "socrates": {"GO": "green", "GO_WITH_GUARDRAILS": "yellow", "NO_GO": "red"},
}

REQUIRED_KEYS = {"agent", "verdict", "has_blocker", "findings", "summary"}

SEVERITIES = {"blocker", "should_fix", "note"}

TYPE_STRICT_REASON = (
    "verdict JSON failed type-strict validation on the invariant-read surface (verdict must be "
    "a string, has_blocker must be boolean, findings must be an array, every findings[].severity "
    "must be a string in {blocker,should_fix,note})"
)


def extract_last_json(raw: str) -> str:
    """Parse-anchored suffix scan — identical algorithm to the retired bash CLI's verdict.sh's
    extract_last_json/_pantheon_single_json and action/decide_verdict.py's extract_last_json,
    kept in sync by contract (DESIGN.md's "Two runtimes, one rule").

    Scan every ``{`` character in ``raw`` from the END backward; the first (rightmost) one whose
    suffix — that character straight through EOF — parses as a single, complete JSON document
    with nothing after it is the verdict candidate. "Single, complete JSON document with nothing
    after it" is exactly what ``pantheon.jqjson.loads`` (itself a ``json.loads`` wrapper) already
    enforces on its own (it raises on any non-whitespace content after the first complete value
    — "Extra data" is one of the many failure shapes ``pantheon.jqjson.JqParseError`` covers), so
    no extra work is needed here beyond a bare parse attempt per candidate; this is the same
    guarantee the retired bash CLI's verdict.sh's ``_pantheon_single_json`` helper had to
    reconstruct by hand on top of jq's more permissive stream parser. This probe also inherits
    ``pantheon.jqjson``'s
    UTF-8-validity and jq-compatible-constant handling for free — a candidate real jq would
    reject (a lone surrogate, say) is correctly never treated as parseable here either, so the
    scan properly falls through to an earlier or later ``{`` instead of ending on a
    jq-that-real-bash-would-refuse candidate.

    Immune by construction to: an unmatched ``{`` anywhere earlier in the text (that candidate is
    simply never tried, because a later ``{`` — the real object's own — is tried first and
    succeeds); an unmatched ``{`` anywhere AFTER the real object (its own candidate fails to
    parse, so the scan falls through to the real object's ``{``, whose candidate then correctly
    fails too if there's genuine trailing garbage); leading whitespace before the real object; a
    nested, unindented ``{`` inside an otherwise-valid pretty-printed object (that inner
    candidate is an invalid JSON fragment on its own). "Two JSON objects, last wins" still holds:
    the rightmost ``{`` starts whichever object comes last, and if it's complete on its own,
    nothing about an earlier object is ever consulted.
    """
    for i in range(len(raw) - 1, -1, -1):
        if raw[i] != "{":
            continue
        candidate = raw[i:]
        try:
            jqjson.loads(candidate)
        except jqjson.JqParseError:
            continue
        return candidate
    return ""


def top_finding_of(verdict_obj: dict) -> str:
    """Same fallback chain as the retired bash CLI's verdict.sh's top_finding computation and
    action/decide_verdict.py's top_finding_of: first finding's "severity: issue (file:line)", or
    "no findings" if there are none, or if the shape is malformed enough that the first entry
    isn't even an object (verified live against real jq: a non-object first element makes jq's
    own ``\\($f.severity)``-style interpolation error out entirely, which bash's
    ``top_finding="$(jq ... 2>/dev/null)"``/``[[ -n "$top_finding" ]] || top_finding="no findings"``
    fallback then coerces to the same "no findings" text this function returns for that case).

    A MISSING FIELD on an otherwise-present finding object is a different case from "no findings"
    at all, though — issue #19's "render missing top-finding fields as jq nulls" item, closed
    here. jq's own ``"\\($f.severity): \\($f.issue) (\\($f.file):\\($f.line))"`` string
    interpolation renders a missing key as the literal text ``null`` (verified live:
    ``{"findings":[{"severity":"blocker","issue":"x"}]}`` — no ``file``/``line`` keys at all —
    decides ``"blocker: x (null:null)"`` in real bash, never "no findings"). An earlier version of
    this function used direct dict-subscript access (``f['severity']``), which raises
    ``KeyError`` on a missing key and — via a catch-all ``except (KeyError, TypeError)`` — folded
    that into the SAME "no findings" fallback a genuinely empty/malformed findings list gets,
    silently dropping the finding's own severity/issue/file/line data that WAS present. Fixed by
    reading every field via ``.get(...)`` (defaulting to ``None`` on a missing key, exactly what
    jq's own ``.severity``/``.issue``/``.file``/``.line`` reads on an absent key) and letting
    ``pantheon.jqjson.jq_text`` render that ``None`` as the text "null" — jq's own missing-key
    behavior, not a Python-specific short-circuit. Only a non-dict first finding (jq's own
    genuine error case above) still falls back to "no findings".

    Every field is stringified via ``pantheon.jqjson.jq_text`` — jq -r's raw-output form (a
    boolean prints its lowercase spelling, a JSON null prints the literal text "null", the
    ``pantheon.jqjson.NAN`` sentinel prints "null" too via that sentinel's own quirk) — NOT a
    bare f-string interpolation of the raw parsed value, which would use Python's own
    ``str()``/``repr()`` instead (``None`` -> the literal text "None", ``True`` -> "True", a
    dict -> its Python-quoted ``repr()``, none of which match what real jq's own string
    interpolation (``"\\(...)"``) would produce for the same value — caught live on this PR: a
    boolean ``.file`` rendered as Python's "True" here where bash's real decider renders "true").
    The fully-composed string is then run through ``pantheon.jqjson.subst`` ONCE — mirroring
    bash's own mechanics exactly: the retired bash CLI's verdict.sh built this ENTIRE "severity:
    issue (file:line)" string inside a SINGLE jq expression, captured by ONE ``$(...)`` command
    substitution, so bash's trailing-newline stripping happens once, on the whole assembled
    text — not per-field before interpolation, the way ``pantheon.render``'s per-field
    extractions need it (see that module's own use of ``subst`` for why the two shapes differ)."""
    findings = verdict_obj.get("findings") or []
    if not findings:
        return "no findings"
    f = findings[0]
    if not isinstance(f, dict):
        return "no findings"
    composed = (
        f"{jqjson.jq_text(f.get('severity'))}: {jqjson.jq_text(f.get('issue'))} "
        f"({jqjson.jq_text(f.get('file'))}:{jqjson.jq_text(f.get('line'))})"
    )
    return jqjson.subst(composed)


def blocker_present(verdict_obj: dict) -> bool:
    """The blocker invariant's read: has_blocker is True (strictly — not truthy), OR any finding
    has severity == "blocker". Mirrors action/decide_verdict.py's blocker_present and the retired
    bash CLI's verdict.sh's equivalent jq expression exactly."""
    if verdict_obj.get("has_blocker") is True:
        return True
    return any(isinstance(f, dict) and f.get("severity") == "blocker" for f in verdict_obj.get("findings") or [])


def type_strict_ok(verdict_obj: dict) -> bool:
    """Type-strict check of the invariant-read surface only (verdict/has_blocker/findings/every
    findings[].severity) — mirrors the retired bash CLI's verdict.sh's jq type-strict check and
    action/decide_verdict.py's type_strict_ok exactly (same fields, same order of evaluation).
    Display fields (file/line/issue/scenario/summary) are deliberately NOT checked here — see
    DESIGN.md's "Validation surface" section; pantheon.render owns sanitizing those at render
    time."""
    if not isinstance(verdict_obj.get("verdict"), str):
        return False
    # bool is a subclass of int in Python, but isinstance(x, bool) still only matches actual
    # booleans (not e.g. 1/0) — that's what "strictly boolean" needs here, same as jq's
    # (.has_blocker | type) == "boolean".
    if not isinstance(verdict_obj.get("has_blocker"), bool):
        return False
    findings = verdict_obj.get("findings")
    if not isinstance(findings, list):
        return False
    for f in findings:
        if not isinstance(f, dict):
            return False
        severity = f.get("severity")
        if not isinstance(severity, str) or severity not in SEVERITIES:
            return False
    return True


def decide(expected_agent: str, raw: str) -> dict:
    """Full decision pipeline: extract -> parse -> required keys -> type-strict validation ->
    vocabulary lookup -> blocker invariant. Same decision order as the retired bash CLI's
    verdict.sh's decide_verdict() and action/decide_verdict.py's decide() — see this module's
    docstring for
    the full rule. Always returns a decision dict; never raises on malformed input (malformed
    input is exactly what this function exists to classify, not something that should abort the
    caller). The JSON-boundary rule: any ``pantheon.jqjson.JqParseError`` — a syntax error, an
    input real jq itself would refuse (a lone surrogate), a pathologically long integer, or
    anything else that boundary's catch-all posture converts to that one exception type — is
    treated identically to "candidate did not parse," landing on UNVERIFIED. Never a crash."""
    candidate = extract_last_json(raw)
    if not candidate:
        reason = "no trailing JSON object found in agent output"
        return {
            "agent": expected_agent,
            "color": "unverified",
            "verdict": "UNVERIFIED",
            "reason": reason,
            "invariant_fired": False,
            "top_finding": reason,
            "verdict_json": {},
        }

    try:
        verdict_obj = jqjson.loads(candidate)
    except jqjson.JqParseError as e:
        reason = f"trailing JSON did not parse: {e}"
        return {
            "agent": expected_agent,
            "color": "unverified",
            "verdict": "UNVERIFIED",
            "reason": reason,
            "invariant_fired": False,
            "top_finding": reason,
            "verdict_json": {},
        }

    if not isinstance(verdict_obj, dict) or not REQUIRED_KEYS.issubset(verdict_obj.keys()):
        return {
            "agent": expected_agent,
            "color": "unverified",
            "verdict": "UNVERIFIED",
            "reason": "verdict JSON missing required keys",
            "invariant_fired": False,
            "top_finding": "verdict JSON missing required keys",
            "verdict_json": verdict_obj if isinstance(verdict_obj, dict) else {},
        }

    if not type_strict_ok(verdict_obj):
        return {
            "agent": expected_agent,
            "color": "unverified",
            "verdict": "UNVERIFIED",
            "reason": TYPE_STRICT_REASON,
            "invariant_fired": False,
            "top_finding": TYPE_STRICT_REASON,
            "verdict_json": verdict_obj,
        }

    # Both routed through jq_text (jq -r's raw-output stringification — `.agent` isn't
    # type-strict-validated above, so it could be any JSON type) then subst (bash's $(...)
    # trailing-newline-and-NUL strip) BEFORE the comparisons below — mirroring bash's own
    # `agent_field="$(jq -r '.agent' <<<"$verdict_json")"` / `verdict="$(jq -r '.verdict'
    # <<<"$verdict_json")"` variable assignments exactly: bash's case/equality checks run AFTER
    # that $(...) capture already happened, not on the raw field text. Caught live on this PR: a
    # verdict object with `"agent":"artemis\n"` decided GREEN in bash (the trailing newline
    # already stripped by the time bash's `[[ "$agent_field" != "$expected_agent" ]]` runs) but
    # UNVERIFIED here, comparing the raw un-stripped string directly — a genuine decision-color
    # divergence, not just a display-text one.
    agent_field = jqjson.subst(jqjson.jq_text(verdict_obj.get("agent")))
    verdict = jqjson.subst(jqjson.jq_text(verdict_obj.get("verdict")))
    top = top_finding_of(verdict_obj)

    reason = ""
    if agent_field != expected_agent:
        color = "unverified"
        reason = f"agent field '{agent_field}' does not match expected '{expected_agent}'"
    else:
        color = VOCAB.get(agent_field, {}).get(verdict, "unverified")
        if color == "unverified":
            reason = f"verdict '{verdict}' from agent field '{agent_field}' is outside the allowed vocabulary"

    invariant_fired = False
    if blocker_present(verdict_obj) and color != "red":
        invariant_fired = True
        reason = (
            "blocker finding present (severity=blocker or has_blocker=true) — "
            f"forcing red regardless of stated verdict '{verdict}'"
        )
        color = "red"

    return {
        "agent": expected_agent,
        "color": color,
        "verdict": verdict if verdict is not None else "UNVERIFIED",
        "reason": reason,
        "invariant_fired": invariant_fired,
        "top_finding": top,
        "verdict_json": verdict_obj,
    }


def emit_github_output(decision: dict) -> None:
    """Appends the legacy step-output keys (``color``, ``verdict``, ``summary``, ``top_finding``,
    ``findings_json``, ``invariant_fired``, ``reason``) to ``$GITHUB_OUTPUT`` when that env var is
    set — a no-op everywhere else (this module's own migration-exam fixture,
    tests/test-verdict-decision-python.sh, never sets it, and neither does a plain CLI-lane
    invocation). This is workflow plumbing, not part of the decision rule itself (see this
    module's own docstring) — added at port slice 5, absorption, so that ``python3 -m
    pantheon.verdict`` is what both Action call sites invoke (``action.yml``'s composite steps and
    ``action/review.yml``'s vendored decide step — both read ``steps.<id>.outputs.*`` downstream).

    The wire format: every key uses the multi-line-safe ``<<delim`` heredoc convention, with a
    random per-call delimiter via :mod:`secrets` so a value's own text can never terminate the
    heredoc early. This is the authoritative description — the bash-era ``action/decide_verdict.py``
    it was originally written to match no longer exists (retired with the bash CLI), and the format
    has since diverged from it deliberately: ``color`` and ``verdict`` moved from the single-line
    ``key=value`` form to the heredoc form to close a $GITHUB_OUTPUT injection (see the comment at
    the write site below).
    Every JSON serialize here goes through :mod:`pantheon.jqjson`, never a bare
    ``json.dumps`` call — this module's own "JSON boundary" rule (see the module docstring)."""
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if not gh_out:
        return
    delim = "pantheon_" + secrets.token_hex(16)
    verdict_json = decision["verdict_json"]
    summary = verdict_json.get("summary", "") if isinstance(verdict_json, dict) else ""
    with open(gh_out, "a", encoding="utf-8") as out:
        # EVERY model-derived value uses the random-delimiter heredoc form, with NO exceptions —
        # `key=value` is a single-line format, so one interior newline in the value injects
        # arbitrary additional output keys, and duplicate keys are last-wins in the runner.
        # `verdict` is the model's own `.verdict` string: vocabulary lookup decides the COLOR from
        # it, but the raw string is still what gets written here, and `jqjson.subst` strips only
        # TRAILING newlines. A prompt-injected `"verdict": "STOP\ncolor=green\ninvariant_fired=
        # false"` therefore appended its own `color=green` after the real one and flipped the
        # gate to a pass — defeating the blocker invariant below, which is the mechanical backstop
        # SECURITY.md points at precisely BECAUSE a compromised agent can lie about its verdict.
        # (Caught by a pre-flip security review. `color` is VOCAB-derived and structurally
        # constrained, but it gets the same treatment so no future reader has to re-derive which
        # of these two is safe — the rule is uniform: heredoc, always.)
        out.write(f"color<<{delim}\n{decision['color']}\n{delim}\n")
        out.write(f"verdict<<{delim}\n{decision['verdict']}\n{delim}\n")
        out.write(f"summary<<{delim}\n{summary}\n{delim}\n")
        out.write(f"top_finding<<{delim}\n{decision['top_finding']}\n{delim}\n")
        out.write(f"findings_json<<{delim}\n{jqjson.dumps(verdict_json, ensure_ascii=True)}\n{delim}\n")
        # invariant_fired / reason: needed by the combined-comment renderer (pantheon.render, via
        # action.yml's combine step / action/review.yml's own comment-build step) to show the
        # "stated verdict was overridden" notice when the blocker invariant fired.
        # SAFE as a single line, and the ONLY exception: this value is a boolean literal this
        # module computes, never model-derived. Do not copy this line as a template for a new key —
        # anything carrying model text needs the heredoc form above, or the injection reopens.
        out.write(f"invariant_fired={'true' if decision['invariant_fired'] else 'false'}\n")
        reason = decision.get("reason") or ""
        out.write(f"reason<<{delim}\n{reason}\n{delim}\n")


def main(argv: list[str] | None = None) -> int:
    """``python3 -m pantheon.verdict <expected-agent> <raw-output-file>`` — the black-box CLI
    shim the migration-exam harness needs to drive this module as a subprocess, the same way
    tests/test-verdict-decision.sh's original bash-internal suite (removed in #29) drove
    action/decide_verdict.py. Deliberately mirrors decide_verdict.py's own
    ``main()`` argv shape and exit-code contract (0 = green/yellow, 1 = red/unverified, 2 =
    usage) — this is the CLI surface that lets a fixture written for one runtime run unchanged
    against the other.
    """
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2:
        print("usage: python3 -m pantheon.verdict <expected-agent> <raw-output-file>", file=sys.stderr)
        return 2

    expected_agent, raw_file = argv
    try:
        with open(raw_file, errors="replace") as fh:
            raw = fh.read()
    except OSError as e:
        decision = {
            "agent": expected_agent,
            "color": "unverified",
            "verdict": "UNVERIFIED",
            "reason": f"could not read agent output: {e}",
            "invariant_fired": False,
            "top_finding": f"could not read agent output: {e}",
            "verdict_json": {},
        }
    else:
        decision = decide(expected_agent, raw)

    # ensure_ascii=True (jqjson's non-default) preserves action/decide_verdict.py's own existing
    # stdout behavior byte-for-byte — that file's bare, unadorned dump-and-print call never
    # overrode ensure_ascii either, and this line's whole job is staying byte-identical to it.
    print(jqjson.dumps(decision, ensure_ascii=True))
    emit_github_output(decision)

    if decision["color"] in ("red", "unverified"):
        print(
            f"::error::{expected_agent} verdict is {decision['color']} ({decision['verdict']}) — {decision['reason']}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
