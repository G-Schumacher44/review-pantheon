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

echo
echo "state-persistence fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
