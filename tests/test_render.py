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
# Credential redaction — literal-value pass
# ---------------------------------------------------------------------------

# Obviously-fake filler, never a real credential shape/value — used everywhere below a test needs
# a stand-in for "some long opaque secret string."
_FAKE_TOKEN_VALUE = "not-a-real-secret-0123456789abcdef"


def test_redact_credentials_redacts_a_literal_env_value(monkeypatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", _FAKE_TOKEN_VALUE)
    text = "leaked in a finding: " + _FAKE_TOKEN_VALUE + " end"
    result = render._redact_credentials(text)
    assert _FAKE_TOKEN_VALUE not in result
    assert "<redacted-credential>" in result


def test_redact_credentials_covers_every_documented_credential_env_key(monkeypatch) -> None:
    for key in render._CREDENTIAL_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    for key in render._CREDENTIAL_ENV_KEYS:
        monkeypatch.setenv(key, _FAKE_TOKEN_VALUE + key)
    for key in render._CREDENTIAL_ENV_KEYS:
        result = render._redact_credentials("value for " + key + ": " + _FAKE_TOKEN_VALUE + key)
        assert _FAKE_TOKEN_VALUE + key not in result, f"{key} was not redacted"


def test_redact_credentials_skips_an_unset_env_var_silently(monkeypatch) -> None:
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    text = "nothing secret here, and definitely not " + _FAKE_TOKEN_VALUE
    # The unset var must never crash and must never redact unrelated text.
    result = render._redact_credentials(text)
    assert result == text


def test_redact_credentials_skips_an_empty_env_value(monkeypatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", "")
    text = "an ordinary sentence that must not be corrupted by an empty redaction target."
    assert render._redact_credentials(text) == text


def test_redact_credentials_skips_a_too_short_env_value(monkeypatch) -> None:
    short_value = "abc123"  # well under _MIN_CREDENTIAL_LITERAL_LEN
    assert len(short_value) < render._MIN_CREDENTIAL_LITERAL_LEN
    monkeypatch.setenv("GITHUB_TOKEN", short_value)
    text = "this prose happens to contain abc123 as an ordinary substring, not a secret."
    assert render._redact_credentials(text) == text


# ---------------------------------------------------------------------------
# Credential redaction — shape-based pass
# ---------------------------------------------------------------------------


def test_redact_credentials_matches_a_github_token_shape_with_no_matching_env_var(monkeypatch) -> None:
    for key in render._CREDENTIAL_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    fake_ghp = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4"
    text = "a token leaked from PR content: " + fake_ghp
    result = render._redact_credentials(text)
    assert fake_ghp not in result
    assert "<redacted-credential>" in result


def test_redact_credentials_matches_every_github_prefix_and_the_fine_grained_pat(monkeypatch) -> None:
    for key in render._CREDENTIAL_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    filler = "A1b2C3d4E5f6G7h8I9j0K1l2M3n4"
    for prefix in ("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"):
        fake = prefix + filler
        result = render._redact_credentials("token: " + fake)
        assert fake not in result, f"{prefix} shape was not redacted"


def test_redact_credentials_matches_an_anthropic_key_shape_with_no_matching_env_var(monkeypatch) -> None:
    for key in render._CREDENTIAL_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    fake_key = "sk-ant-" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4"
    text = "leaked: " + fake_key
    result = render._redact_credentials(text)
    assert fake_key not in result
    assert "<redacted-credential>" in result


def test_redact_credentials_does_not_flag_a_short_unrelated_gh_prefixed_word(monkeypatch) -> None:
    for key in render._CREDENTIAL_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    text = "ghost_of_a_variable_name and ghp_short are not credential leaks"
    result = render._redact_credentials(text)
    # "ghost_..." doesn't match the gh[psour]_ prefix set at all; "ghp_short" is under the
    # 20-char trailing-length floor -- neither should be touched.
    assert result == text


# ---------------------------------------------------------------------------
# Credential redaction, through the redact_paths chokepoint and the machine tail
# ---------------------------------------------------------------------------


def test_redact_paths_redacts_credentials_even_when_repo_root_is_none(monkeypatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", _FAKE_TOKEN_VALUE)
    text = "credential in text with no repo_root configured: " + _FAKE_TOKEN_VALUE
    result = render.redact_paths(text, None)
    assert _FAKE_TOKEN_VALUE not in result
    assert "<redacted-credential>" in result


def test_redact_paths_redacts_both_credentials_and_paths_in_one_call(monkeypatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", _FAKE_TOKEN_VALUE)
    root = "/Users/alice/dev/review-pantheon"
    text = "token " + _FAKE_TOKEN_VALUE + " leaked from " + root + "/src/gate.sh"
    result = render.redact_paths(text, root)
    assert _FAKE_TOKEN_VALUE not in result
    assert root not in result
    assert "<redacted-credential>" in result
    assert "<repo>/src/gate.sh" in result


def test_machine_tail_text_redacts_a_credential_in_the_parsed_json_success_path(monkeypatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", _FAKE_TOKEN_VALUE)
    raw_text = '{"issue": "leaked token ' + _FAKE_TOKEN_VALUE + '"}'
    result = render._machine_tail_text(raw_text, None)
    assert _FAKE_TOKEN_VALUE not in result
    assert "<redacted-credential>" in result


def test_machine_tail_text_redacts_a_credential_in_the_raw_text_fallback_path(monkeypatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", _FAKE_TOKEN_VALUE)
    raw_text = 'not valid json overall: {"issue": "leaked ' + _FAKE_TOKEN_VALUE + '", truncated'
    result = render._machine_tail_text(raw_text, None)
    assert _FAKE_TOKEN_VALUE not in result
    assert "<redacted-credential>" in result


# ---------------------------------------------------------------------------
# Credential redaction must survive _table_top_cell's truncation — regression coverage for the
# bug where truncate(best, 90) ran BEFORE redaction: a credential straddling that 90-char cut
# point kept the literal-value pass from seeing one contiguous run to match, and could push the
# shape regex's trailing-length floor past the truncated tail too, letting a fragment of the real
# credential survive into a posted comment. Repeating across padding offsets covers the
# "reconstruct the secret by walking the truncation window across several runs" attack, not just
# one lucky (or unlucky) alignment.
# ---------------------------------------------------------------------------

# Obviously-fake filler shaped like a GitHub PAT (matches _CREDENTIAL_SHAPE_RE on its own, and is
# also used as a literal GITHUB_TOKEN value below) — never a real credential. 32 chars total, well
# past both _MIN_CREDENTIAL_LITERAL_LEN and the shape regex's 20-char trailing floor.
_FAKE_STRADDLING_TOKEN = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4"


def test_table_top_cell_redacts_a_credential_before_truncating_not_after(monkeypatch) -> None:
    monkeypatch.setenv("GITHUB_TOKEN", _FAKE_STRADDLING_TOKEN)
    for offset in range(0, len(_FAKE_STRADDLING_TOKEN), 4):
        # Padding chosen so the token lands at a different position relative to truncate()'s
        # 90-char cut on each iteration -- some offsets put the cut mid-token, some put the whole
        # token on one side of it. Every offset must come back clean regardless.
        padding = "x" * (60 + offset)
        suffix = "y" * 60
        issue = padding + _FAKE_STRADDLING_TOKEN + suffix
        assert len(issue) > 90  # must actually exercise truncate()'s cap, not just be a no-op
        verdict_obj = {"findings": [{"severity": "blocker", "issue": issue}]}

        cell = render._table_top_cell("VERIFIED", "", verdict_obj, None)
        rendered = render.sanitize_inline(cell, None)  # the same call render_comment() makes

        assert _FAKE_STRADDLING_TOKEN not in rendered, f"offset={offset}: full token leaked"
        # No 8-plus-char fragment of the token should survive either -- a partial leak is still
        # enough for an attacker to stitch the full secret back together across repeated runs.
        for i in range(len(_FAKE_STRADDLING_TOKEN) - 8):
            fragment = _FAKE_STRADDLING_TOKEN[i : i + 8]
            assert fragment not in rendered, f"offset={offset}: fragment {fragment!r} leaked"


def test_table_top_cell_redacts_a_repo_root_before_truncating_not_after() -> None:
    # Same class of bug, the path-redaction half: a repo_root landing across the truncation cut
    # point must not survive as a dangling fragment either.
    #
    # A bare `root not in rendered` check can't fail here: truncate() cuts at 90 chars, and every
    # offset below puts root's start at index >= 60, so truncate() alone already guarantees the
    # untouched string "root" (49 chars) is never fully present past the cut -- the assertion
    # would pass whether or not redact_paths() ran at all. Mirrors the credential sibling above:
    # sweep for any 8-plus-char FRAGMENT of root surviving, which is exactly what a
    # truncate-before-redact regression leaves behind (a partial root cut mid-string, never
    # matched by redact_paths's whole-string pattern on the truncated remainder).
    root = "/Users/alice/dev/review-pantheon-secret-checkout"
    for offset in range(0, len(root), 5):
        padding = "x" * (60 + offset)
        suffix = "y" * 60
        issue = padding + root + "/gate.sh" + suffix
        assert len(issue) > 90
        verdict_obj = {"findings": [{"severity": "blocker", "issue": issue}]}

        cell = render._table_top_cell("VERIFIED", "", verdict_obj, root)
        rendered = render.sanitize_inline(cell, root)

        assert root not in rendered, f"offset={offset}: full repo_root leaked"
        for i in range(len(root) - 8):
            fragment = root[i : i + 8]
            assert fragment not in rendered, f"offset={offset}: fragment {fragment!r} leaked"


def test_redact_paths_is_idempotent_on_already_redacted_text(monkeypatch) -> None:
    # _table_top_cell's early redact_paths() call and the caller's later
    # sanitize_inline(...)/redact_paths() call both run over the SAME text -- correctness depends
    # on the second pass being a true no-op, not just re-redacting harmlessly by luck. Verified
    # explicitly here rather than assumed.
    monkeypatch.setenv("GITHUB_TOKEN", _FAKE_TOKEN_VALUE)
    root = "/Users/alice/dev/review-pantheon"
    text = "token " + _FAKE_TOKEN_VALUE + " leaked from " + root + "/src/gate.sh"

    once = render.redact_paths(text, root)
    twice = render.redact_paths(once, root)

    assert once == twice
    assert _FAKE_TOKEN_VALUE not in once
    assert root not in once
    assert "<redacted-credential>" in once
    assert "<repo>/src/gate.sh" in once


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

    # (a)+(b) One primitive per redaction concern, and each placeholder produced in exactly
    # one place. Parameterized rather than written twice: the path and credential primitives
    # are the same invariant with different names, and the previous form duplicated ~40 lines
    # so a future third primitive would have been copy-pasted a third time.
    #
    # `expected_refs` is how many times the name may appear in the module at all: redact_paths
    # is the public entry point (its own `def` only — callers live in other functions and are
    # counted by (c)'s enumeration instead), while _redact_credentials must appear exactly
    # twice, its `def` plus the single call inside redact_paths. A third occurrence means
    # something bypassed the chokepoint to call it directly.
    def _sub_calls_mentioning(token: str) -> int:
        """Count `.sub(...)` calls whose full argument list mentions `token`.

        Paren-balance-scanned, not "immediately after the open paren", so a call shaped
        `re.sub(pattern, PLACEHOLDER, text)` is caught as well as `pattern.sub(PLACEHOLDER, text)`.
        Verified live against a real mutation before being relied on.
        """
        found = 0
        for m in re.finditer(r"\.sub\(", src):
            i = m.end()
            depth, j = 1, m.end()
            while depth > 0 and j < len(src):
                if src[j] == "(":
                    depth += 1
                elif src[j] == ")":
                    depth -= 1
                j += 1
            if token in src[i:j]:
                found += 1
        return found

    for name, placeholder, expected_refs in (
        ("redact_paths", '"<repo>"', None),
        ("_redact_credentials", "_REDACTED_CREDENTIAL", 2),
    ):
        defs = re.findall(rf"^def {re.escape(name)}\(", src, re.MULTILINE)
        assert len(defs) == 1, f"expected exactly one `def {name}(`, found {len(defs)}"

        emitters = _sub_calls_mentioning(placeholder)
        assert emitters == 1, (
            f"expected exactly one `.sub(...)` call whose arguments reference {placeholder} "
            f"(inside {name}), found {emitters} -- a new redaction site must route through "
            f"{name}, not reimplement its own substitution"
        )

        if expected_refs is not None:
            refs = len(re.findall(rf"{re.escape(name)}\(", src))
            assert refs == expected_refs, (
                f"expected `{name}(` to appear exactly {expected_refs} times in "
                f"{RENDER_PY.name} (its `def` line and the one call inside redact_paths), "
                f"found {refs} -- a new call site must route through redact_paths instead"
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


# ---------------------------------------------------------------------------
# Structural invariant — every credential-shaped forwarded env key is redactable
# ---------------------------------------------------------------------------

# Which of a real allowlist's own key NAMES look credential-shaped -- TOKEN/SECRET/KEY are the
# three substrings every actual secret-value entry on both pantheon.cli._CLI_ENV_PASSTHROUGH_KEYS
# and pantheon.providers._PROVIDER_ENV_PASSTHROUGH_KEYS carries today (GH_TOKEN, GITHUB_TOKEN,
# GH_ENTERPRISE_TOKEN, ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN, OPENAI_API_KEY, GEMINI_API_KEY, GOOGLE_API_KEY,
# CURSOR_API_KEY -- verified by hand once, at authoring time, against both real tuples; NOT
# hand-copied into this test as their own list, which is exactly what let GH_ENTERPRISE_TOKEN slip
# through undetected before this test existed). Every non-credential entry on both allowlists today
# (HOME, USER, LANG, TERM, TMPDIR, TZ, the XDG_* roots, GH_HOST, GH_CONFIG_DIR, SSH_AUTH_SOCK,
# SSH_AGENT_PID, CLAUDE_CONFIG_DIR, the CLAUDE_CODE_USE_* flags, AWS_REGION, AWS_DEFAULT_REGION,
# AWS_PROFILE, GOOGLE_CLOUD_PROJECT, CLOUD_ML_REGION, and every *_PROXY variant) contains none of
# these three substrings -- the one near-miss, GOOGLE_APPLICATION_CREDENTIALS, is excluded via
# providers._PATH_SHAPED_ENV_KEYS below (a credentials FILE PATH, not an opaque credential value --
# redact_paths's containment logic is the right tool for that, not this one).
_CREDENTIAL_NAME_MARKERS = ("TOKEN", "SECRET", "KEY")


def _credential_shaped_keys(env_keys, path_shaped_keys=frozenset()):
    return {
        key
        for key in env_keys
        if key not in path_shaped_keys and any(marker in key.upper() for marker in _CREDENTIAL_NAME_MARKERS)
    }


def test_every_credential_shaped_forwarded_env_key_is_redacted() -> None:
    """Mechanically enforces the actual structural gap Codex found on PR #75 (GH_ENTERPRISE_TOKEN
    forwarded by pantheon.cli, never redacted): every env-var NAME on either real allowlist that
    forwards process env into a reviewer subprocess -- pantheon.cli._CLI_ENV_PASSTHROUGH_KEYS
    (git/gh auth for this repo's own orchestration calls) and
    pantheon.providers._PROVIDER_ENV_PASSTHROUGH_KEYS (the provider CLI lanes) -- and that LOOKS
    credential-shaped by name must also be a literal-value redaction target in
    render._CREDENTIAL_ENV_KEYS. Derived from the real module constants at test time, not a
    hand-copied name list, so a future contributor who forwards a new credential to either
    allowlist without teaching render._CREDENTIAL_ENV_KEYS about it fails THIS test -- the same
    class of gap this test itself was added to close does not get to reopen silently.
    """
    from pantheon import cli, providers

    forwarded_credential_keys = _credential_shaped_keys(cli._CLI_ENV_PASSTHROUGH_KEYS) | _credential_shaped_keys(
        providers._PROVIDER_ENV_PASSTHROUGH_KEYS, providers._PATH_SHAPED_ENV_KEYS
    )
    redacted_keys = set(render._CREDENTIAL_ENV_KEYS)
    missing = forwarded_credential_keys - redacted_keys
    assert not missing, (
        "credential-shaped env var name(s) forwarded to a reviewer subprocess but absent from "
        f"render._CREDENTIAL_ENV_KEYS, so they could never be literally redacted: {sorted(missing)} "
        "-- add each to render._CREDENTIAL_ENV_KEYS"
    )
