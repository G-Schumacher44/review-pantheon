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
# RULES_PRESENT (true/false).
set -euo pipefail

AGENT_NAME="${1:?usage: build_prompt.sh <agent-name> <personas-dir> <prompt-out-file>}"
PERSONAS_DIR="${2:?usage: build_prompt.sh <agent-name> <personas-dir> <prompt-out-file>}"
PROMPT_FILE="${3:?usage: build_prompt.sh <agent-name> <personas-dir> <prompt-out-file>}"

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
  else
    echo "- House rules file: $RULES_FILE (not present - skip house-rule checks, note it)"
  fi
  echo
  echo "Use \`git diff ${BASE_SHA}...${HEAD_SHA}\`, \`git show <ref>:path\`, and \`git log\` to inspect the change."
  echo
  echo "## Output contract"
  echo "End your response with exactly one JSON verdict object, per your persona instructions above, and nothing after it. No prose after the JSON. This run additionally constrains your final answer with a JSON schema (--json-schema) matching that same shape — match it."
} >> "$PROMPT_FILE"
