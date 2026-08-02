#!/usr/bin/env bash
# tests/test-state-persistence.sh — fixture test for cli/review-gate's
# update_review_gate_state() (a carried finding from an external reviewer's finding on a
# sibling system, treated as our own): the pre-fix write updated .review-gate-state.json after
# ANY successful `gh pr comment` post, regardless of the computed verdict — so an UNVERIFIED
# result (a transient provider failure) still marked the head reviewed, and follow-up mode would
# then only re-review the incremental diff since that poisoned state, never retrying the run
# that never actually gated anything. Fixed: state is recorded ONLY for green/yellow outcomes;
# red/unverified leave the state file untouched.
#
# update_review_gate_state has no `gh`/network dependency (pure jq + mv on a local file), so
# this extracts it verbatim from the live script (never hand-copied — a drifted copy would
# defeat the point) — same pattern tests/test-prompt-assembly.sh's Part B uses for build_prompt()
# — and exercises it directly with fixture state files, no mocking of the rest of review-gate's
# gh/jq network calls required.
#
# No test framework — plain bash, `bash tests/test-state-persistence.sh` is the whole invocation
# (wired into .github/workflows/ci.yml and tests/test-setup-smoke.sh's existing-suites stage).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW_GATE="$ROOT/cli/review-gate"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

section() { echo; echo "== $1 =="; }

# ---------------------------------------------------------------------------
# Extract update_review_gate_state() verbatim from cli/review-gate.
# ---------------------------------------------------------------------------
section "Extract update_review_gate_state() from cli/review-gate"

extract_func() {
  local name="$1" file="$2"
  awk -v name="$name" '
    $0 ~ ("^" name "\\(\\) \\{") { grab=1 }
    grab { print }
    grab && /^}/ { exit }
  ' "$file"
}

FUNCS_FILE="$(mktemp)"
trap 'rm -f "$FUNCS_FILE"' EXIT
extract_func "update_review_gate_state" "$REVIEW_GATE" > "$FUNCS_FILE"

if [[ -s "$FUNCS_FILE" ]] && grep -q "^update_review_gate_state() {" "$FUNCS_FILE"; then
  pass "extracted update_review_gate_state() from cli/review-gate"
else
  fail "could not extract update_review_gate_state() from cli/review-gate — review-gate's shape changed; update the extractor"
fi

# review-gate's own note() writes to stderr — stub it so the extracted function has something
# to call without pulling in the rest of the script.
note() { echo "note: $*" >&2; }

# shellcheck disable=SC1090
source "$FUNCS_FILE"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
section "update_review_gate_state() fixtures"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# check_persists <label> <overall-color> — a green/yellow outcome MUST write reviewed_sha.
check_persists() {
  local label="$1" overall="$2"
  local state_file="$WORKDIR/state-persists-$overall.json"
  echo '{}' > "$state_file"

  update_review_gate_state "$overall" "42" "deadbeefcafe" "$state_file" "$WORKDIR"

  local reviewed_sha
  reviewed_sha="$(jq -r '.["42"].reviewed_sha // empty' "$state_file" 2>/dev/null)"
  if [[ "$reviewed_sha" == "deadbeefcafe" ]]; then
    pass "$label: overall=$overall records reviewed_sha"
  else
    fail "$label: overall=$overall did NOT record reviewed_sha (state: $(cat "$state_file"))"
  fi
}

# check_leaves_untouched <label> <overall-color> — a red/unverified outcome must NOT write
# anything; the state file's bytes must be byte-identical to what they were before the call.
check_leaves_untouched() {
  local label="$1" overall="$2"
  local state_file="$WORKDIR/state-untouched-$overall.json"
  printf '{"42":{"reviewed_sha":"priorsha0000"}}' > "$state_file"
  local before
  before="$(cat "$state_file")"

  update_review_gate_state "$overall" "42" "newshathatshouldnotland" "$state_file" "$WORKDIR"

  local after
  after="$(cat "$state_file")"
  if [[ "$after" == "$before" ]]; then
    pass "$label: overall=$overall leaves the state file byte-identical (no poisoning)"
  else
    fail "$label: overall=$overall modified the state file (before: $before / after: $after)"
  fi

  local reviewed_sha
  reviewed_sha="$(jq -r '.["42"].reviewed_sha // empty' "$state_file" 2>/dev/null)"
  if [[ "$reviewed_sha" == "priorsha0000" ]]; then
    pass "$label: overall=$overall still shows the PRIOR reviewed_sha, not the new (unreviewed) head"
  else
    fail "$label: overall=$overall's reviewed_sha changed to '$reviewed_sha' — the new head was wrongly marked reviewed"
  fi
}

check_persists "green outcome" "green"
check_persists "yellow outcome" "yellow"
check_leaves_untouched "unverified outcome (transient provider failure)" "unverified"
check_leaves_untouched "red outcome (blocked)" "red"

# A fresh PR (no prior entry at all) with an unverified outcome must not create one either —
# same fail-closed rule, the "nothing to leave untouched" edge of the same fixture.
section "Fresh PR, unverified outcome — no entry should be created at all"
FRESH_STATE="$WORKDIR/state-fresh-unverified.json"
echo '{}' > "$FRESH_STATE"
update_review_gate_state "unverified" "99" "somehead" "$FRESH_STATE" "$WORKDIR"
fresh_after="$(cat "$FRESH_STATE")"
if [[ "$fresh_after" == "{}" ]]; then
  pass "fresh PR + unverified outcome: state file stays exactly '{}', no entry created"
else
  fail "fresh PR + unverified outcome: state file changed unexpectedly ($fresh_after)"
fi

# ---------------------------------------------------------------------------
# CRITICAL fix's REFERENCE BASELINE (adversarial review, fixed on the Python port only —
# pantheon/state.py::update_state()/pantheon/cli.py::run_gate() — this bash implementation is
# what the fix must MATCH, not something changed here). This suite's own Part above only
# extracts+sources update_review_gate_state() in isolation, under this TEST SCRIPT's `set -uo
# pipefail` (deliberately no `-e`, so a failing call here never aborts THIS harness) — that never
# actually exercised the property real cli/review-gate has: it calls
# `update_review_gate_state "$OVERALL" ...` as a BARE TOP-LEVEL STATEMENT, under the whole
# script's `set -euo pipefail`, and that function's own `mv "$tmp_state" "$state_file"` line is
# NOT inside an if-condition (unlike the `jq ... > "$tmp_state"` redirect immediately before it,
# which IS an if-condition and so IS errexit-exempt) — so a failing `mv` (a read-only state
# directory) aborts the WHOLE SCRIPT nonzero right there. This section reproduces THAT exact
# invocation shape (source the function, then call it as a bare statement under `set -e`) against
# a real chmod-555 directory, proving the reference baseline the Python port's own fix
# (tests/test-state-persistence-python.sh's matching fixture) must reproduce. Skipped when
# running as root (POSIX permission checks are bypassed for root).
# ---------------------------------------------------------------------------
section "State-write failure fails closed under set -e (cli/review-gate's real invocation shape)"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: running as root — POSIX permission checks are bypassed, precondition unmet"
else
  FAILCLOSED_DIR="$(mktemp -d)"
  FAILCLOSED_STATE="$FAILCLOSED_DIR/state.json"
  echo '{}' > "$FAILCLOSED_STATE"
  chmod 555 "$FAILCLOSED_DIR"

  FAILCLOSED_STATUS=0
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$FUNCS_FILE"
    # shellcheck disable=SC2329 # called indirectly by the sourced update_review_gate_state()
    note() { echo "note: $*" >&2; }
    update_review_gate_state "green" "42" "deadbeefcafe" "$FAILCLOSED_STATE" "$WORKDIR"
  ) >/dev/null 2>&1 || FAILCLOSED_STATUS=$?

  chmod 755 "$FAILCLOSED_DIR"  # restore so cleanup below can actually remove it
  rm -rf "$FAILCLOSED_DIR"

  if [[ "$FAILCLOSED_STATUS" -ne 0 ]]; then
    pass "cli/review-gate's real invocation shape (bare statement, no if-guard, under set -euo pipefail) aborts NONZERO when the state directory is unwritable for a green verdict — the reference baseline the Python port's own CRITICAL-3 fix matches"
  else
    fail "expected a nonzero exit when update_review_gate_state's mv fails under set -e (state dir chmod 555), got 0 — bash's own fail-closed-on-write-failure property is not actually exercised by this suite"
  fi
fi

echo
echo "state-persistence fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
