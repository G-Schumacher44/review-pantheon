#!/usr/bin/env bash
# install.sh — idempotent installer for review-pantheon into a target repo.
#
# Usage: install.sh /abs/path/to/target-repo
#
# Copies the review personas and GitHub Action into the target repo so its own CI checkout
# can see them (the CLI runner reads agents/*.md from this repo directly; the Action runs
# inside the target repo's checkout and needs its own copy — see DESIGN.md rule 4). Never
# overwrites a file that's been customized: a file that differs from the shipped version is
# left alone and reported as skipped.
set -euo pipefail

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "install.sh: $*"; }

[[ $# -eq 1 ]] || die "usage: install.sh /abs/path/to/target-repo"

TARGET="$1"
[[ -d "$TARGET" ]] || die "target repo does not exist: $TARGET"
TARGET="$(cd "$TARGET" && pwd)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENTS_SRC="$SCRIPT_DIR/agents"
ACTION_SRC="$SCRIPT_DIR/action/review.yml"
RULES_SRC="$SCRIPT_DIR/REVIEW_RULES.example.md"
GATE_CONF_SRC="$SCRIPT_DIR/gate.conf.example"

AGENTS_DEST="$TARGET/.github/review-agents"
WORKFLOW_DEST="$TARGET/.github/workflows/review.yml"
RULES_DEST="$TARGET/REVIEW_RULES.md"
GATE_CONF_DEST="$TARGET/gate.conf"
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
[[ -f "$ACTION_SRC" ]] || die "missing $ACTION_SRC"
[[ -f "$RULES_SRC" ]] || die "missing $RULES_SRC"
[[ -f "$GATE_CONF_SRC" ]] || die "missing $GATE_CONF_SRC"

mkdir -p "$AGENTS_DEST"
for persona in "$AGENTS_SRC"/*.md; do
  install_file "$persona" "$AGENTS_DEST/$(basename "$persona")"
done

install_file "$ACTION_SRC" "$WORKFLOW_DEST"
install_file "$RULES_SRC" "$RULES_DEST"
install_file "$GATE_CONF_SRC" "$GATE_CONF_DEST"

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
  4. Open a test PR with a deliberately planted blocker (a secret in a diff, an unguarded
     rm, whatever your REVIEW_RULES.md forbids) and confirm the gate goes RED before you
     trust a green result on a real PR.
  5. Only after step 4 passes, consider adding this workflow as a required status check.
EOF
