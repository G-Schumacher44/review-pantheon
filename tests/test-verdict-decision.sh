#!/usr/bin/env bash
# tests/test-verdict-decision.sh — cross-runner fixture test for the verdict decision rule.
#
# review-pantheon implements the verdict decision (extract trailing JSON, validate the
# schema, map verdict->color, enforce the blocker invariant) twice: once in bash+jq
# (cli/lib/verdict.sh, used by cli/review-gate) and once in Python (action/decide_verdict.py,
# used by the GitHub Action). DESIGN.md accepts that split — the CLI shouldn't require Python
# and the Action can't cleanly source bash — on the condition that both stay behaviorally
# identical. This script is that check: every fixture below runs through BOTH
# implementations and this script fails if either one disagrees with the expected result, or
# if the two implementations disagree with each other.
#
# No test framework — plain bash, so `bash tests/test-verdict-decision.sh` is the whole
# invocation (also wired into .github/workflows/ci.yml for this repo).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/cli/lib/verdict.sh"

PASS=0
FAIL=0

# check <name> <expected-agent> <raw-output> <expected-color> <expected-invariant-fired>
check() {
  local name="$1" agent="$2" raw="$3" expected_color="$4" expected_invariant="$5"
  local ok=true

  # -- bash+jq path: exactly what cli/review-gate runs (extract_last_json then decide_verdict) --
  local candidate bash_decision bash_color bash_invariant
  candidate="$(printf '%s\n' "$raw" | extract_last_json)"
  bash_decision="$(decide_verdict "$agent" "$candidate")"
  bash_color="$(jq -r '.color' <<<"$bash_decision")"
  bash_invariant="$(jq -r '.invariant_fired' <<<"$bash_decision")"

  # -- python path: the exact file the Action installs and runs, action/decide_verdict.py --
  local raw_file py_decision py_color py_invariant
  raw_file="$(mktemp)"
  printf '%s' "$raw" > "$raw_file"
  py_decision="$(python3 "$ROOT/action/decide_verdict.py" "$agent" "$raw_file" 2>/dev/null)"
  rm -f "$raw_file"
  py_color="$(jq -r '.color' <<<"$py_decision" 2>/dev/null || echo "PARSE_FAILURE")"
  py_invariant="$(jq -r '.invariant_fired' <<<"$py_decision" 2>/dev/null || echo "PARSE_FAILURE")"

  if [[ "$bash_color" != "$expected_color" ]]; then
    echo "FAIL $name: bash  color = '$bash_color', expected '$expected_color'"
    ok=false
  fi
  if [[ "$py_color" != "$expected_color" ]]; then
    echo "FAIL $name: python color = '$py_color', expected '$expected_color'"
    ok=false
  fi
  if [[ "$bash_invariant" != "$expected_invariant" ]]; then
    echo "FAIL $name: bash  invariant_fired = '$bash_invariant', expected '$expected_invariant'"
    ok=false
  fi
  if [[ "$py_invariant" != "$expected_invariant" ]]; then
    echo "FAIL $name: python invariant_fired = '$py_invariant', expected '$expected_invariant'"
    ok=false
  fi
  if [[ "$bash_color" != "$py_color" ]]; then
    echo "FAIL $name: cross-runner disagreement — bash=$bash_color python=$py_color"
    ok=false
  fi

  if $ok; then
    echo "PASS $name (color=$expected_color, invariant_fired=$expected_invariant)"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

check "well-formed-green" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass, nothing to report"}' \
  "green" "false"

check "trailing-prose-after-json" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass"}
Thanks for reading — let me know if you have questions about this review.' \
  "unverified" "false"

check "missing-required-key" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":false}' \
  "unverified" "false"

check "no-json-at-all" "artemis" \
  'I looked at the diff and it seems fine overall, no notable issues found.' \
  "unverified" "false"

check "two-json-objects-last-wins" "artemis" \
  '{"agent":"artemis","verdict":"STOP","has_blocker":true,"findings":[{"severity":"blocker","file":"a.sh","line":1,"issue":"draft finding, ignore","scenario":"n/a"}],"summary":"first draft, discard"}
{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"final answer after reconsidering"}' \
  "green" "false"

check "wrong-vocabulary-verdict" "artemis" \
  '{"agent":"artemis","verdict":"LGTM","has_blocker":false,"findings":[],"summary":"looks good to me"}' \
  "unverified" "false"

check "inconsistent-ship-with-blocker-finding" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":true,"findings":[{"severity":"blocker","file":"src/gate.sh","line":42,"issue":"unquoted variable in rm path","scenario":"a branch name containing a space deletes the wrong path"}],"summary":"looks fine to me"}' \
  "red" "true"

# Bonus coverage: the invariant is an OR of has_blocker and severity=="blocker" — each half
# must independently force red even when the other is absent/false.
check "has-blocker-true-no-blocker-severity" "apollo" \
  '{"agent":"apollo","verdict":"ACCEPT","has_blocker":true,"findings":[{"severity":"should_fix","file":"a","line":1,"issue":"minor","scenario":"minor"}],"summary":"mostly fine"}' \
  "red" "true"

check "blocker-severity-with-has-blocker-false" "apollo" \
  '{"agent":"apollo","verdict":"ACCEPT","has_blocker":false,"findings":[{"severity":"blocker","file":"a","line":1,"issue":"claim not backed by evidence","scenario":"stated test run never happened"}],"summary":"mostly fine"}' \
  "red" "true"

# ---------------------------------------------------------------------------
# Type-strict validation surface — presence-only validation (has("has_blocker") etc.) let a
# malformed field THROUGH the schema check as long as the key existed, regardless of its type.
# jq's `==` / Python's `is`/`==` comparisons in the blocker invariant are type-strict, so
# `"has_blocker": "true"` (a string) never matched `== true` and the invariant silently never
# fired — a malformed verdict could read as a clean, ungated green. Every fixture below must
# come back unverified (never green — a malformed object earns no trust either way) with the
# invariant NOT firing (type-strict failure is checked before the blocker invariant, so there's
# no reliable blocker signal to trust in an object that isn't type-shaped correctly).
# ---------------------------------------------------------------------------
check "has-blocker-is-a-string-not-boolean" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":"true","findings":[],"summary":"clean pass, nothing to report"}' \
  "unverified" "false"

check "findings-is-an-object-not-an-array" "artemis" \
  '{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":{"severity":"should_fix","file":"a","line":1,"issue":"x","scenario":"y"},"summary":"one note"}' \
  "unverified" "false"

check "finding-severity-is-numeric-not-a-string" "artemis" \
  '{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":2,"file":"a","line":1,"issue":"x","scenario":"y"}],"summary":"one note"}' \
  "unverified" "false"

check "finding-severity-out-of-vocabulary" "artemis" \
  '{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"critical","file":"a","line":1,"issue":"x","scenario":"y"}],"summary":"one note"}' \
  "unverified" "false"

check "verdict-field-is-a-number-not-a-string" "artemis" \
  '{"agent":"artemis","verdict":5,"has_blocker":false,"findings":[],"summary":"clean pass"}' \
  "unverified" "false"

# ---------------------------------------------------------------------------
# Extractor hardening — leading whitespace before the trailing JSON object, and an unindented
# `{` belonging to a NESTED object inside an otherwise valid pretty-printed verdict, must not
# defeat extraction (the old `/^\{/`-anchored version reset on both). Fail-closed behavior for
# genuinely malformed output is unaffected — covered above and by the pre-existing fixtures.
# ---------------------------------------------------------------------------
check "leading-whitespace-before-json-object" "artemis" \
  '  {"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass, nothing to report"}' \
  "green" "false"

check "pretty-printed-with-nested-unindented-brace" "artemis" \
  '{
"agent": "artemis",
"verdict": "STOP",
"has_blocker": true,
"findings": [
{
"severity": "blocker",
"file": "src/gate.sh",
"line": 42,
"issue": "unquoted variable in rm path",
"scenario": "a branch name containing a space deletes the wrong path"
}
],
"summary": "one real blocker"
}' \
  "red" "false"

# shellcheck disable=SC2016
# The backtick below is fixture DATA (single-quoted, so bash never interprets it as command
# substitution) — not shell syntax shellcheck needs to warn about.
check "stray-brace-in-prose-before-the-real-verdict" "artemis" \
  'Note: the config format uses `{key}` placeholders, not <angle> brackets.
{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass, nothing to report"}' \
  "green" "false"

# ---------------------------------------------------------------------------
# Extractor round 2 — parse-anchored suffix scan. REPLACES the brace-depth-tracking version
# above (see cli/lib/verdict.sh's extract_last_json / action/decide_verdict.py's own header
# comment for the full incident): Artemis caught, live on this PR, that a `{` left unmatched
# ANYWHERE EARLIER in the output pinned brace-depth above 0 for the rest of the document, so
# the real trailing verdict's own `{` was never treated as a fresh candidate — a legitimate
# green verdict came back UNVERIFIED. The "stray-brace-in-prose" fixture above did NOT catch
# this: it was green-by-construction for exactly the failure it existed to catch, because its
# stray brace happened to be balanced (`{key}`, closed on the same line). Each fixture below
# was verified to FAIL against the round-2 (brace-depth) extractor before being counted here —
# see this PR's commit for the exact repro.
# ---------------------------------------------------------------------------

check "unmatched-brace-in-prose-before-the-real-verdict" "artemis" \
  'Note: the config uses a { that never closes in this sentence, worth flagging.
{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass, nothing to report"}' \
  "green" "false"

check "unmatched-brace-in-prose-after-the-real-verdict" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass, nothing to report"}
Note: a trailing thought with an unmatched { that never closes.' \
  "unverified" "false"

check "pathological-all-braces-no-json" "artemis" \
  '{ { {{ not json at all { { { still not json {{{' \
  "unverified" "false"

# ---------------------------------------------------------------------------
# Extractor round 3 — cross-runtime multi-document divergence (a carried finding from PR #4's
# final review round). jq's stream parser accepts multiple whitespace-separated top-level JSON
# documents and `jq -e '.'` bases its exit status on only the LAST one — so a candidate that's a
# well-formed verdict object immediately followed by a second, unrelated JSON document (an
# array, a bare number — a REAL second document, not malformed prose) read as "valid" to the
# pre-fix bash extractor even though Python's json.loads() already rejects it via "Extra data".
# Left unfixed, this corrupted decide_verdict()'s --argjson calls (each requires exactly one
# JSON value) and crashed the calling shell into empty output under `set -e` instead of
# returning a clean UNVERIFIED — reproduced live against the pre-fix code before landing this
# fix (`jq: invalid JSON text passed to --argjson`, decide_verdict producing empty stdout).
# cli/lib/verdict.sh's `_pantheon_single_json` is the fix: bash now requires exactly one JSON
# document, identically to Python, instead of trusting `jq -e`'s truthy-on-last-value check.
# ---------------------------------------------------------------------------

check "multi-doc-json-stream-two-objects" "artemis" \
  '{"a":1} {"b":2}' \
  "unverified" "false"

check "verdict-followed-by-second-json-doc-trailing-array" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass, nothing to report"}
["not","expected"]' \
  "unverified" "false"

check "verdict-followed-by-second-json-doc-trailing-scalar" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass, nothing to report"}
42' \
  "unverified" "false"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "verdict-decision fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
