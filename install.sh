#!/usr/bin/env bash
# install.sh — idempotent installer for review-pantheon into a target repo.
#
# Usage: install.sh /abs/path/to/target-repo
#
# Copies the review personas, the verdict-decision script, and the GitHub Action into the
# target repo so its own CI checkout can see them (the CLI runner reads agents/*.md and
# cli/lib/verdict.sh from this repo directly; the Action runs inside the target repo's
# checkout and needs its own copy of everything it uses — see DESIGN.md rule 4). Never
# overwrites a file that's been customized: a file that differs from the shipped version is
# left alone and reported as skipped.
#
# Does NOT install gate.conf — that file only matters to the CLI lane, and copying it into
# every repo by default meant most installs got a config file they never look at. CLI-lane
# users copy gate.conf.example themselves (README documents this under CLI usage).
set -euo pipefail

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "install.sh: $*"; }

[[ $# -eq 1 ]] || die "usage: install.sh /abs/path/to/target-repo"

TARGET="$1"
[[ -d "$TARGET" ]] || die "target repo does not exist: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENTS_SRC="$SCRIPT_DIR/agents"
DECIDE_SRC="$SCRIPT_DIR/action/decide_verdict.py"
ACTION_SRC="$SCRIPT_DIR/action/review.yml"
RULES_SRC="$SCRIPT_DIR/REVIEW_RULES.example.md"

AGENTS_DEST="$TARGET/.github/review-agents"
DECIDE_DEST="$TARGET/.github/review-agents/decide_verdict.py"
WORKFLOW_DEST="$TARGET/.github/workflows/review.yml"
RULES_DEST="$TARGET/REVIEW_RULES.md"
GITIGNORE_DEST="$TARGET/.gitignore"

SKIPPED=()

# install_file <src> <dest>
# Copies src to dest unless dest already exists and differs from src (customized) —
# in which case it's left alone and reported. If dest exists and is identical, it's a no-op.
install_file() {
  local src="$1" dest="$2"
  if [[ -f "$dest" ]]; then
    if cmp -s "$src" "$dest"; then
      return 0
    fi
    SKIPPED+=("$dest")
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  note "installed $dest"
}

[[ -d "$AGENTS_SRC" ]] || die "missing $AGENTS_SRC — run this from a review-pantheon checkout"
[[ -f "$DECIDE_SRC" ]] || die "missing $DECIDE_SRC"
[[ -f "$ACTION_SRC" ]] || die "missing $ACTION_SRC"
[[ -f "$RULES_SRC" ]] || die "missing $RULES_SRC"

mkdir -p "$AGENTS_DEST"
for persona in "$AGENTS_SRC"/*.md; do
  install_file "$persona" "$AGENTS_DEST/$(basename "$persona")"
done

install_file "$DECIDE_SRC" "$DECIDE_DEST"
install_file "$ACTION_SRC" "$WORKFLOW_DEST"
install_file "$RULES_SRC" "$RULES_DEST"

# .gitignore: append the state-file entry if not already present.
if [[ -f "$GITIGNORE_DEST" ]]; then
  if ! grep -qxF '.review-gate-state.json' "$GITIGNORE_DEST"; then
    printf '%s\n' '.review-gate-state.json' >> "$GITIGNORE_DEST"
    note "appended .review-gate-state.json to $GITIGNORE_DEST"
  fi
else
  printf '%s\n' '.review-gate-state.json' > "$GITIGNORE_DEST"
  note "created $GITIGNORE_DEST"
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  note "left unchanged (differs from shipped version — looks customized):"
  for f in "${SKIPPED[@]}"; do
    note "  - $f"
  done
fi

cat <<EOF

review-pantheon installed into $TARGET

Post-install checklist:
  1. Set the repo secret CLAUDE_CODE_OAUTH_TOKEN (Settings -> Secrets and variables -> Actions).
  2. Set the repo variable REVIEW_GATE_ENABLED=true (Settings -> Secrets and variables ->
     Actions -> Variables) — the workflow no-ops until this is set.
  3. Pin the action in .github/workflows/review.yml: it ships with a placeholder
     PIN-ME-TO-A-FULL-COMMIT-SHA in place of a real anthropics/claude-code-action commit SHA.
     Replace it with a real full 40-character commit SHA before relying on this gate.
  4. Verify the action's input/output names (claude_code_oauth_token, prompt, allowed_tools,
     the "result" output the decide step reads) against the release you just pinned — they
     are unverified guesses, written without network access to the action's docs. This is
     the same warning that's in review.yml's own header comment.
  5. Open a test PR with a deliberately planted blocker (a secret in a diff, an unguarded
     rm, whatever your REVIEW_RULES.md forbids) and confirm the gate goes RED before you
     trust a green result on a real PR.
  6. Only after step 5 passes, consider adding this workflow as a required status check.
  7. Using the CLI lane too? Copy gate.conf.example to gate.conf at your repo root and edit
     it — it isn't installed automatically (see README's CLI usage section).
EOF
