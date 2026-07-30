#!/usr/bin/env python3
"""decide_verdict.py — the Python half of review-pantheon's two-runtime verdict decision.

This is the canonical source for the Action's decide step. review.yml runs THIS file (its
installed copy in the target repo, at .github/review-agents/decide_verdict.py — install.sh
installs it alongside the personas) rather than an inline copy of the same logic, so there is
exactly one place this rule lives for the Action lane. The CLI lane implements the identical
rule in bash+jq at cli/lib/verdict.sh (two runtimes, one repo — the CLI shouldn't require
Python and the Action can't cleanly source bash — see DESIGN.md's verdict-contract section for
why that split is accepted). If you change the rule in one file, change it in the other and
re-run tests/test-verdict-decision.sh, which runs both against the same fixtures.

Usage:
    decide_verdict.py <expected-agent> <raw-output-file>

Reads the agent's raw stdout from <raw-output-file>, extracts the trailing JSON verdict object,
validates it, and applies the blocker invariant. Always prints one JSON decision object to
stdout on a single line:

    {"agent": "...", "color": "green|yellow|red|unverified", "verdict": "...",
     "reason": "...", "invariant_fired": bool, "top_finding": "...", "verdict_json": {...}}

Exit code: 0 if color is "green" or "yellow", 1 if "red" or "unverified" — this mirrors the
CLI's fail-closed posture (the workflow step is marked failed on anything worse than a review
note, but every subsequent step in review.yml runs under `if: always()` so a failed decide step
still produces and uploads its verdict artifact).

When the GITHUB_OUTPUT env var is set, this script ALSO appends the legacy step-output keys
(color, verdict, summary, top_finding, findings_json) that review.yml's later steps read via
`steps.decide.outputs.*` — that's workflow plumbing, not part of the decision rule itself.
"""
import json
import os
import secrets
import sys

# Per-agent verdict vocabulary -> gate color. Mirrors the case statement in
# cli/lib/verdict.sh's agent_color() exactly — same agents, same words, same colors.
VOCAB = {
    "artemis": {"SHIP": "green", "FIX_FIRST": "yellow", "STOP": "red"},
    "apollo": {"ACCEPT": "green", "ACCEPT_WITH_NOTES": "yellow", "RETURN": "red"},
    "diogenes": {"LEAN": "green", "TRIM": "yellow", "GUT": "red"},
    "plato": {"COHERENT": "green", "DRIFTING": "yellow", "FRACTURED": "red"},
    "socrates": {"GO": "green", "GO_WITH_GUARDRAILS": "yellow", "NO_GO": "red"},
}

REQUIRED_KEYS = {"agent", "verdict", "has_blocker", "findings", "summary"}


def extract_last_json(raw: str):
    """Same rule as cli/lib/verdict.sh's extract_last_json: the last `{`-anchored block
    through EOF. Returns the candidate text (possibly empty)."""
    lines = raw.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith("{"):
            start = i
    return "\n".join(lines[start:]) if start is not None else ""


def top_finding_of(verdict_obj) -> str:
    findings = verdict_obj.get("findings") or []
    if not findings:
        return "no findings"
    f = findings[0]
    try:
        return f"{f['severity']}: {f['issue']} ({f['file']}:{f['line']})"
    except (KeyError, TypeError):
        return "no findings"


def blocker_present(verdict_obj) -> bool:
    if verdict_obj.get("has_blocker") is True:
        return True
    for f in verdict_obj.get("findings") or []:
        if isinstance(f, dict) and f.get("severity") == "blocker":
            return True
    return False


def decide(expected_agent: str, raw: str) -> dict:
    """Same decision order as cli/lib/verdict.sh's decide_verdict: parse -> required keys ->
    vocabulary lookup -> blocker invariant (checked last, can only make the result worse)."""
    candidate = extract_last_json(raw)
    if not candidate:
        return {
            "agent": expected_agent, "color": "unverified", "verdict": "UNVERIFIED",
            "reason": "no trailing JSON object found in agent output",
            "invariant_fired": False,
            "top_finding": "no trailing JSON object found in agent output",
            "verdict_json": {},
        }

    try:
        verdict_obj = json.loads(candidate)
    except json.JSONDecodeError as e:
        return {
            "agent": expected_agent, "color": "unverified", "verdict": "UNVERIFIED",
            "reason": f"trailing JSON did not parse: {e}",
            "invariant_fired": False,
            "top_finding": f"trailing JSON did not parse: {e}",
            "verdict_json": {},
        }

    if not isinstance(verdict_obj, dict) or not REQUIRED_KEYS.issubset(verdict_obj.keys()):
        return {
            "agent": expected_agent, "color": "unverified", "verdict": "UNVERIFIED",
            "reason": "verdict JSON missing required keys",
            "invariant_fired": False,
            "top_finding": "verdict JSON missing required keys",
            "verdict_json": verdict_obj if isinstance(verdict_obj, dict) else {},
        }

    agent_field = verdict_obj.get("agent")
    verdict = verdict_obj.get("verdict")
    top = top_finding_of(verdict_obj)

    reason = ""
    if agent_field != expected_agent:
        color = "unverified"
        reason = f"agent field '{agent_field}' does not match expected '{expected_agent}'"
    else:
        color = VOCAB.get(agent_field, {}).get(verdict, "unverified")
        if color == "unverified":
            reason = f"verdict '{verdict}' from agent field '{agent_field}' is outside the allowed vocabulary"

    invariant_fired = False
    if blocker_present(verdict_obj) and color != "red":
        invariant_fired = True
        reason = (
            "blocker finding present (severity=blocker or has_blocker=true) — "
            f"forcing red regardless of stated verdict '{verdict}'"
        )
        color = "red"

    return {
        "agent": expected_agent, "color": color, "verdict": verdict if verdict is not None else "UNVERIFIED",
        "reason": reason, "invariant_fired": invariant_fired, "top_finding": top,
        "verdict_json": verdict_obj,
    }


def emit_github_output(decision: dict) -> None:
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if not gh_out:
        return
    delim = "pantheon_" + secrets.token_hex(16)
    with open(gh_out, "a") as out:
        out.write(f"color={decision['color']}\n")
        out.write(f"verdict={decision['verdict']}\n")
        summary = decision["verdict_json"].get("summary", "") if isinstance(decision["verdict_json"], dict) else ""
        out.write(f"summary<<{delim}\n{summary}\n{delim}\n")
        out.write(f"top_finding<<{delim}\n{decision['top_finding']}\n{delim}\n")
        out.write(f"findings_json<<{delim}\n{json.dumps(decision['verdict_json'])}\n{delim}\n")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: decide_verdict.py <expected-agent> <raw-output-file>", file=sys.stderr)
        return 2

    expected_agent, raw_file = sys.argv[1], sys.argv[2]
    try:
        with open(raw_file, "r", errors="replace") as fh:
            raw = fh.read()
    except OSError as e:
        decision = {
            "agent": expected_agent, "color": "unverified", "verdict": "UNVERIFIED",
            "reason": f"could not read agent output: {e}", "invariant_fired": False,
            "top_finding": f"could not read agent output: {e}", "verdict_json": {},
        }
    else:
        decision = decide(expected_agent, raw)

    print(json.dumps(decision))
    emit_github_output(decision)

    if decision["color"] in ("red", "unverified"):
        print(f"::error::{expected_agent} verdict is {decision['color']} ({decision['verdict']}) — {decision['reason']}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
