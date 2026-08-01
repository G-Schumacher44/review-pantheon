#!/usr/bin/env bash
# cli/lib/verdict.sh — the verdict-extraction-and-decision path, factored out of
# cli/review-gate so tests/test-verdict-decision.sh can source it directly without
# duplicating (and silently drifting from) the real logic.
#
# This is the bash+jq half of the two-runtime verdict decision described in DESIGN.md.
# The GitHub Action runs the same rules in action/decide_verdict.py. Both implement:
#   - the same per-agent verdict vocabulary -> color map
#   - the same fail-closed rule: missing/unparseable/out-of-vocabulary verdict -> unverified
#   - the same blocker invariant: any finding with severity=="blocker", or has_blocker==true,
#     forces the color to red regardless of the stated verdict.
# If you change the rules here, change action/decide_verdict.py too and re-run the fixture
# test — it runs both implementations against the same fixtures and diffs their output.
#
# Requires: bash, jq. No `set -euo pipefail` here — this file is sourced by both a caller
# that has it on (cli/review-gate) and the test harness, and none of these functions expect
# to abort the caller's shell on a bad candidate (a bad candidate is exactly the input this
# code exists to classify, not something that should kill the process).

# Parse-anchored suffix scan (REPLACES an earlier brace-depth-tracking version — see this
# file's git history for why: it regressed on an unmatched `{` anywhere earlier in the output.
# A brace left open by prose or a quoted code snippet before the real verdict — plausible in
# this tool's own domain, code review of brace-heavy files — pinned `depth` above 0 for the
# rest of the document, so the real trailing JSON's own `{` was never treated as a fresh
# candidate, and a legitimate verdict came back UNVERIFIED. Artemis caught this live on PR #4;
# the balanced-braces fixture that existed at the time was green-by-construction for exactly
# the failure it was meant to catch, because its stray brace happened to be balanced).
#
# Correctness now comes from an ACTUAL PARSE ATTEMPT, not from tracking anything about braces.
# Read the whole candidate text, then scan every `{` character from the END of the text
# backward; the first (rightmost) one whose suffix — that character straight through EOF —
# parses as a single, complete JSON value via `jq -e` is the verdict. Immune BY CONSTRUCTION to:
#   - an unmatched `{` anywhere earlier in the text (that candidate is simply never tried,
#     because a later `{` — the real object's own — is tried first and succeeds),
#   - an unmatched `{` anywhere AFTER the real object (its own candidate fails to parse, so the
#     scan falls through to the real object's `{` — whose candidate then correctly fails too,
#     since genuine trailing garbage after a complete value is a jq parse error either way; this
#     is the "nothing after the JSON" contract already enforced by the "trailing prose after
#     JSON" case, just now covering trailing content that happens to contain a stray brace too),
#   - leading whitespace before the real object (the candidate starts exactly at the `{`, never
#     at column 0 specifically),
#   - a nested, unindented `{` inside an otherwise-valid pretty-printed object (that inner
#     candidate is a JSON fragment — invalid on its own — so it fails to parse and the scan
#     correctly falls through to the real, outer `{`).
# "Two JSON objects, last wins" still holds: the rightmost `{` in the text is the start of
# whichever object comes last, and if it's complete on its own, nothing about an earlier object
# is ever consulted. Not a full tokenizer and doesn't need to be — the parser IS the check, so
# there's no separate brace/string-awareness to get subtly wrong. Outputs from these agents are
# small; a handful of parse attempts per call is an accepted cost for the correctness this buys
# (mirrored exactly in action/decide_verdict.py's extract_last_json — keep both in sync, same
# as everywhere else in this file).
# _pantheon_single_json <text> — prints <text>'s single JSON document (compact) on stdout and
# returns 0 iff <text> is EXACTLY one JSON document with no trailing content, matching what
# Python's json.loads() already enforces on its own (it raises "Extra data" on anything after
# the first complete value). jq's stream parser does NOT enforce this by itself: `jq -e '.'
# <<<"$text"` happily accepts multiple whitespace-separated top-level JSON documents and bases
# its exit status on only the LAST one — so a candidate consisting of a valid verdict object
# immediately followed by a second, unrelated JSON value (an array, a bare number — not
# malformed prose, a genuine second document) read as "valid" to that check even though Python
# already rejected the same text. Left unfixed, this cross-runtime divergence corrupted every
# downstream --argjson caller below (each requires EXACTLY one JSON value) and could crash the
# calling shell into empty output under `set -e` instead of returning a clean UNVERIFIED —
# reproduced live against the pre-fix version of this function (jq: invalid JSON text passed to
# --argjson) before this fix landed; see tests/test-verdict-decision.sh's "multi-doc"/"verdict
# followed by a second JSON doc" fixtures for the same repro, now fixed. Slurping into an array
# (`jq -c -s`) is what makes "how many top-level documents did this parse into" checkable at
# all — a plain `jq -e '.'` has no concept of "count", only "did the last one succeed."
_pantheon_single_json() {
  local text="$1" slurped count
  slurped="$(jq -c -s '.' <<<"$text" 2>/dev/null)" || return 1
  count="$(jq -r 'length' <<<"$slurped" 2>/dev/null)" || return 1
  [[ "$count" == "1" ]] || return 1
  jq -c '.[0]' <<<"$slurped"
}

extract_last_json() {
  local text i candidate
  text="$(cat)"
  for (( i = ${#text} - 1; i >= 0; i-- )); do
    [[ "${text:i:1}" == "{" ]] || continue
    candidate="${text:i}"
    if _pantheon_single_json "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf ''
}

# Per-agent verdict vocabulary -> gate color. Mirrors the VOCAB table in
# action/decide_verdict.py exactly — same agents, same words, same colors.
agent_color() {
  local agent="$1" verdict="$2"
  case "${agent}:${verdict}" in
    artemis:SHIP|apollo:ACCEPT|diogenes:LEAN|plato:COHERENT|socrates:GO) echo green ;;
    artemis:FIX_FIRST|apollo:ACCEPT_WITH_NOTES|diogenes:TRIM|plato:DRIFTING|socrates:GO_WITH_GUARDRAILS) echo yellow ;;
    artemis:STOP|apollo:RETURN|diogenes:GUT|plato:FRACTURED|socrates:NO_GO) echo red ;;
    *) echo unverified ;;
  esac
}

# decide_verdict <expected-agent> <candidate-text>
#
# <candidate-text> is whatever extract_last_json produced (or any other candidate blob —
# this function makes no assumption about where it came from). Always prints exactly one
# single-line JSON object to stdout and always returns 0; callers branch on `.color`:
#
#   {"agent": "<expected-agent>", "color": "green|yellow|red|unverified",
#    "verdict": "<reported verdict or UNVERIFIED>", "reason": "<why, empty if none>",
#    "invariant_fired": true|false, "top_finding": "<summary or 'no findings'>",
#    "verdict_json": <the parsed object, or {} if nothing parsed>}
#
# Decision order (fail-closed; the blocker invariant is checked LAST and can only make the
# result worse, never better):
#   1. Candidate must parse as JSON -> else unverified, verdict_json={}.
#   2. Parsed object must have all five required keys -> else unverified.
#   3. Type-strict validation of the invariant-read surface only — verdict must be a string,
#      has_blocker must be strictly boolean, findings must be strictly an array, and every
#      findings[].severity must be a string in {blocker, should_fix, note} -> else unverified.
#      This is the fix for a real gap: presence-only validation (step 2) let a malformed
#      `"has_blocker": "true"` (a string) through, and jq's type-strict `==` comparison in the
#      blocker invariant below then silently never fired for it — a malformed verdict could
#      read as a clean green. Display fields (file/line/issue/scenario/summary) are
#      deliberately NOT checked here; DESIGN.md's "Validation surface" section is the contract
#      for why (the render layer, cli/lib/render_comment.sh, sanitizes those at render time).
#   4. Look up color from the agent+verdict vocabulary; agent-field mismatch or an
#      out-of-vocabulary verdict -> unverified (but keeps verdict_json, since we can still
#      check it for a blocker below).
#   5. Blocker invariant: if has_blocker==true OR any finding has severity=="blocker", and
#      the color so far isn't already red, force color=red and invariant_fired=true. This
#      is deliberately checked regardless of whether step 4 landed on a valid vocabulary
#      color OR on unverified — a blocker finding is unambiguous even when the verdict WORD
#      itself is malformed (typo'd/out-of-vocabulary), and red is the fail-closed direction (it
#      blocks merge; unverified would only flag "not gated," a weaker signal than a known
#      blocker deserves). An object that fails step 3's type-strict check never reaches this
#      step at all — there's no reliable blocker signal to trust in an object that isn't even
#      type-shaped correctly, so that case stays unverified, never red.
decide_verdict() {
  local expected_agent="$1" candidate="$2"
  local verdict_json

  # _pantheon_single_json (above) is the exactly-one-document check — a candidate that is
  # itself a verdict object followed by trailing content that's ALSO valid JSON (not just
  # malformed prose) must be rejected here identically to Python's json.loads(), not silently
  # accepted as if the trailing document weren't there. See that function's header comment for
  # the concrete cross-runtime divergence this closes.
  if ! verdict_json="$(_pantheon_single_json "$candidate")"; then
    jq -nc --arg agent "$expected_agent" \
      --arg reason "no parseable JSON object found in provider output" \
      '{agent:$agent, color:"unverified", verdict:"UNVERIFIED", reason:$reason,
        invariant_fired:false, top_finding:$reason, verdict_json:{}}'
    return 0
  fi

  if ! jq -e 'has("agent") and has("verdict") and has("has_blocker") and has("findings") and has("summary")' \
        <<<"$verdict_json" >/dev/null 2>&1; then
    jq -nc --arg agent "$expected_agent" \
      --arg reason "verdict JSON missing required keys" \
      --argjson vj "$verdict_json" \
      '{agent:$agent, color:"unverified", verdict:"UNVERIFIED", reason:$reason,
        invariant_fired:false, top_finding:$reason, verdict_json:$vj}'
    return 0
  fi

  # Type-strict validation surface — see decision-order comment above and DESIGN.md's
  # "Validation surface". Deliberately scoped to verdict/has_blocker/findings/severity only.
  if ! jq -e '
        (.verdict | type) == "string"
        and (.has_blocker | type) == "boolean"
        and (.findings | type) == "array"
        and (.findings | all(
              type == "object"
              and (.severity | type) == "string"
              and (.severity | IN("blocker","should_fix","note"))
            ))
      ' <<<"$verdict_json" >/dev/null 2>&1; then
    jq -nc --arg agent "$expected_agent" \
      --arg reason "verdict JSON failed type-strict validation on the invariant-read surface (verdict must be a string, has_blocker must be boolean, findings must be an array, every findings[].severity must be a string in {blocker,should_fix,note})" \
      --argjson vj "$verdict_json" \
      '{agent:$agent, color:"unverified", verdict:"UNVERIFIED", reason:$reason,
        invariant_fired:false, top_finding:$reason, verdict_json:$vj}'
    return 0
  fi

  local agent_field verdict blocker_present base_color top_finding color reason invariant_fired
  agent_field="$(jq -r '.agent' <<<"$verdict_json")"
  verdict="$(jq -r '.verdict' <<<"$verdict_json")"
  blocker_present="$(jq -r '
      (.has_blocker == true) or ((.findings // []) | any(.severity == "blocker"))
    ' <<<"$verdict_json" 2>/dev/null || echo false)"

  top_finding="$(jq -r '
      (.findings // [])[0] as $f
      | if $f == null then "no findings"
        else "\($f.severity): \($f.issue) (\($f.file):\($f.line))"
        end
    ' <<<"$verdict_json" 2>/dev/null)"
  [[ -n "$top_finding" ]] || top_finding="no findings"

  reason=""
  if [[ "$agent_field" != "$expected_agent" ]]; then
    color="unverified"
    reason="agent field '$agent_field' does not match expected '$expected_agent'"
  else
    base_color="$(agent_color "$agent_field" "$verdict")"
    color="$base_color"
    if [[ "$color" == "unverified" ]]; then
      reason="verdict '$verdict' from agent field '$agent_field' is outside the allowed vocabulary"
    fi
  fi

  invariant_fired=false
  if [[ "$blocker_present" == "true" && "$color" != "red" ]]; then
    invariant_fired=true
    reason="blocker finding present (severity=blocker or has_blocker=true) — forcing red regardless of stated verdict '$verdict'"
    color="red"
  fi

  jq -nc --arg agent "$expected_agent" --arg color "$color" --arg verdict "$verdict" \
    --arg reason "$reason" --argjson invariant "$invariant_fired" --arg top "$top_finding" \
    --argjson vj "$verdict_json" \
    '{agent:$agent, color:$color, verdict:$verdict, reason:$reason,
      invariant_fired:$invariant, top_finding:$top, verdict_json:$vj}'
}
