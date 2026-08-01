#!/usr/bin/env bash
# cli/lib/execution.sh — tiered tool-execution policy for the CLI lane (readonly default,
# trusted opt-in). Sourced by cli/review-gate; cli/providers/claude.sh reads the computed value
# via the PANTHEON_ALLOWED_TOOLS env var review-gate exports, rather than sourcing this file
# itself, so a provider lane invoked directly (outside review-gate) still has a sane read-only
# default of its own — see that file's fallback.
#
# Why this exists (the HIGH-1 finding this closes): every agent runs via `claude -p ...
# --allowedTools <list>` against content that, on a fork PR, is 100% attacker-controlled. A
# blanket `Bash` tool set turns "prompt injection steers the model" into "prompt injection runs
# an arbitrary shell command" — the persona files already ask agents to stay read-only (see
# agents/*.md's "Read-only working-tree discipline"), but persona prose is exactly what
# injection defeats; it is not a mechanical control. This file is the mechanical backstop:
# `readonly` (the default everywhere this repo invokes a provider) restricts Bash to a read-only
# git allowlist so an agent literally cannot execute anything beyond inspecting the diff, no
# matter what a hostile diff/comment/PR-title tries to talk it into; `trusted` restores full
# Bash and is an explicit, documented opt-in for own-repo/trusted-author use only — never for
# reviewing a fork PR you don't control. See DESIGN.md's "Security posture" for the same
# rationale applied to the Action lanes (action.yml, action/review.yml), which compute the
# equivalent tool list inline in their own embedded shell (no cross-repo source path exists
# between this file and a workflow YAML's `run:` step).
#
# The `Bash(git diff *)` / `Bash(git show *)` / `Bash(git log *)` / `Bash(git status *)` syntax
# below is Claude Code's own permission-rule format (a tool name plus a parenthesized command
# prefix pattern, `*` as a trailing wildcard) — verified against Claude Code's own settings/
# permissions documentation and claude-code-action's own published example workflows (which use
# this exact space-before-asterisk form for a read-only review lane) before writing this,
# not assumed from the colon-form sometimes seen in other tools' docs.

# pantheon_allowed_tools_for <execution-tier> -> prints the --allowedTools value for that tier.
pantheon_allowed_tools_for() {
  local tier="$1"
  case "$tier" in
    trusted)
      printf 'Read,Grep,Glob,Bash'
      ;;
    *)
      # readonly is also the fallback for anything that isn't literally "trusted" — this
      # function is only ever called after pantheon_validate_execution has already rejected an
      # unrecognized value, so in practice this branch only ever sees "readonly"; the fallback
      # exists so a caller that skips validation still fails safe (read-only), not open.
      printf 'Read,Grep,Glob,Bash(git diff *),Bash(git show *),Bash(git log *),Bash(git status *)'
      ;;
  esac
}

# pantheon_validate_execution <value> -> 0 if "readonly" or "trusted", 1 otherwise.
pantheon_validate_execution() {
  case "$1" in
    readonly|trusted) return 0 ;;
    *) return 1 ;;
  esac
}
