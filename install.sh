#!/usr/bin/env bash
# install.sh — idempotent installer for review-pantheon into a target repo.
#
# Usage: install.sh /abs/path/to/target-repo [--claude] [--cursor] [--codex] [--gemini]
#
# With no flags: gate-only install (unchanged from prior behavior) — copies the review
# personas, the verdict-decision script, and the GitHub Action into the target repo so its own
# CI checkout can see them (the CLI runner reads agents/*.md and cli/lib/verdict.sh from this
# repo directly; the Action runs inside the target repo's checkout and needs its own copy of
# everything it uses — see DESIGN.md rule 4). Never overwrites a file that's been customized: a
# file that differs from the shipped version is left alone and reported as skipped.
#
# Does NOT install gate.conf — that file only matters to the CLI lane, and copying it into
# every repo by default meant most installs got a config file they never look at. CLI-lane
# users copy gate.conf.example themselves (README documents this under CLI usage).
#
# --claude / --cursor / --codex / --gemini (combinable): install the counsel agents (and, for
# Claude, all five personas) as in-editor/in-CLI commands so they're usable interactively during
# planning and design, not just from the CI gate. agents/*.md stays the single canonical source
# (DESIGN.md rule 4) — every file these flags write is GENERATED from it at install time, never
# a hand-maintained duplicate. See README's "Provider lanes" section and DESIGN.md's "Generated
# per-tool projections" subsection for the design.
set -euo pipefail

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "install.sh: $*"; }

usage() {
  cat <<'EOF'
Usage: install.sh /abs/path/to/target-repo [--claude] [--cursor] [--codex] [--gemini]

  (no flags)   Gate-only install: personas + verdict script + GitHub Action (default, unchanged).
  --claude     Also install personas as Claude Code subagents + a /counsel command.
  --cursor     Also generate Cursor subagents, .cursor/agents/*.md (best-effort — see README).
  --codex      Also generate Codex Skills, .agents/skills/*/SKILL.md (best-effort — see README).
  --gemini     Also generate Gemini CLI commands, .gemini/commands/*.toml (best-effort — see README).

Flags are combinable: install.sh /path/to/repo --claude --cursor
EOF
}

[[ $# -ge 1 ]] || { usage; die "usage: install.sh /abs/path/to/target-repo [--claude] [--cursor] [--codex] [--gemini]"; }

TARGET=""
DO_CLAUDE=false
DO_CURSOR=false
DO_CODEX=false
DO_GEMINI=false

for arg in "$@"; do
  case "$arg" in
    --claude) DO_CLAUDE=true ;;
    --cursor) DO_CURSOR=true ;;
    --codex) DO_CODEX=true ;;
    --gemini) DO_GEMINI=true ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; die "unknown flag: $arg" ;;
    *)
      [[ -z "$TARGET" ]] || die "unexpected extra argument: $arg"
      TARGET="$arg"
      ;;
  esac
done

[[ -n "$TARGET" ]] || { usage; die "target repo path is required"; }
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

# ---------------------------------------------------------------------------
# Editor/CLI lanes (--claude / --cursor / --codex / --gemini) — install the
# counsel agents (and, for Claude, all five personas) as in-session commands
# so they're usable during planning/design, not just from the CI gate.
# agents/*.md stays the single canonical source (DESIGN.md rule 4): every
# file written below is GENERATED from it right here, never hand-duplicated.
# ---------------------------------------------------------------------------
# persona_body <persona-file> — strips the YAML frontmatter, prints the body.
# Same fence-counting approach as cli/review-gate's strip_frontmatter.
persona_body() {
  awk '
    /^---[[:space:]]*$/ { fence++; next }
    fence >= 2 { print }
  ' "$1"
}

# persona_field <persona-file> <key> — pulls a single-line "key: value" out of
# the frontmatter (good enough for name/description/model — none of which span
# lines in these persona files).
persona_field() {
  local file="$1" key="$2"
  awk -v key="$key" '
    /^---[[:space:]]*$/ { fence++; if (fence == 2) exit; next }
    fence == 1 && $0 ~ "^" key ":" { sub("^" key ":[[:space:]]*", ""); print; exit }
  ' "$file"
}

# escape_bs_quote — reads a value on stdin and escapes backslash then double-
# quote (in that order, so the backslash the quote step inserts isn't itself
# re-escaped). This is the shared \\ / \" escape pair used by BOTH a TOML
# basic string (single- or multi-line — see the Gemini generator below) and a
# YAML double-quoted scalar (see the Cursor/Codex generators below): escaping
# every quote also defangs any embedded run of 3+ quotes (e.g. a literal
# """), since no unescaped triple survives. Composes with a pipe so it works
# for both a single-line value (persona_field) and a multi-line one
# (persona_body).
escape_bs_quote() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

if [[ "$DO_CLAUDE" == "true" ]]; then
  CLAUDE_AGENTS_DEST="$TARGET/.claude/agents"
  mkdir -p "$CLAUDE_AGENTS_DEST"
  for persona in "$AGENTS_SRC"/*.md; do
    install_file "$persona" "$CLAUDE_AGENTS_DEST/$(basename "$persona")"
  done

  COUNSEL_TMP="$(mktemp)"
  cat > "$COUNSEL_TMP" <<'COUNSEL_EOF'
---
description: Run the review-pantheon counsel tier (Socrates, then Diogenes + Plato) against a design, spec, or diff, and synthesize their verdicts.
argument-hint: [design/spec/diff reference — a file, a PR, a paragraph describing the proposal]
---

<!-- GENERATED by install.sh --claude from review-pantheon's agents/{socrates,diogenes,plato}.md
     (installed alongside this file at .claude/agents/). Do not edit by hand — re-run
     install.sh --claude to refresh it. Edit the personas themselves in review-pantheon's
     agents/*.md instead: that file is the single canonical source (DESIGN.md rule 4), this
     command is a generated projection of it, not a copy. -->

# /counsel — the review-pantheon counsel tier

Reference under review: $ARGUMENTS

Run the counsel agents installed at `.claude/agents/{socrates,diogenes,plato}.md` against the
reference above:

1. **If the decision is still open** — no committed design yet, or the approach itself is in
   question — invoke @socrates first to map the genuinely distinct options and give a go/no-go
   before anything narrower runs. Wait for its verdict before continuing.
2. **Once there is a proposed shape** — a design, spec, or diff to weigh in on — invoke
   @diogenes and @plato (either order, or together) against that shape. Diogenes asks whether
   it's more than the job needs; Plato asks whether it has a coherent shape or is drifting.
3. Skip socrates only when the request makes clear the approach is already decided and just the
   shape is under review — in that case run diogenes + plato only.

Each subagent ends its output with the standard JSON verdict object (agent, verdict,
has_blocker, findings, summary — see review-pantheon's DESIGN.md verdict contract). After every
invoked agent has reported:

- Show each agent's verdict and top findings.
- Surface disagreement plainly: if any agent reports a red verdict (`NO_GO`, `GUT`, `FRACTURED`)
  or `has_blocker: true`, lead with that — don't bury a blocker under a summary that reads as
  approval.
- End with one combined recommendation: proceed, proceed with the named guardrails, or stop and
  resolve the blocker(s) first.
COUNSEL_EOF

  install_file "$COUNSEL_TMP" "$TARGET/.claude/commands/counsel.md"
  rm -f "$COUNSEL_TMP"
fi

# --cursor: Cursor's native subagent convention. VERIFIED against current official docs
# (cursor.com/docs/subagents, introduced Cursor 2.4) — project-level agents live at
# .cursor/agents/*.md, frontmatter is name/description/model/readonly/is_background. Cursor's
# older "Commands" feature (.cursor/commands/*.md) is deprecated as of the same release and
# folded into a separate "Skills" feature that has no documented argument-passing mechanism —
# Subagents is the closer match to a named, invokable persona and is what's generated here.
if [[ "$DO_CURSOR" == "true" ]]; then
  CURSOR_AGENTS_DEST="$TARGET/.cursor/agents"
  mkdir -p "$CURSOR_AGENTS_DEST"
  for persona in "$AGENTS_SRC"/*.md; do
    persona_name="$(basename "$persona" .md)"
    persona_desc="$(persona_field "$persona" description)"
    persona_model="$(persona_field "$persona" model)"
    persona_desc_esc="$(printf '%s' "$persona_desc" | escape_bs_quote)"
    CURSOR_TMP="$(mktemp)"
    {
      echo "---"
      echo "name: $persona_name"
      echo "description: \"$persona_desc_esc\""
      [[ -n "$persona_model" ]] && echo "model: $persona_model"
      echo "readonly: true"
      echo "---"
      echo
      echo "<!-- GENERATED by install.sh --cursor from review-pantheon's agents/$persona_name.md"
      echo "     — do not edit by hand; re-run install.sh --cursor to refresh it. Cursor's native"
      echo "     subagent format (verified: cursor.com/docs/subagents, Cursor 2.4+) — best-effort"
      echo "     lane, not integration-tested against a live Cursor install in this repo's CI. -->"
      echo
      persona_body "$persona"
    } > "$CURSOR_TMP"
    install_file "$CURSOR_TMP" "$CURSOR_AGENTS_DEST/$persona_name.md"
    rm -f "$CURSOR_TMP"
  done
fi

# --codex: Codex CLI has NO documented repo-level custom-command/prompt convention — its
# custom-prompts feature (~/.codex/prompts/*.md) is user-level only and itself deprecated per
# OpenAI's own docs (learn.chatgpt.com/docs/custom-prompts). The documented, git-shareable,
# repo-level mechanism is Skills: .agents/skills/<name>/SKILL.md, frontmatter name+description
# (developers.openai.com/codex/skills). That's what's generated here — not an invented
# per-repo "command" convention Codex doesn't actually have.
if [[ "$DO_CODEX" == "true" ]]; then
  CODEX_SKILLS_DEST="$TARGET/.agents/skills"
  for persona in "$AGENTS_SRC"/*.md; do
    persona_name="$(basename "$persona" .md)"
    persona_desc="$(persona_field "$persona" description)"
    persona_desc_esc="$(printf '%s' "$persona_desc" | escape_bs_quote)"
    mkdir -p "$CODEX_SKILLS_DEST/$persona_name"
    CODEX_TMP="$(mktemp)"
    {
      echo "---"
      echo "name: $persona_name"
      echo "description: \"$persona_desc_esc\""
      echo "---"
      echo
      echo "<!-- GENERATED by install.sh --codex from review-pantheon's agents/$persona_name.md"
      echo "     — do not edit by hand; re-run install.sh --codex to refresh it. Codex Skills"
      echo "     format (verified: developers.openai.com/codex/skills) — best-effort lane, not"
      echo "     integration-tested against a live Codex install in this repo's CI. -->"
      echo
      persona_body "$persona"
    } > "$CODEX_TMP"
    install_file "$CODEX_TMP" "$CODEX_SKILLS_DEST/$persona_name/SKILL.md"
    rm -f "$CODEX_TMP"
  done
fi

# --gemini: Gemini CLI's native custom-command convention. VERIFIED against the official docs
# (github.com/google-gemini/gemini-cli/blob/main/docs/cli/custom-commands.md) — project-level
# commands at .gemini/commands/*.toml ARE officially supported (and take priority over the
# user-level ~/.gemini/commands/ equivalent), TOML fields are `description` and `prompt`, and
# `{{args}}` is the argument placeholder.
if [[ "$DO_GEMINI" == "true" ]]; then
  GEMINI_COMMANDS_DEST="$TARGET/.gemini/commands"
  mkdir -p "$GEMINI_COMMANDS_DEST"
  for persona in "$AGENTS_SRC"/*.md; do
    persona_name="$(basename "$persona" .md)"
    persona_desc="$(persona_field "$persona" description)"
    persona_desc="$(printf '%s' "$persona_desc" | escape_bs_quote)"
    GEMINI_TMP="$(mktemp)"
    {
      echo "# GENERATED by install.sh --gemini from review-pantheon's agents/$persona_name.md —"
      echo "# do not edit by hand; re-run install.sh --gemini to refresh it. Gemini CLI custom-"
      echo "# command TOML format (verified: github.com/google-gemini/gemini-cli/blob/main/docs/"
      echo "# cli/custom-commands.md) — best-effort lane, not integration-tested against a live"
      echo "# Gemini CLI install in this repo's CI."
      echo
      printf 'description = "%s"\n' "$persona_desc"
      echo 'prompt = """'
      # persona_body is escaped for the enclosing TOML basic multi-line string
      # (backslash and any embedded quote, including a literal """) — see
      # escape_bs_quote above. Unescaped, a backslash (e.g. a Windows path) or
      # a literal """ in the body produces invalid TOML that this script would
      # still report as installed.
      persona_body "$persona" | escape_bs_quote
      echo
      echo "Reference under review: {{args}}"
      echo '"""'
    } > "$GEMINI_TMP"
    install_file "$GEMINI_TMP" "$GEMINI_COMMANDS_DEST/$persona_name.toml"
    rm -f "$GEMINI_TMP"
  done
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
  3. .github/workflows/review.yml ships pinned to anthropics/claude-code-action's v1.0.183
     commit SHA — confirm that SHA still matches a release you trust
     (gh api repos/anthropics/claude-code-action/git/ref/tags/v1.0.183, or check
     github.com/anthropics/claude-code-action/releases) before relying on this gate. If you
     re-pin to a newer release, re-verify the with: inputs and output below against that
     release's action.yml too — the interface can change between releases.
  4. What review.yml uses today, already confirmed against v1.0.183's real action.yml:
     claude_code_oauth_token, prompt, claude_args (with --allowedTools and --json-schema —
     v1 has no allowed_tools input), and the structured_output output (v1 has no "result"
     output). See review.yml's own header comment for the sources this was verified against.
  5. Open a test PR with a deliberately planted blocker (a secret in a diff, an unguarded
     rm, whatever your REVIEW_RULES.md forbids) and confirm the gate goes RED before you
     trust a green result on a real PR.
  6. Only after step 5 passes, consider adding this workflow as a required status check.
  7. Using the CLI lane too? Copy gate.conf.example to gate.conf at your repo root and edit
     it — it isn't installed automatically (see README's CLI usage section).

Prefer zero repo footprint? Skip install.sh's gate files entirely and use the published
action instead — see examples/review-gate.yml and README's "Option A — published action."
EOF
