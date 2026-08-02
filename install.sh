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
# users copy gate.conf.example themselves (docs/CLI.md documents this under gate.conf).
#
# --claude / --cursor / --codex / --gemini (combinable): install the counsel agents (and, for
# Claude, all five personas) as in-editor/in-CLI commands so they're usable interactively during
# planning and design, not just from the CI gate. agents/*.md stays the single canonical source
# (DESIGN.md rule 4) — every file these flags write is GENERATED from it at install time, never
# a hand-maintained duplicate. See DESIGN.md's "Provider lanes" and "Generated per-tool
# projections" sections for the design.
#
# --claude additionally installs the four canonical skills (skills/{gate,counsel,spec-driven,
# design-contract}/SKILL.md — the single hand-maintained source, same shape as agents/*.md under
# rule 4) verbatim into .claude/skills/<name>/SKILL.md, plus a generated /gate command
# (.claude/commands/gate.md, alongside the existing /counsel) that thin-invokes the gate skill.
# Claude-Code-only: no other tool flag touches skills/.
#
# --user (combined with one or more of the above): installs the SAME generated projections at
# USER level ($HOME) instead of into a target repo, so the personas follow you across every
# project instead of being installed per-repo. No target-repo argument is accepted with --user —
# it always writes under $HOME. The gate files (workflow, decide_verdict.py, REVIEW_RULES) are
# NOT installed under --user: they're repo concepts (a PR gate belongs to one repo's CI), so
# --user installs only the per-tool agent/command projections, and requires at least one tool
# flag. Each tool's user-level destination is the same relative path as its repo-level one, just
# rooted at $HOME instead of the target repo — verified per tool against current official docs
# (see each generator's comment block below for the source).
set -euo pipefail

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "install.sh: $*"; }

usage() {
  cat <<'EOF'
Usage: install.sh /abs/path/to/target-repo [--claude] [--cursor] [--codex] [--gemini]
       install.sh --user [--claude] [--cursor] [--codex] [--gemini]

  (no flags)   Gate-only install: personas + verdict script + GitHub Action (default, unchanged).
  --claude     Also install personas as Claude Code subagents, the four canonical skills
               (.claude/skills/{gate,counsel,spec-driven,design-contract}/), + /counsel and
               /gate commands.
  --cursor     Also generate Cursor subagents, .cursor/agents/*.md (best-effort — see DESIGN.md).
  --codex      Also generate Codex Skills, .agents/skills/*/SKILL.md (best-effort — see DESIGN.md).
  --gemini     Also generate Gemini CLI commands, .gemini/commands/*.toml (best-effort — see DESIGN.md).
  --user       Install the per-tool agent projections at USER level ($HOME) instead of into a
               target repo — no target-repo argument, requires at least one of the flags above,
               and does NOT install the gate files (those are repo concepts).

Flags are combinable: install.sh /path/to/repo --claude --cursor
User-level:            install.sh --user --claude --cursor --codex --gemini
EOF
}

[[ $# -ge 1 ]] || { usage; die "usage: install.sh /abs/path/to/target-repo [--claude] [--cursor] [--codex] [--gemini]"; }

TARGET=""
DO_CLAUDE=false
DO_CURSOR=false
DO_CODEX=false
DO_GEMINI=false
DO_USER=false

for arg in "$@"; do
  case "$arg" in
    --claude) DO_CLAUDE=true ;;
    --cursor) DO_CURSOR=true ;;
    --codex) DO_CODEX=true ;;
    --gemini) DO_GEMINI=true ;;
    --user) DO_USER=true ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; die "unknown flag: $arg" ;;
    *)
      [[ -z "$TARGET" ]] || die "unexpected extra argument: $arg"
      TARGET="$arg"
      ;;
  esac
done

# --user installs at $HOME instead of into a target repo: no path argument, and at least one
# tool flag is required (a bare --user with nothing to generate would do nothing silently).
if [[ "$DO_USER" == "true" ]]; then
  [[ -z "$TARGET" ]] || die "--user installs at \$HOME, not a target repo — unexpected argument: '$TARGET'. Usage: install.sh --user [--claude] [--cursor] [--codex] [--gemini]"
  if [[ "$DO_CLAUDE" != "true" && "$DO_CURSOR" != "true" && "$DO_CODEX" != "true" && "$DO_GEMINI" != "true" ]]; then
    die "--user requires at least one tool flag: --claude, --cursor, --codex, --gemini"
  fi
  [[ -n "${HOME:-}" ]] || die "--user requires \$HOME to be set"
  DEST_ROOT="$HOME"
else
  [[ -n "$TARGET" ]] || { usage; die "target repo path is required"; }
  [[ -d "$TARGET" ]] || die "target repo does not exist: $TARGET"
  TARGET="$(cd "$TARGET" && pwd)"
  DEST_ROOT="$TARGET"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AGENTS_SRC="$SCRIPT_DIR/agents"
SKILLS_SRC="$SCRIPT_DIR/skills"
DECIDE_SRC="$SCRIPT_DIR/action/decide_verdict.py"
ACTION_SRC="$SCRIPT_DIR/action/review.yml"
RULES_SRC="$SCRIPT_DIR/REVIEW_RULES.example.md"
GIT_WRAPPER_SRC="$SCRIPT_DIR/cli/lib/pantheon-git-readonly.sh"
# The verdict decider's real implementation (port slice 5's absorption, DESIGN.md's "Two
# runtimes, one rule") — action/review.yml's "Resolve gate scripts (base-pinned)" step reads
# these three files (the ONLY ones `pantheon.verdict` actually imports: itself, the package's
# own __init__.py, and pantheon.jqjson for JSON parsing) at the PR's base commit, so they need
# to exist HERE, vendored into the target repo, for base-pinning to ever find them. DECIDE_SRC
# above (a deprecated, one-release compat shim as of this slice — see action/decide_verdict.py's
# own header) is still vendored too, unchanged, for anything scripting against it directly.
PANTHEON_PKG_SRC="$SCRIPT_DIR/pantheon"

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
[[ -d "$SKILLS_SRC" ]] || die "missing $SKILLS_SRC — run this from a review-pantheon checkout"

# Gate files (personas into .github/review-agents, decide_verdict.py, the workflow, the house
# rules template, .gitignore) are a repo concept — a PR gate belongs to one repo's CI — so
# --user skips this whole section and installs only the per-tool projections below.
if [[ "$DO_USER" != "true" ]]; then
  [[ -f "$DECIDE_SRC" ]] || die "missing $DECIDE_SRC"
  [[ -f "$ACTION_SRC" ]] || die "missing $ACTION_SRC"
  [[ -f "$RULES_SRC" ]] || die "missing $RULES_SRC"
  [[ -f "$GIT_WRAPPER_SRC" ]] || die "missing $GIT_WRAPPER_SRC"
  [[ -f "$PANTHEON_PKG_SRC/__init__.py" ]] || die "missing $PANTHEON_PKG_SRC/__init__.py"
  [[ -f "$PANTHEON_PKG_SRC/jqjson.py" ]] || die "missing $PANTHEON_PKG_SRC/jqjson.py"
  [[ -f "$PANTHEON_PKG_SRC/verdict.py" ]] || die "missing $PANTHEON_PKG_SRC/verdict.py"

  AGENTS_DEST="$TARGET/.github/review-agents"
  DECIDE_DEST="$TARGET/.github/review-agents/decide_verdict.py"
  WORKFLOW_DEST="$TARGET/.github/workflows/review.yml"
  RULES_DEST="$TARGET/REVIEW_RULES.md"
  GITIGNORE_DEST="$TARGET/.gitignore"
  # Base-pinned by action/review.yml's "Resolve gate scripts (base-pinned)" step (see
  # PANTHEON_PKG_SRC's own comment above) — same "installed here is required, but the literal
  # path used at run time is the base-pinned $RUNNER_TEMP copy, not this one" caveat as
  # GIT_WRAPPER_DEST below.
  PANTHEON_PKG_DEST="$TARGET/.github/review-agents/pantheon"
  # action/review.yml reads this file's CONTENT from the PR's base commit (`git show
  # $BASE_SHA:.github/review-agents/pantheon-git-readonly.sh`, its "Resolve read-only git
  # wrapper (base-pinned)" step) into $RUNNER_TEMP, and points claude_args' readonly-tier Bash
  # prefix at THAT resolved path, not at this checked-out-working-tree path directly — installing
  # it here is still required (it's what gets committed and read at the PR's base), but the path
  # itself is never the literal --allowedTools prefix. See that step's own comment for why a
  # wrapper is needed instead of a bare `Bash(git diff *)`-style pattern (Codex P1, round 1) and
  # why base-pinning is needed on top of the wrapper itself (Codex P1, round 2 — a bare
  # $GITHUB_WORKSPACE-pinned prefix would let a PR replace this exact file and still be trusted).
  GIT_WRAPPER_DEST="$TARGET/.github/review-agents/pantheon-git-readonly.sh"

  mkdir -p "$AGENTS_DEST"
  for persona in "$AGENTS_SRC"/*.md; do
    install_file "$persona" "$AGENTS_DEST/$(basename "$persona")"
  done

  install_file "$DECIDE_SRC" "$DECIDE_DEST"
  install_file "$ACTION_SRC" "$WORKFLOW_DEST"
  install_file "$RULES_SRC" "$RULES_DEST"
  install_file "$GIT_WRAPPER_SRC" "$GIT_WRAPPER_DEST"
  chmod +x "$GIT_WRAPPER_DEST"

  mkdir -p "$PANTHEON_PKG_DEST"
  for pyfile in __init__.py jqjson.py verdict.py; do
    install_file "$PANTHEON_PKG_SRC/$pyfile" "$PANTHEON_PKG_DEST/$pyfile"
  done

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

# Each generator below is parameterized by <dest_root> so the SAME generated-file logic runs
# for both a repo install (dest_root=$TARGET, e.g. .claude/agents/) and a --user install
# (dest_root=$HOME, e.g. ~/.claude/agents/) — one function, two roots, never two copies of the
# generation logic. generator_field/generator_body/escape_bs_quote above are already dest-root-
# agnostic (they only read from $AGENTS_SRC).

# install_claude <dest_root> — personas verbatim into <dest_root>/.claude/agents/, the four
# canonical skills verbatim into <dest_root>/.claude/skills/<name>/SKILL.md, plus generated
# /counsel and /gate commands at <dest_root>/.claude/commands/{counsel,gate}.md. VERIFIED at both
# project and user scope against current official docs (code.claude.com/docs/en/sub-agents,
# code.claude.com/docs/en/skills, code.claude.com/docs/en/slash-commands, fetched 2026-08-01):
# subagents load from both `.claude/agents/` (project) and `~/.claude/agents/` (user — "available
# in every project on your machine"); skills load identically from `.claude/skills/<name>/SKILL.md`
# (project) and `~/.claude/skills/<name>/SKILL.md` (personal — "all your projects") — a SKILL.md
# needs only a `description` field (recommended, not required) for Claude to know when to load it;
# `name` is optional and defaults to the directory name, which is what these skills rely on since
# their directory names (gate, counsel, spec-driven, design-contract) are already the intended
# command/skill names. Slash commands are documented as merged into Skills going forward, but the
# docs explicitly say ".claude/commands/ files keep working" — that mechanism is symmetric across
# scopes (Claude Code scans a `commands/` dir wherever it finds one under `.claude/`), so
# `~/.claude/commands/{counsel,gate}.md` work the same way their project-level counterparts do.
install_claude() {
  local dest_root="$1"
  local claude_agents_dest="$dest_root/.claude/agents"
  mkdir -p "$claude_agents_dest"
  for persona in "$AGENTS_SRC"/*.md; do
    install_file "$persona" "$claude_agents_dest/$(basename "$persona")"
  done

  # Skills — skills/{gate,counsel,spec-driven,design-contract}/SKILL.md is the single
  # hand-maintained source (same shape as agents/*.md under DESIGN.md rule 4); copied verbatim,
  # never regenerated per install, into .claude/skills/<name>/SKILL.md.
  local claude_skills_dest="$dest_root/.claude/skills"
  for skill_dir in "$SKILLS_SRC"/*/; do
    local skill_name
    skill_name="$(basename "$skill_dir")"
    mkdir -p "$claude_skills_dest/$skill_name"
    install_file "$skill_dir/SKILL.md" "$claude_skills_dest/$skill_name/SKILL.md"
  done

  local gate_tmp
  gate_tmp="$(mktemp)"
  cat > "$gate_tmp" <<'GATE_EOF'
---
description: Run review-pantheon's review gate (Artemis + Apollo) against a PR — dry-run first, then live, and read the combined verdict per the gate skill's discipline.
argument-hint: "[--pr <number>] [--dry-run]"
---

<!-- GENERATED by install.sh --claude — do not edit by hand; re-run install.sh --claude to
     refresh it. Thin invoker: the actual procedure lives in the gate skill installed alongside
     this file at .claude/skills/gate/SKILL.md. Edit that skill in review-pantheon's own
     skills/gate/SKILL.md (the canonical source), not this command. -->

# /gate — run the review-pantheon gate

PR reference / flags: $ARGUMENTS

Follow the procedure in the installed `gate` skill (`.claude/skills/gate/SKILL.md`) — dry-run
first, reading the combined verdict correctly, follow-up mode, and the findings discipline — to
run `pantheon gate` (the current CLI; the deprecated `cli/review-gate`/`review-gate` compat shim
still works this release, same flags) against the PR referenced above (ask which PR if none was
given). Default to a `--dry-run` pass first unless the arguments explicitly request a live run.

`/gate` installs the *procedure*, not the CLI itself — `install.sh --claude` never puts
`pantheon` on `PATH`. Before running it, check `command -v pantheon`; if that fails, see the
skill's "Locating `pantheon`" note rather than assuming the command doesn't exist.
GATE_EOF

  install_file "$gate_tmp" "$dest_root/.claude/commands/gate.md"
  rm -f "$gate_tmp"

  local counsel_tmp
  counsel_tmp="$(mktemp)"
  cat > "$counsel_tmp" <<'COUNSEL_EOF'
---
description: Run the review-pantheon counsel tier (Socrates, then Diogenes + Plato) against a design, spec, or diff, and synthesize their verdicts.
argument-hint: "[design/spec/diff reference — a file, a PR, a paragraph describing the proposal]"
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

  install_file "$counsel_tmp" "$dest_root/.claude/commands/counsel.md"
  rm -f "$counsel_tmp"
}

# install_cursor <dest_root> — Cursor's native subagent convention. VERIFIED against current
# official docs (cursor.com/docs/subagents, fetched 2026-07-30) at both scopes: project agents
# at `.cursor/agents/*.md`, user agents at `~/.cursor/agents/*.md` ("All projects for current
# user" — the doc's own scope table). Frontmatter is name/description/model/readonly/
# is_background. Cursor's older "Commands" feature (.cursor/commands/*.md) is deprecated as of
# the same release and folded into a separate "Skills" feature that has no documented
# argument-passing mechanism — Subagents is the closer match to a named, invokable persona and
# is what's generated here, at both scopes.
install_cursor() {
  local dest_root="$1"
  local cursor_agents_dest="$dest_root/.cursor/agents"
  mkdir -p "$cursor_agents_dest"
  for persona in "$AGENTS_SRC"/*.md; do
    local persona_name persona_desc persona_model persona_desc_esc cursor_tmp
    persona_name="$(basename "$persona" .md)"
    persona_desc="$(persona_field "$persona" description)"
    persona_model="$(persona_field "$persona" model)"
    persona_desc_esc="$(printf '%s' "$persona_desc" | escape_bs_quote)"
    cursor_tmp="$(mktemp)"
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
    } > "$cursor_tmp"
    install_file "$cursor_tmp" "$cursor_agents_dest/$persona_name.md"
    rm -f "$cursor_tmp"
  done
}

# install_codex <dest_root> — Codex CLI has NO documented repo-level custom-command/prompt
# convention — its custom-prompts feature (~/.codex/prompts/*.md) is user-level only and itself
# deprecated per OpenAI's own docs (learn.chatgpt.com/docs/custom-prompts). The documented,
# git-shareable, repo-level mechanism is Skills: `.agents/skills/<name>/SKILL.md`. Skills also
# has a documented USER scope — VERIFIED against current official docs
# (developers.openai.com/codex/skills -> learn.chatgpt.com/docs/build-skills, fetched
# 2026-07-30): its discovery-scope table lists `USER` at `$HOME/.agents/skills` ("curate skills
# relevant to a user that apply to any repository"), the same relative layout as the repo scope
# — that's what's generated here at both roots, not an invented "command" convention Codex
# doesn't actually have.
install_codex() {
  local dest_root="$1"
  local codex_skills_dest="$dest_root/.agents/skills"
  for persona in "$AGENTS_SRC"/*.md; do
    local persona_name persona_desc persona_desc_esc codex_tmp
    persona_name="$(basename "$persona" .md)"
    persona_desc="$(persona_field "$persona" description)"
    persona_desc_esc="$(printf '%s' "$persona_desc" | escape_bs_quote)"
    mkdir -p "$codex_skills_dest/$persona_name"
    codex_tmp="$(mktemp)"
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
    } > "$codex_tmp"
    install_file "$codex_tmp" "$codex_skills_dest/$persona_name/SKILL.md"
    rm -f "$codex_tmp"
  done
}

# install_gemini <dest_root> — Gemini CLI's native custom-command convention. VERIFIED against
# the official docs (github.com/google-gemini/gemini-cli/blob/main/docs/cli/custom-commands.md,
# fetched 2026-07-30) at both scopes — project-level commands at `.gemini/commands/*.toml` ARE
# officially supported and take priority over the user-level `~/.gemini/commands/*.toml`
# equivalent when a name collides ("the project command will always be used"); both scopes use
# the same TOML fields (`description`, `prompt`) and the `{{args}}` placeholder, so the same
# generator runs for both — --user just writes the lower-priority copy at $HOME instead.
install_gemini() {
  local dest_root="$1"
  local gemini_commands_dest="$dest_root/.gemini/commands"
  mkdir -p "$gemini_commands_dest"
  for persona in "$AGENTS_SRC"/*.md; do
    local persona_name persona_desc gemini_tmp
    persona_name="$(basename "$persona" .md)"
    persona_desc="$(persona_field "$persona" description)"
    persona_desc="$(printf '%s' "$persona_desc" | escape_bs_quote)"
    gemini_tmp="$(mktemp)"
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
    } > "$gemini_tmp"
    install_file "$gemini_tmp" "$gemini_commands_dest/$persona_name.toml"
    rm -f "$gemini_tmp"
  done
}

[[ "$DO_CLAUDE" == "true" ]] && install_claude "$DEST_ROOT"
[[ "$DO_CURSOR" == "true" ]] && install_cursor "$DEST_ROOT"
[[ "$DO_CODEX" == "true" ]] && install_codex "$DEST_ROOT"
[[ "$DO_GEMINI" == "true" ]] && install_gemini "$DEST_ROOT"

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  note "left unchanged (differs from shipped version — looks customized):"
  for f in "${SKIPPED[@]}"; do
    note "  - $f"
  done
fi

if [[ "$DO_USER" == "true" ]]; then
  INSTALLED_TOOLS=()
  [[ "$DO_CLAUDE" == "true" ]] && INSTALLED_TOOLS+=("claude ($DEST_ROOT/.claude/agents/, $DEST_ROOT/.claude/skills/{gate,counsel,spec-driven,design-contract}/, $DEST_ROOT/.claude/commands/{counsel,gate}.md)")
  [[ "$DO_CURSOR" == "true" ]] && INSTALLED_TOOLS+=("cursor ($DEST_ROOT/.cursor/agents/)")
  [[ "$DO_CODEX" == "true" ]] && INSTALLED_TOOLS+=("codex ($DEST_ROOT/.agents/skills/)")
  [[ "$DO_GEMINI" == "true" ]] && INSTALLED_TOOLS+=("gemini ($DEST_ROOT/.gemini/commands/)")

  cat <<EOF

review-pantheon user-level install complete — projections follow you across every project on
this machine:
EOF
  for t in "${INSTALLED_TOOLS[@]}"; do
    note "  - $t"
  done
  cat <<EOF

No gate files were installed (workflow, decide_verdict.py, REVIEW_RULES.md) — those are repo
concepts. Run install.sh (without --user) inside each repo you want the CI gate in.
EOF
  exit 0
fi

cat <<EOF

review-pantheon installed into $TARGET

Post-install checklist:
  1. Set the repo secret CLAUDE_CODE_OAUTH_TOKEN (Settings -> Secrets and variables -> Actions).
     Mint one with: claude setup-token (interactive, requires a Claude Code subscription) --
     then store it with: gh secret set CLAUDE_CODE_OAUTH_TOKEN.
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
     it — it isn't installed automatically (see docs/CLI.md's gate.conf section).

Prefer zero repo footprint? Skip install.sh's gate files entirely and use the published
action instead — see examples/review-gate.yml and docs/SETUP.md's "Way C — published action."
EOF
