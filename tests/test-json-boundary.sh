#!/usr/bin/env bash
# tests/test-json-boundary.sh — asserts pantheon.jqjson is the ONE place this port's Python
# modules parse, serialize, OR stringify-for-display JSON, per docs/PYTHON-PORT.md's "JSON
# boundary" section.
#
# Four straight review-gate rounds on pantheon/verdict.py and pantheon/render.py found the same
# class of divergence, one Python-vs-jq mismatch at a time: a non-standard JSON-extension token,
# a lone surrogate real jq rejects but json.loads accepts, a pathologically long integer raising
# a bare ValueError json.JSONDecodeError doesn't catch, a numeric literal overflowing Python's
# IEEE double while jq's arbitrary-precision handling keeps it exact (the parse/serialize
# boundary, closed first) — then, immediately after, a SECOND boundary: top_finding_of
# interpolating a raw parsed field via Python's own str()/repr() instead of jq -r's stringify
# form, and a summary of a bare trailing newline reading as non-empty because bash's own
# $(...) command-substitution newline-strip had no Python equivalent. Patching one instance at a
# time never converged, because the fix has to live at the boundary itself, not scattered across
# every call site that happens to touch a JSON-sourced value. pantheon/jqjson.py is both
# boundaries; this test is the mechanical guarantee nothing quietly reaches past either one again.
#
# A plain `grep -E 'json\.(loads|dumps)\('` would also match `jqjson.loads(`/`jqjson.dumps(`
# (the substring "json.loads(" is literally contained in "jqjson.loads("), so this uses a
# `\b` word-boundary anchor before `json` instead — there is no word boundary between the "q"
# and "j" in "jqjson" (both are word characters), so `\bjson\.` only matches a BARE `json.`,
# never the "...jqjson." it's part of inside a real jqjson call. Verified against both shapes
# before relying on it (see this repo's own PR history for the live check).
#
# No test framework — plain bash, `bash tests/test-json-boundary.sh` is the whole invocation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

# check_file <path> — asserts <path> contains no bare `json.loads(`/`json.dumps(` call, and no
# `import json` (the only legitimate reason to import the stdlib module directly is to BE
# pantheon/jqjson.py itself).
check_file() {
  local path="$1" rel="${1#"$ROOT"/}"
  local hits

  hits="$(grep -nE '\bjson\.(loads|dumps)\(' "$path" || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL $rel: bare json.loads(/json.dumps( call(s) found — route through pantheon.jqjson instead:"
    while IFS= read -r line; do echo "    $line"; done <<<"$hits"
    FAIL=$((FAIL + 1))
  else
    echo "PASS $rel: no bare json.loads(/json.dumps( calls"
    PASS=$((PASS + 1))
  fi

  hits="$(grep -nE '^\s*import json\s*$' "$path" || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL $rel: 'import json' found — this file should import pantheon.jqjson instead:"
    while IFS= read -r line; do echo "    $line"; done <<<"$hits"
    FAIL=$((FAIL + 1))
  else
    echo "PASS $rel: no direct 'import json'"
    PASS=$((PASS + 1))
  fi
}

check_file "$ROOT/pantheon/verdict.py"
check_file "$ROOT/pantheon/render.py"

# jqjson.py itself is exempt — it's the one file that's allowed (required) to touch the stdlib
# json module directly; sanity-check it actually does, so this suite would notice if that file
# were ever gutted/renamed and the boundary silently stopped existing.
if grep -qE '\bjson\.(loads|dumps)\(' "$ROOT/pantheon/jqjson.py" && grep -qE '^import json\s*$' "$ROOT/pantheon/jqjson.py"; then
  echo "PASS pantheon/jqjson.py: is itself the json boundary (imports + calls json directly, as expected)"
  PASS=$((PASS + 1))
else
  echo "FAIL pantheon/jqjson.py: does not import/call the stdlib json module — the boundary itself may be broken or missing"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Display-text boundary (jqjson.jq_text / jqjson.subst) — a second, narrower set of mechanical
# checks targeting the EXACT call sites the two live gate findings identified, not a fully
# generic "no dict/list subscript inside any f-string anywhere" rule (which would false-positive
# on legitimate interpolations of THIS module's own already-safe computed values, e.g.
# pantheon/verdict.py's `decision['color']` in its own error-annotation line — never itself
# untrusted parsed-JSON model output, no jq_text needed there).
# ---------------------------------------------------------------------------

# pantheon/verdict.py: top_finding_of's composed "severity: issue (file:line)" string must not
# regress to bare dict-subscript interpolation (`{f['severity']}` etc.) — the exact shape the
# live finding was. `\{f\[` (an f-string brace IMMEDIATELY followed by `f[`) matches that
# original bug precisely and does not match the fixed form (`{jqjson.jq_text(f['severity'])}`,
# where other characters sit between the brace and `f[`) — verified against both shapes before
# relying on it.
hits="$(grep -nE '\{f\[' "$ROOT/pantheon/verdict.py" || true)"
if [[ -n "$hits" ]]; then
  echo "FAIL pantheon/verdict.py: bare {f[...]} f-string interpolation found — route through jqjson.jq_text instead:"
  while IFS= read -r line; do echo "    $line"; done <<<"$hits"
  FAIL=$((FAIL + 1))
else
  echo "PASS pantheon/verdict.py: no bare {f[...]} dict-subscript interpolation (top_finding_of routes through jq_text)"
  PASS=$((PASS + 1))
fi

# pantheon/render.py: the five per-field extraction sites (summary, severity/file/issue/scenario)
# each mirror a bash `var="$(jq -r '.field // default' <<<"$json")"` assignment and must each
# route through BOTH jq_text (stringify) and subst (trailing-newline strip) — matched by variable
# name assigned from a `.get(` call (the extraction line itself, not a later fallback
# reassignment like `summary = d.top`, which legitimately isn't a jq_text/subst site).
extraction_lines="$(grep -nE '^\s*(summary|sev|f_field|issue|scenario) = .*\.get\(' "$ROOT/pantheon/render.py" || true)"
if [[ -z "$extraction_lines" ]]; then
  echo "FAIL pantheon/render.py: none of the five expected per-field extraction assignments found — has render_comment() been restructured?"
  FAIL=$((FAIL + 1))
else
  missing=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" != *"jq_text("* || "$line" != *"subst("* ]]; then
      echo "FAIL pantheon/render.py: extraction site missing jq_text(/subst(: $line"
      missing=1
    fi
  done <<<"$extraction_lines"
  if [[ "$missing" -eq 0 ]]; then
    echo "PASS pantheon/render.py: all five per-field extraction sites route through jq_text + subst"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "json-boundary fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
