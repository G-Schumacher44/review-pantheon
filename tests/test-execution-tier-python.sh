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
# Slice 4 ADDS (below Part F): Part C equivalent (a real `pantheon gate --execution bogus-tier
# --pr 1` invocation, now that pantheon.cli exists), Part E equivalent (--permission-mode dontAsk
# in pantheon/providers.py's claude lane), and Part G equivalent (pantheon.cli's execution=
# base-pinning, via real git fixture repos rather than an extracted bash block). Still explicitly
# OUT OF SCOPE (bash/Action-lane surfaces this port doesn't touch, per docs/PYTHON-PORT.md §4):
# Part B (cross-surface consistency across cli/providers/claude.sh, action.yml,
# action/review.yml — those stay bash until Slice 5) and Part D (action/review.yml's base-pinned
# wrapper resolution — Action-lane, unrelated to this module). tests/test-execution-tier.sh
# itself is UNCHANGED and still runs its own Parts A-G, green, against bash — this file does not
# replace it.
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

# ---------------------------------------------------------------------------
# Part C equivalent (Slice 4) — pantheon.cli wiring: a real, fail-closed invocation from a
# scratch (non-review-pantheon) git repo, before any gh/network call — mirrors the bash
# original's Part C real-invocation fixture exactly.
# ---------------------------------------------------------------------------
section "Part C equivalent: pantheon gate --execution bogus-tier --pr 1 (real invocation)"

if python3 -c "import pantheon.cli" >/dev/null 2>&1; then
  SCRATCH="$(mktemp -d)"
  git init -q "$SCRATCH"

  bogus_out="$(cd "$SCRATCH" && python3 -m pantheon.cli gate --execution bogus-tier --pr 1 2>&1)"
  bogus_status=$?
  if [[ $bogus_status -ne 0 ]] && grep -qF "unknown execution tier 'bogus-tier'" <<<"$bogus_out"; then
    pass "pantheon gate --execution bogus-tier --pr 1: fails closed with the execution-tier error, before any gh call"
  else
    fail "pantheon gate --execution bogus-tier --pr 1: did not fail closed as expected (status=$bogus_status, output: $bogus_out)"
  fi

  rm -rf "$SCRATCH"
else
  fail "pantheon.cli is NOT importable — cannot run the Part C equivalent"
fi

# ---------------------------------------------------------------------------
# Part E equivalent (Slice 4) — --permission-mode dontAsk on the claude provider lane.
# ---------------------------------------------------------------------------
section "Part E equivalent: --permission-mode dontAsk in pantheon/providers.py"

PROVIDERS_SRC="$ROOT/pantheon/providers.py"
if grep -qF '"--permission-mode", "dontAsk"' "$PROVIDERS_SRC"; then
  pass "pantheon/providers.py's claude lane passes --permission-mode dontAsk"
else
  fail "pantheon/providers.py's claude lane does NOT pass --permission-mode dontAsk"
fi

if grep -qE '"--permission-mode",\s*"default"' "$PROVIDERS_SRC"; then
  fail "pantheon/providers.py regressed back to --permission-mode default"
else
  pass "pantheon/providers.py does not pass --permission-mode default anywhere"
fi

# ---------------------------------------------------------------------------
# Part G equivalent (Slice 4) — pantheon.cli's execution= is base-pinned, not working-tree-pinned
# (the same Codex P1 finding cli/review-gate's own Part G closes) — exercised via real git
# fixture repos and pantheon.cli's own private helper, the same shape
# tests/test-prompt-assembly-python.sh's Part P3 uses for the sibling rules/spec-file reads.
# ---------------------------------------------------------------------------
section "Part G equivalent: pantheon.cli's execution= is base-pinned, not working-tree-pinned"

if python3 -c "import pantheon.cli" >/dev/null 2>&1; then
  git_fixture_repo_exec() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "test"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "fixture commit"
    git -C "$dir" rev-parse HEAD
  }

  py_resolve_execution() {
    python3 -c "
import sys
sys.path.insert(0, '$ROOT')
from pantheon.cli import _resolve_execution_from_base
print(_resolve_execution_from_base('$1', '$2'), end='')
"
  }

  # G1 — base has execution=readonly committed; a fork PR's head EDITS gate.conf to
  # execution=trusted. The base-pinned read must see 'readonly', never the working tree's
  # 'trusted'.
  FIXTURE_G1="$(mktemp -d)"
  echo "execution=readonly" > "$FIXTURE_G1/gate.conf"
  FIXTURE_G1_BASE_SHA="$(git_fixture_repo_exec "$FIXTURE_G1")"
  echo "execution=trusted" > "$FIXTURE_G1/gate.conf"
  git -C "$FIXTURE_G1" commit -q -am "fork PR edits gate.conf to execution=trusted"

  G1_RESULT="$(py_resolve_execution "$FIXTURE_G1" "$FIXTURE_G1_BASE_SHA")"
  if [[ "$G1_RESULT" == "readonly" ]]; then
    pass "base has execution=readonly, PR-edited working tree has execution=trusted -> base-pinned value (readonly) wins"
  else
    fail "base-pinning regression: expected 'readonly', got '$G1_RESULT' — the working-tree-edited value leaked through"
  fi
  rm -rf "$FIXTURE_G1"

  # G2 — a fork PR INTRODUCES gate.conf for the first time (absent at base entirely) with
  # execution=trusted. Must fall back to readonly, never read the PR-introduced file.
  FIXTURE_G2="$(mktemp -d)"
  echo "unrelated" > "$FIXTURE_G2/README.md"
  FIXTURE_G2_BASE_SHA="$(git_fixture_repo_exec "$FIXTURE_G2")"
  echo "execution=trusted" > "$FIXTURE_G2/gate.conf"
  git -C "$FIXTURE_G2" add gate.conf
  git -C "$FIXTURE_G2" commit -q -m "fork PR introduces gate.conf with execution=trusted"

  G2_RESULT="$(py_resolve_execution "$FIXTURE_G2" "$FIXTURE_G2_BASE_SHA")"
  if [[ "$G2_RESULT" == "readonly" ]]; then
    pass "gate.conf absent at base, PR introduces execution=trusted -> falls back to readonly, PR-introduced file never read"
  else
    fail "base-pinning regression: expected 'readonly' (gate.conf absent at base), got '$G2_RESULT'"
  fi
  rm -rf "$FIXTURE_G2"

  # G3 — a LEGITIMATE, already-merged gate.conf at base with execution=trusted must still be
  # honored — base-pinning isn't "always readonly," it's "trust the base commit, not the PR's own
  # edits."
  FIXTURE_G3="$(mktemp -d)"
  echo "execution=trusted" > "$FIXTURE_G3/gate.conf"
  FIXTURE_G3_BASE_SHA="$(git_fixture_repo_exec "$FIXTURE_G3")"

  G3_RESULT="$(py_resolve_execution "$FIXTURE_G3" "$FIXTURE_G3_BASE_SHA")"
  if [[ "$G3_RESULT" == "trusted" ]]; then
    pass "execution=trusted legitimately committed AT BASE (not PR-introduced) -> honored"
  else
    fail "expected 'trusted' (a legitimately base-committed value), got '$G3_RESULT'"
  fi
  rm -rf "$FIXTURE_G3"
else
  fail "pantheon.cli is NOT importable — cannot run the Part G equivalent"
fi

echo
echo "execution-tier-python fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
