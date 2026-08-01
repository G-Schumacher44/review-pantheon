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

if grep -qE '^\s*execution\) CFG_EXECUTION=' "$REVIEW_GATE"; then
  pass "cli/review-gate's gate.conf parser has an execution= case"
else
  fail "cli/review-gate's gate.conf parser is missing an execution= case"
fi

# shellcheck disable=SC2016 # literal text search, not variable expansion — see cli/review-gate
if grep -qF 'pantheon_validate_execution "$EXECUTION"' "$REVIEW_GATE"; then
  pass "cli/review-gate validates EXECUTION via pantheon_validate_execution before using it"
else
  fail "cli/review-gate does not call pantheon_validate_execution on EXECUTION"
fi

# Real invocation, from a scratch (non-review-pantheon) git repo: an invalid --execution value
# must die BEFORE any gh/network call — the die message must be the execution one, not a `gh`
# failure, and it must return fast (no hang waiting on network/auth).
SCRATCH="$(mktemp -d)"
git init -q "$SCRATCH"

bogus_out="$(cd "$SCRATCH" && "$REVIEW_GATE" --execution bogus-tier --pr 1 2>&1)"
bogus_status=$?
if [[ $bogus_status -ne 0 ]] && grep -qF "unknown execution tier 'bogus-tier'" <<<"$bogus_out"; then
  pass "review-gate --execution bogus-tier --pr 1: fails closed with the execution-tier error, before any gh call"
else
  fail "review-gate --execution bogus-tier --pr 1: did not fail closed as expected (status=$bogus_status, output: $bogus_out)"
fi

echo "execution=also-bogus" > "$SCRATCH/gate.conf"
gateconf_out="$(cd "$SCRATCH" && "$REVIEW_GATE" --pr 1 2>&1)"
gateconf_status=$?
rm -f "$SCRATCH/gate.conf"
if [[ $gateconf_status -ne 0 ]] && grep -qF "unknown execution tier 'also-bogus'" <<<"$gateconf_out"; then
  pass "gate.conf's execution=also-bogus: fails closed with the execution-tier error, before any gh call"
else
  fail "gate.conf's execution=also-bogus: did not fail closed as expected (status=$gateconf_status, output: $gateconf_out)"
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
# Part F — cli/lib/pantheon-git-readonly.sh: structural checks for the round-2 hardening
# (config/attributes-driven diff-driver bypass, index-write hygiene) that
# tests/test-git-readonly-wrapper.sh exercises live. This is the same file/behavior check
# pairing used throughout this repo (e.g. Part B above checks the same shape via grep that
# tests/test-git-readonly-wrapper.sh proves via live invocation).
# ---------------------------------------------------------------------------
section "Part F: cli/lib/pantheon-git-readonly.sh round-2 hardening (structural)"

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

echo
echo "execution-tier fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
