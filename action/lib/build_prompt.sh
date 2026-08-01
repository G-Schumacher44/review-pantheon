#!/usr/bin/env bash
# action/lib/build_prompt.sh — shared prompt-builder for the composite action (action.yml).
#
# action.yml can't loop `uses:` steps at runtime (composite-action steps are a static YAML
# list, not a template body — see action.yml's own header comment for the doc-verified
# reasoning), so the five possible agents each get their own literal build/run/decide step
# trio. This script is what keeps that unrolling from becoming five hand-copied prompt-builder
# bodies: one file, invoked once per enabled agent, same fence-stripping + context-block shape
# as action/review.yml's inline "Build prompt" step (kept identical on purpose — DESIGN.md's
# "Two runtimes, one rule" is about the verdict decision, but the prompt shape should match too
# so a persona sees the same context regardless of which runtime invoked it).
#
# Usage: build_prompt.sh <agent-name> <personas-dir> <prompt-out-file>
# Reads from env: REPO_NAME, PR_NUMBER, PR_TITLE, BASE_SHA, HEAD_SHA, BASE_REF, RULES_FILE,
# RULES_PRESENT (true/false), RULES_CONTENT_PATH, and — apollo only — SPEC_FILE, SPEC_PRESENT
# (true/false), SPEC_CONTENT_PATH. The non-apollo build-prompt steps in action.yml don't set
# SPEC_FILE/SPEC_PRESENT/SPEC_CONTENT_PATH at all, so all three default to empty/false below
# rather than tripping `set -u`.
#
# RULES_CONTENT_PATH/SPEC_CONTENT_PATH are PATHS to already-fetched file content (under
# $RUNNER_TEMP), resolved ONCE by action.yml's "Resolve gate configuration" step via
# `git show <base-sha>:<path>` against the PR's BASE commit — never read from disk here directly,
# and never from the checked-out working tree, which on a fork PR is attacker-controlled head
# content (DESIGN.md's "Security posture" — "Base-SHA-pinned context file reads"). Content
# travels as a file path, not the content itself, because a large base spec/rules file blew past
# the OS's per-step environment size limit when it rode along as a plain env var — a file has no
# such ceiling. This script only cats what it's handed; it has no filesystem access to
# REVIEW_RULES.md/DESIGN.md of its own, by design — there's structurally no path here for head
# content to reach the prompt.
set -euo pipefail

AGENT_NAME="${1:?usage: build_prompt.sh <agent-name> <personas-dir> <prompt-out-file>}"
PERSONAS_DIR="${2:?usage: build_prompt.sh <agent-name> <personas-dir> <prompt-out-file>}"
PROMPT_FILE="${3:?usage: build_prompt.sh <agent-name> <personas-dir> <prompt-out-file>}"

RULES_CONTENT_PATH="${RULES_CONTENT_PATH:-}"
SPEC_FILE="${SPEC_FILE:-}"
SPEC_PRESENT="${SPEC_PRESENT:-false}"
SPEC_CONTENT_PATH="${SPEC_CONTENT_PATH:-}"

PERSONA="$PERSONAS_DIR/${AGENT_NAME}.md"
if [ ! -f "$PERSONA" ]; then
  echo "::error::missing persona file $PERSONA — check the 'agents' and 'personas_path' inputs (personas_path overrides where personas are read from; leave it unset to use the ones bundled with this action)." >&2
  exit 1
fi

# Strip YAML frontmatter (same fence-counting approach as action/review.yml's inline step and
# install.sh's persona_body()) — the second `---` fence ends the frontmatter block.
awk '
  /^---[[:space:]]*$/ { fence++; next }
  fence >= 2 { print }
' "$PERSONA" > "$PROMPT_FILE"

{
  echo
  echo "---"
  echo "## Run context"
  echo "- Repo: $REPO_NAME"
  printf -- "- PR: #%s - %s\n" "$PR_NUMBER" "$PR_TITLE"
  echo "- Diff range: ${BASE_SHA}...${HEAD_SHA}"
  echo "- Base branch: $BASE_REF"
  if [ "$RULES_PRESENT" = "true" ]; then
    echo "- House rules file: $RULES_FILE (present - treat each rule as a blocker-class check)"
    echo "  Pinned to the PR's base commit (${BASE_SHA}), not its head - this is the only copy to"
    echo "  trust, even if you notice a different one while inspecting the working tree."
    echo '  ```'
    if [ -n "$RULES_CONTENT_PATH" ] && [ -f "$RULES_CONTENT_PATH" ]; then
      printf '  %s\n' "$(cat "$RULES_CONTENT_PATH")"
    fi
    echo '  ```'
  else
    echo "- House rules file: $RULES_FILE (not present at base ${BASE_SHA} - not applied)"
  fi
  # Spec-file context — apollo only, not other agents (SPEC_PRESENT is only ever "true" for the
  # apollo build-prompt step; every other agent leaves it at the "false" default above). The
  # persona itself skips the check silently when this line is absent, so a repo with no spec
  # file gets today's behavior unchanged for every agent.
  if [ "$AGENT_NAME" = "apollo" ] && [ "$SPEC_PRESENT" = "true" ]; then
    echo "- Spec file: $SPEC_FILE (present — check the delivered change against the sections of it relevant to the changed behavior; a contradiction is a finding that states both resolutions: fix the code or amend the spec)"
    echo "  Pinned to the PR's base commit (${BASE_SHA}), not its head - this is the only copy to"
    echo "  trust, even if you notice a different one while inspecting the working tree."
    echo '  ```'
    if [ -n "$SPEC_CONTENT_PATH" ] && [ -f "$SPEC_CONTENT_PATH" ]; then
      printf '  %s\n' "$(cat "$SPEC_CONTENT_PATH")"
    fi
    echo '  ```'
  fi
  echo
  echo "Use \`git diff ${BASE_SHA}...${HEAD_SHA}\`, \`git show <ref>:path\`, and \`git log\` to inspect the change."
  echo
  echo "## Output contract"
  echo "End your response with exactly one JSON verdict object, per your persona instructions above, and nothing after it. No prose after the JSON. This run additionally constrains your final answer with a JSON schema (--json-schema) matching that same shape — match it."
} >> "$PROMPT_FILE"
