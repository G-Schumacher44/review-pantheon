"""pantheon.render — the combined-PR-comment renderer (docs/PYTHON-PORT.md section 6).

Ports ``cli/lib/render_comment.sh`` — the ONE bash implementation shared by ``cli/review-gate``
and ``action/lib/combine_verdicts.sh`` (see DESIGN.md's "Combined PR comment" section) — to
Python. Byte-identical OUTPUT to the bash renderer for identical inputs is the bar
docs/PYTHON-PORT.md's Slice-2 charter sets for this module; ``action/review.yml``'s own
hand-synced inline copy is a separate, pre-existing surface this port does not touch.

Two public entry points, mirroring the bash file's contract exactly:

  overall_color(colors)                         -> "green" | "yellow" | "red" | "unverified"
  render_comment(head_sha, agents, agent_data)   -> the full comment markdown, as one string

``agent_data`` is a mapping of agent name -> :class:`AgentRenderData`, replacing the bash
contract's per-agent env-var convention (``<NAME>_COLOR``, ``<NAME>_VERDICT``, ``<NAME>_TOP``,
``<NAME>_FINDINGS``, ``<NAME>_INVARIANT``, ``<NAME>_REASON``) with an explicit structure — Python
has no need for bash's ``${!var}`` indirection trick. :func:`render_from_env` reconstructs that
same env-var contract for callers (and the migration-exam harness, and eventually ``pantheon.cli``)
that still want to drive this module the way the bash version is driven today.

Sanitize-at-render (the two-layer contract DESIGN.md's "Validation surface" section describes):
every value this module reads out of an agent's JSON, or derives from one, is untrusted model
output — verdict, summary, and each finding's severity/file/line/issue/scenario — and is routed
through :func:`sanitize_inline` (or a stricter variant, e.g. the line-number-or-"?" coercion in
:func:`_finding_line_or_placeholder`) before it reaches the human-readable section of the
comment. The one deliberate exception is the machine tail (the nested "Raw verdict JSON" block
near the end of :func:`render_comment`) — it prints the untouched JSON on purpose, because that's
the whole point of keeping a machine-readable copy.

Every JSON parse and every JSON serialize in this module goes through ``pantheon.jqjson``
(docs/PYTHON-PORT.md's "JSON boundary" section), not Python's own json module's parse/serialize
entry points directly — see that module's own docstring for why: this port found three straight
rounds of the same class of divergence (a non-standard JSON-extension token, a lone surrogate, a
pathologically long integer, an overflowing numeric literal) by patching one Python-specific
failure mode at a time, which never converges. ``pantheon.verdict`` routes through the same
boundary, so the two modules share exactly one place this judgment call lives.

Fixture suite: tests/test-render-comment.sh (bash-internal in its original form — sources
cli/lib/render_comment.sh directly). Its black-box Python equivalent, per docs/PYTHON-PORT.md
section 4, is tests/test-render-comment-python.sh, which drives this module the same way the
original suite drives the sourced bash functions: via ``python3 -m pantheon.render``.
"""
from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field
from typing import Any, Iterable

from pantheon import jqjson

_SEVERITY_RANK = {"blocker": 0, "should_fix": 1, "note": 2}
_LINE_RE = re.compile(r"^[0-9]+$")
_LONE_SURROGATE_RE = re.compile(r"[\ud800-\udfff]")


@dataclass
class AgentRenderData:
    """One agent's render-time inputs — the structured equivalent of the bash contract's six
    per-agent env vars (``<NAME>_COLOR`` etc., see this module's docstring).

    ``findings_json`` is the STRUCTURED view every display helper in this module reads
    (``{}`` if the source text failed to parse, or parsed to something other than a JSON
    object — matching the fail-closed-to-``{}`` guards those helpers already apply).
    ``findings_raw`` is the exact source text, kept separately, purely for the machine tail's
    fallback-to-raw-text behavior (see :func:`_machine_tail_text`) — mirroring
    ``cli/lib/render_comment.sh``'s own ``jq '.' <<<"$findings_json" 2>/dev/null ||
    printf '%s\\n' "$findings_json"`` pattern, which shows the PARSED-and-pretty-printed value on
    success (of any JSON type, not just objects) but falls back to the untouched raw text on a
    parse failure — including bash's own ``\\{}``-shaped default-value quirk for a completely
    unset env var (see :func:`_agent_data_from_env`), which is itself invalid JSON and so
    triggers that same raw-text fallback in bash's real output."""

    color: str = "unverified"
    verdict: str = "UNVERIFIED"
    top: str = ""
    findings_json: dict = field(default_factory=dict)
    findings_raw: str | None = None
    invariant: bool = False
    reason: str = ""

    def __post_init__(self) -> None:
        # A direct caller (this module's programmatic API, not the env-var bridge below) that
        # only sets findings_json gets a findings_raw derived from it automatically, so the
        # machine tail stays in sync with findings_json by default — an explicit findings_raw
        # (what the env-var bridge always provides, and what a test deliberately exercising the
        # raw-text-fallback path can still pass) overrides this.
        if self.findings_raw is None:
            self.findings_raw = jqjson.dumps(self.findings_json, ensure_ascii=False)


# ---------------------------------------------------------------------------
# Small helpers (module-private; not part of the public contract)
# ---------------------------------------------------------------------------


def sanitize_inline(s: Any) -> str:
    """Markdown/HTML-hostile-content-safe + single-line, for ANY model-controlled string this
    renderer interpolates — table cells, prose, AND values placed inside a backtick code span.
    Mirrors ``cli/lib/render_comment.sh``'s ``_pantheon_sanitize_inline`` exactly, same order of
    operations (order matters — see that function's header comment for why each step is where it
    is):

      - Stringified via ``pantheon.jqjson.jq_text`` first (jq -r's raw-output form — see that
        function's docstring), not a bare ``str()``. By the time a value reaches here it has
        USUALLY already passed through ``jq_text``/``jqjson.subst`` at its extraction site (see
        :func:`render_comment`'s per-field extraction, which mirrors bash's own
        ``var="$(jq -r ... <<<"$json")"`` variable-assignment shape) — calling ``jq_text`` again
        here is then a harmless no-op (a string passes through unchanged), and is what keeps this
        function safe to call directly on a value that HASN'T been through that pipeline yet
        (``d.verdict``/``d.reason``, which come from a bash counterpart that reads an env var
        DIRECTLY, never through ``$(...)``, and so were never jq-stringified or newline-stripped
        in the first place — see ``pantheon.jqjson.subst``'s own docstring for that distinction).
      - NUL (U+0000) dropped outright. Not a markdown/HTML concern like the rest of this
        function — it's a bash-parity one: bash's ``$(...)`` command substitution cannot hold a
        NUL byte and silently drops it (a documented bash limitation, not something
        ``cli/lib/render_comment.sh``'s own code does explicitly), so a NUL smuggled into a
        display field via a JSON ``\\u0000`` escape survives Python's render but is silently gone
        from bash's — a real, verified byte-output divergence. Verified this is the ONLY C0
        control character bash's pipeline drops: a fixture with ``\\u0001``/``\\u0007``/``\\u001b``
        alongside a NUL showed every one of those three survive unchanged in bash's real output,
        only the NUL vanished — so this is scoped to NUL specifically, not C0 controls broadly.
        (Caught live — the repo's own self-hosted gate on this PR flagged this.)
      - Newlines collapsed to spaces (so a multi-line value can't fracture a table row/list item).
      - Pipes escaped (``\\|``), so a stray ``|`` can't fracture a markdown table row.
      - Backticks replaced with a straight quote — there is no backslash-escape for a backtick
        INSIDE a single-backtick-fenced code span in CommonMark.
      - Angle brackets HTML-escaped (``&lt;``/``&gt;``), so a value can't be mistaken for an HTML
        tag in GitHub's comment renderer.
      - ``@`` replaced with the fullwidth lookalike ＠ (U+FF20), so a model's text can't page an
        arbitrary user/team via a real GitHub notification.

    The machine tail (the nested "Raw verdict JSON" block, see this module's docstring) needs no
    equivalent NUL handling: a JSON serializer always escapes control characters — including NUL
    — as backslash-u-XXXX sequences regardless of ASCII-escaping mode, per the JSON spec, exactly
    like jq's own non-``-r`` pretty-printer does for the bash machine tail. A raw NUL byte only
    ever reaches bash's output via the ``-r`` (raw-string) mode this human-readable path uses;
    the machine tail was never at risk.
    """
    s = jqjson.jq_text(s)
    s = s.replace("\x00", "")
    s = s.replace("\n", " ")
    s = s.replace("|", "\\|")
    s = s.replace("`", "'")
    s = s.replace("<", "&lt;")
    s = s.replace(">", "&gt;")
    s = s.replace("@", "＠")
    return s


def truncate(text: str, max_len: int = 90) -> str:
    """Character-safe (codepoint-safe) truncation — mirrors ``cli/lib/render_comment.sh``'s
    ``_pantheon_truncate``, which reroutes through jq specifically because bash's own
    ``${#text}``/``${text:a:b}`` are only character-safe under a UTF-8-aware locale. Python's
    ``str`` is always a sequence of Unicode codepoints regardless of the process locale, so a
    plain slice is already the codepoint-safe operation jq's string functions give bash — no
    locale workaround needed here."""
    if len(text) <= max_len:
        return text
    return text[: max_len - 1] + "…"


def emoji_for_color(color: str) -> str:
    return {"green": "🟢", "yellow": "🟡", "red": "🔴"}.get(color, "🟠")


def severity_badge(severity: Any) -> str:
    """Mirrors ``_pantheon_severity_badge``: the three known severities get a fixed label; an
    out-of-enum severity is visibly flagged (not silently treated as a fourth kind of legitimate
    badge) and sanitized like every other model-controlled field.

    ``severity`` is expected to already be ``pantheon.jqjson.jq_text``/``jqjson.subst``-processed
    text by the time it reaches here (see :func:`render_comment`'s extraction site) — mirroring
    bash's own ``sev="$(jq -r '.severity // "note"' <<<"$finding_obj")"`` variable, which is
    ALREADY the fully-stringified, trailing-newline-stripped text by the time bash's ``case``
    statement compares it. Comparing against the raw, un-stringified parsed value here instead
    would miss a match bash's real pipeline makes — e.g. a JSON boolean ``true`` severity, or a
    string severity with a trailing newline bash's ``$(...)`` would have already stripped before
    comparing it to ``"blocker"``."""
    if severity == "blocker":
        return "**blocker**"
    if severity == "should_fix":
        return "should_fix"
    if severity == "note":
        return "note"
    return f"unrecognized-severity({sanitize_inline(severity)})"


def _safe_findings(verdict_obj: Any) -> list[dict]:
    """Mirrors ``_pantheon_safe_findings_filter``: ``.findings`` is only checked for PRESENCE
    upstream (pantheon.verdict / cli/lib/verdict.sh / action/decide_verdict.py), never for being
    an array of objects — a malformed verdict (``"findings": "none"``, or a stray non-object
    element mixed into an otherwise-valid array) must degrade to "no findings"/fewer findings
    here, never crash every downstream ``.severity``/``.file``/``.issue`` access."""
    if not isinstance(verdict_obj, dict):
        return []
    findings = verdict_obj.get("findings")
    if not isinstance(findings, list):
        return []
    return [f for f in findings if isinstance(f, dict)]


def _severity_rank(severity: Any) -> int:
    """The sort key `_sorted_findings` ranks on. Only a STRING severity can ever match
    `_SEVERITY_RANK`'s keys, but severity is unvalidated model output at this layer (the
    type-strict check lives upstream in ``pantheon.verdict`` and only gates the overall verdict
    COLOR — a finding that fails it still reaches this renderer via the raw findings array, same
    fail-open-to-display/fail-closed-to-decision split DESIGN.md's "Validation surface" section
    describes). A non-string severity that also happens to be UNHASHABLE (a JSON array or
    object) would crash a bare ``dict.get(severity, 3)`` with ``TypeError: unhashable type``,
    aborting the entire render — not just this one finding's badge — before the fail-closed
    comment could even be produced. Guard the type first so any non-string severity (hashable or
    not) degrades to the same fallback rank 3 a genuinely out-of-vocabulary STRING severity
    already gets, mirroring jq's own behavior: jq's ``.severity == "blocker"`` comparison is
    type-safe across JSON value kinds (an array/object never equals a string, no jq error), so
    the bash renderer already falls through to its `else 3` branch for the same malformed input
    without crashing. (Caught live — the repo's own self-hosted gate on this PR flagged this as
    a P1: a malformed ``severity`` array/object crashes the Python renderer entirely, where the
    bash renderer degrades gracefully.)"""
    if isinstance(severity, str):
        return _SEVERITY_RANK.get(severity, 3)
    return 3


def _sorted_findings(verdict_obj: Any) -> list[dict]:
    """Findings sorted blocker -> should_fix -> note -> other (a stable sort, matching jq's
    ``sort_by``); mirrors ``_pantheon_sorted_findings``."""
    return sorted(_safe_findings(verdict_obj), key=lambda f: _severity_rank(f.get("severity")))


def _top_finding_text(verdict_obj: Any) -> str:
    """Highest-severity finding's issue text, or "" if there are none — mirrors
    ``_pantheon_top_finding_text`` (including its ``.issue // ""`` fallback: a JSON ``null`` OR
    ``false`` issue value degrades to "", matching jq's ``//`` operator, not just a missing
    key). Bash's own ``_pantheon_top_finding_text`` is captured by its caller via ``$(...)``
    (``best="$(_pantheon_top_finding_text "$findings_json")"``), so this applies
    ``pantheon.jqjson.subst`` to the stringified result, matching that trailing-newline strip."""
    sorted_findings = _sorted_findings(verdict_obj)
    if not sorted_findings:
        return ""
    return jqjson.subst(jqjson.jq_text(_or_default(sorted_findings[0].get("issue"), "")))


def _table_top_cell(verdict: str, top_text: str, verdict_obj: Any) -> str:
    """Mirrors ``_pantheon_table_top_cell``."""
    if verdict == "SKIPPED":
        return f"skipped — {top_text}"
    best = _top_finding_text(verdict_obj)
    if best:
        return truncate(best, 90)
    if top_text and top_text != "no findings":
        return top_text
    return "—"


def _headline_lines(overall: str) -> tuple[str, str]:
    """Mirrors ``_pantheon_headline_lines``: the bold signal line's phrase, then a one-sentence
    plain-language explanation of what that signal means for the merge decision."""
    if overall == "green":
        phrase = "Clean pass"
        explain = (
            "No blocker or review-note findings from any agent — this reads as safe to merge on "
            "the gate's own signal."
        )
    elif overall == "yellow":
        phrase = "Review notes"
        explain = (
            "Non-blocking findings below are worth a look, but nothing here is stopping the "
            "merge."
        )
    elif overall == "red":
        phrase = "Blocked"
        explain = "A blocker finding was reported — this should not merge until it is resolved."
    else:
        phrase = "NOT GATED (fail-closed)"
        explain = (
            "At least one agent did not return a trustworthy verdict, so the gate is refusing to "
            "vouch for this PR instead of guessing — treat this as unreviewed, not as a pass."
        )
    return f"### {emoji_for_color(overall)} **{phrase}**", explain


def _finding_line_or_placeholder(raw_line: Any) -> str:
    """``.line`` is schema'd as a number, but it's still model output — coerce anything that
    isn't a plain non-negative integer to the same "?" placeholder used when the key is missing
    entirely, rather than interpolating arbitrary text where a line number is expected. Mirrors
    the bash renderer's ``[[ "$ln" =~ ^[0-9]+$ ]] || ln="?"`` coercion, applied to whatever
    ``ln="$(jq -r '.line // "?"' <<<"$finding_obj")"`` would have already produced — the full
    ``// default`` -> jq-``-r``-stringify -> ``$(...)``-newline-strip chain (``jqjson.jq_text``
    then ``jqjson.subst``), not just a bare ``str()``. Without the ``subst`` step, a ``.line``
    value that was itself a string ending in a newline (e.g. ``"42\\n"``) would keep that
    embedded newline in the returned text — Python's ``re`` module's ``$`` anchor matches just
    before a single trailing newline by default, so the digit-regex check below would ACCEPT
    ``"42\\n"`` without ever stripping it, corrupting the markdown list item this value is
    interpolated into (a raw newline splits one list item into two lines) — a distinct, latent
    bug this fix also closes, not just a byte-parity nicety."""
    text = jqjson.subst(jqjson.jq_text(_or_default(raw_line, "?")))
    return text if _LINE_RE.match(text) else "?"


def _or_default(value: Any, default: str) -> Any:
    """jq's ``// default`` operator: substitute ``default`` when ``value`` is JSON null or
    false, keep ``value`` (including falsy-but-not-null/false values like ``0`` or ``""``)
    otherwise."""
    if value is None or value is False:
        return default
    return value


def _machine_tail_text(raw_text: str) -> str:
    """The machine tail's per-agent code-fence content — mirrors
    ``cli/lib/render_comment.sh``'s ``jq '.' <<<"$findings_json" 2>/dev/null ||
    printf '%s\\n' "$findings_json"`` exactly: pretty-print the PARSED value (2-space indent, raw
    UTF-8, jq-compatible constant/overflow-number handling via ``pantheon.jqjson``) if
    ``raw_text`` parses — of WHATEVER JSON type it parses to, not narrowed to an object, since
    jq's ``.`` filter happily pretty-prints a bare array/scalar too — otherwise fall back to
    ``raw_text`` completely untouched (a ``pantheon.jqjson.JqParseError`` covers every reason a
    parse can fail: a genuine syntax error, an input real jq itself would refuse, bash's own
    ``\\{}`` default-value quirk for a totally unset env var). This is deliberately a DIFFERENT
    rule than the structured render helpers use (``_safe_findings`` et al., which narrow anything
    non-object/non-array to an empty/absent result): the machine tail's whole purpose is showing
    what's actually there, parseable or not, exactly like bash's own fallback does."""
    try:
        parsed = jqjson.loads(raw_text)
    except jqjson.JqParseError:
        return raw_text
    return jqjson.dumps(parsed, indent=2, ensure_ascii=False)


def _escape_lone_surrogates(s: str) -> str:
    """A Python ``str`` can hold a lone (unpaired) surrogate code point (U+D800-U+DFFF) —
    reachable here via a JSON ``\\ud800``-style escape in an agent's raw output. ``pantheon.jqjson``
    already refuses to PARSE a lone surrogate at all (real jq rejects it too — see that module's
    ``_verify_utf8``), so this function's job today is narrower than it once was: a defense-in-
    depth backstop for any code point in this range that reaches a rendered string through a path
    that doesn't go through ``pantheon.jqjson.loads`` (e.g. a caller building an
    :class:`AgentRenderData` by hand with a raw Python string, not JSON text) — there is no UTF-8
    byte sequence for an unpaired surrogate, so the moment ANY caller encodes this module's
    output to UTF-8, an unhandled one would raise ``UnicodeEncodeError`` and abort rendering
    entirely. Re-escaping it back to its literal ``\\uXXXX`` text form keeps it visible (never
    silently dropped) and always safely encodable, without touching any other code point.
    Applied once, to this function's whole rendered output. (Originally caught live as a P2: an
    escaped lone surrogate in an otherwise-unused JSON field crashed the CLI while writing the
    comment — closed at its root by ``pantheon.jqjson``'s parse-time rejection; this function
    remains as the belt to that boundary's suspenders.)"""
    return _LONE_SURROGATE_RE.sub(lambda m: f"\\u{ord(m.group()):04x}", s)


# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------


def overall_color(colors: Iterable[str]) -> str:
    """Worst-wins aggregate across the panel — mirrors ``pantheon_overall_color``. A
    missing/empty color is the caller's responsibility to have already defaulted to
    "unverified" (fail-closed), same convention as the bash version (which reads
    ``${!color_var:-unverified}``)."""
    overall = "green"
    for color in colors:
        if color == "red":
            overall = "red"
        elif color == "unverified":
            if overall != "red":
                overall = "unverified"
        elif color == "yellow":
            if overall == "green":
                overall = "yellow"
    return overall


def render_comment(head_sha: str, agents: list[str], agent_data: dict) -> str:
    """The full combined-PR-comment markdown, as one string — mirrors
    ``pantheon_render_comment`` line for line. ``agent_data`` maps each agent name in ``agents``
    to an :class:`AgentRenderData` (missing entries fall back to that dataclass's defaults, the
    same fail-closed defaults the bash contract's ``${!var:-default}`` expansions use)."""
    short_sha = head_sha[:7] if head_sha else ""
    if not short_sha:
        short_sha = "unknown"

    def data_for(agent: str) -> AgentRenderData:
        return agent_data.get(agent) or AgentRenderData()

    overall = overall_color(data_for(a).color for a in agents)

    lines: list[str] = []
    headline, explain = _headline_lines(overall)
    lines.append(headline)
    lines.append(explain)
    lines.append("")
    lines.append("| Agent | Verdict | Top finding |")
    lines.append("|---|---|---|")

    total_findings = 0
    for agent in agents:
        d = data_for(agent)
        findings_obj = d.findings_json if isinstance(d.findings_json, dict) else {}
        total_findings += len(_safe_findings(findings_obj))

        # Sanitize the raw verdict value FIRST, then wrap it in our own backticks — sanitizing an
        # already-backtick-wrapped string would treat those backticks as hostile content too.
        vcell = f"`{sanitize_inline(d.verdict)}` — {d.color}"
        topcell = sanitize_inline(_table_top_cell(d.verdict, d.top, findings_obj))
        lines.append(f"| {agent} | {vcell} | {topcell} |")

    lines.append("")
    fold_open = " open" if overall in ("red", "unverified") else ""
    lines.append(f"<details{fold_open}>")
    lines.append(f"<summary>Full findings ({total_findings})</summary>")
    lines.append("")

    for agent in agents:
        d = data_for(agent)
        findings_obj = d.findings_json if isinstance(d.findings_json, dict) else {}
        emoji = emoji_for_color(d.color)

        lines.append(f"**{agent}** @ `{short_sha}` — {emoji} {sanitize_inline(d.verdict)}")
        lines.append("")

        # jq_text-ify AND subst (trailing-newline-strip) BEFORE testing emptiness, not after:
        # bash's own `summary="$(jq -r '.summary // empty' <<<"$findings_json")"` already ran
        # BOTH the `// default` -> jq -r stringify -> $(...) newline-strip chain before its own
        # `[ -n "$summary" ]` emptiness check ever runs. Skipping jq_text lets `0`/`[]`/`{}`
        # wrongly read as falsy in Python (caught live — the repo's own self-hosted gate flagged
        # this); skipping subst lets a summary of exactly a trailing newline (e.g. "\n") wrongly
        # read as non-empty in Python where bash's $(...) would have already stripped it to ""
        # and fallen through to `d.top` (caught live in a later round, same PR).
        summary = jqjson.subst(jqjson.jq_text(_or_default(findings_obj.get("summary") if isinstance(findings_obj, dict) else None, "")))
        if not summary:
            summary = d.top
        if not summary:
            summary = "no summary reported."
        lines.append(sanitize_inline(summary))
        lines.append("")

        if d.invariant and d.reason:
            lines.append(f"**Overridden verdict:** {sanitize_inline(d.reason)}")
            lines.append("")

        any_finding = False
        for finding in _sorted_findings(findings_obj):
            any_finding = True
            # Every one of these five mirrors a bash `var="$(jq -r '.field // default'
            # <<<"$finding_obj")"` assignment — full jq_text-then-subst chain at the extraction
            # site itself (not deferred to display time), matching bash's own variable semantics:
            # by the time bash's `sev`/`f`/`issue`/`scenario` hold a value, jq's stringification
            # AND $(...)'s trailing-newline strip have ALREADY run — including before severity's
            # own case-statement comparison, which is why `sev` is pre-processed here rather than
            # left for severity_badge() to stringify only in its unrecognized-severity fallback.
            sev = jqjson.subst(jqjson.jq_text(_or_default(finding.get("severity"), "note")))
            f_field = sanitize_inline(jqjson.subst(jqjson.jq_text(_or_default(finding.get("file"), "?"))))
            ln = _finding_line_or_placeholder(finding.get("line"))
            issue = jqjson.subst(jqjson.jq_text(_or_default(finding.get("issue"), "")))
            scenario = jqjson.subst(jqjson.jq_text(_or_default(finding.get("scenario"), "")))
            badge = severity_badge(sev)
            lines.append(f"- {badge} `{f_field}:{ln}` — {sanitize_inline(issue)}")
            if scenario:
                lines.append(f"  scenario: {sanitize_inline(scenario)}")
        if any_finding:
            lines.append("")

    lines.append("<details>")
    lines.append("<summary>Raw verdict JSON</summary>")
    lines.append("")
    for agent in agents:
        d = data_for(agent)
        lines.append(f"**{agent}**")
        lines.append("")
        lines.append("```json")
        lines.append(_machine_tail_text(d.findings_raw))
        lines.append("```")
        lines.append("")
    lines.append("</details>")
    lines.append("</details>")
    lines.append("")
    lines.append(
        "_review-pantheon — fails closed: a missing or unparseable verdict reads as NOT GATED, "
        "never as a pass._"
    )

    return _escape_lone_surrogates("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# Env-var bridge — reconstructs the bash contract's per-agent env-var convention (see this
# module's docstring), for callers/tests that still want to drive this module that way.
# ---------------------------------------------------------------------------


def _agent_data_from_env(agent: str) -> AgentRenderData:
    upper = agent.upper()
    color = os.environ.get(f"{upper}_COLOR") or "unverified"
    verdict = os.environ.get(f"{upper}_VERDICT") or "UNVERIFIED"
    top = os.environ.get(f"{upper}_TOP", "")
    # bash's own contract, verbatim: `findings_json="${!findings_var:-\{\}}"` — bash's `:-`
    # operator substitutes its default word for BOTH an unset var and one set to an empty
    # string (unlike `${var-default}`, which only fires on unset). The literal default word
    # itself is NOT the 2-char `{}` it looks like at a glance: verified live
    # (`x="${FOO:-\{\}}"; printf '%s' "$x"` with FOO unset) that bash's own escaping rules
    # collapse it to the 3-char string `\{}` — a backslash followed by a plain, unescaped `{}`
    # pair — not `{}` and not the 4-char `\{\}` either. That string is invalid JSON (a JSON
    # document can't start with a backslash), so it triggers the same jq-parse-failure ->
    # raw-text-fallback path as any other malformed FINDINGS text (see _machine_tail_text) —
    # confirmed live against the real bash renderer for both the fully-unset-var case AND the
    # set-to-empty-string case (both produce the identical `\{}` machine-tail text). Matching
    # this exactly (not the "clean" `{}` this bridge used before) is what makes the machine
    # tail byte-identical to bash's for an agent whose FINDINGS var was never populated.
    findings_raw = os.environ.get(f"{upper}_FINDINGS") or "\\{}"
    try:
        findings_json = jqjson.loads(findings_raw)
    except jqjson.JqParseError:
        findings_json = {}
    if not isinstance(findings_json, dict):
        findings_json = {}
    invariant = os.environ.get(f"{upper}_INVARIANT", "false") == "true"
    reason = os.environ.get(f"{upper}_REASON", "")
    return AgentRenderData(
        color=color,
        verdict=verdict,
        top=top,
        findings_json=findings_json,
        findings_raw=findings_raw,
        invariant=invariant,
        reason=reason,
    )


def render_from_env(head_sha: str, agents: list[str]) -> str:
    """Reads the bash-contract env vars (``<NAME>_COLOR`` etc.) for each agent in ``agents`` and
    renders the comment — the env-var-driven equivalent of calling ``render_comment`` directly
    with a hand-built ``agent_data`` mapping."""
    return render_comment(head_sha, agents, {a: _agent_data_from_env(a) for a in agents})


def overall_color_from_env(agents: list[str]) -> str:
    return overall_color(_agent_data_from_env(a).color for a in agents)


# ---------------------------------------------------------------------------
# CLI shim — docs/PYTHON-PORT.md section 4's "thin CLI shim ... mirroring how the suites drive
# the bash" mechanism for this module. Not the final `pantheon` CLI surface (that's
# `pantheon.cli`, Slice 4); this exists so the migration-exam harness can drive this module as a
# subprocess the same way tests/test-render-comment.sh's original bash-internal suite sources
# cli/lib/render_comment.sh and calls its two public functions directly.
#
#   python3 -m pantheon.render comment <head_sha> <agent...>   # prints the full comment
#   python3 -m pantheon.render overall <agent...>               # prints the overall color
#   python3 -m pantheon.render truncate <text> [max_len]        # exposes the truncate() helper
#
# The third subcommand isn't part of the bash file's two-entry-point public contract (truncate
# is an internal helper there, `_pantheon_truncate`) — it's exposed here purely so the migration-
# exam harness can exercise the character-safe-truncation boundary cases directly, the same way
# tests/test-render-comment.sh's Case 1/Case 2 fixtures call `_pantheon_truncate` in-process
# (this module has no in-process access from a bash test, so the CLI is the black-box seam).
#
# Both `comment`/`overall` read the per-agent env-var contract described in this module's
# docstring; `truncate` takes its input as plain argv.
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) < 1:
        print(
            "usage: python3 -m pantheon.render "
            "{comment <head_sha> <agent...>|overall <agent...>|truncate <text> [max_len]}",
            file=sys.stderr,
        )
        return 2

    subcommand, rest = argv[0], argv[1:]
    if subcommand == "comment":
        if len(rest) < 1:
            print("usage: python3 -m pantheon.render comment <head_sha> <agent...>", file=sys.stderr)
            return 2
        head_sha, agents = rest[0], rest[1:]
        sys.stdout.write(render_from_env(head_sha, agents))
        return 0
    if subcommand == "truncate":
        if len(rest) < 1 or len(rest) > 2:
            print("usage: python3 -m pantheon.render truncate <text> [max_len]", file=sys.stderr)
            return 2
        text = rest[0]
        try:
            max_len = int(rest[1]) if len(rest) == 2 else 90
        except ValueError:
            print("usage: python3 -m pantheon.render truncate <text> [max_len] (max_len must be an integer)", file=sys.stderr)
            return 2
        print(truncate(text, max_len))
        return 0
    if subcommand == "overall":
        if len(rest) < 1:
            print("usage: python3 -m pantheon.render overall <agent...>", file=sys.stderr)
            return 2
        print(overall_color_from_env(rest))
        return 0

    print(f"unknown subcommand: {subcommand}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
