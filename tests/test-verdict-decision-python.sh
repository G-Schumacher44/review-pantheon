#!/usr/bin/env bash
# tests/test-verdict-decision-python.sh — the black-box Python equivalent of
# tests/test-verdict-decision.sh, per docs/PYTHON-PORT.md section 4's disposition for that
# suite:
#
#   "Needs a black-box equivalent against pantheon's verdict module. Its whole premise (diff two
#    runtimes) collapses once there's one Python implementation — repurpose as a straight
#    fixture test at Slice 2, then simplify away the cross-runtime-diff assertion at Slice 5
#    once the bash decider is retired."
#
# The original suite is bash-internal (it sources cli/lib/verdict.sh directly and execs
# action/decide_verdict.py as a subprocess to cross-check both existing runtimes against the
# same fixtures) — sourcing a .py file the way that suite sources a .sh file is not the right
# shape for its Python equivalent (docs/PYTHON-PORT.md section 4's own framing). This file keeps
# that suite's exact fixture set (same names, same inputs, same expected color/invariant_fired)
# and drives pantheon.verdict as a subprocess instead, the same way the original suite already
# drives action/decide_verdict.py: `python3 -m pantheon.verdict <expected-agent> <raw-file>`.
#
# tests/test-verdict-decision.sh itself is untouched by this port (still sources
# cli/lib/verdict.sh, still execs action/decide_verdict.py) and stays green — this file is an
# ADDITION, not a replacement, until Slice 5 retires the bash decider.
#
# No test framework — plain bash, `bash tests/test-verdict-decision-python.sh` is the whole
# invocation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

# check <name> <expected-agent> <raw-output> <expected-color> <expected-invariant-fired>
check() {
  local name="$1" agent="$2" raw="$3" expected_color="$4" expected_invariant="$5"
  local ok=true

  local raw_file py_decision py_color py_invariant
  raw_file="$(mktemp)"
  printf '%s' "$raw" > "$raw_file"
  py_decision="$(cd "$ROOT" && python3 -m pantheon.verdict "$agent" "$raw_file" 2>/dev/null)"
  rm -f "$raw_file"
  py_color="$(jq -r '.color' <<<"$py_decision" 2>/dev/null || echo "PARSE_FAILURE")"
  py_invariant="$(jq -r '.invariant_fired' <<<"$py_decision" 2>/dev/null || echo "PARSE_FAILURE")"

  if [[ "$py_color" != "$expected_color" ]]; then
    echo "FAIL $name: python color = '$py_color', expected '$expected_color'"
    ok=false
  fi
  if [[ "$py_invariant" != "$expected_invariant" ]]; then
    echo "FAIL $name: python invariant_fired = '$py_invariant', expected '$expected_invariant'"
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
# Fixtures — identical set to tests/test-verdict-decision.sh (same names, inputs, expectations).
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

check "has-blocker-true-no-blocker-severity" "apollo" \
  '{"agent":"apollo","verdict":"ACCEPT","has_blocker":true,"findings":[{"severity":"should_fix","file":"a","line":1,"issue":"minor","scenario":"minor"}],"summary":"mostly fine"}' \
  "red" "true"

check "blocker-severity-with-has-blocker-false" "apollo" \
  '{"agent":"apollo","verdict":"ACCEPT","has_blocker":false,"findings":[{"severity":"blocker","file":"a","line":1,"issue":"claim not backed by evidence","scenario":"stated test run never happened"}],"summary":"mostly fine"}' \
  "red" "true"

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

check "multi-doc-json-stream-two-objects (baseline — does not exercise the fix; see comment above)" "artemis" \
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
echo "verdict-decision (python) fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
