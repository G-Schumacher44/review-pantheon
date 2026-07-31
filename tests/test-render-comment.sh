#!/usr/bin/env bash
# tests/test-render-comment.sh — fixture test for cli/lib/render_comment.sh, the combined-PR-
# comment renderer shared by cli/review-gate and action/lib/combine_verdicts.sh (see DESIGN.md's
# "Combined PR comment" section). Feeds it hand-built per-agent verdict sets covering every
# color/edge case and asserts the structural markers a human-first, machine-readable comment
# must carry: the signal headline, the verdict table (right row count, one row per agent), the
# per-agent identity line (agent @ short SHA), severity badges, the blocker-invariant-override
# notice, the reviewed SHA, and the nested machine-readable JSON tail.
#
# No test framework — plain bash, `bash tests/test-render-comment.sh` is the whole invocation
# (also wired into .github/workflows/ci.yml).
#
# shellcheck disable=SC2089,SC2090
# These fixtures assign literal JSON strings (containing quotes) to the exact env var names
# cli/lib/render_comment.sh's contract reads, then `export` them — never `eval`'d or used
# unquoted in a constructed command, so the usual "quotes will be treated literally" gotcha
# these codes warn about doesn't apply here; the values are only ever read back via `${!var}`
# indirection inside the sourced renderer.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/cli/lib/render_comment.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }

# assert_contains <case-name> <check-name> <haystack> <needle>
assert_contains() {
  local case_name="$1" check_name="$2" haystack="$3" needle="$4"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$case_name: $check_name"
  else
    fail "$case_name: $check_name" "expected to find '$needle'"
  fi
}

# assert_not_contains <case-name> <check-name> <haystack> <needle>
assert_not_contains() {
  local case_name="$1" check_name="$2" haystack="$3" needle="$4"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$case_name: $check_name"
  else
    fail "$case_name: $check_name" "did not expect to find '$needle'"
  fi
}

# assert_count <case-name> <check-name> <haystack> <needle> <expected-count>
assert_count() {
  local case_name="$1" check_name="$2" haystack="$3" needle="$4" expected="$5" got
  got="$(grep -o -F "$needle" <<<"$haystack" | wc -l | tr -d ' ')"
  if [[ "$got" == "$expected" ]]; then
    pass "$case_name: $check_name"
  else
    fail "$case_name: $check_name" "expected $expected occurrence(s) of '$needle', got $got"
  fi
}

# Reset every per-agent env var this file's contract reads, between fixtures — otherwise a var
# set by an earlier case would leak into a later one that doesn't set it.
reset_agent_env() {
  local agent upper
  for agent in artemis apollo socrates diogenes plato; do
    upper="$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]')"
    unset "${upper}_COLOR" "${upper}_VERDICT" "${upper}_TOP" "${upper}_FINDINGS" \
      "${upper}_INVARIANT" "${upper}_REASON"
  done
}

HEAD_SHA="dd66f1babc9876543210"
SHORT_SHA="dd66f1b"

# ---------------------------------------------------------------------------
# Fixture: all-green
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass, nothing to report"}'
APOLLO_COLOR=green APOLLO_VERDICT=ACCEPT APOLLO_TOP="no findings"
APOLLO_FINDINGS='{"agent":"apollo","verdict":"ACCEPT","has_blocker":false,"findings":[],"summary":"claims match the diff"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export APOLLO_COLOR APOLLO_VERDICT APOLLO_TOP APOLLO_FINDINGS

out="$(pantheon_render_comment "$HEAD_SHA" artemis apollo)"
assert_contains "all-green" "headline emoji" "$out" "🟢"
assert_contains "all-green" "headline phrase" "$out" "**Clean pass**"
assert_count "all-green" "table row count" "$out" "| artemis |" 1
assert_count "all-green" "table row count (apollo)" "$out" "| apollo |" 1
assert_contains "all-green" "top-finding placeholder for clean agent" "$out" "| — |"
assert_contains "all-green" "identity line — artemis" "$out" "**artemis** @ \`$SHORT_SHA\` — 🟢 SHIP"
assert_contains "all-green" "identity line — apollo" "$out" "**apollo** @ \`$SHORT_SHA\` — 🟢 ACCEPT"
assert_contains "all-green" "machine tail present" "$out" "<summary>Raw verdict JSON</summary>"
assert_not_contains "all-green" "fold not forced open" "$out" "<details open>"

# ---------------------------------------------------------------------------
# Fixture: yellow with review notes
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="should_fix: missing test coverage"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"should_fix","file":"src/gate.sh","line":12,"issue":"missing test coverage on the retry path","scenario":"a flaky retry regresses silently"},{"severity":"note","file":"src/gate.sh","line":30,"issue":"could log more context","scenario":"harder to debug in prod"}],"summary":"mostly fine, two notes worth a look"}'
APOLLO_COLOR=green APOLLO_VERDICT=ACCEPT APOLLO_TOP="no findings"
APOLLO_FINDINGS='{"agent":"apollo","verdict":"ACCEPT","has_blocker":false,"findings":[],"summary":"claims match the diff"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export APOLLO_COLOR APOLLO_VERDICT APOLLO_TOP APOLLO_FINDINGS

out="$(pantheon_render_comment "$HEAD_SHA" artemis apollo)"
assert_contains "yellow-notes" "headline emoji" "$out" "🟡"
assert_contains "yellow-notes" "headline phrase" "$out" "**Review notes**"
assert_contains "yellow-notes" "should_fix badge" "$out" "should_fix \`src/gate.sh:12\`"
assert_contains "yellow-notes" "note badge" "$out" "note \`src/gate.sh:30\`"
assert_contains "yellow-notes" "scenario line" "$out" "scenario: a flaky retry regresses silently"
assert_contains "yellow-notes" "top-finding cell picks should_fix over note" "$out" "missing test coverage on the retry path"
assert_not_contains "yellow-notes" "fold not forced open on yellow" "$out" "<details open>"

# ---------------------------------------------------------------------------
# Fixture: red with blocker + invariant fired
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=red ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="blocker: unquoted variable in rm path"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"SHIP","has_blocker":true,"findings":[{"severity":"blocker","file":"src/gate.sh","line":42,"issue":"unquoted variable in rm path","scenario":"a branch name containing a space deletes the wrong path"}],"summary":"looks fine to me overall"}'
ARTEMIS_INVARIANT=true
ARTEMIS_REASON="blocker finding present (severity=blocker or has_blocker=true) — forcing red regardless of stated verdict 'SHIP'"
APOLLO_COLOR=green APOLLO_VERDICT=ACCEPT APOLLO_TOP="no findings"
APOLLO_FINDINGS='{"agent":"apollo","verdict":"ACCEPT","has_blocker":false,"findings":[],"summary":"claims match the diff"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS ARTEMIS_INVARIANT ARTEMIS_REASON
export APOLLO_COLOR APOLLO_VERDICT APOLLO_TOP APOLLO_FINDINGS

out="$(pantheon_render_comment "$HEAD_SHA" artemis apollo)"
assert_contains "red-blocker" "headline emoji" "$out" "🔴"
assert_contains "red-blocker" "headline phrase" "$out" "**Blocked**"
assert_contains "red-blocker" "blocker badge bolded" "$out" "**blocker** \`src/gate.sh:42\`"
assert_contains "red-blocker" "invariant override notice" "$out" "**Overridden verdict:**"
assert_contains "red-blocker" "override notice cites original stated verdict" "$out" "stated verdict 'SHIP'"
assert_contains "red-blocker" "identity line still shows original verdict word" "$out" "**artemis** @ \`$SHORT_SHA\` — 🔴 SHIP"
assert_contains "red-blocker" "fold forced open on red" "$out" "<details open>"
assert_contains "red-blocker" "machine tail present" "$out" "<summary>Raw verdict JSON</summary>"

# ---------------------------------------------------------------------------
# Fixture: unverified (agent did not run)
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=unverified ARTEMIS_VERDICT=UNVERIFIED ARTEMIS_TOP="agent did not run (not in 'agents' input, or the run step failed before producing a result)"
ARTEMIS_FINDINGS='{}'
APOLLO_COLOR=green APOLLO_VERDICT=ACCEPT APOLLO_TOP="no findings"
APOLLO_FINDINGS='{"agent":"apollo","verdict":"ACCEPT","has_blocker":false,"findings":[],"summary":"claims match the diff"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export APOLLO_COLOR APOLLO_VERDICT APOLLO_TOP APOLLO_FINDINGS

out="$(pantheon_render_comment "$HEAD_SHA" artemis apollo)"
assert_contains "unverified" "headline emoji" "$out" "🟠"
assert_contains "unverified" "headline phrase" "$out" "**NOT GATED (fail-closed)**"
assert_contains "unverified" "top-finding cell falls back to explanatory text" "$out" "agent did not run"
assert_contains "unverified" "fold forced open on unverified/orange" "$out" "<details open>"

# ---------------------------------------------------------------------------
# Fixture: malformed findings shape (a string instead of an array) — regression coverage for
# a gap this repo's own gate found on itself (PR #3, artemis's FIX_FIRST finding): upstream
# validation (cli/lib/verdict.sh, decide_verdict.py) only checks that the `findings` KEY is
# present, never that it's an array, so `"findings": "none"` (a plausible LLM slip) reaches
# this renderer unfiltered. Must degrade to "no findings" (count 0), never a bogus length.
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":"none","summary":"malformed findings shape"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS

out="$(pantheon_render_comment "$HEAD_SHA" artemis)"
assert_contains "malformed-findings" "table top-finding cell degrades to em dash, not a crash" "$out" "| artemis | \`SHIP\` — green | — |"
assert_contains "malformed-findings" "fold count degrades to 0, not the string's character length" "$out" "<summary>Full findings (0)</summary>"
assert_not_contains "malformed-findings" "no bogus non-zero count leaks through" "$out" "Full findings (4)"

# ---------------------------------------------------------------------------
# Fixture: one agent skipped (docs-only apollo skip), loud row required
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":[],"summary":"clean pass"}'
APOLLO_COLOR=yellow APOLLO_VERDICT=SKIPPED APOLLO_TOP="docs-only diff: apollo skipped by design"
APOLLO_FINDINGS='{"agent":"apollo","verdict":"SKIPPED","has_blocker":false,"findings":[],"summary":"docs-only diff: apollo skipped by design"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export APOLLO_COLOR APOLLO_VERDICT APOLLO_TOP APOLLO_FINDINGS

out="$(pantheon_render_comment "$HEAD_SHA" artemis apollo)"
assert_contains "one-skipped" "skipped row is loud in the table" "$out" "| apollo | \`SKIPPED\` — yellow | skipped — docs-only diff: apollo skipped by design |"
assert_contains "one-skipped" "skipped agent still gets an identity-lined section" "$out" "**apollo** @ \`$SHORT_SHA\` — 🟡 SKIPPED"

# ---------------------------------------------------------------------------
# pantheon_overall_color — worst-wins, independent of the renderer
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=green; APOLLO_COLOR=yellow
export ARTEMIS_COLOR APOLLO_COLOR
overall="$(pantheon_overall_color artemis apollo)"
if [[ "$overall" == "yellow" ]]; then
  pass "overall-color: yellow beats green"
else
  fail "overall-color: yellow beats green" "got '$overall'"
fi

reset_agent_env
ARTEMIS_COLOR=red; APOLLO_COLOR=unverified
export ARTEMIS_COLOR APOLLO_COLOR
overall="$(pantheon_overall_color artemis apollo)"
if [[ "$overall" == "red" ]]; then
  pass "overall-color: red beats unverified"
else
  fail "overall-color: red beats unverified" "got '$overall'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "render-comment fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
