#!/usr/bin/env bash
# tests/test-execution-tier-python.sh — Python-native black-box equivalent of
# tests/test-execution-tier.sh's Slice-3-scoped portion, per docs/PYTHON-PORT.md §4's
# disposition for that suite: "Mixed... The black-box behavioral assertions (readonly default,
# trusted opt-in, fail-closed on an unrecognized tier before any gh call) translate directly...
# Slice 3 (execution module) / Slice 4 (full CLI wiring) exit bar."
#
# This file covers exactly the Slice-3 (module-level) slice of that disposition:
#   - Part A equivalent: pantheon.execution's allowed_tools_for/validate_execution/
#     execution_context_note, tested directly (the Python equivalent of sourcing
#     cli/lib/execution.sh's three functions — pantheon.execution IS the module under test, so
#     this imports it rather than shelling out, the same "test the unit directly" shape Part A of
#     the bash original uses).
#   - Part F equivalent: structural regression guards on pantheon/execution.py's own source,
#     mirroring the bash original's grep-based checks against cli/lib/pantheon-git-readonly.sh
#     (adapted to Python's shape — a dict-literal env key, not a bash `export`/`unset`
#     statement).
#
# Explicitly OUT OF SCOPE here (deferred to Slice 4, named so nothing is silently dropped — see
# docs/PYTHON-PORT.md §4's own table): Part B (cross-surface consistency across
# cli/providers/claude.sh, action.yml, action/review.yml — those stay bash until Slice 5), Part C
# (a real `pantheon gate --execution bogus-tier --pr 1` invocation — pantheon.cli doesn't exist
# until Slice 4), Part D (action/review.yml's base-pinned wrapper resolution — Action-lane,
# unrelated to this module), Part E (--permission-mode dontAsk on provider invocations — CLI-lane
# wiring, Slice 4), Part G (cli/review-gate's execution= base-pinning — CLI-lane wiring, Slice 4).
# tests/test-execution-tier.sh itself is UNCHANGED and still runs all of those, green, against
# bash — this file does not replace it, it covers the module-level subset Slice 3 owns.
#
# No test framework — plain bash, `bash tests/test-execution-tier-python.sh` is the whole
# invocation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
SRC_FILE="$ROOT/pantheon/execution.py"

PASS=0
FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $1 =="; }

if python3 -c "import pantheon.execution" >/dev/null 2>&1; then
  pass "pantheon.execution is importable"
else
  fail "pantheon.execution is NOT importable — cannot run any further checks"
  echo; echo "execution-tier-python fixtures: $PASS passed, $FAIL failed"; exit 1
fi

# pycall <python-expression> — evaluates a pantheon.execution expression and prints its result
# (str(...) of it) on stdout. Used to pull function return values into bash variables the same
# way the bash original captures a sourced function's stdout via command substitution.
pycall() {
  python3 -c "
import sys
sys.path.insert(0, '$ROOT')
from pantheon import execution
print($1, end='')
"
}

WRAPPER_PATH="/opt/review-pantheon/cli/lib/pantheon-git-readonly.sh"

# ---------------------------------------------------------------------------
# Part A — pantheon.execution.allowed_tools_for / validate_execution / execution_context_note
# ---------------------------------------------------------------------------
section "Part A: pantheon.execution.allowed_tools_for / validate_execution / execution_context_note"

readonly_tools="$(pycall "execution.allowed_tools_for('readonly', '$WRAPPER_PATH')")"
if [[ "$readonly_tools" == "Read,Grep,Glob,Bash($WRAPPER_PATH *)" ]]; then
  pass "allowed_tools_for readonly: routes Bash through the wrapper path, Read/Grep/Glob unrestricted"
else
  fail "allowed_tools_for readonly: unexpected value '$readonly_tools'"
fi

if [[ "$readonly_tools" != *"Bash(git diff"* && "$readonly_tools" != *"Bash(git show"* \
   && "$readonly_tools" != *"Bash(git log"* && "$readonly_tools" != *"Bash(git status"* ]]; then
  pass "allowed_tools_for readonly: does NOT contain the old bypassable 'Bash(git <subcommand> *)' prefix form"
else
  fail "allowed_tools_for readonly: regressed back to a bare 'Bash(git ...)' prefix pattern"
fi

trusted_tools="$(pycall "execution.allowed_tools_for('trusted', '$WRAPPER_PATH')")"
if [[ "$trusted_tools" == "Read,Grep,Glob,Bash" ]]; then
  pass "allowed_tools_for trusted: full Bash, ignores the wrapper path argument"
else
  fail "allowed_tools_for trusted: unexpected value '$trusted_tools'"
fi

fallback_tools="$(pycall "execution.allowed_tools_for('bogus-tier', '$WRAPPER_PATH')")"
if [[ "$fallback_tools" == "$readonly_tools" ]]; then
  pass "allowed_tools_for <unrecognized>: fails safe to the readonly value, not open"
else
  fail "allowed_tools_for <unrecognized>: did not fail safe to readonly (got '$fallback_tools')"
fi

for good in readonly trusted; do
  result="$(pycall "execution.validate_execution('$good')")"
  if [[ "$result" == "True" ]]; then
    pass "validate_execution accepts '$good'"
  else
    fail "validate_execution rejected '$good' (should accept)"
  fi
done

for bad in "" "bogus" "READONLY" "Trusted" "readonly " "read-only"; do
  result="$(pycall "execution.validate_execution('$bad')")"
  if [[ "$result" == "False" ]]; then
    pass "validate_execution rejects '$bad'"
  else
    fail "validate_execution accepted '$bad' (should reject)"
  fi
done

readonly_note="$(pycall "execution.execution_context_note('readonly', '$WRAPPER_PATH')")"
if [[ -n "$readonly_note" ]] && grep -qF "$WRAPPER_PATH" <<<"$readonly_note"; then
  pass "execution_context_note readonly: non-empty, names the wrapper path"
else
  fail "execution_context_note readonly: empty or missing the wrapper path"
fi

trusted_note="$(pycall "execution.execution_context_note('trusted', '$WRAPPER_PATH')")"
if [[ -z "$trusted_note" ]]; then
  pass "execution_context_note trusted: empty (no note needed — raw git is available)"
else
  fail "execution_context_note trusted: expected empty, got '$trusted_note'"
fi

# ---------------------------------------------------------------------------
# Part F equivalent — pantheon/execution.py structural regression guards (mirrors the bash
# original's Part F, adapted to Python's shape).
# ---------------------------------------------------------------------------
section "Part F: pantheon/execution.py hardening (structural)"

if grep -qF '"--no-ext-diff", "--no-textconv"' "$SRC_FILE"; then
  pass "pantheon/execution.py forces --no-ext-diff --no-textconv on diff/show"
else
  fail "pantheon/execution.py no longer forces --no-ext-diff --no-textconv — the configured-diff-driver bypass could regress"
fi

if grep -qF 'env["GIT_OPTIONAL_LOCKS"] = "0"' "$SRC_FILE"; then
  pass "pantheon/execution.py sets GIT_OPTIONAL_LOCKS=0"
else
  fail "pantheon/execution.py no longer sets GIT_OPTIONAL_LOCKS=0 — the status index-write regression could recur"
fi

if grep -qF '"core.fsmonitor=false"' "$SRC_FILE"; then
  pass "pantheon/execution.py forces -c core.fsmonitor=false"
else
  fail "pantheon/execution.py no longer forces -c core.fsmonitor=false — the configured-fsmonitor-hook bypass could regress"
fi

# Checks for a live CODE occurrence (a quoted string literal, e.g. `"diff.external="`), not the
# module docstring's own prose explaining why it was rejected (which uses backticks, not quotes).
if grep -qF '"diff.external=' "$SRC_FILE"; then
  fail "pantheon/execution.py sets a 'diff.external=' override — this was tested and found to break diff entirely in the bash original; --no-ext-diff alone covers this config key"
else
  pass "pantheon/execution.py does not carry a broken empty 'diff.external=' override"
fi

if grep -qF 'env["GIT_NO_LAZY_FETCH"] = "1"' "$SRC_FILE"; then
  pass "pantheon/execution.py forces GIT_NO_LAZY_FETCH=1"
else
  fail "pantheon/execution.py no longer forces GIT_NO_LAZY_FETCH=1 — the partial-clone lazy-fetch write regression could recur"
fi

# GIT_TRACE and siblings must never appear as an explicitly-set env key — _forced_env() builds a
# fresh dict, so absence (not a bash `unset`) IS the closure; this checks the negative.
if grep -qE 'env\["GIT_TRACE' "$SRC_FILE"; then
  fail "pantheon/execution.py explicitly sets a GIT_TRACE* env key — trace-output-sink write regression"
else
  pass "pantheon/execution.py never sets any GIT_TRACE* env key (neutralized by omission)"
fi

# Round 7 / issue #7 item 3: real revspec validation, not a substring-only check.
if grep -qF '"..." in first' "$SRC_FILE" && grep -qF '".." in first' "$SRC_FILE"; then
  pass "pantheon/execution.py's diff-range detection still requires a '..' or '...' substring before considering something a range"
else
  fail "pantheon/execution.py no longer detects a '..'/'...'-shaped range on diff"
fi

if grep -qF 'rev-parse", "--verify", "--quiet"' "$SRC_FILE"; then
  pass "pantheon/execution.py verifies both sides of a diff range with 'git rev-parse --verify --quiet' (real revspec validation)"
else
  fail "pantheon/execution.py no longer verifies diff-range sides via 'git rev-parse --verify --quiet'"
fi

# Round 8 / issue #7 Codex round 2: the caller can never supply '--' at all — every '-'-prefixed
# argument (including a bare '--') is refused by the SAME top-level check, with no special case
# carving '--' out as allowed.
if grep -qF 'arg.startswith("-")' "$SRC_FILE"; then
  pass "pantheon/execution.py's argv-validation loop refuses every '-'-prefixed argument (including a bare '--') for every subcommand, with no special case"
else
  fail "pantheon/execution.py's argv-validation loop no longer refuses '-'-prefixed arguments uniformly"
fi

if grep -qF 'len(args) != 1' "$SRC_FILE"; then
  pass "pantheon/execution.py caps diff at exactly one positional argument"
else
  fail "pantheon/execution.py no longer caps diff at exactly one argument"
fi

if grep -qF 'validated_range, "--"' "$SRC_FILE"; then
  pass "pantheon/execution.py's diff exec appends its OWN trailing '--' after the validated range"
else
  fail "pantheon/execution.py's diff exec no longer appends its own trailing '--' after the validated range"
fi

for gc_override in '"gc.auto=0"' '"maintenance.auto=false"'; do
  if grep -qF "$gc_override" "$SRC_FILE"; then
    pass "pantheon/execution.py forces -c $gc_override"
  else
    fail "pantheon/execution.py no longer forces -c $gc_override"
  fi
done

echo
echo "execution-tier-python fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
