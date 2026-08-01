#!/usr/bin/env bash
# cli/lib/pantheon-git-readonly.sh — a strict, argv-validating read-only git wrapper.
#
# Why this exists (Codex P1 finding on this PR, cli/lib/execution.sh:42): Claude Code's
# `--allowedTools` permission rule `Bash(git diff *)` matches on the LITERAL COMMAND-STRING
# PREFIX only — it has no understanding of git's own argument grammar. That means the prior
# `readonly` tier's `Bash(git diff *)` / `Bash(git show *)` / `Bash(git log *)` /
# `Bash(git status *)` patterns also permitted anything appended after that prefix:
# `git diff --output=tracked-file` (git's own `--no-index -h` documents `--output <file>` as
# "output to a specific file"), `git diff --ext-diff` (spawns an arbitrary external helper),
# `git log --output=/tmp/x`, `git -c core.pager=...` — none of those are read-only in any
# meaningful sense, and a prefix-string match on a command the MODEL chose to type is not a
# security boundary when prompt injection is exactly the thing steering what the model types.
#
# This script IS the boundary. The `readonly` execution tier now grants Bash exactly one
# prefix — `Bash(<this-script's-installed-path> *)` — no `Bash(git ...)` pattern at all, so
# every invocation passes through here first, and this wrapper validates the FULL argv itself
# before ever calling the real `git` binary:
#   - the subcommand (argv[1]) must be exactly one of the four names DESIGN.md's rule 1 tells
#     personas to use: diff, show, log, status. Anything else — including a `-c` or other
#     global-flag-shaped token in that position, which would otherwise be interpreted as a
#     config override if it preceded a subcommand in ordinary git usage — is refused outright,
#     not guessed at.
#   - every remaining argument must be a plain value (a ref, a path, a range like
#     `base...head`) or the bare `--` pathspec separator. NO flag of any kind is permitted —
#     not a per-subcommand allowlist of "safe-looking" flags, a flat refusal, because git's own
#     flag grammar is large, subcommand-context-dependent, and not this script's job to
#     re-implement correctly. An argument this wrapper doesn't recognize fails closed.
#   - the environment is forced to something with no pager, no interactive editor, and no
#     external diff/merge substitution, regardless of what the invoking shell already has set —
#     defense in depth on top of the flag refusal above, not a substitute for it.
#
# What this does NOT claim to fix: Claude Code's own Bash-permission matching for CHAINED shell
# commands (`cmd1 && cmd2`, `cmd1; cmd2`, `cmd1 | cmd2`, command substitution) is a property of
# the underlying `claude` CLI, not of this repo — it has been the subject of multiple upstream
# bug reports (anthropics/claude-code) about compound commands not being fully re-validated
# per-segment. This wrapper closes the vector Codex named (writing/execution-capable flags
# smuggled inside an otherwise-permitted git subcommand) and the general class it belongs to
# (any git flag beyond a bare positional argument); it is defense in depth on top of, not a
# replacement for, whatever chained-command protection the installed `claude` CLI itself
# provides. See DESIGN.md's "Security posture" for this same honesty applied to the tier as a
# whole.
set -euo pipefail

die() {
  echo "pantheon-git-readonly: $*" >&2
  exit 1
}

[[ $# -ge 1 ]] || die "no subcommand given (expected one of: diff, show, log, status)"

subcommand="$1"
shift

case "$subcommand" in
  diff | show | log | status) ;;
  *) die "subcommand '$subcommand' is not on the read-only allowlist (diff, show, log, status)" ;;
esac

for arg in "$@"; do
  case "$arg" in
    --) ;; # the pathspec separator — inert on its own, no config/exec/output semantics
    -*) die "argument '$arg' is not permitted — this wrapper allows plain refs/paths/ranges only, no flags of any kind" ;;
    *) ;;
  esac
done

# Force a safe environment regardless of whatever the caller's shell already has set — a pager
# or editor can itself be an arbitrary external program (via $PAGER/$EDITOR or git's own
# core.pager/core.editor config), and external diff/merge substitution is exactly the
# execution-capable behavior the flag refusal above is meant to close off; this is the same
# closure applied to ambient environment instead of argv.
export GIT_PAGER=cat
export PAGER=cat
export GIT_EDITOR=true
export GIT_SEQUENCE_EDITOR=true
unset GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT 2>/dev/null || true

exec git "$subcommand" "$@"
