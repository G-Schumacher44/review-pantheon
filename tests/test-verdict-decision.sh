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
# Summary
# ---------------------------------------------------------------------------
echo
echo "verdict-decision fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
