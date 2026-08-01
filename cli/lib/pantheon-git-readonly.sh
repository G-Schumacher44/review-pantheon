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
#   - `diff` additionally requires its first positional argument to be a real revision range
#     (`A..B` or `A...B`) where BOTH `A` and `B` independently resolve via `git rev-parse --verify
#     --quiet <side>^{commit}` — containing the substring `..` is necessary but not sufficient. See
#     the EXEC/WRITE-SURFACE MATRIX's "clean/smudge filters" and "`..`-substring range spoofed by a
#     same-named path" rows for why: this is a structural closure (verify it is really a commit
#     range before git ever runs), not a blocklist/pattern-match entry — a tracked working-tree
#     path literally named `foo..bar` also contains `..` and must be REFUSED, not diffed.
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
#   `..`-substring range spoofed    diff                  each side resolved via          live
#     by a same-named path (e.g. a                           `git rev-parse --verify
#     tracked file literally named                           --quiet <side>^{commit}`
#     `foo..bar` — git's own                                 BEFORE diff runs — real
#     disambiguation falls back to                            revspec validation, not a
#     treating it as a pathspec)                              substring match; a side that
#                                                              fails to resolve is refused
#   core.fsmonitor (hook pathname)  status, diff, any    -c core.fsmonitor=false          live
#                                     working-tree scan
#   Optional index-lock write       status                GIT_OPTIONAL_LOCKS=0            live
#   Partial-clone lazy fetch of     diff, show, log (any  GIT_NO_LAZY_FETCH=1 (forced     live
#     missing promisor objects       object access in a     env) — the read fails closed
#     (a remote round-trip +        partial clone)          with no object written
#     `.git/objects` pack writes,
#     from an allowlisted READ)
#   core.pager / $PAGER             any (paginated out)  GIT_PAGER=cat, PAGER=cat,        reasoning
#                                                            -c core.pager=cat
#   core.editor / $EDITOR           none of the four     GIT_EDITOR=true,                 defense
#                                     normally invoke one   GIT_SEQUENCE_EDITOR=true,        in depth
#                                                            -c core.editor=true
#   log.showSignature + gpg.program log, show             -c log.showSignature=false       tested,
#                                                                                            not repro'd
#   GIT_TRACE and siblings           any                   unset (see full list below)     live
#     (trace-output-sink env vars)
#   GIT_REDIRECT_STDOUT /            any (Windows-only     unset (alongside the             structural
#     GIT_REDIRECT_STDERR (a Git      redirection sink)      GIT_TRACE* block below)           (Windows-
#     for Windows-only sink — same                                                             only; a
#     inherited-env class as                                                                   no-op on
#     GIT_TRACE*)                                                                               this
#                                                                                                platform's
#                                                                                                git per
#                                                                                                local repro)
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

# Force a safe environment regardless of whatever the caller's shell already has set — see the
# EXEC/WRITE-SURFACE MATRIX above for what each closes. Deliberately done BEFORE the diff-range
# validation below: that validation shells out to `git rev-parse` itself, and that sub-invocation
# needs the same hardened environment (GIT_OPTIONAL_LOCKS, GIT_NO_LAZY_FETCH, the trace-sink
# unsets, GLOBAL_OVERRIDES) as the final command — it is still a `git` invocation this wrapper is
# responsible for, not just a syntax check.
export GIT_PAGER=cat
export PAGER=cat
export GIT_EDITOR=true
export GIT_SEQUENCE_EDITOR=true
export GIT_OPTIONAL_LOCKS=0
# GIT_NO_LAZY_FETCH=1: in a partial clone with missing promisor objects (blob:none/tree:none),
# an allowlisted diff/show/log that touches a missing object silently contacts the configured
# remote and writes the fetched pack into `.git/objects` — a network round-trip AND a write, from
# a subcommand this wrapper's whole premise is "read-only, no transport." Reproduced live: a bare
# partial clone (blobs missing), `show HEAD:<path>` through the pre-fix wrapper fetched and wrote
# 4 new loose/pack objects; with GIT_NO_LAZY_FETCH=1 the same command instead fails closed
# ("fatal: Not a valid object name") with zero objects written. See git's own docs for
# GIT_NO_LAZY_FETCH.
export GIT_NO_LAZY_FETCH=1
unset GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT 2>/dev/null || true

# Trace-output-sink environment variables (git-scm.com/docs/git's GIT_TRACE*/GIT_TRACE2*
# environment section, plus GIT_CURL_VERBOSE, the same class for curl's own verbose output): set
# to an absolute path, git APPENDS trace records there on every invocation, no flag or config
# needed — reproduced live (GIT_TRACE against a plain file, GIT_TRACE2_EVENT's directory-sink
# form). The general trace, every per-subsystem trace (fsmonitor, pack access, packet, packfile,
# performance, refs, setup, shallow, curl and its verbose sibling), and the Trace2 library's
# three sinks (human-readable, JSON event, perf). Also unset here: GIT_REDIRECT_STDOUT and
# GIT_REDIRECT_STDERR — git's own docs describe these as a Git for Windows mechanism that
# redirects git.exe's own stdout/stderr handles to the named path; a no-op on this platform's git
# (confirmed by local repro — set and run, no file created), but inherited-environment-driven the
# exact same way as GIT_TRACE*, so scrubbed here rather than assumed absent on every platform this
# wrapper might run on.
unset GIT_TRACE GIT_TRACE_FSMONITOR GIT_TRACE_PACK_ACCESS GIT_TRACE_PACKET GIT_TRACE_PACKFILE \
      GIT_TRACE_PERFORMANCE GIT_TRACE_REFS GIT_TRACE_SETUP GIT_TRACE_SHALLOW GIT_TRACE_CURL \
      GIT_TRACE_CURL_NO_DATA GIT_CURL_VERBOSE GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF \
      GIT_REDIRECT_STDOUT GIT_REDIRECT_STDERR 2>/dev/null || true

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

# `diff` must be given a proper revision range — see the EXEC/WRITE-SURFACE MATRIX above, "clean/
# smudge filters" and "`..`-substring range spoofed by a same-named path" rows. A bare `diff` or
# `diff <single-ref>` compares the WORKING TREE (not just repository objects) against the index or
# that ref, and git applies any configured `filter.<name>.clean` command to convert the dirty
# working-tree file before comparing — reproduced live. A proper range (`A..B` / `A...B`) never
# touches the working tree at all — git compares two repository objects directly — which is also
# the ONLY form DESIGN.md rule 1 and every generated run-context prompt ever tell an agent to use
# (`git diff <base>...<branch>`), so requiring one costs no legitimate capability.
#
# Containing the substring `..` is necessary but not sufficient: a tracked working-tree path
# literally named `foo..bar` also contains it, and real git's own disambiguation rule — fall back
# to treating a token that doesn't resolve as a revision as a pathspec, when it names an existing
# path — is exactly what lets that path reopen the clean-filter path this range requirement exists
# to close (reproduced live: raw git treats `foo..bar` as the existing file, not a range, and the
# pre-fix wrapper's substring check let it straight through). So each side of the range is
# independently resolved to a REAL commit with `git rev-parse --verify --quiet <side>^{commit}`
# BEFORE diff ever runs, under the same hardened environment/GLOBAL_OVERRIDES as every other git
# invocation this wrapper makes. Either side failing that is a rejected pathspec/working-tree
# path, named in the error, not silently reinterpreted as one.
if [[ "$subcommand" == "diff" ]]; then
  first_positional=""
  for arg in "$@"; do
    [[ "$arg" == "--" ]] && continue
    first_positional="$arg"
    break
  done

  range_left=""
  range_right=""
  if [[ -n "$first_positional" && "$first_positional" == *"..."* ]]; then
    range_left="${first_positional%%...*}"
    range_right="${first_positional#*...}"
  elif [[ -n "$first_positional" && "$first_positional" == *".."* ]]; then
    range_left="${first_positional%%..*}"
    range_right="${first_positional#*..}"
  fi

  [[ -n "$range_left" && -n "$range_right" ]] \
    || die "diff requires a range argument containing '..' or '...' (e.g. 'base...head') — a bare 'diff', a single ref, or a bare path compares against the working tree, which this wrapper does not allow (working-tree comparisons can trigger a configured clean/smudge filter)"

  for side in "$range_left" "$range_right"; do
    # Belt-and-braces: a side beginning with '-' can never be a legal ref name (git itself
    # disallows it), so refuse it outright here rather than ever handing an attacker-controlled,
    # dash-prefixed string to `git rev-parse` as an argument — no-cost insurance against that
    # being reinterpreted as a flag, same posture as the gc.auto/log.showSignature overrides above.
    if [[ "$side" == -* ]]; then
      die "diff range argument '$first_positional' has a side ('$side') starting with '-' — not a legal ref name, refused before ever reaching git"
    fi
    git "${GLOBAL_OVERRIDES[@]}" rev-parse --verify --quiet "${side}^{commit}" >/dev/null 2>&1 \
      || die "diff range argument '$first_positional' does not resolve to two real commits ('$side' failed 'git rev-parse --verify --quiet') — this wrapper requires a genuine revision range, not a working-tree path or pathspec that merely contains '..'"
  done
fi

# --no-ext-diff/--no-textconv are diff-machinery flags: valid on diff/show (which is where a
# configured driver or textconv filter could otherwise fire), invalid on log/status (git itself
# rejects them there — "error: unknown option"), so this is scoped to exactly the two
# subcommands that can trigger diff output, appended after the subcommand and before whatever
# plain refs/paths/ranges the model supplied.
case "$subcommand" in
  diff | show) exec git "${GLOBAL_OVERRIDES[@]}" "$subcommand" --no-ext-diff --no-textconv "$@" ;;
  *) exec git "${GLOBAL_OVERRIDES[@]}" "$subcommand" "$@" ;;
esac
