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
# whole. Also disclosed there: Claude Code itself treats a built-in set of Bash commands,
# including "read-only forms of git", as always-approved in every permission mode — bare
# `git diff`/`show`/`log`/`status` can run without ever reaching this wrapper at all. This
# wrapper's job is everything BEYOND that built-in set: anything with a flag, and every other
# subcommand.
#
# Round 2 (Codex P1, fresh evidence after the flag-refusal fix above): rejecting `--ext-diff` as
# an explicit argument doesn't stop a CONFIGURED external diff driver from firing on a plain,
# validation-passing `diff`/`show` — a `.gitattributes` entry (`*.foo diff=evil`) plus a
# `diff.evil.command=...` config entry activates the driver without the model ever typing
# `--ext-diff`, and unsetting `$GIT_EXTERNAL_DIFF` (already done below) doesn't touch
# attributes/config-driven activation. Reproduced live by Codex against the pre-fix wrapper.
# Fixed by forcing `--no-ext-diff --no-textconv` onto every `diff`/`show` invocation this
# wrapper makes — not accepted from the model's argv (still rejected as a flag, same as any
# other), injected by the wrapper itself, so no config or attributes state the target repo (or
# environment) happens to carry can re-enable an external helper or content filter. Verified
# `--no-ext-diff` alone also covers the REPO-WIDE `diff.external` config key, not just an
# attribute-scoped driver — one flag, both activation paths.
#
# Round 3 (Codex P1, fresh evidence again): a pathname-valued `core.fsmonitor` — git's own docs
# define that as the path to an external "fsmonitor hook" command — ran on a validation-passing
# `status`, AND on plain `diff` too (git queries the fsmonitor hook to speed up its working-tree
# scan regardless of which read command triggered the scan), with `GIT_OPTIONAL_LOCKS=0` doing
# nothing to stop it (a different mechanism entirely). Reproduced live by Codex, then reproduced
# again here against a real marker-writing helper before landing the fix, on both `status` and
# `diff`. Fixed by forcing `-c core.fsmonitor=false` as a GLOBAL override (a `-c key=value` must
# precede the subcommand in git's own argument grammar, which is exactly why the flag-refusal
# loop below rejects the model ever supplying one) — applied to every subcommand, not just
# status/diff, since the hook is a property of the repository scan, not of any one subcommand.
# `-c core.hooksPath=/dev/null` and `-c core.pager=cat`/`-c core.editor=true` ride along as the
# same class of defense in depth, redundant with the env vars below by design (config-file state
# and environment state are two different override surfaces; forcing both closes either being
# bypassed independently). `-c diff.external=` (an empty value, attempted here first) was
# REJECTED after testing: git interprets an empty `diff.external` as "run a program named
# nothing," which errors out and breaks `diff` entirely rather than disabling it — `--no-ext-diff`
# already fully covers that config key on its own (verified above), so no `-c` override for it
# is needed.
#
# IMPORTANT distinction, since it's easy to misread the flag-refusal loop below as contradicting
# GLOBAL_OVERRIDES: the loop rejects a `-c` (or any other flag) supplied by the CALLER's argv —
# the model never gets to inject one. GLOBAL_OVERRIDES is a config list this wrapper writes and
# controls itself, applied AFTER argv validation has already rejected anything the model tried to
# smuggle in; it is trusted precisely because nothing the model supplies can reach it or alter it.
#
# Round 4 sweep — every git config key that names an executable, reachable from an allowlisted
# subcommand's default behavior with NO explicit flag, checked against git's own config docs:
#   - diff.external / diff.<driver>.command (attribute or global) -> closed by --no-ext-diff
#   - diff.<driver>.textconv                                      -> closed by --no-textconv
#   - core.fsmonitor                                              -> closed by -c core.fsmonitor=false
#   - core.pager                                                  -> closed by GIT_PAGER env + -c core.pager=cat
#   - core.editor                                                 -> closed by GIT_EDITOR env + -c core.editor=true
#   - log.showSignature + gpg.program: tested live (log.showsignature=true + a marker-writing
#     gpg.program, against `log`/`show` with no explicit --show-signature flag) — did NOT fire on
#     this wrapper's target git version; forced `-c log.showSignature=false` anyway as no-cost
#     insurance against a git version or config combination where it might.
#   - core.sshCommand, credential.helper, protocol.*.allow: all transport/remote-operation
#     mechanisms — NOT reachable from this wrapper, because none of the four allowlisted
#     subcommands (diff, show, log, status) contact a remote. Deliberately not on the allowlist:
#     fetch, pull, clone, push, ls-remote, and anything else that would make this reachability
#     claim false. If a future change ever adds a networked subcommand to the allowlist, this
#     reasoning needs re-auditing — it is NOT self-maintaining.
#   - difftool.*/merge.tool: only reachable via the separate `git difftool`/`git mergetool`
#     subcommands, neither on the allowlist.
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
# closure applied to ambient environment instead of argv. GIT_OPTIONAL_LOCKS=0 (a Codex P2
# finding: `status` performs an optional index refresh that writes `.git/index`, contradicting
# this tier's "never mutates the index" claim and able to race a concurrent repo operation on a
# shared runner) disables every optional-lock operation git would otherwise perform, not status
# alone.
export GIT_PAGER=cat
export PAGER=cat
export GIT_EDITOR=true
export GIT_SEQUENCE_EDITOR=true
export GIT_OPTIONAL_LOCKS=0
unset GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT 2>/dev/null || true

# Round 5 (Codex P2): git's own docs define GIT_TRACE and its siblings as trace-output sinks —
# set to an absolute path, git APPENDS trace records to that file on every invocation, no flag
# or config needed at all, just an inherited environment variable. Reproduced live here before
# fixing: GIT_TRACE=<path to a tracked file> pantheon-git-readonly.sh status grew that file and
# left the working tree dirty — a write, contradicting the readonly tier's no-mutation claim,
# and reachable purely from ambient environment (a debugging-enabled CI runner, a shell that
# happened to have one of these set) rather than anything the model or a hostile PR controls
# directly. Also reproduced GIT_TRACE2_EVENT's directory-sink form (git docs: a directory value
# creates a per-process file inside it) creating a real file pre-fix, and confirmed it creates
# none post-fix. Unset every documented trace-output-sink variable (git-scm.com/docs/git — the
# GIT_TRACE* / GIT_TRACE2* environment section, plus GIT_CURL_VERBOSE, the same class for curl's
# own verbose/trace output): the general trace, the per-subsystem traces (fsmonitor, pack
# access, packet, packfile, performance, refs, setup, shallow, curl and its verbose sibling),
# and the Trace2 library's three sinks (human-readable, JSON event, perf).
unset GIT_TRACE GIT_TRACE_FSMONITOR GIT_TRACE_PACK_ACCESS GIT_TRACE_PACKET GIT_TRACE_PACKFILE \
      GIT_TRACE_PERFORMANCE GIT_TRACE_REFS GIT_TRACE_SETUP GIT_TRACE_SHALLOW GIT_TRACE_CURL \
      GIT_TRACE_CURL_NO_DATA GIT_CURL_VERBOSE GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF 2>/dev/null || true

# Global -c overrides — must precede the subcommand in git's own argument grammar (the reason
# the flag-refusal loop above rejects the model ever supplying its own `-c`). Applied to every
# subcommand: the fsmonitor hook is a property of git's working-tree scan, not of any one
# subcommand, so this isn't scoped to status/diff the way --no-ext-diff/--no-textconv are.
GLOBAL_OVERRIDES=(
  -c core.fsmonitor=false
  -c core.hooksPath=/dev/null
  -c core.pager=cat
  -c core.editor=true
  -c log.showSignature=false
)

# --no-ext-diff/--no-textconv are diff-machinery flags: valid on diff/show (which is where a
# configured driver or textconv filter could otherwise fire), invalid on log/status (git itself
# rejects them there — "error: unknown option"), so this is scoped to exactly the two
# subcommands that can trigger diff output, appended after the subcommand and before whatever
# plain refs/paths/ranges the model supplied.
case "$subcommand" in
  diff | show) exec git "${GLOBAL_OVERRIDES[@]}" "$subcommand" --no-ext-diff --no-textconv "$@" ;;
  *) exec git "${GLOBAL_OVERRIDES[@]}" "$subcommand" "$@" ;;
esac
