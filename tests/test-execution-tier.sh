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

echo
echo "execution-tier fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
