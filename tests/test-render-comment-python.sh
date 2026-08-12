#!/usr/bin/env bash
# tests/test-render-comment-python.sh — the black-box Python equivalent of the retired
# tests/test-render-comment.sh. That suite's disposition:
# "Needs a black-box/Python-native equivalent against the render module. Slice 2 exit bar."
#
# The original suite was bash-internal (it sourced the retired bash CLI's render_comment.sh
# (removed in #29) directly and called its two public functions, pantheon_render_comment /
# pantheon_overall_color, in-process). Sourcing a .py file the way that suite sourced a .sh file
# was not the right shape for its Python equivalent — this file keeps the exact
# same fixture set (same per-agent env vars, same assertions, same expected substrings/counts)
# and drives pantheon.render as a subprocess instead, via the module's CLI shim:
#   python3 -m pantheon.render comment <head_sha> <agent...>   (reads the same *_COLOR/etc. env
#   python3 -m pantheon.render overall <agent...>               vars the bash contract does)
#
# tests/test-render-comment.sh itself was deleted along with the rest of the bash CLI in #29;
# this file, originally an ADDITION alongside it, is now the sole suite covering this behavior.
#
# No test framework — plain bash, `bash tests/test-render-comment-python.sh` is the whole
# invocation.
#
# shellcheck disable=SC2089,SC2090
# Same rationale as tests/test-render-comment.sh's own header: these fixtures assign literal
# JSON strings (containing quotes) to env vars, then `export` them — never `eval`'d or used
# unquoted in a constructed command.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# Reset every per-agent env var this module's env-var contract reads, between fixtures.
reset_agent_env() {
  local agent upper
  for agent in artemis apollo socrates diogenes plato; do
    upper="$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]')"
    unset "${upper}_COLOR" "${upper}_VERDICT" "${upper}_TOP" "${upper}_FINDINGS" \
      "${upper}_INVARIANT" "${upper}_REASON"
  done
}

# render <head_sha> <agent...> — invokes the pantheon.render CLI shim in-repo.
render() {
  (cd "$ROOT" && python3 -m pantheon.render comment "$@")
}

# overall_color <agent...> — invokes the pantheon.render CLI shim's "overall" subcommand.
overall_color() {
  (cd "$ROOT" && python3 -m pantheon.render overall "$@")
}

# render_truncate <text> [max_len] — invokes the pantheon.render CLI shim's "truncate"
# subcommand (a debug-only seam this module's CLI shim exposes purely so this suite can exercise
# the character-safe-truncation boundary cases directly, the same way the original bash suite's
# Case 1/Case 2 fixtures call `_pantheon_truncate` in-process).
render_truncate() {
  (cd "$ROOT" && python3 -m pantheon.render truncate "$@")
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

out="$(render "$HEAD_SHA" artemis apollo)"
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

out="$(render "$HEAD_SHA" artemis apollo)"
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

out="$(render "$HEAD_SHA" artemis apollo)"
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

out="$(render "$HEAD_SHA" artemis apollo)"
assert_contains "unverified" "headline emoji" "$out" "🟠"
assert_contains "unverified" "headline phrase" "$out" "**NOT GATED (fail-closed)**"
assert_contains "unverified" "top-finding cell falls back to explanatory text" "$out" "agent did not run"
assert_contains "unverified" "fold forced open on unverified/orange" "$out" "<details open>"

# ---------------------------------------------------------------------------
# Fixture: malformed findings shape (a string instead of an array)
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"SHIP","has_blocker":false,"findings":"none","summary":"malformed findings shape"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS

out="$(render "$HEAD_SHA" artemis)"
assert_contains "malformed-findings" "table top-finding cell degrades to em dash, not a crash" "$out" "| artemis | \`SHIP\` — green | — |"
assert_contains "malformed-findings" "fold count degrades to 0, not the string's character length" "$out" "<summary>Full findings (0)</summary>"
assert_not_contains "malformed-findings" "no bogus non-zero count leaks through" "$out" "Full findings (4)"

# ---------------------------------------------------------------------------
# Fixture: a findings ARRAY with one real object and one non-object stray element
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=red ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="blocker: real blocker"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"SHIP","has_blocker":true,"findings":[{"severity":"blocker","file":"a.sh","line":1,"issue":"real blocker","scenario":"n/a"},"a stray malformed entry"],"summary":"one real blocker, one malformed element"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS

out="$(render "$HEAD_SHA" artemis)"
assert_contains "malformed-element" "the real blocker still renders, badge and all" "$out" "**blocker** \`a.sh:1\` — real blocker"
assert_contains "malformed-element" "fold count reflects only the valid object, not both array entries" "$out" "<summary>Full findings (1)</summary>"
assert_contains "malformed-element" "table top-finding cell still surfaces the real blocker" "$out" "real blocker"

# ---------------------------------------------------------------------------
# Fixture: markdown/HTML-hostile content in .file/.issue and a non-numeric .line
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="hostile content finding"
# shellcheck disable=SC2016
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"should_fix","file":"src/`weird`.sh<script>|pipe","line":"not-a-number","issue":"pipe | and backtick ` and angle <b>tag</b>","scenario":"n/a"}],"summary":"hostile content test"}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS

out="$(render "$HEAD_SHA" artemis)"
human_readable="${out%%<summary>Raw verdict JSON*}"

assert_contains "hostile-content" "non-numeric line degrades to the '?' placeholder" "$out" ":?\` —"
assert_not_contains "hostile-content" "the code span isn't prematurely closed by a smuggled backtick" "$out" "\`src/\`weird\`"
assert_contains "hostile-content" "backtick in .file is neutralized, not dropped silently" "$out" "src/'weird'.sh"
assert_contains "hostile-content" "pipe in .file is escaped, not left to fracture structure" "$out" '\|pipe:?`'
assert_contains "hostile-content" "angle brackets in .file are HTML-escaped" "$out" "&lt;script&gt;"
assert_contains "hostile-content" "angle brackets in .issue are HTML-escaped too" "$out" "&lt;b&gt;tag&lt;/b&gt;"
assert_not_contains "hostile-content" "no raw HTML tag reaches the human-readable section" "$human_readable" "<script>"
assert_not_contains "hostile-content" "no raw HTML tag from .issue reaches the human-readable section" "$human_readable" "<b>tag</b>"
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

out="$(render "$HEAD_SHA" artemis apollo)"
assert_contains "one-skipped" "skipped row is loud in the table" "$out" "| apollo | \`SKIPPED\` — yellow | skipped — docs-only diff: apollo skipped by design |"
assert_contains "one-skipped" "skipped agent still gets an identity-lined section" "$out" "**apollo** @ \`$SHORT_SHA\` — 🟡 SKIPPED"

# ---------------------------------------------------------------------------
# overall_color — worst-wins, independent of the renderer
# ---------------------------------------------------------------------------
reset_agent_env
ARTEMIS_COLOR=green; APOLLO_COLOR=yellow
export ARTEMIS_COLOR APOLLO_COLOR
overall="$(overall_color artemis apollo)"
if [[ "$overall" == "yellow" ]]; then
  pass "overall-color: yellow beats green"
else
  fail "overall-color: yellow beats green" "got '$overall'"
fi

reset_agent_env
ARTEMIS_COLOR=red; APOLLO_COLOR=unverified
export ARTEMIS_COLOR APOLLO_COLOR
overall="$(overall_color artemis apollo)"
if [[ "$overall" == "red" ]]; then
  pass "overall-color: red beats unverified"
else
  fail "overall-color: red beats unverified" "got '$overall'"
fi

# ---------------------------------------------------------------------------
# Fixture: COMPLETENESS — every field carries a markdown/HTML-hostile payload at once.
# ---------------------------------------------------------------------------
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

out="$(render "$HEAD_SHA" artemis)"
human_readable="${out%%<summary>Raw verdict JSON*}"

assert_contains "completeness" "table header survives" "$human_readable" "| Agent | Verdict | Top finding |"
assert_contains "completeness" "the agent's table row is present and 3-column" "$human_readable" "| artemis | \`"
assert_count "completeness" "exactly two real <details> tags in the human-readable section" "$human_readable" "<details" 2
assert_contains "completeness" "outer fold forced open on red" "$human_readable" "<details open>"
assert_contains "completeness" "the identity line and its SHA code span survive" "$human_readable" "**artemis** @ \`$SHORT_SHA\` —"
assert_contains "completeness" "out-of-enum severity is normalized, visually distinct" "$human_readable" "unrecognized-severity("
assert_contains "completeness" "non-numeric line degrades to the placeholder" "$human_readable" ":?\`"

for token in '<script>' '<b>tag' '<i>tag' '<img' '<details><summary>' '</details></details>' '@here' '@mention' '@evil' '@x'; do
  assert_not_contains "completeness" "no raw '$token' in the human-readable section" "$human_readable" "$token"
done

assert_contains "completeness" "backticks neutralized to a straight quote" "$human_readable" "SHIP'"
assert_contains "completeness" "angle brackets HTML-escaped" "$human_readable" "&lt;script&gt;"
assert_contains "completeness" "the raw <details> payload is escaped, not rendered as a real nested fold" "$human_readable" "&lt;details&gt;&lt;summary&gt;"
assert_contains "completeness" "@-mentions neutralized to the fullwidth lookalike" "$human_readable" "＠here"
assert_contains "completeness" "pipes escaped, table structure not fractured" "$human_readable" '\|'

# ---------------------------------------------------------------------------
# Fixture: truncate is character-safe, not byte-safe.
# ---------------------------------------------------------------------------
MB_PREFIX_88="$(printf 'x%.0s' $(seq 1 88))"
MB_SUFFIX_20="$(printf 'y%.0s' $(seq 1 20))"

MB_PREFIX_89="$(printf 'x%.0s' $(seq 1 89))"

# Case 1: the multi-byte character (→, a 3-byte UTF-8 codepoint) sits exactly AT the cut — the
# 89th character, i.e. still inside the kept `max - 1` = 89 characters. Must be kept whole,
# immediately followed by the ellipsis, never split into a broken byte sequence.
mb_text_1_direct="${MB_PREFIX_88}→${MB_SUFFIX_20}"
truncated_1="$(render_truncate "$mb_text_1_direct" 90)"
if [[ "$truncated_1" == "${MB_PREFIX_88}→…" ]]; then
  pass "truncate: multi-byte char sitting exactly at the cut boundary is kept whole, not split"
else
  fail "truncate: multi-byte char sitting exactly at the cut boundary is kept whole, not split" "got '$truncated_1'"
fi

# Case 2: the same character sits one position further out (the 90th character) — now past the
# kept 89 characters. Must be dropped whole (never split into a dangling lead byte).
mb_text_2="${MB_PREFIX_89}→${MB_SUFFIX_20}"
truncated_2="$(render_truncate "$mb_text_2" 90)"
if [[ "$truncated_2" == "${MB_PREFIX_89}…" ]]; then
  pass "truncate: multi-byte char just past the cut boundary is dropped whole, not split"
else
  fail "truncate: multi-byte char just past the cut boundary is dropped whole, not split" "got '$truncated_2'"
fi

# Case 3: the same hostile-content-style check, but through the full render path (a top-finding
# table cell), the way this helper is actually invoked in production.
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="no findings"
mb_text_1="${MB_PREFIX_88}→${MB_SUFFIX_20}"
ARTEMIS_FINDINGS="$(jq -nc --arg issue "$mb_text_1" '{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"note","file":"a.sh","line":1,"issue":$issue,"scenario":"n/a"}],"summary":"multi-byte truncation check"}')"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "multi-byte-truncation" "the table cell keeps the boundary character whole" "$out" "${MB_PREFIX_88}→…"

# ---------------------------------------------------------------------------
# JSON-boundary regression coverage — nine divergences a bash-vs-Python byte-diff originally
# caught (bash is retired; these are now asserted directly against pantheon.render's own
# documented-correct output, per pantheon.jqjson's JSON-boundary contract, not by diffing
# against a second implementation that no longer exists).
# ---------------------------------------------------------------------------

# Divergence 1: NaN in a display field must print jq's "null" (jq's own print form for its NaN
# coercion), not Python's re-emitted literal "NaN" token.
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
ARTEMIS_FINDINGS='{"summary":NaN,"findings":[]}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "nan-in-summary-prints-jq-null" "machine tail prints null, not NaN" "$out" $'"summary": null,'
assert_not_contains "nan-in-summary-prints-jq-null" "no literal NaN token anywhere" "$out" "NaN"

# Divergence 2: a completely UNSET FINDINGS env var must reproduce the documented default-value
# quirk (the literal 3-char string `\{}`, invalid JSON) in the machine tail's raw-text fallback —
# not a "clean" `{}`.
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP
unset ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "unset-findings-var-machine-tail-matches-bash-quirk" "machine tail shows the literal \\{} fallback" "$out" $'```json\n\\{}\n```'

# Divergence 3: FINDINGS set to valid JSON that ISN'T an object (a bare array) — the machine tail
# must pretty-print the parsed array (matching jq's `.` filter, which doesn't care that it's not
# an object), not collapse it to `{}`.
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
ARTEMIS_FINDINGS='[1,2,3]'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "non-object-json-findings-pretty-prints-in-machine-tail" "array pretty-printed, not collapsed to {}" "$out" $'[\n  1,\n  2,\n  3\n]'

# Divergence 4: Infinity in a display field must render as jq's coerced max-double text, not
# Python's re-emitted literal "Infinity" token (also not valid JSON in the machine tail).
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="x"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"note","file":"a","line":1,"issue":"x","scenario":"y"}],"summary":Infinity}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "infinity-in-summary-prints-jq-max-double" "jq's coerced max-double text appears" "$out" "1.7976931348623157e+308"
assert_not_contains "infinity-in-summary-prints-jq-max-double" "no literal Infinity token anywhere" "$out" "Infinity"

# Divergence 5 (pantheon/jqjson.py's "JSON boundary"): a numeric literal that overflows Python's
# IEEE double during parsing (e.g. 1e400) must print jq's own canonicalized, still-exact number
# text (1E+400) in the machine tail, not silently lose precision to a bare "Infinity" token the
# way an un-fixed float('inf') round-trip would (which also isn't valid JSON — RFC 8259 has no
# such literal).
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="x"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"note","file":"a","line":1,"issue":"x","scenario":"y"}],"summary":"s","extra":1e400}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "1e400-overflow-preserves-jq-canonical-number-in-machine-tail" "canonical exact number text preserved" "$out" $'"extra": 1E+400'
assert_not_contains "1e400-overflow-preserves-jq-canonical-number-in-machine-tail" "no lossy Infinity token" "$out" "Infinity"

# Divergence 6 (pantheon.jqjson's second boundary — display-TEXT, jqjson.subst): a summary of
# exactly a trailing newline ("\n") must be treated as EMPTY and fall through to $top — not
# render as a blank line.
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="fallback-top-text"
ARTEMIS_FINDINGS='{"summary":"\n","findings":[]}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "trailing-newline-only-summary-falls-through-to-top" "falls through to the top-finding text" "$out" $'\nfallback-top-text\n'

# Divergence 7 (pantheon.jqjson's parse-side boundary, _parse_float): jq's number handling is
# arbitrary-precision decimal, not IEEE double -- a literal that UNDERFLOWS a double to 0.0
# (1e-400) or simply has more significant digits than a double can hold exactly
# (1.234567890123456789, verbatim in an unvalidated extra field) must both preserve their exact
# source text in the machine tail, not silently round through a lossy float() conversion.
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP=x
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"note","file":"a","line":1,"issue":"x","scenario":"y"}],"summary":"s","extra1":1e-400,"extra2":1.234567890123456789}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "underflow-and-precision-loss-preserved-exactly-in-machine-tail" "underflowed literal preserved exactly" "$out" $'"extra1": 1E-400,'
assert_contains "underflow-and-precision-loss-preserved-exactly-in-machine-tail" "high-precision literal preserved exactly (not rounded)" "$out" "1.234567890123456789"

# Divergence 8 (pantheon.jqjson.dumps's _RawBigNumber placeholder-splice mechanism): a genuine
# string field equal to the placeholder's own text pattern must NOT be corrupted into the
# preserved overflow number — the earlier, deterministic placeholder ("jqjson-raw-0") was
# guessable from this repo's own public source; a payload deliberately containing that literal
# text as genuine model output (here: an .issue field) must survive untouched.
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP=x
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"note","file":"a","line":1,"issue":"jqjson-raw-0","scenario":"y"}],"summary":"s","extra":1e400}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "raw-number-placeholder-text-as-genuine-content-not-corrupted" "the placeholder-shaped issue text survives untouched" "$out" $'"issue": "jqjson-raw-0",'
assert_contains "raw-number-placeholder-text-as-genuine-content-not-corrupted" "the real overflow number is still preserved exactly, unconfused with the placeholder text" "$out" $'"extra": 1E+400'

# Divergence 9 (pantheon.jqjson.subst): a severity of "blocker\x00" (embedded NUL) must still
# match the "blocker" case, not fall through to the unrecognized-severity fallback the way a NUL
# left unstripped until final display would.
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP=x
ARTEMIS_FINDINGS="$(python3 -c 'import json; print(json.dumps({"agent":"artemis","verdict":"FIX_FIRST","has_blocker":False,"findings":[{"severity":"blocker\x00","file":"a.py","line":1,"issue":"x","scenario":"y"}],"summary":"s"}))')"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
out="$(render "$HEAD_SHA" artemis)"
assert_contains "nul-in-severity-stripped-before-comparison-not-just-display" "NUL-suffixed severity still recognized as a real blocker" "$out" $'- **blocker** `a.py:1` — x'

# ---------------------------------------------------------------------------
# Fixture: repo-root redaction (a coordinator-flagged information-disclosure regression:
# CRITICAL-1's own fix, adversarial review, exposes the repo's absolute path to the reviewing
# persona so Read/Grep/Glob still work once the provider no longer launches with the repo
# checkout as its own cwd — a model can echo that absolute path back into a finding's
# file/issue/scenario/summary text, which then reaches a POSTED PR comment verbatim: on a CLI-
# lane run from a maintainer's own machine, that's their real home directory path, published
# into what may be a public PR). Closed via PANTHEON_REPO_ROOT: every model-controlled display
# field, AND the machine-tail JSON, must have every occurrence of that path replaced with the
# stable placeholder `<repo>` before the comment is ever rendered — see
# pantheon.render.redact_paths's own docstring.
# ---------------------------------------------------------------------------
reset_agent_env
FIXTURE_ABS_REPO_ROOT="/Users/realmaintainer/dev/review-pantheon"
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST
ARTEMIS_TOP="finding under $FIXTURE_ABS_REPO_ROOT/src/gate.sh"
ARTEMIS_FINDINGS="$(python3 -c "
import json
root = '$FIXTURE_ABS_REPO_ROOT'
print(json.dumps({
    'agent': 'artemis',
    'verdict': 'FIX_FIRST',
    'has_blocker': False,
    'findings': [{
        'severity': 'should_fix',
        'file': root + '/src/gate.sh',
        'line': 12,
        'issue': 'leaked path in issue: ' + root + '/src/gate.sh',
        'scenario': 'leaked path in scenario: ' + root,
    }],
    'summary': 'leaked path in summary: ' + root,
}))
")"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export PANTHEON_REPO_ROOT="$FIXTURE_ABS_REPO_ROOT"

out="$(render "$HEAD_SHA" artemis)"
assert_not_contains "repo-root-redaction" "table top-finding cell does not leak the absolute repo root" "$out" "$FIXTURE_ABS_REPO_ROOT"
assert_not_contains "repo-root-redaction" "finding's file field does not leak the absolute repo root" "$out" "$FIXTURE_ABS_REPO_ROOT/src/gate.sh"
assert_not_contains "repo-root-redaction" "finding's issue text does not leak the absolute repo root" "$out" "leaked path in issue: $FIXTURE_ABS_REPO_ROOT"
assert_not_contains "repo-root-redaction" "finding's scenario text does not leak the absolute repo root" "$out" "leaked path in scenario: $FIXTURE_ABS_REPO_ROOT"
assert_not_contains "repo-root-redaction" "summary text does not leak the absolute repo root" "$out" "leaked path in summary: $FIXTURE_ABS_REPO_ROOT"
assert_not_contains "repo-root-redaction" "machine-tail raw JSON does not leak the absolute repo root either" "$out" "$FIXTURE_ABS_REPO_ROOT"
assert_contains "repo-root-redaction" "the redaction placeholder appears in its place" "$out" "<repo>/src/gate.sh"

unset PANTHEON_REPO_ROOT

# Regression-direction guard: WITHOUT PANTHEON_REPO_ROOT set at all, the same fixture must NOT
# be redacted (redaction is opt-in via that env var — a caller that never set it, or a value
# that's the empty string, must see the model's real text unchanged; this also proves the
# assertions above are testing the redaction mechanism, not some unrelated always-on scrub).
out_no_redact="$(render "$HEAD_SHA" artemis)"
assert_contains "repo-root-redaction" "without PANTHEON_REPO_ROOT, the absolute path is NOT redacted (opt-in, not always-on)" "$out_no_redact" "$FIXTURE_ABS_REPO_ROOT"

# ---------------------------------------------------------------------------
# Fixture: repo-root redaction WIDENED (adversarial review, round 2 — coordinator finding). The
# fixture above only proved the EXACT repo_root string gets redacted; a live finding showed a
# plain str.replace(repo_root, ...) still leaks real variants a model can produce with no
# adversarial intent at all: a bare home-directory prefix, a trailing-slash mismatch, a
# symlink-resolved spelling, or a differently-cased spelling on a case-insensitive filesystem.
# See pantheon.render.redact_paths's own docstring (the "Widened" section) for the full
# rationale. Each sub-case below is proven leaking against the ORIGINAL exact-match
# implementation (verified live via `git stash` while authoring this fixture) before this widened
# version closes it.
# ---------------------------------------------------------------------------

# --- Sub-case: parent-path leak (the home-directory prefix alone, no repo suffix at all) -------
# Uses a scratch $HOME so the fixture is deterministic regardless of the box it runs on: home
# is only ever treated as an identifying redaction target when it's a real ancestor of
# repo_root (see _home_directory_redaction_targets's docstring) -- overriding both together
# keeps that ancestor relationship true without depending on the real operator's own $HOME.
reset_agent_env
FAKE_HOME="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$FAKE_HOME" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
FIXTURE_PARENT_LEAK_ROOT="$FAKE_HOME/dev/review-pantheon"
mkdir -p "$FIXTURE_PARENT_LEAK_ROOT"
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="see summary"
ARTEMIS_FINDINGS="$(python3 -c "
import json
home = '$FAKE_HOME'
print(json.dumps({
    'agent': 'artemis', 'verdict': 'FIX_FIRST', 'has_blocker': False,
    'findings': [{'severity': 'should_fix', 'file': 'a', 'line': 1,
                  'issue': 'checkout lives under ' + home, 'scenario': 'y'}],
    'summary': 'parent-path leak: ' + home,
}))
")"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export PANTHEON_REPO_ROOT="$FIXTURE_PARENT_LEAK_ROOT"
old_home="${HOME:-}"
export HOME="$FAKE_HOME"
out="$(render "$HEAD_SHA" artemis)"
export HOME="$old_home"
assert_not_contains "repo-root-redaction-parent-leak" "the bare home-directory prefix (no repo suffix) is redacted" "$out" "$FAKE_HOME"
assert_contains "repo-root-redaction-parent-leak" "the redaction placeholder appears in its place" "$out" "<repo>"
unset PANTHEON_REPO_ROOT
rm -rf "$FAKE_HOME"

# --- Sub-case: trailing-slash form mismatch ------------------------------------------------
# PANTHEON_REPO_ROOT (what ctx.repo_root actually holds) carries a trailing slash; the leaked
# finding text cites the SAME directory WITHOUT one -- the exact-string implementation this
# widened version replaces requires the trailing slash to be present in the text too, so it
# misses this direction entirely.
reset_agent_env
FIXTURE_TRAILING_SLASH_ROOT="/Users/realmaintainer/dev/review-pantheon"
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="see summary"
ARTEMIS_FINDINGS="$(python3 -c "
import json
root = '$FIXTURE_TRAILING_SLASH_ROOT'
print(json.dumps({
    'agent': 'artemis', 'verdict': 'FIX_FIRST', 'has_blocker': False,
    'findings': [{'severity': 'should_fix', 'file': 'a', 'line': 1,
                  'issue': 'no-trailing-slash leak: ' + root, 'scenario': 'y'}],
    'summary': 'no-trailing-slash leak: ' + root,
}))
")"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export PANTHEON_REPO_ROOT="$FIXTURE_TRAILING_SLASH_ROOT/"
out="$(render "$HEAD_SHA" artemis)"
assert_not_contains "repo-root-redaction-trailing-slash" "a no-trailing-slash leak is redacted even though repo_root itself carries a trailing slash" "$out" "$FIXTURE_TRAILING_SLASH_ROOT"
unset PANTHEON_REPO_ROOT

# --- Sub-case: symlink-resolved form -------------------------------------------------------
# ctx.repo_root holds a SYMLINK path (mirroring macOS's own /tmp -> /private/tmp); the leaked
# finding text cites the REALPATH-RESOLVED spelling instead -- a textually different string
# naming the identical directory, which a plain string-equality redaction target never matches.
reset_agent_env
SYMLINK_SCRATCH="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$SYMLINK_SCRATCH" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
REAL_REPO_DIR="$SYMLINK_SCRATCH/real-repo"
SYMLINK_REPO_DIR="$SYMLINK_SCRATCH/repo-via-symlink"
mkdir -p "$REAL_REPO_DIR"
ln -s "$REAL_REPO_DIR" "$SYMLINK_REPO_DIR"
RESOLVED_REPO_DIR="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$SYMLINK_REPO_DIR")"
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="see summary"
ARTEMIS_FINDINGS="$(python3 -c "
import json
resolved = '$RESOLVED_REPO_DIR'
print(json.dumps({
    'agent': 'artemis', 'verdict': 'FIX_FIRST', 'has_blocker': False,
    'findings': [{'severity': 'should_fix', 'file': 'a', 'line': 1,
                  'issue': 'symlink-resolved leak: ' + resolved, 'scenario': 'y'}],
    'summary': 'symlink-resolved leak: ' + resolved,
}))
")"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export PANTHEON_REPO_ROOT="$SYMLINK_REPO_DIR"
out="$(render "$HEAD_SHA" artemis)"
if [[ "$RESOLVED_REPO_DIR" != "$SYMLINK_REPO_DIR" ]]; then
  assert_not_contains "repo-root-redaction-symlink" "the realpath-resolved spelling is redacted even though ctx.repo_root holds the symlink path" "$out" "$RESOLVED_REPO_DIR"
else
  pass "repo-root-redaction-symlink: skipped (this tmpdir is not actually behind a symlink on this box) — mechanism still exercised by the direct-match assertion below"
fi
assert_not_contains "repo-root-redaction-symlink" "the as-given symlink spelling is also redacted (belt-and-suspenders: both forms are targets)" "$out" "$SYMLINK_REPO_DIR"
unset PANTHEON_REPO_ROOT
rm -rf "$SYMLINK_SCRATCH"

# --- Sub-case: case variant on a case-insensitive filesystem -------------------------------
# Platform-conditional both ways: on macOS/Windows (case-insensitive default), a differently-
# cased spelling of the same path must be redacted; on Linux (case-sensitive), the SAME
# differently-cased text is a genuinely different, unrelated string and must NOT be redacted --
# asserting that direction too proves this doesn't over-redact on the platform CI actually runs.
reset_agent_env
FIXTURE_CASE_ROOT="/Users/RealMaintainer/Dev/Review-Pantheon"
FIXTURE_CASE_VARIANT="/users/realmaintainer/dev/review-pantheon"
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="see summary"
ARTEMIS_FINDINGS="$(python3 -c "
import json
variant = '$FIXTURE_CASE_VARIANT'
print(json.dumps({
    'agent': 'artemis', 'verdict': 'FIX_FIRST', 'has_blocker': False,
    'findings': [{'severity': 'should_fix', 'file': 'a', 'line': 1,
                  'issue': 'case-variant leak: ' + variant, 'scenario': 'y'}],
    'summary': 'case-variant leak: ' + variant,
}))
")"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export PANTHEON_REPO_ROOT="$FIXTURE_CASE_ROOT"
out="$(render "$HEAD_SHA" artemis)"
CASE_INSENSITIVE_PLATFORM="$(python3 -c "import sys; print('1' if (sys.platform == 'darwin' or sys.platform.startswith('win')) else '0')")"
if [[ "$CASE_INSENSITIVE_PLATFORM" == "1" ]]; then
  assert_not_contains "repo-root-redaction-case-variant" "on a case-insensitive platform, a differently-cased spelling is redacted" "$out" "$FIXTURE_CASE_VARIANT"
else
  assert_contains "repo-root-redaction-case-variant" "on a case-sensitive platform, a differently-cased spelling is a DIFFERENT path and is correctly NOT redacted (no over-redaction)" "$out" "$FIXTURE_CASE_VARIANT"
fi
unset PANTHEON_REPO_ROOT

# --- Sub-case: an ORDERING bug — repo_root containing a JSON-escapable character (adversarial
# review, round 4, coordinator finding). _machine_tail_text used to JSON-SERIALIZE the parsed
# findings (jqjson.dumps, which escapes `"`/`\`/control chars) BEFORE redact_paths ever ran
# on the result — so a repo_root containing a literal `"` or `\` no longer matched its OWN
# already-escaped form in that serialized text, and leaked into the machine tail untouched. A
# real path shape, not just theoretical: a POSIX directory name can legally contain a `"`, and
# Git Bash on Windows checks repos out under paths containing a literal `\`. Fixed by redacting
# the DATA (the parsed value, and separately the whole findings_obj dict used by the human-
# readable path) BEFORE any jqjson.dumps/jq_text serialization step, everywhere in this module —
# see pantheon.render._machine_tail_text's and redact_paths's own docstrings. This
# fixture's repo_root carries BOTH hazards at once (a `"` AND a `\`), and additionally plants the
# leak in a JSON field ("machine_tail_only_field") no human-readable display code ever reads by
# name — the ONLY way it can reach rendered output at all is via the machine tail's full-object
# dump, isolating exactly the code path this fix touches.
reset_agent_env
FIXTURE_HOSTILE_ROOT='/Users/mal"icious\user/dev/review-pantheon'
HOSTILE_ROOT_FILE="$(mktemp)"
printf '%s' "$FIXTURE_HOSTILE_ROOT" > "$HOSTILE_ROOT_FILE"
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="see summary"
# Reads the hostile root from a FILE (not a shell-interpolated Python string literal) — the
# fixture value's own `"`/`\` characters would otherwise be ambiguous to embed directly inside a
# python3 -c "..." double-quoted argument from bash.
ARTEMIS_FINDINGS="$(python3 -c "
import json, sys
root = open(sys.argv[1], encoding='utf-8').read()
print(json.dumps({
    'agent': 'artemis', 'verdict': 'FIX_FIRST', 'has_blocker': False,
    'findings': [{'severity': 'should_fix', 'file': root + '/src/gate.sh', 'line': 1,
                  'issue': 'ordering-bug leak: ' + root, 'scenario': 'y'}],
    'summary': 'ordering-bug leak: ' + root,
    'machine_tail_only_field': root,
}))
" "$HOSTILE_ROOT_FILE")"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export PANTHEON_REPO_ROOT="$FIXTURE_HOSTILE_ROOT"
out="$(render "$HEAD_SHA" artemis)"
# The exact JSON-escaped form (`"` -> `\"`, `\` -> `\\`) is what the OLD, pre-fix ordering
# produced in the machine tail — checked explicitly, not just the raw form, since the raw form
# alone wouldn't distinguish "redacted correctly" from "coincidentally never appeared escaped".
ESCAPED_HOSTILE_ROOT="$(python3 -c "
import json, sys
root = open(sys.argv[1], encoding='utf-8').read()
print(json.dumps(root)[1:-1])
" "$HOSTILE_ROOT_FILE")"
assert_not_contains "repo-root-redaction-ordering-bug" "human-readable section: the raw hostile repo root does not leak" "$out" "$FIXTURE_HOSTILE_ROOT"
assert_not_contains "repo-root-redaction-ordering-bug" "machine tail: the raw hostile repo root does not leak" "$out" "$FIXTURE_HOSTILE_ROOT"
assert_not_contains "repo-root-redaction-ordering-bug" "machine tail: the JSON-ESCAPED form of the hostile repo root does not leak either (the actual ordering bug shape)" "$out" "$ESCAPED_HOSTILE_ROOT"
assert_contains "repo-root-redaction-ordering-bug" "the redaction placeholder appears in the machine-tail-only field's place" "$out" "\"machine_tail_only_field\": \"<repo>\""
unset PANTHEON_REPO_ROOT
rm -f "$HOSTILE_ROOT_FILE"

# --- Sub-case: SIBLING-PATH NON-CORRUPTION (adversarial review, round 5, coordinator finding) ---
# An UNANCHORED substring match on the home-directory target "/home/alice" also matches (and
# would mangle) an entirely unrelated SIBLING path like "/home/alice2/service" -- a DIFFERENT
# user's home directory that merely shares "/home/alice" as a text prefix. redact_paths must
# require the match to end at a real path boundary (a "/", a non-path-component character, or
# end of string) before redacting -- proven broken pre-fix (git-stash comparison) below.
reset_agent_env
FAKE_HOME_SIBLING_BASE="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$FAKE_HOME_SIBLING_BASE" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
FAKE_HOME_SIBLING="$FAKE_HOME_SIBLING_BASE/alice"
mkdir -p "$FAKE_HOME_SIBLING"
FAKE_HOME_PARENT="$(dirname "$FAKE_HOME_SIBLING")"
FIXTURE_SIBLING_REPO_ROOT="$FAKE_HOME_SIBLING/dev/review-pantheon"
FIXTURE_SIBLING_PATH="$FAKE_HOME_PARENT/alice2/unrelated-service/file.py"
mkdir -p "$FIXTURE_SIBLING_REPO_ROOT"
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="see summary"
ARTEMIS_FINDINGS="$(python3 -c "
import json
target = '$FIXTURE_SIBLING_REPO_ROOT'
sibling = '$FIXTURE_SIBLING_PATH'
print(json.dumps({
    'agent': 'artemis', 'verdict': 'FIX_FIRST', 'has_blocker': False,
    'findings': [{'severity': 'should_fix', 'file': 'a', 'line': 1,
                  'issue': 'real leak: ' + target + ' -- unrelated sibling: ' + sibling, 'scenario': 'y'}],
    'summary': 'real leak: ' + target + ' -- unrelated sibling: ' + sibling,
}))
")"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export PANTHEON_REPO_ROOT="$FIXTURE_SIBLING_REPO_ROOT"
old_home="${HOME:-}"
export HOME="$FAKE_HOME_SIBLING"
out="$(render "$HEAD_SHA" artemis)"
export HOME="$old_home"
assert_not_contains "repo-root-redaction-sibling-non-corruption" "the real repo_root leak is redacted" "$out" "$FIXTURE_SIBLING_REPO_ROOT"
assert_contains "repo-root-redaction-sibling-non-corruption" "an unrelated SIBLING path sharing a text prefix with the home-directory target is left completely untouched" "$out" "$FIXTURE_SIBLING_PATH"
unset PANTHEON_REPO_ROOT
rm -rf "$FAKE_HOME_PARENT"

# --- Sub-case: escapable-char root leaking through the malformed-JSON FALLBACK path (adversarial
# review, round 5, coordinator finding — the fallback-path half of the ordering-bug fix). The
# fixture above proves the NORMAL (parse-succeeds) machine-tail path; this one feeds genuinely
# malformed (never-parses) JSON that still contains an individually-escaped fragment of the
# hostile root -- a truncated/malformed document can still hold validly-escaped JSON string
# content even though the overall document fails to parse. An earlier round's fallback branch
# only ever searched for the RAW spelling there, missing this shape entirely.
reset_agent_env
FIXTURE_FALLBACK_HOSTILE_ROOT='/Users/mal"formed\user/dev/review-pantheon'
FALLBACK_ROOT_FILE="$(mktemp)"
printf '%s' "$FIXTURE_FALLBACK_HOSTILE_ROOT" > "$FALLBACK_ROOT_FILE"
FALLBACK_ESCAPED_ROOT="$(python3 -c "
import json, sys
root = open(sys.argv[1], encoding='utf-8').read()
print(json.dumps(root)[1:-1])
" "$FALLBACK_ROOT_FILE")"
# Deliberately malformed as a WHOLE document (truncated, no closing brace) -- jqjson.loads must
# fail to parse this, forcing _machine_tail_text's raw-text FALLBACK branch, while the escaped
# root fragment inside it is still individually valid JSON string content.
ARTEMIS_FINDINGS="not valid json overall: {\"file\": \"${FALLBACK_ESCAPED_ROOT}\", \"truncated"
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="see summary"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
export PANTHEON_REPO_ROOT="$FIXTURE_FALLBACK_HOSTILE_ROOT"
out="$(render "$HEAD_SHA" artemis)"
unset PANTHEON_REPO_ROOT
assert_not_contains "repo-root-redaction-fallback-escaped" "the machine tail's raw-text FALLBACK does not leak the raw hostile root" "$out" "$FIXTURE_FALLBACK_HOSTILE_ROOT"
assert_not_contains "repo-root-redaction-fallback-escaped" "the machine tail's raw-text FALLBACK does not leak the JSON-ESCAPED hostile root either (the actual missed-fallback bug shape)" "$out" "$FALLBACK_ESCAPED_ROOT"
assert_contains "repo-root-redaction-fallback-escaped" "the redaction placeholder appears in the fallback text's place" "$out" "<repo>"
rm -f "$FALLBACK_ROOT_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "render-comment (python) fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
