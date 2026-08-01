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
# Fixture: a findings ARRAY with one real object and one non-object stray element — regression
# coverage for a deeper version of the same class this repo's own gate found on itself (PR #3,
# artemis's second-round FIX_FIRST finding): the array-type guard above only checked
# `.findings` itself, never that every ELEMENT is an object, so a stray non-object element
# (e.g. a plain string mixed into an otherwise-valid array) crashed every downstream
# .severity/.file/.issue access and silently emptied the itemized list — even for a real
# blocker sitting right next to the malformed element. Must keep the real finding, drop only
# the malformed element, never lose the blocker or crash.
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=red ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="blocker: real blocker"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"SHIP","has_blocker":true,"findings":[{"severity":"blocker","file":"a.sh","line":1,"issue":"real blocker","scenario":"n/a"},"a stray malformed entry"],"summary":"one real blocker, one malformed element"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS

out="$(pantheon_render_comment "$HEAD_SHA" artemis)"
assert_contains "malformed-element" "the real blocker still renders, badge and all" "$out" "**blocker** \`a.sh:1\` — real blocker"
assert_contains "malformed-element" "fold count reflects only the valid object, not both array entries" "$out" "<summary>Full findings (1)</summary>"
assert_contains "malformed-element" "table top-finding cell still surfaces the real blocker" "$out" "real blocker"

# ---------------------------------------------------------------------------
# Fixture: markdown/HTML-hostile content in .file/.issue and a non-numeric .line — regression
# coverage for this repo's own gate finding on itself (PR #3, artemis's live-review round):
# .file/.line reached the itemized list WITHOUT going through _pantheon_sanitize_inline, unlike
# .issue/.scenario/.summary — a model-controlled .file value could carry a backtick and
# prematurely close the single-backtick `file:line` code span (CommonMark has no backslash-
# escape for a backtick INSIDE a single-backtick span), a pipe could fracture the table row,
# and an angle bracket could look like an HTML tag. .line is schema'd as a number but is still
# model output, so a non-numeric value must degrade to the same "?" placeholder used when the
# key is missing, not get interpolated raw where a line number belongs. Everything here must
# still render as a single, structurally intact list item — no broken code span, no extra
# table columns, no raw HTML tag.
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="hostile content finding"
# shellcheck disable=SC2016
# The literal backticks below are JSON string content (single-quoted, so bash never
# interprets them as command substitution) — not shell syntax shellcheck needs to warn about.
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"should_fix","file":"src/`weird`.sh<script>|pipe","line":"not-a-number","issue":"pipe | and backtick ` and angle <b>tag</b>","scenario":"n/a"}],"summary":"hostile content test"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS

out="$(pantheon_render_comment "$HEAD_SHA" artemis)"
# The machine tail (nested "Raw verdict JSON") deliberately ships the RAW, unsanitized verdict
# JSON — that's the whole point of keeping machine-readability (DESIGN.md's "Combined PR
# comment"), so a raw `<script>` legitimately appears there. Only the HUMAN-READABLE section
# (headline through the end of the findings fold's prose, before the machine tail) is what
# this fixture is checking stays sanitized — slice it off before asserting "no raw tag".
human_readable="${out%%<summary>Raw verdict JSON*}"

assert_contains "hostile-content" "non-numeric line degrades to the '?' placeholder" "$out" ":?\` —"
assert_not_contains "hostile-content" "the code span isn't prematurely closed by a smuggled backtick" "$out" "\`src/\`weird\`"
assert_contains "hostile-content" "backtick in .file is neutralized, not dropped silently" "$out" "src/'weird'.sh"
assert_contains "hostile-content" "pipe in .file is escaped, not left to fracture structure" "$out" '\|pipe:?`'
assert_contains "hostile-content" "angle brackets in .file are HTML-escaped" "$out" "&lt;script&gt;"
assert_contains "hostile-content" "angle brackets in .issue are HTML-escaped too" "$out" "&lt;b&gt;tag&lt;/b&gt;"
assert_not_contains "hostile-content" "no raw HTML tag reaches the human-readable section" "$human_readable" "<script>"
assert_not_contains "hostile-content" "no raw HTML tag from .issue reaches the human-readable section" "$human_readable" "<b>tag</b>"
# The renderer's own formatting backticks (the verdict code-span, the identity line's SHA code
# span) must survive intact — sanitizing a value must never corrupt markup THIS FILE added
# around it (the bug the fix above introduced and then had to correct: sanitizing an
# already-backtick-wrapped verdict cell turned its own formatting backticks into quotes too).
assert_contains "hostile-content" "the verdict table cell keeps its own code-span backticks" "$out" "| artemis | \`FIX_FIRST\` — yellow |"
assert_contains "hostile-content" "the identity line keeps its own SHA code-span backticks" "$out" "**artemis** @ \`$SHORT_SHA\` — 🟡 FIX_FIRST"

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
# Fixture: COMPLETENESS — every field of a verdict object (verdict, severity, file, line,
# issue, scenario, summary — plus the invariant-override reason and the fallback "top" text)
# carries a markdown/HTML-hostile payload (backticks, pipes, angle brackets, a raw `<details>`
# tag, an @-mention, and a non-numeric line), all at once. This is the completeness check for
# the audit in cli/lib/render_comment.sh's header comment ("sanitize-at-render" contract): NO
# byte of model-controlled input should reach the human-readable section unsanitized, in ANY
# field, not just the ones earlier fixtures happened to cover one at a time. Regression
# coverage for three rounds of the same bug class this repo's own gate found on itself on PR
# #3: round 1 was .file/.line in the itemized list, round 2 was the renderer's OWN formatting
# backticks getting corrupted by the round-1 fix, round 3 was _pantheon_severity_badge's
# out-of-enum default branch.
#
# The one deliberate exception: the machine tail (nested "Raw verdict JSON") ships the
# untouched JSON on purpose (that's the whole point of keeping a machine-readable copy) — the
# "no raw hostile token" assertions below are scoped to the human-readable section only, the
# same way the earlier "hostile-content" fixture's checks are.
# ---------------------------------------------------------------------------
# Every literal backtick from here through ARTEMIS_REASON below is fixture DATA (single-quoted,
# so bash never interprets it as command substitution) — not shell syntax the linter needs to
# warn about. Same rationale as the file-header disable note above, repeated per-line below
# because the linter's inline directives apply per-line, not to a whole block.
reset_agent_env
ARTEMIS_COLOR=red
# shellcheck disable=SC2016
ARTEMIS_VERDICT='SHIP`<script>|@here'
# shellcheck disable=SC2016
ARTEMIS_TOP='fallback `top` <b>text</b> | @mention'
# shellcheck disable=SC2016
ARTEMIS_FINDINGS='{"agent":"artemis`<x>|@evil","verdict":"SHIP`<script>|@here","has_blocker":true,"findings":[{"severity":"totally_bogus`<sev>|@x","file":"src/`file`.sh<img>|pipe@x","line":"not-a-number`<ln>","issue":"issue `backtick` <b>tag</b> | pipe @mention","scenario":"scenario `backtick` <i>tag</i> | pipe @mention <details><summary>x</summary></details>"}],"summary":"summary `backtick` <script>alert(1)</script> | pipe @mention <details><summary>x</summary></details>"}'
ARTEMIS_INVARIANT=true
# shellcheck disable=SC2016
ARTEMIS_REASON='blocker finding present (severity=blocker or has_blocker=true) — forcing red regardless of stated verdict `SHIP`<script>|@here`'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS ARTEMIS_INVARIANT ARTEMIS_REASON

out="$(pantheon_render_comment "$HEAD_SHA" artemis)"
human_readable="${out%%<summary>Raw verdict JSON*}"

# --- structural validity ---
# Counts are scoped to $human_readable, not the full $out: the raw JSON machine tail is
# deliberately UNSANITIZED (see this fixture's header comment), so the hostile payload's own
# literal "<details>" text legitimately appears again inside the pretty-printed JSON dump —
# counting on $out would conflate that expected, by-design content with a real structural bug.
assert_contains "completeness" "table header survives" "$human_readable" "| Agent | Verdict | Top finding |"
assert_contains "completeness" "the agent's table row is present and 3-column" "$human_readable" "| artemis | \`"
# Exactly two REAL <details> tags belong in the human-readable slice: the outer findings fold
# (forced open) and the bare opening tag of the nested machine-tail fold (the slice cuts right
# after it, at <summary>Raw verdict JSON). Any more than two means a hostile payload leaked an
# unescaped structural tag into the output instead of being neutralized to &lt;details&gt;.
assert_count "completeness" "exactly two real <details> tags in the human-readable section" "$human_readable" "<details" 2
assert_contains "completeness" "outer fold forced open on red" "$human_readable" "<details open>"
assert_contains "completeness" "the identity line and its SHA code span survive" "$human_readable" "**artemis** @ \`$SHORT_SHA\` —"
assert_contains "completeness" "out-of-enum severity is normalized, visually distinct" "$human_readable" "unrecognized-severity("
assert_contains "completeness" "non-numeric line degrades to the placeholder" "$human_readable" ":?\`"

# --- no raw hostile token anywhere in the human-readable section ---
for token in '<script>' '<b>tag' '<i>tag' '<img' '<details><summary>' '</details></details>' '@here' '@mention' '@evil' '@x'; do
  assert_not_contains "completeness" "no raw '$token' in the human-readable section" "$human_readable" "$token"
done

# --- the hostile payloads are neutralized, not silently dropped (content still visible) ---
assert_contains "completeness" "backticks neutralized to a straight quote" "$human_readable" "SHIP'"
assert_contains "completeness" "angle brackets HTML-escaped" "$human_readable" "&lt;script&gt;"
assert_contains "completeness" "the raw <details> payload is escaped, not rendered as a real nested fold" "$human_readable" "&lt;details&gt;&lt;summary&gt;"
assert_contains "completeness" "@-mentions neutralized to the fullwidth lookalike" "$human_readable" "＠here"
assert_contains "completeness" "pipes escaped, table structure not fractured" "$human_readable" '\|'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "render-comment fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
