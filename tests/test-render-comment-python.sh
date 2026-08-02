#!/usr/bin/env bash
# tests/test-render-comment-python.sh — the black-box Python equivalent of
# tests/test-render-comment.sh, per docs/PYTHON-PORT.md section 4's disposition for that suite:
# "Needs a black-box/Python-native equivalent against the render module. Slice 2 exit bar."
#
# The original suite is bash-internal (it sources cli/lib/render_comment.sh directly and calls
# its two public functions, pantheon_render_comment / pantheon_overall_color, in-process).
# Sourcing a .py file the way that suite sources a .sh file is not the right shape for its
# Python equivalent (docs/PYTHON-PORT.md section 4's own framing) — this file keeps the exact
# same fixture set (same per-agent env vars, same assertions, same expected substrings/counts)
# and drives pantheon.render as a subprocess instead, via the module's CLI shim:
#   python3 -m pantheon.render comment <head_sha> <agent...>   (reads the same *_COLOR/etc. env
#   python3 -m pantheon.render overall <agent...>               vars the bash contract does)
#
# tests/test-render-comment.sh itself is untouched by this port (still sources
# cli/lib/render_comment.sh) and stays green — this file is an ADDITION, not a replacement,
# until Slice 5 retires the bash renderer.
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
# Additional Python-port regression coverage (beyond the 1:1 bash-suite mirror above) — the
# repo's own self-hosted gate (Codex) found these four divergences on this PR, each proven
# failing pre-fix against a live repro (bash vs. Python, byte-diffed) before the corresponding
# pantheon/render.py fix landed. Asserted here as direct byte-identity checks against the real
# bash renderer (cli/lib/render_comment.sh, sourced fresh per case), not string-contains checks,
# since "byte-identical output" is the exact property each of these gaps violated.
# ---------------------------------------------------------------------------

# bash_render <head_sha> <agent...> — the bash-side counterpart to render(), used only in this
# section for direct byte-identity comparison against the same command-substitution capture
# shape render() already uses (both sides losing a trailing newline the same way is fine; what
# matters is comparing like-for-like).
bash_render() {
  # shellcheck disable=SC1091
  (source "$ROOT/cli/lib/render_comment.sh" && pantheon_render_comment "$@")
}

assert_byte_identical() {
  local case_name="$1"
  local bash_out py_out
  bash_out="$(bash_render "$HEAD_SHA" artemis)"
  py_out="$(render "$HEAD_SHA" artemis)"
  if [[ "$bash_out" == "$py_out" ]]; then
    pass "$case_name: byte-identical to cli/lib/render_comment.sh"
  else
    fail "$case_name: byte-identical to cli/lib/render_comment.sh" "outputs differ (see diff below)"
    diff <(printf '%s' "$bash_out") <(printf '%s' "$py_out") | head -20
  fi
}

# Divergence 1: NaN in a display field must print jq's "null" (jq's own print form for its NaN
# coercion), not Python's re-emitted literal "NaN" token.
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
ARTEMIS_FINDINGS='{"summary":NaN,"findings":[]}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
assert_byte_identical "nan-in-summary-prints-jq-null"

# Divergence 2: a completely UNSET FINDINGS env var must reproduce bash's own
# `${!findings_var:-\{\}}` default-value quirk (the literal 3-char string `\{}`, invalid JSON) in
# the machine tail's raw-text fallback — not a "clean" `{}`.
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP
unset ARTEMIS_FINDINGS
assert_byte_identical "unset-findings-var-machine-tail-matches-bash-quirk"

# Divergence 3: FINDINGS set to valid JSON that ISN'T an object (a bare array) — the machine tail
# must pretty-print the parsed array (matching jq's `.` filter, which doesn't care that it's not
# an object), not collapse it to `{}`.
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="no findings"
ARTEMIS_FINDINGS='[1,2,3]'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
assert_byte_identical "non-object-json-findings-pretty-prints-in-machine-tail"

# Divergence 4: Infinity in a display field must render as jq's coerced max-double text, not
# Python's re-emitted literal "Infinity" token (also not valid JSON in the machine tail).
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="x"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"note","file":"a","line":1,"issue":"x","scenario":"y"}],"summary":Infinity}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
assert_byte_identical "infinity-in-summary-prints-jq-max-double"

# Divergence 5 (docs/PYTHON-PORT.md's "JSON boundary" section, pantheon/jqjson.py): a numeric
# literal that overflows Python's IEEE double during parsing (e.g. 1e400) must print jq's own
# canonicalized, still-exact number text (1E+400) in the machine tail, not silently lose
# precision to a bare "Infinity" token the way an un-fixed float('inf') round-trip would (which
# also isn't valid JSON — RFC 8259 has no such literal).
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP="x"
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"note","file":"a","line":1,"issue":"x","scenario":"y"}],"summary":"s","extra":1e400}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
assert_byte_identical "1e400-overflow-preserves-jq-canonical-number-in-machine-tail"

# Divergence 6 (pantheon.jqjson's second boundary — display-TEXT, jqjson.subst): bash's
# `summary="$(jq -r '.summary // empty' <<<"$findings_json")"` runs through a $(...) command
# substitution, which strips ALL trailing newlines from the captured text BEFORE bash's own
# `[ -n "$summary" ]` emptiness check ever runs. A summary of exactly a trailing newline ("\n")
# must therefore be treated as EMPTY and fall through to $top — not render as a blank line.
reset_agent_env
ARTEMIS_COLOR=green ARTEMIS_VERDICT=SHIP ARTEMIS_TOP="fallback-top-text"
ARTEMIS_FINDINGS='{"summary":"\n","findings":[]}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
assert_byte_identical "trailing-newline-only-summary-falls-through-to-top"

# Divergence 7 (pantheon.jqjson's parse-side boundary, _parse_float): jq's number handling is
# arbitrary-precision decimal, not IEEE double -- a literal that UNDERFLOWS a double to 0.0
# (1e-400) or simply has more significant digits than a double can hold exactly
# (1.234567890123456789, verbatim in an unvalidated extra field) must both preserve their exact
# source text in the machine tail, not silently round through a lossy float() conversion.
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP=x
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"note","file":"a","line":1,"issue":"x","scenario":"y"}],"summary":"s","extra1":1e-400,"extra2":1.234567890123456789}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
assert_byte_identical "underflow-and-precision-loss-preserved-exactly-in-machine-tail"

# Divergence 8 (pantheon.jqjson.dumps's _RawBigNumber placeholder-splice mechanism): a genuine
# string field equal to the placeholder's own text pattern must NOT be corrupted into the
# preserved overflow number — the earlier, deterministic placeholder ("jqjson-raw-0") was
# guessable from this repo's own public source; a payload deliberately containing that literal
# text as genuine model output (here: an .issue field) must survive untouched.
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP=x
ARTEMIS_FINDINGS='{"agent":"artemis","verdict":"FIX_FIRST","has_blocker":false,"findings":[{"severity":"note","file":"a","line":1,"issue":"jqjson-raw-0","scenario":"y"}],"summary":"s","extra":1e400}'
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
assert_byte_identical "raw-number-placeholder-text-as-genuine-content-not-corrupted"

# Divergence 9 (pantheon.jqjson.subst): bash's $(...) command substitution drops ALL NUL bytes
# from the captured text -- not just trailing newlines -- and does so BEFORE bash's own variable
# holds the value, i.e. before any comparison against it. A severity of "blocker\x00" must
# therefore still match the "blocker" case (bash already stripped the NUL by comparison time),
# not fall through to the unrecognized-severity fallback the way a NUL left unstripped until
# final display would.
reset_agent_env
ARTEMIS_COLOR=yellow ARTEMIS_VERDICT=FIX_FIRST ARTEMIS_TOP=x
ARTEMIS_FINDINGS="$(python3 -c 'import json; print(json.dumps({"agent":"artemis","verdict":"FIX_FIRST","has_blocker":False,"findings":[{"severity":"blocker\x00","file":"a.py","line":1,"issue":"x","scenario":"y"}],"summary":"s"}))')"
export ARTEMIS_COLOR ARTEMIS_VERDICT ARTEMIS_TOP ARTEMIS_FINDINGS
assert_byte_identical "nul-in-severity-stripped-before-comparison-not-just-display"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "render-comment (python) fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
