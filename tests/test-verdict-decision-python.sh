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
# Additional Python-port regression coverage (beyond the 1:1 bash-suite mirror above) — the
# repo's own self-hosted gate (Codex) found these on this PR, both proven failing pre-fix
# against a live repro before the corresponding pantheon/verdict.py fix landed:
#
#   - NaN in a display field (not the type-strict-validated surface) must not crash decide(),
#     and the resulting decision dict must itself be JSON-safe to re-serialize (main()'s own
#     json.dumps(decision) call) — pre-fix, a raw Python float('nan') survived parsing and
#     `json.dumps(decision)` re-emitted the bare, non-standard `NaN` token (invalid per RFC 8259).
#   - top_finding_of's f-string interpolation of a NaN-valued .line must print jq's own "null"
#     text, not Python's default str(None) == "None" — pre-fix (a plain `None` mapping instead
#     of the _JqNaN sentinel) this printed "blocker: x (a:None)" instead of "blocker: x (a:null)".
#
# These aren't decision-color divergences (NaN never reaches the type-strict-validated surface,
# so color/verdict/invariant_fired are unaffected either way — verified separately) — they're
# about decide()'s own JSON-safety and text output, which the 23-fixture mirror above doesn't
# exercise since none of its fixtures contain non-standard JSON constants.
# ---------------------------------------------------------------------------

check_no_crash_and_valid_json() {
  local name="$1" agent="$2" raw="$3"
  local raw_file py_stdout py_exit
  raw_file="$(mktemp)"
  printf '%s' "$raw" > "$raw_file"
  py_stdout="$(cd "$ROOT" && python3 -m pantheon.verdict "$agent" "$raw_file" 2>/dev/null)"
  py_exit=$?
  rm -f "$raw_file"
  if [[ "$py_exit" -ne 0 && "$py_exit" -ne 1 ]]; then
    echo "FAIL $name: python3 -m pantheon.verdict exited $py_exit (expected 0 or 1, a crash/traceback exits differently)"
    FAIL=$((FAIL + 1))
    return
  fi
  if ! jq -e . <<<"$py_stdout" >/dev/null 2>&1; then
    echo "FAIL $name: decision JSON itself failed to parse (a bare NaN/Infinity token would do this): $py_stdout"
    FAIL=$((FAIL + 1))
    return
  fi
  echo "PASS $name (decide() did not crash; its own JSON output is valid JSON)"
  PASS=$((PASS + 1))
}

check_no_crash_and_valid_json "nan-in-summary-does-not-crash-and-json-dumps-cleanly" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":NaN}'

# top_finding text must interpolate jq's "null" print form for a NaN .line, not Python's "None".
raw_file="$(mktemp)"
printf '%s' '{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"blocker","file":"a","line":NaN,"issue":"x","scenario":"y"}],"summary":"s"}' > "$raw_file"
py_decision="$(cd "$ROOT" && python3 -m pantheon.verdict artemis "$raw_file" 2>/dev/null)"
rm -f "$raw_file"
py_top="$(jq -r '.top_finding' <<<"$py_decision" 2>/dev/null)"
if [[ "$py_top" == "blocker: x (a:null)" ]]; then
  echo "PASS nan-line-interpolates-as-jq-null-not-python-none (top_finding='$py_top')"
  PASS=$((PASS + 1))
else
  echo "FAIL nan-line-interpolates-as-jq-null-not-python-none: got '$py_top', expected 'blocker: x (a:null)'"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# JSON-boundary regression coverage (docs/PYTHON-PORT.md's "JSON boundary" section,
# pantheon/jqjson.py) — three more real gate findings, each independently verified live
# (against real bash / real jq / real Python) as failing pre-fix before pantheon.jqjson landed.
# ---------------------------------------------------------------------------

check "lone-surrogate-in-display-field-is-unverified-not-green" "artemis" \
  '{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"\ud800"}' \
  "unverified" "false"
# Verified live against the real bash decider (cli/lib/verdict.sh, sourced directly): its own
# extract_last_json/_pantheon_single_json returns an EMPTY candidate for this exact input — jq's
# parser rejects a lone surrogate outright — so bash's decide_verdict lands on the identical
# "no parseable JSON object found" -> unverified outcome the check() call above asserts for
# Python. Pre-fix, pantheon.verdict (before routing through pantheon.jqjson) decided GREEN for
# this input instead — json.loads accepted the lone surrogate without complaint, a genuine
# decision-color divergence from bash's real, already-correct behavior, not just a display-text
# one.

check "5000-digit-integer-in-display-field-is-unverified-not-a-crash" "artemis" \
  "{\"agent\":\"artemis\",\"verdict\":\"SHIP\",\"has_blocker\":false,\"findings\":[],\"summary\":$(printf '9%.0s' $(seq 1 5000))}" \
  "unverified" "false"
# Python 3.11+'s int-string-conversion digit limit (sys.set_int_max_str_digits, default 4300)
# makes a bare json.loads() raise ValueError -- NOT json.JSONDecodeError -- for an integer this
# long anywhere in the source text, even in a wholly unvalidated display field. Pre-fix, neither
# extract_last_json's per-candidate probe nor decide()'s own parse call caught this exception
# type, so this fixture crashed the whole process (an uncaught traceback) instead of landing on
# the fail-closed "unverified" this check() call now asserts -- pantheon.jqjson's deliberate
# catch-ALL posture (not an enumerated list of exception types) is what closes this.

# pantheon.jqjson's second boundary (display-TEXT, jq_text): top_finding_of's composed string
# must stringify a boolean/null field the way jq's own string interpolation would (lowercase
# true/false, the literal text "null"), not Python's default str()/repr() (True/False/None).
raw_file="$(mktemp)"
printf '%s' '{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"blocker","file":true,"line":1,"issue":null}],"summary":"s"}' > "$raw_file"
py_decision="$(cd "$ROOT" && python3 -m pantheon.verdict artemis "$raw_file" 2>/dev/null)"
rm -f "$raw_file"
py_top="$(jq -r '.top_finding' <<<"$py_decision" 2>/dev/null)"
if [[ "$py_top" == "blocker: null (true:1)" ]]; then
  echo "PASS bool-and-null-fields-interpolate-jq-compatible-not-python-repr (top_finding='$py_top')"
  PASS=$((PASS + 1))
else
  echo "FAIL bool-and-null-fields-interpolate-jq-compatible-not-python-repr: got '$py_top', expected 'blocker: null (true:1)'"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "verdict-decision (python) fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
