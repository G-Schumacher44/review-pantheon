#!/usr/bin/env bash
# action/lib/combine_verdicts.sh — builds and (optionally) posts review-pantheon's ONE combined
# PR comment for the composite action (action.yml), and reports the overall gate color so the
# action's final "Enforce gate result" step can fail loud on red/unverified.
#
# The comment itself (headline + verdict table + human-first findings fold + machine-readable
# JSON tail) is built by `pantheon.render`, invoked below via a path relative to this file — safe
# because the published action ships this whole repo at github.action_path, unlike
# bootstrap.sh's CLI-only install footprint (which never touches action/). `pantheon.render` is
# the one renderer implementation every lane calls — this file's job is just to normalize this
# job's per-agent step outputs (env vars, see below) into its `<NAME>_*` env-var contract and
# call it. The vendored action/review.yml used to be a second render path that couldn't invoke
# it directly (a target repo never got a copy of pantheon/ except as a base-pinned $RUNNER_TEMP
# read, so it stayed a hand-synced inline copy) — issue #36 deleted that surface, leaving this
# script as the only place that assembles the comment for an Action-lane run.
#
# Usage: combine_verdicts.sh <space-separated agent list, e.g. "artemis apollo">
#
# Per agent NAME (upper-cased for the env var lookup), reads:
#   <NAME>_COLOR, <NAME>_VERDICT, <NAME>_TOP, <NAME>_FINDINGS, <NAME>_INVARIANT, <NAME>_REASON
#   — the matching decide-<agent> step's outputs (color / verdict / top_finding /
#   findings_json / invariant_fired / reason — see pantheon/verdict.py's emit_github_output).
#   An agent whose <NAME>_COLOR is empty is treated as "did not run" ->
#   unverified, same fail-closed rule as everywhere else in this repo.
# Also reads from env:
#   PR_NUMBER        - the PR to comment on (skips posting, with a warning, if unset — the
#                       shape a workflow_dispatch counsel run always takes, since there is no PR)
#   GH_TOKEN          - passed through to `gh pr comment`
#   HEAD_SHA          - the reviewed PR head SHA, shown (short) in each agent's identity line
#   POST_COMMENT      - "true"/"false"; "false" computes the result and prints it but posts
#                       nothing (the action's own exit status still reflects the gate result
#                       either way, via GITHUB_OUTPUT's overall_color below)
#   APOLLO_DOCS_SKIPPED - "true"/"false"; synthesizes apollo's docs-only SKIPPED result since
#                       there's no separate artifact-writing step in this flow to do it in
#   MODE              - "gate" (default, if unset) or "counsel" (issue #95). Counsel mode
#                       prepends an "advisory, not a gate" banner to `pantheon_render_comment`'s
#                       own output before it's posted/printed — no new review logic, the SAME
#                       renderer every lane calls, just framed for a lane that cannot block a
#                       merge. Gate mode's own comment shape is completely unaffected: the banner
#                       block below only ever executes when MODE is literally "counsel".
# Writes: $GITHUB_OUTPUT's overall_color (green|yellow|red|unverified) — for counsel mode this is
# purely informational (see action.yml's "Counsel result" step, which never fails on it).
set -uo pipefail

AGENTS="${1:?usage: combine_verdicts.sh <space-separated agent list>}"
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PANTHEON_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# pantheon.render's own CLI shim — invoked via its OWN ABSOLUTE PATH (never `python3 -m
# pantheon.render`, which would prepend this process's cwd to sys.path and risk shadowing by a
# PR-committed pantheon/render.py). Both subcommands read the same `<NAME>_COLOR`/`<NAME>_VERDICT`/
# `<NAME>_TOP`/`<NAME>_FINDINGS` env-var contract this file's own per-agent loop below populates
# — those vars are already part of this step's process environment (GitHub Actions `env:` block),
# so the python subprocess inherits them same as the old sourced-bash-function call did.
pantheon_overall_color() {
  PYTHONPATH="$PANTHEON_ROOT" python3 "$PANTHEON_ROOT/pantheon/render.py" overall "$@"
}
pantheon_render_comment() {
  PYTHONPATH="$PANTHEON_ROOT" python3 "$PANTHEON_ROOT/pantheon/render.py" comment "$@"
}

# Word-split $AGENTS into an array once, so downstream calls into the shared renderer can pass
# it as "${AGENT_LIST[@]}" instead of relying on unquoted-expansion word splitting everywhere.
read -ra AGENT_LIST <<< "$AGENTS"

for agent in "${AGENT_LIST[@]}"; do
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
  [ -n "$findings" ] || findings='{}'

  printf -v "$color_var" '%s' "$color"
  printf -v "$verdict_var" '%s' "$verdict"
  printf -v "$top_var" '%s' "$top"
  printf -v "$findings_var" '%s' "$findings"
done

overall="$(pantheon_overall_color "${AGENT_LIST[@]}")"

comment_file="$RUNNER_TEMP/pantheon-comment.md"
: > "$comment_file"

if [ "${MODE:-gate}" = "counsel" ]; then
  {
    echo "> **🔭 review-pantheon counsel — advisory, not a gate.**"
    echo "> The three verdicts below are for the author to weigh, not a required check — this"
    echo "> run cannot fail your CI and does not affect any gate's pass/fail result, whatever"
    echo "> color they show."
    echo
  } > "$comment_file"
fi
pantheon_render_comment "${HEAD_SHA:-}" "${AGENT_LIST[@]}" >> "$comment_file"

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
