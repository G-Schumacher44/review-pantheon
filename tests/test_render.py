"""tests/test_render.py — fast pytest-level unit coverage for pantheon.render's pure helpers,
PLUS a mechanical enumeration test guarding the one-chokepoint redaction contract.

Most of pantheon.render's coverage lives in the black-box shell suites
(tests/test-render-comment-python.sh, mirroring tests/test-render-comment.sh's bash-parity
fixtures — see that file's own header for why). This file adds:

  1. Direct unit coverage for redact_paths and _machine_tail_text, the two pure helpers where a
     black-box round-trip through the CLI shim would obscure the actual invariant under test.

  2. test_redact_paths_is_the_only_redaction_chokepoint_in_this_module — a MECHANICAL,
     source-level enumeration test (the same pattern tests/test-json-boundary.sh uses to keep
     pantheon.jqjson the one JSON boundary), added per an adversarial-review, round-5,
     coordinator finding: five straight rounds of instance-by-instance redaction patching (too
     narrow -> partial variants -> escape ordering -> unanchored substitution + a missed
     fallback path) converged on ONE rule instead — redact_paths is the module's SOLE redaction
     primitive, and EVERY render_comment() output site that can carry model text or a path
     routes through it (directly, or via sanitize_inline/_machine_tail_text, which themselves
     call it). This test asserts that shape stays true at the SOURCE level, so a sixth ad hoc
     redaction call site can't be added silently — the same guarantee test-json-boundary.sh gives
     pantheon.jqjson, applied to this module's own boundary.
"""

from __future__ import annotations

import inspect
import re
from pathlib import Path

from pantheon import render

RENDER_PY = Path(inspect.getfile(render))


# ---------------------------------------------------------------------------
# Direct unit coverage
# ---------------------------------------------------------------------------


def test_redact_paths_redacts_the_exact_repo_root() -> None:
    root = "/Users/alice/dev/review-pantheon"
    text = "finding under " + root + "/src/gate.sh"
    assert render.redact_paths(text, root) == "finding under <repo>/src/gate.sh"


def test_redact_paths_is_a_noop_when_repo_root_is_falsy() -> None:
    text = "/Users/alice/dev/review-pantheon/src/gate.sh"
    assert render.redact_paths(text, None) == text
    assert render.redact_paths(text, "") == text


def test_redact_paths_does_not_corrupt_an_unrelated_sibling_path() -> None:
    # Adversarial review, round 5, coordinator finding: an unanchored substring match on
    # "/home/alice" also matched (and mangled) the unrelated "/home/alice2/service" -- a
    # DIFFERENT user's home directory that merely shares a prefix. Both directions checked: the
    # real target IS redacted, and the sibling is NOT touched at all.
    root = "/home/alice/dev/review-pantheon"
    text = "see /home/alice/dev/review-pantheon/gate.sh and also /home/alice2/service/unrelated.py"
    result = render.redact_paths(text, root)
    assert "<repo>/gate.sh" in result
    assert "/home/alice2/service/unrelated.py" in result
    assert "<repo>2" not in result


def test_redact_paths_matches_json_escaped_spellings_too() -> None:
    # Adversarial review, round 4/5: a repo_root containing a JSON-escapable character ('"' or
    # '\\') must be redacted whether it appears in its raw form OR its JSON-string-escaped form
    # (backslash-escaped) -- both forms are searched unconditionally, not just the raw one.
    root = '/Users/mal"icious\\user/dev/review-pantheon'
    escaped = root.replace("\\", "\\\\").replace('"', '\\"')
    assert render.redact_paths("raw: " + root, root) == "raw: <repo>"
    assert render.redact_paths("escaped: " + escaped, root) == "escaped: <repo>"


def test_redact_paths_redacts_the_home_directory_prefix_alone() -> None:
    import os

    home = os.path.expanduser("~")
    root = os.path.join(home, "dev", "review-pantheon")
    text = "checkout lives under " + home
    assert render.redact_paths(text, root) == "checkout lives under <repo>"


def test_redact_paths_redacts_trailing_slash_and_realpath_variants() -> None:
    import os

    root = os.path.realpath(__file__)  # a real, existing path on this box
    root_dir = os.path.dirname(root)
    # repo_root itself carries a trailing slash; the leaked text does not.
    assert render.redact_paths("see " + root_dir, root_dir + "/") == "see <repo>"
    # repo_root itself is the realpath-resolved form already (os.path.realpath above), so this
    # also exercises the realpath-variant branch trivially (raw == realpath here); the dedicated
    # symlink-divergence case lives in tests/test-render-comment-python.sh's
    # "repo-root-redaction-symlink" fixture, which needs a real on-disk symlink to be meaningful.


def test_machine_tail_text_redacts_repo_root_containing_json_escapable_characters() -> None:
    root = '/Users/mal"icious\\user/dev/review-pantheon'
    raw_text = '{"file": "' + root.replace("\\", "\\\\").replace('"', '\\"') + '/gate.sh"}'
    result = render._machine_tail_text(raw_text, root)
    assert root not in result
    assert "<repo>/gate.sh" in result


def test_machine_tail_text_redacts_repo_root_in_the_raw_text_fallback_path_too() -> None:
    # Invalid JSON as a WHOLE document -> the raw-text-fallback branch, which never goes through
    # jqjson.dumps() at all. Both the raw AND the JSON-escaped spelling are checked: a malformed/
    # truncated document can still contain individually-escaped fragments that are valid JSON
    # string content even though the overall document doesn't parse (missed in an earlier round).
    root = '/Users/mal"icious\\user/dev/review-pantheon'
    escaped = root.replace("\\", "\\\\").replace('"', '\\"')
    raw_text = 'not valid json overall: {"file": "' + escaped + '", truncated'
    result = render._machine_tail_text(raw_text, root)
    assert root not in result
    assert escaped not in result
    assert "<repo>" in result


def test_machine_tail_text_is_a_noop_when_repo_root_is_none() -> None:
    raw_text = '{"file": "/Users/alice/dev/review-pantheon/gate.sh"}'
    result = render._machine_tail_text(raw_text, None)
    assert "/Users/alice/dev/review-pantheon" in result


# ---------------------------------------------------------------------------
# Mechanical enumeration test — the one-chokepoint contract
# ---------------------------------------------------------------------------

# Bare identifiers a lines.append(...) f-string in render_comment() may interpolate WITHOUT
# itself calling a safety primitive on that same line, because each is already provably safe by
# construction — verified by inspection, documented here so a change to any of these must also
# update this allowlist (and its justification) rather than silently widening what "safe" means:
#   headline, explain   -- _headline_lines(overall): fixed vocabulary keyed only by the `overall`
#                           enum ("green"/"yellow"/"red"/"unverified"), never model-derived text.
#   agent                -- the loop variable from render_comment()'s own `agents` argument (an
#                           operator/config-supplied agent-name list), never JSON model output.
#   short_sha             -- a truncation of `head_sha`, a git SHA the caller/CI context supplies,
#                           never agent JSON output.
#   emoji                 -- emoji_for_color(d.color): a fixed lookup table.
#   fold_open, total_findings -- derived from `overall`/`len(...)`, non-text/count values.
#   vcell, topcell        -- pre-sanitized on their OWN assignment lines a few lines above use
#                           (each wraps a sanitize_inline(...) call there).
#   badge                 -- severity_badge(sev, repo_root): fixed labels for the three known
#                           severities; its only non-fixed branch calls sanitize_inline internally.
#   f_field, ln           -- pre-sanitized (f_field) or format-constrained to `^[0-9]+$` (ln, via
#                           _finding_line_or_placeholder — can never carry a path) on their own
#                           assignment lines, a few lines above use.
_KNOWN_SAFE_BARE_IDENTIFIERS = {
    "headline",
    "explain",
    "agent",
    "short_sha",
    "emoji",
    "fold_open",
    "total_findings",
    "vcell",
    "topcell",
    "badge",
    "f_field",
    "ln",
}

# A lines.append(...) call is exempt entirely when its whole argument is a static string literal
# with no interpolation at all -- nothing external can reach it.
_STATIC_LITERAL_RE = re.compile(r'^\s*"[^{]*"\s*$|^\s*f?"[^{]*"\s*$')

# The three functions that either ARE the redaction chokepoint, or that call it internally on
# every code path -- a lines.append(...) argument calling one of these directly is safe.
_SAFE_CALL_MARKERS = ("sanitize_inline(", "redact_paths(", "_machine_tail_text(")

# {name} -- a bare-identifier f-string interpolation.
_BRACE_IDENTIFIER_RE = re.compile(r"\{(\w+)\}")


def _extract_render_comment_source() -> str:
    src = RENDER_PY.read_text(encoding="utf-8")
    start = src.index("\ndef render_comment(")
    # The next top-level (column-0) "def " after render_comment's own def line is where its body
    # ends -- render_comment is this module's last function before the env-var bridge section.
    rest = src[start + 1 :]
    next_def = re.search(r"\n\ndef |\n\n# -{3,}", rest[len("def render_comment(") :])
    end = len(rest) if next_def is None else next_def.start() + len("def render_comment(")
    return rest[:end]


def _extract_append_call_args(body: str) -> list[str]:
    """Every ``lines.append(...)`` call's argument text, paren-balance-scanned (not a full Python
    parser -- correct here because render_comment's own append calls never nest another
    ``lines.append(`` inside one, and every string literal in this function has balanced
    parens)."""
    calls: list[str] = []
    for m in re.finditer(r"lines\.append\(", body):
        i = m.end()
        depth = 1
        j = i
        while depth > 0:
            if body[j] == "(":
                depth += 1
            elif body[j] == ")":
                depth -= 1
            j += 1
        calls.append(body[i : j - 1])
    return calls


def test_redact_paths_is_the_only_redaction_chokepoint_in_this_module() -> None:
    src = RENDER_PY.read_text(encoding="utf-8")

    # (a) Exactly one function is named redact_paths -- the single primitive.
    def_hits = re.findall(r"^def redact_paths\(", src, re.MULTILINE)
    assert len(def_hits) == 1, f"expected exactly one `def redact_paths(`, found {len(def_hits)}"

    # (b) The redaction placeholder "<repo>" is only ever PRODUCED (as an argument to a `.sub(`
    # call — matches both `pattern.sub(...)` and a bare `re.sub(...)`) inside redact_paths
    # itself — a second ad hoc site independently emitting "<repo>" would be exactly the "sixth
    # site with its own bespoke logic" this test exists to catch. Paren-balance-scanned (not just
    # "immediately follows the open paren") so a call shape like `re.sub(pattern, "<repo>", text)`
    # — the replacement in a DIFFERENT argument position than redact_paths's own
    # `pattern.sub("<repo>", text)` — is still caught; verified this actually catches such a
    # mutation live before relying on it (not merely "should work in theory").
    sub_call_starts = [m.end() for m in re.finditer(r"\.sub\(", src)]
    sub_calls_with_repo_placeholder = 0
    for i in sub_call_starts:
        depth = 1
        j = i
        while depth > 0 and j < len(src):
            if src[j] == "(":
                depth += 1
            elif src[j] == ")":
                depth -= 1
            j += 1
        if '"<repo>"' in src[i:j]:
            sub_calls_with_repo_placeholder += 1
    assert sub_calls_with_repo_placeholder == 1, (
        f"expected exactly one `.sub(...)` call whose arguments contain the \"<repo>\" placeholder "
        f"(inside redact_paths), found {sub_calls_with_repo_placeholder} -- a new redaction call "
        "site must route through redact_paths, not reimplement its own substitution"
    )

    # (c) Every lines.append(...) call inside render_comment() either carries a static string
    # literal (nothing external can reach it), a KNOWN-safe bare identifier (see the allowlist
    # above), or directly invokes one of the three safety primitives.
    body = _extract_render_comment_source()
    append_args = _extract_append_call_args(body)
    assert len(append_args) >= 20, (
        f"expected to find at least 20 lines.append(...) calls in render_comment() (found "
        f"{len(append_args)}) -- has this function been restructured? update this enumeration's "
        "extraction logic (and the allowlist above) to match its new shape"
    )

    violations: list[str] = []
    for arg in append_args:
        stripped = arg.strip()
        if _STATIC_LITERAL_RE.match(stripped):
            continue
        if any(marker in stripped for marker in _SAFE_CALL_MARKERS):
            continue
        if stripped in _KNOWN_SAFE_BARE_IDENTIFIERS:
            continue
        # An f-string argument: every bare {identifier} inside it must be on the allowlist, and
        # anything else inside braces must be one of the safe-call markers (already checked above
        # against the whole argument, so a MIXED f-string like the badge/f_field/ln/sanitize_inline
        # one is handled by the `any(marker in stripped ...)` check above already passing).
        if stripped.startswith('f"') or stripped.startswith("f'"):
            bare_names = set(_BRACE_IDENTIFIER_RE.findall(stripped))
            unknown = bare_names - _KNOWN_SAFE_BARE_IDENTIFIERS
            # sanitize_inline/redact_paths/_machine_tail_text calls inside braces aren't matched
            # by _BRACE_IDENTIFIER_RE (it only matches a BARE {name}, not {call(...)}), so
            # `unknown` here is genuinely the set of un-vetted bare interpolations.
            if not unknown:
                continue
        violations.append(stripped[:120])

    assert not violations, (
        "lines.append(...) call(s) in render_comment() found that neither call a redaction/"
        "sanitization primitive directly nor reference a documented known-safe identifier -- "
        "either route this through sanitize_inline(...)/redact_paths(...), or add the new "
        "identifier to _KNOWN_SAFE_BARE_IDENTIFIERS above WITH a justification for why it's safe "
        "by construction:\n" + "\n".join(f"  - {v}" for v in violations)
    )
