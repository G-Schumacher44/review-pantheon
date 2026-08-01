#!/usr/bin/env bash
# cli/lib/pantheon-git-readonly.sh — a strict, argv-validating read-only git wrapper.
#
# Why this exists: Claude Code's `--allowedTools` permission rule `Bash(git diff *)` matches on
# the LITERAL COMMAND-STRING PREFIX only — it has no understanding of git's own argument
# grammar, config, attributes, or environment. A prefix match on a command the MODEL chose to
# type is not a security boundary when prompt injection is exactly what's steering the model, or
# when a hostile PR's own tracked content (`.gitattributes`, committed config) can activate
# behavior the model never explicitly asked for. This script IS the boundary: the `readonly`
# execution tier grants Bash exactly one prefix — `Bash(<this script's installed path> *)`, no
# `Bash(git ...)` pattern at all — so every invocation passes through here first, and this
# wrapper validates the FULL argv AND neutralizes every git config/attribute/environment
# mechanism that could otherwise turn a "read-only" subcommand into command execution or a
# working-tree write, before ever calling the real `git` binary.
#
# ARGV VALIDATION (the CALLER's argv — the model's own typed command):
#   - subcommand (argv[1]) must be exactly one of: diff, show, log, status — the four names
#     DESIGN.md rule 1 tells personas to use. Anything else, including a `-c` or other
#     global-flag-shaped token in that position, is refused outright.
#   - every remaining argument must be a plain value (a ref, a path, a range like `base...head`)
#     or the bare `--` pathspec separator. NO flag of any kind is permitted — not a
#     per-subcommand allowlist of "safe-looking" flags, a flat refusal, because git's own flag
#     grammar is large, subcommand-context-dependent, and not this script's job to re-implement
#     correctly. An argument this wrapper doesn't recognize fails closed.
#   - `diff` additionally requires its first positional argument to contain `..` (a proper range
#     — `A..B` or `A...B`). See the EXEC/WRITE-SURFACE MATRIX's "clean/smudge filters" row for
#     why: this is a structural closure, not a blocklist entry.
#
# EXEC/WRITE-SURFACE MATRIX — every git config key, attribute, or environment variable that
# names an executable or a write target, checked against git's own documentation for whether an
# allowlisted subcommand (diff/show/log/status) can reach it with NO explicit model-supplied
# flag, and how each is neutralized. "Live-verified" means reproduced firing against the
# unpatched wrapper (or plain git) and confirmed silent post-fix; the corresponding fixture in
# tests/test-git-readonly-wrapper.sh carries the same live-firing negative control so the test
# itself can't rot into green-by-construction.
#
#   VECTOR                          REACHABLE FROM      NEUTRALIZED BY                  VERIFIED
#   ------------------------------  -------------------  ------------------------------  --------
#   diff.external / attribute-      diff, show           --no-ext-diff (wrapper-forced   live
#     scoped diff.<d>.command                              flag on diff/show)
#   diff.<driver>.textconv          diff, show            --no-textconv (same)            reasoning
#   filter.<name>.clean/smudge      diff (working-tree-   diff restricted to a proper     live
#     (gitattributes clean filter)   touching forms only)   range — see ARGV VALIDATION;
#                                                            blob-to-blob diffs never
#                                                            invoke the filter machinery.
#                                                            show/log/status confirmed
#                                                            NOT to trigger this at all.
#   core.fsmonitor (hook pathname)  status, diff, any    -c core.fsmonitor=false          live
#                                     working-tree scan
#   Optional index-lock write       status                GIT_OPTIONAL_LOCKS=0            live
#   core.pager / $PAGER             any (paginated out)  GIT_PAGER=cat, PAGER=cat,        reasoning
#                                                            -c core.pager=cat
#   core.editor / $EDITOR           none of the four     GIT_EDITOR=true,                 defense
#                                     normally invoke one   GIT_SEQUENCE_EDITOR=true,        in depth
#                                                            -c core.editor=true
#   log.showSignature + gpg.program log, show             -c log.showSignature=false       tested,
#                                                                                            not repro'd
#   GIT_TRACE and siblings           any                   unset (see full list below)     live
#     (trace-output-sink env vars)
#   core.hooksPath (standard hooks) none of the four      -c core.hooksPath=/dev/null      defense
#                                     invoke a tracked                                       in depth
#                                     hook under normal
#                                     behavior
#   gc.auto / maintenance.auto      tested: status does   -c gc.auto=0                     tested,
#     (auto-maintenance)              not trigger it         -c maintenance.auto=false       not repro'd
#   GIT_CONFIG / GIT_CONFIG_        env-based config       unset (closes the whole          reasoning
#     PARAMETERS / GIT_CONFIG_COUNT   injection, any          GIT_CONFIG_KEY_<n>/VALUE_<n>
#                                                              mechanism too — git never
#                                                              looks for the numbered vars
#                                                              when COUNT is unset)
#
# NOT REACHABLE — verified by reasoning, not by fixture (there is nothing to reproduce: these
# mechanisms have no path from repository content or model argv at all under the current
# allowlist):
#   - core.sshCommand, credential.helper, protocol.*.allow: all transport/remote-operation
#     mechanisms. None of diff/show/log/status contact a remote. Deliberately not on the
#     allowlist: fetch, pull, clone, push, ls-remote, or anything else that would make this
#     claim false. If a future change ever adds a networked subcommand, this needs re-auditing —
#     it is NOT self-maintaining.
#   - difftool.*/merge.tool: only reachable via the separate `git difftool`/`git mergetool`
#     subcommands, neither on the allowlist.
#   - Git aliases (`alias.<name> = !shell-command`, which can shadow diff/show/log/status
#     entirely): alias definitions live in `.git/config`, global `~/.gitconfig`, or system
#     config — none of which a PR's own tracked repository content can write to. Getting a
#     hostile alias defined at all requires the attacker to already have a SEPARATE, pre-existing
#     way to modify local or global git config (a compromised CI image, a devcontainer/setup
#     script a human or CI step actually executes) — at which point they already have code
#     execution some other way and this wrapper was never the boundary being crossed. This
#     wrapper trusts the git binary and config state of the machine it runs on, the same implicit
#     assumption as everywhere else in this file (e.g. GLOBAL_OVERRIDES below is only meaningful
#     if the `git` on $PATH is the real one).
#
# GLOBAL_OVERRIDES below are `-c key=value` pairs this wrapper writes and controls ITSELF —
# distinct from the CALLER's argv, where the validation loop rejects a `-c` (or any other flag)
# the model tries to supply. GLOBAL_OVERRIDES is applied AFTER that validation has already
# rejected anything the model tried to smuggle in; it is trusted precisely because nothing the
# model supplies can reach or alter it. A `-c key=value` must precede the subcommand in git's own
# argument grammar, which is exactly why the caller is never allowed to supply one.
#
# `-c diff.external=` (an empty value) was tested and REJECTED: git interprets an empty
# `diff.external` as "run a program named nothing," which errors out and breaks `diff` entirely
# rather than disabling it. `--no-ext-diff` already fully covers that config key on its own
# (verified: closes both the attribute-scoped AND the global `diff.external` activation paths),
# so no `-c` override for it is used.
#
# What this does NOT claim to fix: Claude Code's own Bash-permission matching for CHAINED shell
# commands (`cmd1 && cmd2`, `cmd1; cmd2`, `cmd1 | cmd2`, command substitution) is a property of
# the underlying `claude` CLI, not of this repo — it has been the subject of multiple upstream
# bug reports (anthropics/claude-code) about compound commands not being fully re-validated
# per-segment. This wrapper closes every git-side vector enumerated above; it is defense in depth
# on top of, not a replacement for, whatever chained-command protection the installed `claude`
# CLI itself provides. See DESIGN.md's "Security posture" for this same honesty applied to the
# tier as a whole. Also disclosed there: Claude Code itself treats a built-in, non-configurable
# set of Bash commands, including "read-only forms of git", as always-approved in EVERY
# permission mode — bare `git diff`/`show`/`log`/`status` with no flags can run without ever
# reaching this wrapper at all, on any tier. This wrapper's actual job is everything BEYOND that
# built-in-safe set: anything with a flag, anything config/attribute/environment-driven, and
# every other subcommand.
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

# `diff` must be given a proper range (contains `..`) — see the EXEC/WRITE-SURFACE MATRIX above,
# "clean/smudge filters" row. A bare `diff` or `diff <single-ref>` compares the WORKING TREE
# (not just repository objects) against the index or that ref, and git applies any configured
# `filter.<name>.clean` command to convert the dirty working-tree file before comparing —
# reproduced live. A proper range (`A..B` / `A...B`) never touches the working tree at all — git
# compares two repository objects directly — which is also the ONLY form DESIGN.md rule 1 and
# every generated run-context prompt ever tell an agent to use (`git diff <base>...<branch>`),
# so requiring one costs no legitimate capability.
if [[ "$subcommand" == "diff" ]]; then
  first_positional=""
  for arg in "$@"; do
    [[ "$arg" == "--" ]] && continue
    first_positional="$arg"
    break
  done
  [[ -n "$first_positional" && "$first_positional" == *..* ]] \
    || die "diff requires a range argument containing '..' or '...' (e.g. 'base...head') — a bare 'diff' or a single ref compares against the working tree, which this wrapper does not allow (working-tree comparisons can trigger a configured clean/smudge filter)"
fi

# Force a safe environment regardless of whatever the caller's shell already has set — see the
# EXEC/WRITE-SURFACE MATRIX above for what each closes.
export GIT_PAGER=cat
export PAGER=cat
export GIT_EDITOR=true
export GIT_SEQUENCE_EDITOR=true
export GIT_OPTIONAL_LOCKS=0
unset GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT 2>/dev/null || true

# Trace-output-sink environment variables (git-scm.com/docs/git's GIT_TRACE*/GIT_TRACE2*
# environment section, plus GIT_CURL_VERBOSE, the same class for curl's own verbose output): set
# to an absolute path, git APPENDS trace records there on every invocation, no flag or config
# needed — reproduced live (GIT_TRACE against a plain file, GIT_TRACE2_EVENT's directory-sink
# form). The general trace, every per-subsystem trace (fsmonitor, pack access, packet, packfile,
# performance, refs, setup, shallow, curl and its verbose sibling), and the Trace2 library's
# three sinks (human-readable, JSON event, perf).
unset GIT_TRACE GIT_TRACE_FSMONITOR GIT_TRACE_PACK_ACCESS GIT_TRACE_PACKET GIT_TRACE_PACKFILE \
      GIT_TRACE_PERFORMANCE GIT_TRACE_REFS GIT_TRACE_SETUP GIT_TRACE_SHALLOW GIT_TRACE_CURL \
      GIT_TRACE_CURL_NO_DATA GIT_CURL_VERBOSE GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF 2>/dev/null || true

# Global -c overrides — see the EXEC/WRITE-SURFACE MATRIX and the "GLOBAL_OVERRIDES" comment
# block above for what each closes and why these are trusted (wrapper-written, never
# caller-supplied). Applied to every subcommand, not scoped to any one: fsmonitor/hooksPath/
# pager/editor/signature-verification/maintenance are all properties of the repository scan or
# git's own startup, not of any one subcommand.
GLOBAL_OVERRIDES=(
  -c core.fsmonitor=false
  -c core.hooksPath=/dev/null
  -c core.pager=cat
  -c core.editor=true
  -c log.showSignature=false
  -c gc.auto=0
  -c maintenance.auto=false
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
