#!/usr/bin/env bash
# tests/test-execution-tier.sh — fixture test for the tiered-execution feature itself
# (cli/lib/execution.sh's pantheon_allowed_tools_for / pantheon_validate_execution /
# pantheon_execution_context_note), and a cross-surface consistency check across every place
# that computes an --allowedTools value (cli/providers/claude.sh's fallback, action.yml,
# action/review.yml) plus cli/review-gate's own wiring. This is the gap the repo's own gate
# flagged on this PR's first push (a real Artemis finding, self-applied): every other
# security-relevant change in this PR shipped with a fixture (verdict multi-doc handling,
# fail-closed state persistence, the five-persona wording), but the execution-tier logic itself
# did not.
#
# The tests below were written AFTER the wrapper-based fix (Codex P1, round 2: a bare
# `Bash(git diff *)`-style prefix pattern can't tell a read-only git subcommand from the same
# subcommand carrying a writing/execution-capable flag) — so Part B's cross-surface check
# guards against regressing BACK to that bypassable shape, not just against drift between two
# equally-bypassable copies.
#
# No test framework — plain bash, `bash tests/test-execution-tier.sh` is the whole invocation
# (wired into .github/workflows/ci.yml and tests/test-setup-smoke.sh).
#
# shellcheck disable=SC2034 # Part G's run_exec_block() sets several vars read only by the
# sourced/extracted cli/review-gate block, which shellcheck can't see through.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/cli/lib/execution.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

section() { echo; echo "== $1 =="; }

# ---------------------------------------------------------------------------
# Part A — cli/lib/execution.sh's three functions, sourced directly.
# ---------------------------------------------------------------------------
section "Part A: pantheon_allowed_tools_for / pantheon_validate_execution / pantheon_execution_context_note"

WRAPPER_PATH="/opt/review-pantheon/cli/lib/pantheon-git-readonly.sh"

readonly_tools="$(pantheon_allowed_tools_for readonly "$WRAPPER_PATH")"
if [[ "$readonly_tools" == "Read,Grep,Glob,Bash($WRAPPER_PATH *)" ]]; then
  pass "pantheon_allowed_tools_for readonly: routes Bash through the wrapper path, Read/Grep/Glob unrestricted"
else
  fail "pantheon_allowed_tools_for readonly: unexpected value '$readonly_tools'"
fi

if [[ "$readonly_tools" != *"Bash(git diff"* && "$readonly_tools" != *"Bash(git show"* \
   && "$readonly_tools" != *"Bash(git log"* && "$readonly_tools" != *"Bash(git status"* ]]; then
  pass "pantheon_allowed_tools_for readonly: does NOT contain the old bypassable 'Bash(git <subcommand> *)' prefix form"
else
  fail "pantheon_allowed_tools_for readonly: regressed back to a bare 'Bash(git ...)' prefix pattern — reintroduces the Codex P1 finding (a prefix match can't tell a read-only subcommand from one carrying --output=/--ext-diff)"
fi

trusted_tools="$(pantheon_allowed_tools_for trusted "$WRAPPER_PATH")"
if [[ "$trusted_tools" == "Read,Grep,Glob,Bash" ]]; then
  pass "pantheon_allowed_tools_for trusted: full Bash, ignores the wrapper path argument"
else
  fail "pantheon_allowed_tools_for trusted: unexpected value '$trusted_tools'"
fi

fallback_tools="$(pantheon_allowed_tools_for bogus-tier "$WRAPPER_PATH")"
if [[ "$fallback_tools" == "$readonly_tools" ]]; then
  pass "pantheon_allowed_tools_for <unrecognized>: fails safe to the readonly value, not open"
else
  fail "pantheon_allowed_tools_for <unrecognized>: did not fail safe to readonly (got '$fallback_tools')"
fi

for good in readonly trusted; do
  if pantheon_validate_execution "$good"; then
    pass "pantheon_validate_execution accepts '$good'"
  else
    fail "pantheon_validate_execution rejected '$good' (should accept)"
  fi
done

for bad in "" "bogus" "READONLY" "Trusted" "readonly " "read-only"; do
  if ! pantheon_validate_execution "$bad"; then
    pass "pantheon_validate_execution rejects '$bad'"
  else
    fail "pantheon_validate_execution accepted '$bad' (should reject)"
  fi
done

readonly_note="$(pantheon_execution_context_note readonly "$WRAPPER_PATH")"
if [[ -n "$readonly_note" ]] && grep -qF "$WRAPPER_PATH" <<<"$readonly_note"; then
  pass "pantheon_execution_context_note readonly: non-empty, names the wrapper path"
else
  fail "pantheon_execution_context_note readonly: empty or missing the wrapper path"
fi

trusted_note="$(pantheon_execution_context_note trusted "$WRAPPER_PATH")"
if [[ -z "$trusted_note" ]]; then
  pass "pantheon_execution_context_note trusted: empty (no note needed — raw git is available)"
else
  fail "pantheon_execution_context_note trusted: expected empty, got '$trusted_note'"
fi

# ---------------------------------------------------------------------------
# Part B — cross-surface consistency: every place that computes an --allowedTools value must
# route readonly through the wrapper script, never a bare `Bash(git <subcommand> *)` prefix.
# ---------------------------------------------------------------------------
section "Part B: cross-surface consistency (cli/providers/claude.sh, action.yml, action/review.yml)"

BYPASSABLE_PATTERNS='Bash\(git (diff|show|log|status) \*\)'

# Every file checked here also DOCUMENTS the old bypassable pattern in a comment, as the
# rationale for why it was replaced (honest history, not a live code path) — e.g. cli/lib/
# execution.sh's own header comment says `Bash(git diff *)` by name while explaining the fix.
# Strip comment lines (anything from the first unescaped `#` to end of line — true for both
# bash's and YAML's comment syntax) before checking, so this test flags a REGRESSION back to the
# bypassable shape in actual code, not the prose that explains why it was removed.
strip_comments() {
  sed -E 's/(^|[^\\])#.*/\1/' "$1"
}

check_no_bypassable_pattern() {
  local label="$1" file="$2"
  if strip_comments "$file" | grep -qE "$BYPASSABLE_PATTERNS"; then
    fail "$label: contains a bare 'Bash(git <subcommand> *)' prefix pattern — the exact bypassable shape Codex flagged (a prefix match can't tell a read-only subcommand from one carrying --output=/--ext-diff)"
  else
    pass "$label: no bare 'Bash(git <subcommand> *)' prefix pattern found"
  fi
}

check_references_wrapper() {
  local label="$1" file="$2"
  if grep -qF "pantheon-git-readonly.sh" "$file" 2>/dev/null; then
    pass "$label: references pantheon-git-readonly.sh"
  else
    fail "$label: does NOT reference pantheon-git-readonly.sh — readonly tier has no mechanical enforcement on this surface"
  fi
}

for f in "$ROOT/cli/providers/claude.sh" "$ROOT/action.yml" "$ROOT/action/review.yml" "$ROOT/cli/lib/execution.sh" "$ROOT/install.sh" "$ROOT/bootstrap.sh"; do
  label="$(basename "$(dirname "$f")")/$(basename "$f")"
  check_no_bypassable_pattern "$label" "$f"
done

for f in "$ROOT/cli/providers/claude.sh" "$ROOT/action.yml" "$ROOT/action/review.yml" "$ROOT/cli/review-gate" "$ROOT/install.sh" "$ROOT/bootstrap.sh"; do
  label="$(basename "$(dirname "$f")")/$(basename "$f")"
  check_references_wrapper "$label" "$f"
done

# ---------------------------------------------------------------------------
# Part C — cli/review-gate: structural wiring + a real fail-closed invocation.
# ---------------------------------------------------------------------------
section "Part C: cli/review-gate wiring"

REVIEW_GATE="$ROOT/cli/review-gate"

# shellcheck disable=SC2016 # literal text search, not variable expansion — see cli/review-gate
if grep -qF 'source "$PANTHEON_ROOT/cli/lib/execution.sh"' "$REVIEW_GATE"; then
  pass "cli/review-gate sources cli/lib/execution.sh"
else
  fail "cli/review-gate does not source cli/lib/execution.sh"
fi

if grep -qE -- '--execution\)' "$REVIEW_GATE"; then
  pass "cli/review-gate's arg parser has an --execution case"
else
  fail "cli/review-gate's arg parser is missing an --execution case"
fi

# Regression guard: the EARLY (working-tree) gate.conf parser must NOT have an execution= case
# — that's the whole point of the base-pinning fix below (Part G). If this reappears, gate.conf's
# execution= is being read from the working tree again, reopening the PR-controlled-config gap.
if grep -qE '^\s*execution\) CFG_EXECUTION=' "$REVIEW_GATE"; then
  fail "cli/review-gate's EARLY (working-tree) gate.conf parser has an execution= case again — this reopens the base-pinning gap Part G's fixtures cover; execution= must only be read base-pinned (see the block Part G extracts)"
else
  pass "cli/review-gate's early (working-tree) gate.conf parser correctly does NOT read execution= (it's base-pinned instead — see Part G)"
fi

# shellcheck disable=SC2016 # literal text search, not variable expansion — see cli/review-gate
if grep -qF 'pantheon_validate_execution "$EXECUTION"' "$REVIEW_GATE"; then
  pass "cli/review-gate validates EXECUTION via pantheon_validate_execution before using it"
else
  fail "cli/review-gate does not call pantheon_validate_execution on EXECUTION"
fi

# Real invocation, from a scratch (non-review-pantheon) git repo: an invalid --EXPLICIT
# --execution flag must die BEFORE any gh/network call — it's operator-typed input, resolved in
# the early section (before PR-number validation), unlike gate.conf's execution= (base-pinned,
# so it necessarily can't be checked without a real PR to fetch — see Part G's fixtures for that
# half instead, which don't need network access).
SCRATCH="$(mktemp -d)"
git init -q "$SCRATCH"

bogus_out="$(cd "$SCRATCH" && "$REVIEW_GATE" --execution bogus-tier --pr 1 2>&1)"
bogus_status=$?
if [[ $bogus_status -ne 0 ]] && grep -qF "unknown execution tier 'bogus-tier'" <<<"$bogus_out"; then
  pass "review-gate --execution bogus-tier --pr 1: fails closed with the execution-tier error, before any gh call"
else
  fail "review-gate --execution bogus-tier --pr 1: did not fail closed as expected (status=$bogus_status, output: $bogus_out)"
fi

rm -rf "$SCRATCH"

# ---------------------------------------------------------------------------
# Part D — action/review.yml: the wrapper must be BASE-PINNED, never a path under
# $GITHUB_WORKSPACE (Codex P1, round 2). action/review.yml's Checkout step pulls the PR's OWN
# tree; a `Bash(<path under $GITHUB_WORKSPACE> *)` permission rule would let a PR simply REPLACE
# the wrapper script at that exact path with an arbitrary executable while the same rule still
# authorized running it. This section is a structural, regression-guard check (the same
# YAML-embedded-shell approach tests/test-prompt-assembly.sh's Parts C/D use) — it can't source
# and execute this workflow directly, so it isolates the relevant steps and asserts their shape.
# ---------------------------------------------------------------------------
section "Part D: action/review.yml's wrapper resolution is base-pinned, not working-tree-pinned"

REVIEW_YML="$ROOT/action/review.yml"

resolve_wrapper_step="$(awk '
  /- name: Resolve read-only git wrapper/ { grab=1 }
  grab && /- name:/ && !/Resolve read-only git wrapper/ { exit }
  grab { print }
' "$REVIEW_YML")"

if [[ -n "$resolve_wrapper_step" ]]; then
  pass "action/review.yml has a 'Resolve read-only git wrapper' step"
else
  fail "action/review.yml is missing a 'Resolve read-only git wrapper' step"
fi

# shellcheck disable=SC2016
if grep -q 'git show "\${BASE_SHA}:\.github/review-agents/pantheon-git-readonly\.sh"' <<<"$resolve_wrapper_step"; then
  pass "action/review.yml resolves the wrapper via 'git show \$BASE_SHA:path' (base-pinned)"
else
  fail "action/review.yml's wrapper-resolution step no longer reads the wrapper via base-pinned git show — check for a regression back to a working-tree path"
fi

# shellcheck disable=SC2016
if grep -qE '\$RUNNER_TEMP' <<<"$resolve_wrapper_step" && grep -q 'wrapper_path=' <<<"$resolve_wrapper_step"; then
  pass "action/review.yml writes the base-pinned wrapper content to \$RUNNER_TEMP and outputs its path"
else
  fail "action/review.yml's wrapper-resolution step no longer writes to \$RUNNER_TEMP with a wrapper_path output"
fi

full_review_yml="$(cat "$REVIEW_YML")"
# shellcheck disable=SC2016
if grep -qF 'Bash(${{ steps.resolve-git-wrapper.outputs.wrapper_path }} *)' <<<"$full_review_yml"; then
  pass "action/review.yml's claude_args points --allowedTools at the resolved (base-pinned) wrapper path"
else
  fail "action/review.yml's claude_args does not reference steps.resolve-git-wrapper.outputs.wrapper_path"
fi

# Regression guard: the OLD working-tree-pinned form must not reappear anywhere in this file.
if grep -qF 'github.workspace }}/.github/review-agents/pantheon-git-readonly.sh' "$REVIEW_YML" \
  || grep -qF 'GITHUB_WORKSPACE/.github/review-agents/pantheon-git-readonly.sh' "$REVIEW_YML"; then
  fail "action/review.yml still references the wrapper under \$GITHUB_WORKSPACE somewhere — a PR-controlled path, exactly the Codex P1 finding this fixed"
else
  pass "action/review.yml no longer references the wrapper under \$GITHUB_WORKSPACE anywhere"
fi

# The new "Validate PR base/head SHAs" step must run before both the wrapper-resolution step and
# the pre-existing docs-only-diff check (both use BASE_SHA in a shell command).
REVIEW_YML_VALIDATE_LINE="$(grep -n -- '- name: Validate PR base/head SHAs' "$REVIEW_YML" 2>/dev/null | head -1 | cut -d: -f1)"
REVIEW_YML_WRAPPER_LINE="$(grep -n -- '- name: Resolve read-only git wrapper' "$REVIEW_YML" 2>/dev/null | head -1 | cut -d: -f1)"
REVIEW_YML_DOCSCHECK_LINE="$(grep -n -- '- name: Detect docs-only diff' "$REVIEW_YML" 2>/dev/null | head -1 | cut -d: -f1)"
if [[ -n "$REVIEW_YML_VALIDATE_LINE" && -n "$REVIEW_YML_WRAPPER_LINE" && -n "$REVIEW_YML_DOCSCHECK_LINE" ]] \
     && [[ "$REVIEW_YML_VALIDATE_LINE" -lt "$REVIEW_YML_WRAPPER_LINE" ]] \
     && [[ "$REVIEW_YML_WRAPPER_LINE" -lt "$REVIEW_YML_DOCSCHECK_LINE" ]]; then
  pass "action/review.yml: SHA validation runs before wrapper resolution, which runs before the docs-only check"
else
  fail "action/review.yml: step ordering regressed (validate=$REVIEW_YML_VALIDATE_LINE wrapper=$REVIEW_YML_WRAPPER_LINE docs-check=$REVIEW_YML_DOCSCHECK_LINE)"
fi

# ---------------------------------------------------------------------------
# Part E — --permission-mode dontAsk on every provider invocation. A real Apollo finding on this
# PR's own self-review of action.yml: without an explicit permission mode, a tool call matching
# --allowedTools still hits a permission decision nothing can answer non-interactively, while
# Claude Code's own unconditional built-in "read-only forms of git" allowance keeps bare
# git log/diff working regardless — so raw git worked and the sanctioned wrapper didn't, the
# opposite of the intended restriction. `dontAsk` (documented as the mode for "locked-down CI
# and scripts") closes it: auto-denies anything not pre-approved, never waits for input.
# ---------------------------------------------------------------------------
section "Part E: --permission-mode dontAsk on every provider invocation"

if grep -qF -- '--permission-mode dontAsk' "$ROOT/cli/providers/claude.sh"; then
  pass "cli/providers/claude.sh passes --permission-mode dontAsk"
else
  fail "cli/providers/claude.sh does NOT pass --permission-mode dontAsk"
fi

if grep -qF -- '--permission-mode dontAsk' "$ROOT/action.yml"; then
  pass "action.yml's CLAUDE_ARGS includes --permission-mode dontAsk"
else
  fail "action.yml's CLAUDE_ARGS does NOT include --permission-mode dontAsk"
fi

if grep -qF -- '--permission-mode dontAsk' "$ROOT/action/review.yml"; then
  pass "action/review.yml's claude_args includes --permission-mode dontAsk"
else
  fail "action/review.yml's claude_args does NOT include --permission-mode dontAsk"
fi

# Regression guard: `default` mode must not silently return as the mode value on any of the
# three surfaces (it was the CLI lane's original, insufficiently-strict value).
if grep -qE -- '--permission-mode default' "$ROOT/cli/providers/claude.sh" "$ROOT/action.yml" "$ROOT/action/review.yml"; then
  fail "one of the three provider-invocation surfaces still passes --permission-mode default — regressed back to the insufficiently-strict mode"
else
  pass "none of the three provider-invocation surfaces pass --permission-mode default anymore"
fi

# ---------------------------------------------------------------------------
# Part F — cli/lib/pantheon-git-readonly.sh: structural checks for the round-2/round-3
# hardening (config/attributes-driven diff-driver bypass, index-write hygiene, configured
# fsmonitor-hook bypass) that tests/test-git-readonly-wrapper.sh exercises live. Same
# file/behavior check pairing used throughout this repo (e.g. Part B above checks the same
# shape via grep that tests/test-git-readonly-wrapper.sh proves via live invocation).
# ---------------------------------------------------------------------------
section "Part F: cli/lib/pantheon-git-readonly.sh round-2/round-3 hardening (structural)"

WRAPPER_SCRIPT="$ROOT/cli/lib/pantheon-git-readonly.sh"

if grep -qF -- '--no-ext-diff --no-textconv' "$WRAPPER_SCRIPT"; then
  pass "pantheon-git-readonly.sh forces --no-ext-diff --no-textconv on diff/show"
else
  fail "pantheon-git-readonly.sh no longer forces --no-ext-diff --no-textconv — the configured-diff-driver bypass could regress"
fi

if grep -qF 'GIT_OPTIONAL_LOCKS=0' "$WRAPPER_SCRIPT"; then
  pass "pantheon-git-readonly.sh sets GIT_OPTIONAL_LOCKS=0"
else
  fail "pantheon-git-readonly.sh no longer sets GIT_OPTIONAL_LOCKS=0 — the status index-write regression could recur"
fi

if grep -qF 'core.fsmonitor=false' "$WRAPPER_SCRIPT"; then
  pass "pantheon-git-readonly.sh forces -c core.fsmonitor=false"
else
  fail "pantheon-git-readonly.sh no longer forces -c core.fsmonitor=false — the configured-fsmonitor-hook bypass could regress"
fi

# Regression guard: an empty diff.external override was tested and rejected (breaks diff
# entirely — git tries to run a program named nothing) in favor of relying on --no-ext-diff,
# which was verified to already cover that config key. Guard against it reappearing as LIVE
# code — the wrapper's own header comment mentions the literal string while explaining why it
# was rejected, so this must check non-comment lines only (strip_comments, defined in Part B
# above), or it flags its own explanatory prose as a false positive.
if strip_comments "$WRAPPER_SCRIPT" | grep -qF 'diff.external='; then
  fail "pantheon-git-readonly.sh sets a 'diff.external=' override in live code — this was tested and found to break diff entirely (git tries to run a program named nothing); --no-ext-diff alone covers this config key"
else
  pass "pantheon-git-readonly.sh does not carry the broken empty 'diff.external=' override in live code"
fi

for trace_var in GIT_TRACE GIT_TRACE2 GIT_TRACE2_EVENT GIT_TRACE2_PERF GIT_CURL_VERBOSE; do
  if strip_comments "$WRAPPER_SCRIPT" | grep -qF "unset" && strip_comments "$WRAPPER_SCRIPT" | grep -qF "$trace_var"; then
    pass "pantheon-git-readonly.sh unsets $trace_var"
  else
    fail "pantheon-git-readonly.sh no longer unsets $trace_var — the trace-output-sink write regression could recur"
  fi
done

# Round 6 (Codex P1): diff must require a proper range — a bare diff or a single-ref diff
# touches the working tree and can trigger a configured clean/smudge filter. Round 7 / issue #7
# item 3 (Codex P1 on PR #5) replaced the original substring-only check ('"$first_positional" ==
# *..*', which a tracked path literally named 'foo..bar' also satisfies) with real revspec
# validation: each side of the range must independently resolve via 'git rev-parse --verify
# --quiet <side>^{commit}' before diff ever runs. Guard against EITHER regressing — the substring
# requirement disappearing entirely (no range check at all) AND the rev-parse verification being
# removed in favor of going back to a bare substring match.
if strip_comments "$WRAPPER_SCRIPT" | grep -qF '*"..."*' && strip_comments "$WRAPPER_SCRIPT" | grep -qF '*".."*'; then
  pass "pantheon-git-readonly.sh's diff-range detection still requires a '..' or '...' substring before considering something a range"
else
  fail "pantheon-git-readonly.sh no longer detects a '..'/'...'-shaped range on diff — the clean-filter bypass via a bare/single-ref diff could regress"
fi

# shellcheck disable=SC2016
if strip_comments "$WRAPPER_SCRIPT" | grep -qF 'rev-parse --verify --quiet "${side}^{commit}"'; then
  pass "pantheon-git-readonly.sh verifies both sides of a diff range with 'git rev-parse --verify --quiet <side>^{commit}' (real revspec validation, not a substring-only check)"
else
  fail "pantheon-git-readonly.sh no longer verifies diff-range sides via 'git rev-parse --verify --quiet' — the '..'-substring-spoofed-by-a-same-named-path bypass (issue #7 item 3) could regress"
fi

# Round 8 / issue #7 Codex round 2: revspec verification alone is not sufficient — a validated
# range re-forwarded to real git alongside a caller-supplied '--' gets parsed as a PATHSPEC, not a
# revision, even though both sides independently resolve as real commits. Closed two ways: the
# caller can never supply '--' at all (the top-level argv-validation loop no longer special-cases
# it), and diff accepts EXACTLY one positional argument, so there is no pathspec slot for a
# caller-supplied '--' (or an implicit trailing pathspec without one) to ever occupy.
if strip_comments "$WRAPPER_SCRIPT" | grep -qE '^\s*--\)\s*;;'; then
  fail "pantheon-git-readonly.sh's argv-validation loop still special-cases a bare '--' as an allowed argument — the caller-supplied-'--' pathspec-position bypass (issue #7 Codex round 2) could regress"
else
  pass "pantheon-git-readonly.sh's argv-validation loop no longer special-cases a caller-supplied '--' as allowed (it is refused like any other '-'-prefixed argument, for every subcommand)"
fi

# NOTE: grepping the RAW file here, not strip_comments' output — strip_comments' naive '#'-starts-
# a-comment regex mistreats bash's own '$#' (argument-count) syntax as a comment start and mangles
# the rest of the line, which would false-negative this check. '[[ $# -eq 1 ]]' only appears in
# this file as the actual diff-arg-count guard (a comment above it references the same fragment
# without the surrounding '[[ ]]', so this exact substring is unambiguous).
# shellcheck disable=SC2016
if grep -qF '[[ $# -eq 1 ]]' "$WRAPPER_SCRIPT" && strip_comments "$WRAPPER_SCRIPT" | grep -q 'subcommand" == "diff"'; then
  pass "pantheon-git-readonly.sh caps diff at exactly one positional argument (no pathspec slot even without a caller-supplied '--')"
else
  fail "pantheon-git-readonly.sh no longer caps diff at exactly one argument — a second positional (pathspec) argument could regress"
fi

# shellcheck disable=SC2016
if strip_comments "$WRAPPER_SCRIPT" | grep -qF '"$first_positional" -- ;;'; then
  pass "pantheon-git-readonly.sh's diff exec appends its OWN trailing '--' after the validated range (never a caller-influenced one)"
else
  fail "pantheon-git-readonly.sh's diff exec no longer appends its own trailing '--' after the validated range"
fi

for gc_override in "gc.auto=0" "maintenance.auto=false"; do
  if strip_comments "$WRAPPER_SCRIPT" | grep -qF "$gc_override"; then
    pass "pantheon-git-readonly.sh forces -c $gc_override"
  else
    fail "pantheon-git-readonly.sh no longer forces -c $gc_override"
  fi
done

# ---------------------------------------------------------------------------
# Part G — cli/review-gate's execution= must be base-pinned, not working-tree-pinned (Codex P1,
# round 6). review-gate never checks out the PR branch itself, but a maintainer who first runs
# `gh pr checkout <n>` (a common local-review habit) before invoking review-gate would have the
# PR's own head content checked out, including a hostile gate.conf shipping `execution=trusted`.
# This extracts the real base-pinned-execution block verbatim from cli/review-gate (never
# hand-copied — the same pattern tests/test-prompt-assembly.sh's Part B uses for build_prompt())
# and exercises it against real git fixture repos.
# ---------------------------------------------------------------------------
section "Part G: cli/review-gate's execution= is base-pinned, not working-tree-pinned"

EXEC_BLOCK_FILE="$(mktemp)"
# shellcheck disable=SC2016
awk '
  /^if \[\[ -z "\$EXECUTION" \]\]; then$/ { grab=1 }
  grab { print }
  grab && /^fi$/ { exit }
' "$REVIEW_GATE" > "$EXEC_BLOCK_FILE"

# shellcheck disable=SC2016
if [[ -s "$EXEC_BLOCK_FILE" ]] && grep -qF 'if [[ -z "$EXECUTION" ]]; then' "$EXEC_BLOCK_FILE"; then
  pass "extracted the base-pinned execution= block verbatim from cli/review-gate"
else
  fail "could not extract the base-pinned execution= block from cli/review-gate — its shape changed; update the extractor"
fi

# `exit 1`, not `return 1`: the real cli/review-gate's die() calls `exit`, which — critically —
# terminates the whole process on a real invocation. `return` would only return from die() itself
# and let the extracted block's script keep running past the failed validation (masking exactly
# the fail-closed behavior G5 below exists to prove), since run_exec_block's subshell has no
# `set -e` of its own to stop at a nonzero-status statement either. Because this runs inside a
# `( ... )` subshell (run_exec_block), `exit` here only terminates that subshell, never this test
# script itself.
die() { echo "test-stub die: $*" >&2; exit 1; }

git_fixture_repo_exec() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture commit"
  git -C "$dir" rev-parse HEAD
}

# run_exec_block <repo-root> <base-sha> [preset-execution]
#
# The extracted block only runs its base-pinned gate.conf read when $EXECUTION is still empty —
# that's the real script's own guard for "no --execution flag was given" (the flag is resolved
# in an EARLIER, unextracted section). [preset-execution] simulates what that earlier section
# would already have set EXECUTION to; leave it empty to exercise the base-pinned read itself
# (the normal case), or pass a value (e.g. "readonly") to prove the late block correctly leaves
# an already-resolved EXECUTION untouched instead of overwriting it from gate.conf.
#
# PANTHEON_GIT_WRAPPER and PANTHEON_ROOT must be set before sourcing — the extracted block
# references both, and this harness's `set -uo pipefail` (inherited by the subshell below) turns
# any unset-variable reference into an immediate, silent-looking subshell exit — no output at
# all, not even a visible error — which is exactly what happened here before this fix (every
# G1-G4 result came back empty, not "wrong").
run_exec_block() {
  (
    REPO_ROOT="$1"
    BASE_SHA="$2"
    EXECUTION="${3:-}"
    PANTHEON_ROOT="$ROOT"
    PANTHEON_GIT_WRAPPER="$ROOT/cli/lib/pantheon-git-readonly.sh"
    # shellcheck disable=SC1090
    source "$EXEC_BLOCK_FILE" >/dev/null 2>&1
    echo "$EXECUTION"
  )
}

# G1 — the exact Codex scenario: base has execution=readonly committed; a fork PR's head EDITS
# gate.conf to execution=trusted (leaving the working tree checked out at the edited version,
# simulating `gh pr checkout` before running review-gate). The base-pinned read must see
# 'readonly', never the working tree's 'trusted'.
FIXTURE_G1="$(mktemp -d)"
echo "execution=readonly" > "$FIXTURE_G1/gate.conf"
FIXTURE_G1_BASE_SHA="$(git_fixture_repo_exec "$FIXTURE_G1")"
echo "execution=trusted" > "$FIXTURE_G1/gate.conf"
git -C "$FIXTURE_G1" commit -q -am "fork PR edits gate.conf to execution=trusted"

G1_RESULT="$(run_exec_block "$FIXTURE_G1" "$FIXTURE_G1_BASE_SHA")"
if [[ "$G1_RESULT" == "readonly" ]]; then
  pass "base has execution=readonly, PR-edited working tree has execution=trusted -> base-pinned value (readonly) wins"
else
  fail "base-pinning regression: expected 'readonly' (the base commit's value), got '$G1_RESULT' — the working-tree-edited value leaked through"
fi

# G2 — a fork PR INTRODUCES gate.conf for the first time (absent at base entirely) with
# execution=trusted. Must fall back to readonly, never read the PR-introduced file.
FIXTURE_G2="$(mktemp -d)"
echo "unrelated" > "$FIXTURE_G2/README.md"
FIXTURE_G2_BASE_SHA="$(git_fixture_repo_exec "$FIXTURE_G2")"
echo "execution=trusted" > "$FIXTURE_G2/gate.conf"
git -C "$FIXTURE_G2" add gate.conf
git -C "$FIXTURE_G2" commit -q -m "fork PR introduces gate.conf with execution=trusted"

G2_RESULT="$(run_exec_block "$FIXTURE_G2" "$FIXTURE_G2_BASE_SHA")"
if [[ "$G2_RESULT" == "readonly" ]]; then
  pass "gate.conf absent at base, PR introduces execution=trusted -> falls back to readonly, PR-introduced file never read"
else
  fail "base-pinning regression: expected 'readonly' (gate.conf absent at base), got '$G2_RESULT'"
fi

# G3 — a LEGITIMATE, already-merged gate.conf at base with execution=trusted (an own-repo
# maintainer's own deliberate choice, committed to the base branch itself) must still be
# honored — base-pinning isn't "always readonly," it's "trust the base commit, not the PR's own
# edits."
FIXTURE_G3="$(mktemp -d)"
echo "execution=trusted" > "$FIXTURE_G3/gate.conf"
FIXTURE_G3_BASE_SHA="$(git_fixture_repo_exec "$FIXTURE_G3")"

G3_RESULT="$(run_exec_block "$FIXTURE_G3" "$FIXTURE_G3_BASE_SHA")"
if [[ "$G3_RESULT" == "trusted" ]]; then
  pass "execution=trusted legitimately committed AT BASE (not PR-introduced) -> honored"
else
  fail "expected 'trusted' (a legitimately base-committed value), got '$G3_RESULT' — base-pinning should trust the base commit's own content"
fi

# G4 — the --execution CLI flag (OPT_EXECUTION) is an explicit operator action, not
# PR-controlled configuration, so it must win over whatever the base-pinned gate.conf says.
G4_RESULT="$(run_exec_block "$FIXTURE_G3" "$FIXTURE_G3_BASE_SHA" "readonly")"
if [[ "$G4_RESULT" == "readonly" ]]; then
  pass "--execution readonly (operator-explicit) overrides base-pinned gate.conf's execution=trusted"
else
  fail "expected 'readonly' (the explicit --execution flag), got '$G4_RESULT' — CLI flag should win over gate.conf"
fi

# G5 — an invalid execution= value AT BASE must still fail closed (this doesn't need network/a
# real PR to test, unlike the live-invocation fixture in Part C — that's exactly why this exists
# here instead). die() is stubbed above to `return 1` rather than exit, so run_exec_block's
# subshell exits nonzero at that point and produces no "echo $EXECUTION" output at all.
FIXTURE_G5="$(mktemp -d)"
echo "execution=bogus-at-base" > "$FIXTURE_G5/gate.conf"
FIXTURE_G5_BASE_SHA="$(git_fixture_repo_exec "$FIXTURE_G5")"

G5_STATUS=0
G5_RESULT="$(run_exec_block "$FIXTURE_G5" "$FIXTURE_G5_BASE_SHA")" || G5_STATUS=$?
if [[ $G5_STATUS -ne 0 && -z "$G5_RESULT" ]]; then
  pass "execution=bogus-at-base fails closed (nonzero exit, no EXECUTION value produced) — not silently coerced to a default"
else
  fail "execution=bogus-at-base did NOT fail closed (status=$G5_STATUS, result='$G5_RESULT')"
fi

rm -rf "$FIXTURE_G1" "$FIXTURE_G2" "$FIXTURE_G3" "$FIXTURE_G5"
rm -f "$EXEC_BLOCK_FILE"

echo
echo "execution-tier fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
