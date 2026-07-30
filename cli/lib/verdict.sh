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

# Last `^{`-anchored block in the output through EOF — resets on every match, so it ends up
# holding only the final JSON object (or garbage, which decide_verdict correctly classifies
# as unverified). Handles "trailing prose after JSON" (prose after the last `{` line still
# gets swept into buf, so a real trailing-JSON case must have the JSON as the true tail) and
# "two JSON objects" (last one wins) the same way.
extract_last_json() {
  awk '
    /^\{/ { buf = "" }
    { buf = buf $0 "\n" }
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
#   3. Look up color from the agent+verdict vocabulary; agent-field mismatch or an
#      out-of-vocabulary verdict -> unverified (but keeps verdict_json, since we can still
#      check it for a blocker below).
#   4. Blocker invariant: if has_blocker==true OR any finding has severity=="blocker", and
#      the color so far isn't already red, force color=red and invariant_fired=true. This
#      is deliberately checked regardless of whether step 3 landed on a valid vocabulary
#      color OR on unverified — a blocker finding is unambiguous even when the rest of the
#      object is malformed, and red is the fail-closed direction (it blocks merge; unverified
#      would only flag "not gated," which is a weaker signal than a known blocker deserves).
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
