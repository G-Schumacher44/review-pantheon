#!/usr/bin/env bash
# action/lib/combine_verdicts.sh — builds and (optionally) posts review-pantheon's ONE combined
# PR comment for the composite action (action.yml), and reports the overall gate color so the
# action's final "Enforce gate result" step can fail loud on red/unverified.
#
# Mirrors action/review.yml's "Build and post combined comment" step on purpose (same headline
# emoji, same table, same folded-findings block) — the two runtimes decide independently
# (DESIGN.md's "Two runtimes, one rule") but the human-facing comment shape should read the
# same either way. review.yml's version reads per-agent results from downloaded artifacts
# (matrix + cross-job passing); this one reads them from this job's own step outputs (env vars,
# see below) — the composite action runs every agent sequentially in one job, so there's no
# cross-job boundary to cross. That's the "simplicity over parallelism" tradeoff noted in
# action.yml's header: one job, no artifact upload/download round-trip, at the cost of agents
# not reviewing concurrently.
#
# Usage: combine_verdicts.sh <space-separated agent list, e.g. "artemis apollo">
#
# Per agent NAME (upper-cased for the env var lookup), reads:
#   <NAME>_COLOR, <NAME>_VERDICT, <NAME>_TOP, <NAME>_FINDINGS
#   — the matching decide-<agent> step's outputs (color / verdict / top_finding /
#   findings_json — see action/decide_verdict.py's emit_github_output). An agent whose
#   <NAME>_COLOR is empty is treated as "did not run" -> unverified, same fail-closed rule
#   as everywhere else in this repo.
# Also reads from env:
#   PR_NUMBER        - the PR to comment on (skips posting, with a warning, if unset)
#   GH_TOKEN          - passed through to `gh pr comment`
#   POST_COMMENT      - "true"/"false"; "false" computes the result and prints it but posts
#                       nothing (the action's own exit status still reflects the gate result
#                       either way, via GITHUB_OUTPUT's overall_color below)
#   APOLLO_DOCS_SKIPPED - "true"/"false"; synthesizes apollo's docs-only SKIPPED result the
#                       same way action/review.yml's "Save verdict artifact" step does, since
#                       there's no separate artifact-writing step in this flow to do it in
# Writes: $GITHUB_OUTPUT's overall_color (green|yellow|red|unverified).
set -uo pipefail

AGENTS="${1:?usage: combine_verdicts.sh <space-separated agent list>}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

overall="green"
rows=""
details=""
any_findings=false

for agent in $AGENTS; do
  upper="$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]')"
  color_var="${upper}_COLOR"
  verdict_var="${upper}_VERDICT"
  top_var="${upper}_TOP"
  findings_var="${upper}_FINDINGS"

  color="${!color_var:-}"
  verdict="${!verdict_var:-}"
  top="${!top_var:-}"
  findings="${!findings_var:-}"

  if [ "$agent" = "apollo" ] && [ "${APOLLO_DOCS_SKIPPED:-false}" = "true" ]; then
    color="yellow"; verdict="SKIPPED"; top="docs-only diff: apollo skipped by design"
    findings='{"agent":"apollo","verdict":"SKIPPED","has_blocker":false,"findings":[],"summary":"docs-only diff: apollo skipped by design"}'
  fi

  if [ -z "$color" ]; then
    color="unverified"; verdict="UNVERIFIED"; top="agent did not run (not in 'agents' input, or the run step failed before producing a result)"
    findings=""
  fi

  rows="${rows}| ${agent} | ${verdict} | ${top} |
"
  case "$color" in
    red) overall="red" ;;
    unverified) [ "$overall" = "red" ] || overall="unverified" ;;
    yellow) if [ "$overall" = "green" ]; then overall="yellow"; fi ;;
  esac

  has_findings=false
  if [ -n "$findings" ]; then
    findings_file="$(mktemp)"
    printf '%s' "$findings" > "$findings_file"
    has_findings="$(python3 -c "
import json
try:
    d = json.load(open('$findings_file'))
    print('true' if d.get('findings') else 'false')
except Exception:
    print('false')
" 2>/dev/null || echo false)"
    rm -f "$findings_file"
  fi
  if [ "$has_findings" = "true" ]; then
    any_findings=true
  fi
  if { [ "$color" != "green" ] || [ "$has_findings" = "true" ]; } && [ -n "$findings" ]; then
    details="${details}
**${agent}**

\`\`\`json
${findings}
\`\`\`
"
  fi
done

case "$overall" in
  green) headline="🟢 review-pantheon: all clear" ;;
  yellow) headline="🟡 review-pantheon: review notes" ;;
  unverified) headline="🟠 review-pantheon: NOT GATED (unverified result)" ;;
  red) headline="🔴 review-pantheon: blocked" ;;
esac

comment_file="$RUNNER_TEMP/pantheon-comment.md"
{
  echo "### $headline"
  echo
  echo "| Agent | Verdict | Top finding |"
  echo "|---|---|---|"
  printf '%s' "$rows"
  # Fold findings in whenever ANY agent actually reported some — not only when the overall
  # signal isn't green (an agent can find should_fix/note items and still land on a
  # green-mapped verdict). Same rule as action/review.yml's post-comment step.
  if [ "$overall" != "green" ] || [ "$any_findings" = "true" ]; then
    echo
    echo "<details>"
    echo "<summary>Full findings</summary>"
    printf '%s' "$details"
    echo "</details>"
  fi
} > "$comment_file"

if [ "${POST_COMMENT:-true}" = "true" ]; then
  if [ -n "${PR_NUMBER:-}" ]; then
    gh pr comment "$PR_NUMBER" --body-file "$comment_file" \
      || echo "::warning::failed to post the combined review comment (non-fatal)"
  else
    echo "::warning::PR_NUMBER is not set — skipping comment post (not a pull_request event?)"
  fi
else
  echo "::notice::post_comment is false — computed the verdict but did not post a comment."
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "overall_color=$overall" >> "$GITHUB_OUTPUT"
fi

cat "$comment_file"
