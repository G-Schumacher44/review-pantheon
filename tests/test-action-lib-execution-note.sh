#!/usr/bin/env bash
# tests/test-action-lib-execution-note.sh — fixture test for action/lib/build_prompt.sh's
# pantheon_execution_context_note() and its action/lib/execution_context_note.py driver.
#
# A live Codex P1 finding on an earlier version of this fix: invoking
# pantheon.execution.execution_context_note() via `python3 -c '<code>'` sets sys.path[0] to "",
# which Python resolves as the process's cwd — on a composite-action step that's the CONSUMING
# repo's checkout, ahead of PYTHONPATH. A fork PR committing its own top-level
# pantheon/__init__.py + pantheon/execution.py would get those imported instead of the trusted
# package. execution_context_note.py closes this by being invoked via its own absolute path
# instead (never -c/-m) — this file is the automated proof that property actually holds, not
# just a manually-reproduced claim in a commit message (an Apollo finding on this PR itself: the
# fix shipped with no checked-in test exercising this exact code path).
#
# No test framework — plain bash, `bash tests/test-action-lib-execution-note.sh` is the whole
# invocation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }

section() { echo; echo "== $1 =="; }

section "execution_context_note.py driver — real output, run from a normal cwd"

note_readonly="$(PYTHONPATH="$ROOT" python3 "$ROOT/action/lib/execution_context_note.py" readonly /some/wrapper/path)"
if grep -q "Execution: readonly" <<<"$note_readonly" && grep -qF "/some/wrapper/path" <<<"$note_readonly"; then
  pass "readonly tier note mentions the wrapper path"
else
  fail "readonly tier note" "did not contain expected text: $note_readonly"
fi

note_trusted="$(PYTHONPATH="$ROOT" python3 "$ROOT/action/lib/execution_context_note.py" trusted /some/wrapper/path)"
if [[ -z "$note_trusted" ]]; then
  pass "trusted tier note is empty (no substitute instruction needed)"
else
  fail "trusted tier note" "expected empty, got: $note_trusted"
fi

# ---------------------------------------------------------------------------
# The actual security property: cwd-shadow-import resistance. A hostile cwd carries its own
# pantheon/__init__.py + pantheon/execution.py — the exact shape a fork PR's own checkout can
# commit on a composite-action step (whose cwd IS that checkout).
# ---------------------------------------------------------------------------
section "cwd-shadow-import resistance (the vector the -c -> absolute-path fix closes)"

HOSTILE_CWD="$(mktemp -d)"
mkdir -p "$HOSTILE_CWD/pantheon"
: > "$HOSTILE_CWD/pantheon/__init__.py"
cat > "$HOSTILE_CWD/pantheon/execution.py" <<'EOF'
def execution_context_note(tier, wrapper_path):
    return "PWNED-SHADOW-OUTPUT\n"
EOF

# Negative control: proves the OLD vulnerable shape (`python3 -c`) really would have been
# shadowed by this hostile cwd — fixture is live, not asserting a difference that was never real.
shadow_out="$(cd "$HOSTILE_CWD" && PYTHONPATH="$ROOT" python3 -c '
import sys
from pantheon import execution
sys.stdout.write(execution.execution_context_note(sys.argv[1], sys.argv[2]))
' readonly /some/wrapper/path)"
if [[ "$shadow_out" == "PWNED-SHADOW-OUTPUT" ]]; then
  pass "negative control: the vulnerable 'python3 -c' shape DOES get shadowed by a hostile cwd's pantheon/ package — fixture is live"
else
  fail "negative control" "expected the -c shape to be shadowed (got: $shadow_out) — this fixture is not exercising anything, the assertion below is meaningless"
fi

# The actual fix: running from the SAME hostile cwd, the real driver must resolve the TRUSTED
# module (its own directory is sys.path[0], never the caller's cwd), not the shadow.
real_out="$(cd "$HOSTILE_CWD" && PYTHONPATH="$ROOT" python3 "$ROOT/action/lib/execution_context_note.py" readonly /some/wrapper/path)"
if [[ "$real_out" == "$note_readonly" ]]; then
  pass "execution_context_note.py resolves the REAL trusted pantheon.execution module even when run from a hostile cwd containing a shadow pantheon/ package"
else
  fail "cwd-shadow resistance" "expected the trusted output ('$note_readonly'), got: '$real_out'"
fi
if [[ "$real_out" != *"PWNED-SHADOW-OUTPUT"* ]]; then
  pass "the shadow package's fake output never leaks through"
else
  fail "cwd-shadow resistance" "shadow output leaked through: $real_out"
fi

rm -rf "$HOSTILE_CWD"

# ---------------------------------------------------------------------------
# build_prompt.sh — full integration run (proves the shell wrapper around the driver, not just
# the driver in isolation, actually works end to end).
# ---------------------------------------------------------------------------
section "build_prompt.sh — full integration run"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

: > "$WORKDIR/rules.txt"
PROMPT_FILE="$WORKDIR/prompt.md"

build_status=0
REPO_NAME="test/repo" PR_NUMBER="1" PR_TITLE="test PR" \
BASE_SHA="$(git -C "$ROOT" rev-parse HEAD~1)" HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)" \
BASE_REF="dev" RULES_FILE="REVIEW_RULES.md" RULES_PRESENT="false" \
RULES_CONTENT_PATH="$WORKDIR/rules.txt" EXECUTION="readonly" \
GIT_WRAPPER_PATH="python3 $ROOT/pantheon/execution.py wrapper" \
  bash "$ROOT/action/lib/build_prompt.sh" artemis "$ROOT/agents" "$PROMPT_FILE" || build_status=$?

if [[ $build_status -eq 0 && -s "$PROMPT_FILE" ]]; then
  pass "build_prompt.sh exits 0 and writes a non-empty prompt file"
else
  fail "build_prompt.sh integration run" "exit=$build_status, non-empty file: $([[ -s "$PROMPT_FILE" ]] && echo yes || echo no)"
fi

if grep -q "Execution: readonly" "$PROMPT_FILE" 2>/dev/null; then
  pass "the built prompt embeds the readonly execution-context note"
else
  fail "build_prompt.sh integration run" "prompt file missing the execution-context note"
fi

if grep -qF "$ROOT/pantheon/execution.py wrapper" "$PROMPT_FILE" 2>/dev/null; then
  pass "the built prompt tells the agent the exact wrapper invocation to use"
else
  fail "build_prompt.sh integration run" "prompt file missing the wrapper invocation string"
fi

echo
echo "action-lib-execution-note fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
