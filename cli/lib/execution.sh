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
# git wrapper so an agent literally cannot execute anything beyond inspecting the diff, no
# matter what a hostile diff/comment/PR-title tries to talk it into; `trusted` restores full
# Bash and is an explicit, documented opt-in for own-repo/trusted-author use only — never for
# reviewing a fork PR you don't control. See DESIGN.md's "Security posture" for the same
# rationale applied to the Action lanes (action.yml, action/review.yml), which compute the
# equivalent tool list inline in their own embedded shell (no cross-repo source path exists
# between this file and a workflow YAML's `run:` step) but reference the SAME wrapper script,
# cli/lib/pantheon-git-readonly.sh, at their own runtime's copy of it.
#
# Round 2 (Codex P1 finding on this PR's first push): the readonly tier originally used bare
# `Bash(git diff *)` / `Bash(git show *)` / `Bash(git log *)` / `Bash(git status *)` patterns —
# Claude Code's own permission-rule format (a tool name plus a parenthesized command-prefix
# pattern), verified against Claude Code's settings/permissions docs and claude-code-action's
# own example workflows before writing it. But a prefix-string match has no understanding of
# git's own argument grammar: `Bash(git diff *)` also permits `git diff --output=tracked-file`
# (git's own docs describe `--output <file>` as writing to a file) and `git diff --ext-diff`
# (spawns an arbitrary external program) — neither read-only in any meaningful sense, and a
# prefix match on a command the MODEL chose to type is not a boundary when prompt injection is
# exactly what's steering the model. Fixed by routing Bash through
# cli/lib/pantheon-git-readonly.sh instead: readonly now grants exactly one Bash prefix — that
# wrapper's own path — and the wrapper validates the full argv itself (subcommand must be
# diff/show/log/status, every remaining argument must be a plain value, no flags of any kind)
# before ever calling real git. See that script's own header comment for the full rationale,
# including what this does and does not claim to fix.

# pantheon_allowed_tools_for <execution-tier> <git-wrapper-path> -> prints the --allowedTools
# value for that tier. <git-wrapper-path> is ignored for "trusted" (full Bash needs no wrapper).
pantheon_allowed_tools_for() {
  local tier="$1" wrapper_path="${2:-}"
  case "$tier" in
    trusted)
      printf 'Read,Grep,Glob,Bash'
      ;;
    *)
      # readonly is also the fallback for anything that isn't literally "trusted" — this
      # function is only ever called after pantheon_validate_execution has already rejected an
      # unrecognized value, so in practice this branch only ever sees "readonly"; the fallback
      # exists so a caller that skips validation still fails safe (read-only), not open.
      printf 'Read,Grep,Glob,Bash(%s *)' "$wrapper_path"
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

# pantheon_execution_context_note <execution-tier> <git-wrapper-path> -> prints a run-context
# line (or nothing, for "trusted") telling the agent HOW to reach read-only git this run. The
# persona files (agents/*.md) give the generic, install-agnostic instruction — "use `git diff`,
# `git show`, `git log`, `git status`" — because they're the single canonical source shared by
# every lane and installer (DESIGN.md rule 4) and can't embed a path that differs per install.
# Under the readonly tier, raw `git` is no longer on the allowed tool list at all (only the
# wrapper's own path is), so every runtime's generated per-run context block calls this to tell
# the agent to substitute the wrapper for literal `git` — same instruction, worded identically,
# for every agent (not apollo-only: any of the five may want to inspect the diff/history).
pantheon_execution_context_note() {
  local tier="$1" wrapper_path="$2"
  case "$tier" in
    trusted) return 0 ;;
    *)
      cat <<EOF
- Execution: readonly — Bash is restricted to a read-only git wrapper this run, not raw \`git\`.
  Use \`$wrapper_path diff|show|log|status <plain refs/paths/ranges, no flags>\` in place of
  \`git diff|show|log|status\` (e.g. \`$wrapper_path diff <range>\`, \`$wrapper_path show <ref>:<path>\`)
  — the wrapper refuses any flag/option and any other subcommand, so this is the only Bash
  invocation available. No other command execution is possible this run.
EOF
      ;;
  esac
}
