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

# Last top-level JSON object in the output through EOF — resets the candidate buffer every
# time a `{` is seen while brace-depth is 0 (a genuinely new top-level object starting), so it
# ends up holding only the final one (or garbage, which decide_verdict correctly classifies as
# unverified). Handles "trailing prose after JSON" (prose after a closed object still gets
# swept into buf — depth is back to 0 by then, and only a fresh `{` resets — so a real
# trailing-JSON case must have the JSON as the true tail, same contract as before) and "two
# JSON objects" (last one wins) the same way as the previous column-0-anchored version.
#
# Two hardenings over the old `/^\{/`-anchored version (mirrored in action/decide_verdict.py's
# extract_last_json — keep both in sync, same as everywhere else in this file):
#   - Leading whitespace before the object no longer defeats detection — depth-tracking finds
#     the `{` wherever it sits on the line, not just at column 0.
#   - A `{` seen while ALREADY inside an open top-level object (e.g. a pretty-printed verdict
#     whose nested `findings[]` element also happens to have its own `{` unindented, at column
#     0) no longer falsely resets the buffer and truncates the real object — only a `{` at
#     depth 0 counts as a new candidate's start.
# Not a full JSON tokenizer: brace-counting here isn't string-aware, so a `{`/`}` character
# sitting inside a JSON string value (e.g. `"issue": "the object needs a { here"`) is counted
# like any other brace. That's an accepted, documented limitation ("brace-counting, not a
# parser") — a stray brace in prose ahead of the real verdict is only handled correctly if it's
# balanced within the line(s) it appears on; jq's own parse of the resulting candidate is still
# the final fail-closed backstop either way.
extract_last_json() {
  awk '
    {
      line = $0
      len = length(line)
      linestart = 1
      for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (c == "{") {
          if (depth == 0) { buf = ""; linestart = i }
          depth++
        } else if (c == "}") {
          if (depth > 0) depth--
        }
      }
      buf = buf substr(line, linestart) "\n"
    }
    END { printf "%s", buf }
  '
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

  if ! verdict_json="$(jq -e '.' <<<"$candidate" 2>/dev/null)"; then
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
