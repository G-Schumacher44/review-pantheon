#!/usr/bin/env bash
# tests/test-json-boundary.sh — asserts pantheon.jqjson is the ONE place this port's Python
# modules parse or serialize JSON directly, per docs/PYTHON-PORT.md's "JSON boundary" section.
#
# Three straight review-gate rounds on pantheon/verdict.py and pantheon/render.py found the same
# class of divergence, one Python-vs-jq mismatch at a time (a non-standard JSON-extension token,
# a lone surrogate real jq rejects but json.loads accepts, a pathologically long integer raising
# a bare ValueError json.JSONDecodeError doesn't catch, a numeric literal overflowing Python's
# IEEE double while jq's arbitrary-precision handling keeps it exact) — patching one instance at
# a time never converged, because the fix has to live at the parse/serialize BOUNDARY itself, not
# scattered across every call site that happens to touch JSON. pantheon/jqjson.py is that
# boundary; this test is the mechanical guarantee nothing quietly reaches past it again.
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
# Summary
# ---------------------------------------------------------------------------
echo
echo "json-boundary fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
