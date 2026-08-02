#!/usr/bin/env bash
# tests/test-state-persistence-python.sh — the black-box Python equivalent of
# tests/test-state-persistence.sh, per docs/PYTHON-PORT.md section 4's disposition for that
# suite: "Needs a black-box equivalent against the state module. Slice 4 exit bar."
#
# The original suite is bash-internal (it extracts update_review_gate_state() verbatim from
# cli/review-gate via the $FUNCS_FILE pattern) — sourcing a .py file the way that suite sources
# a .sh file is not the right shape for its Python equivalent (docs/PYTHON-PORT.md section 4's
# own framing). This file keeps the same fixture set (same scenarios, same expectations) and
# drives pantheon.state as a real subprocess instead, via
# `python -m pantheon.state update <overall> <pr> <head-sha> <state-file> <workdir>` — the same
# black-box seam pantheon/state.py's own CLI shim exists to provide.
#
# tests/test-state-persistence.sh itself is untouched by this port (still extracts and exercises
# the bash function) and stays green — this file is an ADDITION, not a replacement.
#
# No test framework — plain bash, `bash tests/test-state-persistence-python.sh` is the whole
# invocation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $1 =="; }

if python3 -c "import pantheon.state" >/dev/null 2>&1; then
  pass "pantheon.state is importable"
else
  fail "pantheon.state is NOT importable — cannot run any further checks"
  echo; echo "state-persistence (python) fixtures: $PASS passed, $FAIL failed"; exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

py_update() {
  # py_update <overall> <pr> <head-sha> <state-file>
  python3 -m pantheon.state update "$1" "$2" "$3" "$4" "$WORKDIR"
}

section "update_state() fixtures (mirrors tests/test-state-persistence.sh's own scenarios)"

# check_persists <label> <overall-color> — a green/yellow outcome MUST write reviewed_sha.
check_persists() {
  local label="$1" overall="$2"
  local state_file="$WORKDIR/state-persists-$overall.json"
  echo '{}' > "$state_file"

  py_update "$overall" "42" "deadbeefcafe" "$state_file" >/dev/null 2>&1

  local reviewed_sha
  reviewed_sha="$(jq -r '.["42"].reviewed_sha // empty' "$state_file" 2>/dev/null)"
  if [[ "$reviewed_sha" == "deadbeefcafe" ]]; then
    pass "$label: overall=$overall records reviewed_sha"
  else
    fail "$label: overall=$overall did NOT record reviewed_sha (state: $(cat "$state_file"))"
  fi
}

# check_leaves_untouched <label> <overall-color> — a red/unverified outcome must NOT write
# anything; the state file's PARSED content must be unchanged (byte-identical isn't required of
# the Python port the way it is of the bash extraction — pantheon.jqjson.dumps's own pretty-print
# form may differ in whitespace from a hand-typed fixture literal; what must never change is the
# recorded reviewed_sha).
check_leaves_untouched() {
  local label="$1" overall="$2"
  local state_file="$WORKDIR/state-untouched-$overall.json"
  printf '{"42":{"reviewed_sha":"priorsha0000"}}' > "$state_file"
  local before
  before="$(cat "$state_file")"

  py_update "$overall" "42" "newshathatshouldnotland" "$state_file" >/dev/null 2>&1

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

section "Fresh PR, unverified outcome — no entry should be created at all"
FRESH_STATE="$WORKDIR/state-fresh-unverified.json"
echo '{}' > "$FRESH_STATE"
py_update "unverified" "99" "somehead" "$FRESH_STATE" >/dev/null 2>&1
fresh_after="$(jq -c . "$FRESH_STATE" 2>/dev/null)"
if [[ "$fresh_after" == "{}" ]]; then
  pass "fresh PR + unverified outcome: state file stays exactly '{}', no entry created"
else
  fail "fresh PR + unverified outcome: state file changed unexpectedly ($fresh_after)"
fi

# ---------------------------------------------------------------------------
# Codex review finding on this port's own PR: a state file whose EXISTING content is malformed
# (not the "fresh/absent" case above) must be left completely untouched by a green/yellow
# update_state() call too — never silently replaced with a fresh {} + only the current PR's
# entry, which would permanently destroy every other PR's previously recorded reviewed_sha.
# Mirrors bash's own update_review_gate_state(): its single `jq '...' "$state_file" > "$tmp"`
# exits nonzero on a malformed read, the `if` takes the else branch, nothing is written.
# ---------------------------------------------------------------------------
section "Malformed EXISTING state — a green/yellow update must NOT silently replace it"

MALFORMED_UPDATE_STATE="$WORKDIR/state-malformed-update.json"
printf 'not valid json at all { { {' > "$MALFORMED_UPDATE_STATE"
malformed_before="$(cat "$MALFORMED_UPDATE_STATE")"

py_update "green" "42" "deadbeefcafe" "$MALFORMED_UPDATE_STATE" >/dev/null 2>&1

malformed_after="$(cat "$MALFORMED_UPDATE_STATE")"
if [[ "$malformed_after" == "$malformed_before" ]]; then
  pass "update_state(): a green outcome against a malformed EXISTING state file leaves it byte-identical (does not silently replace it with a fresh, empty state)"
else
  fail "update_state(): malformed existing state was overwritten (before: $malformed_before / after: $malformed_after) — recoverable state destroyed"
fi

# ---------------------------------------------------------------------------
# Python-port-specific coverage: load_state()/reviewed_sha_for()/is_ancestor() — the
# follow-up-mode read side, which the bash suite's extracted-function shape doesn't reach (bash's
# equivalents are inline `jq` reads in cli/review-gate, not a separately named function).
# ---------------------------------------------------------------------------
section "load_state() / reviewed_sha_for() / is_ancestor() — the follow-up-mode read side"

pycall() {
  python3 -c "
import sys
sys.path.insert(0, '$ROOT')
from pantheon import state
_v = $1
print('' if _v is None else _v, end='')
"
}

BOOTSTRAP_STATE="$WORKDIR/bootstrap.json"
rm -f "$BOOTSTRAP_STATE"
py_bootstrap_content="$(pycall "state.load_state('$BOOTSTRAP_STATE')")"
if [[ -f "$BOOTSTRAP_STATE" ]] && [[ "$(cat "$BOOTSTRAP_STATE")" == "{}" ]]; then
  pass "load_state() bootstraps a missing state file to '{}' (unconditionally, same as cli/review-gate's own [[ -f \$STATE_FILE ]] || echo '{}' > \$STATE_FILE)"
else
  fail "load_state() did not bootstrap a missing state file correctly (content: $(cat "$BOOTSTRAP_STATE" 2>/dev/null))"
fi
if [[ "$py_bootstrap_content" == "{}" ]]; then
  pass "load_state() returns {} for a freshly-bootstrapped file"
else
  fail "load_state() returned unexpected content for a freshly-bootstrapped file: $py_bootstrap_content"
fi

MALFORMED_STATE="$WORKDIR/malformed.json"
printf 'not json at all' > "$MALFORMED_STATE"
malformed_content="$(pycall "state.load_state('$MALFORMED_STATE')")"
if [[ "$malformed_content" == "{}" ]]; then
  pass "load_state() fails closed to {} on unparseable state-file content"
else
  fail "load_state() did not fail closed on malformed content (got: $malformed_content)"
fi

SHA_STATE="$WORKDIR/sha-lookup.json"
printf '{"7":{"reviewed_sha":"abc123"},"8":{}}' > "$SHA_STATE"
present_sha="$(pycall "state.reviewed_sha_for(state.load_state('$SHA_STATE'), '7')")"
if [[ "$present_sha" == "abc123" ]]; then
  pass "reviewed_sha_for(): a present PR entry returns its reviewed_sha"
else
  fail "reviewed_sha_for(): expected 'abc123', got '$present_sha'"
fi

missing_key_sha="$(pycall "state.reviewed_sha_for(state.load_state('$SHA_STATE'), '8')")"
if [[ -z "$missing_key_sha" ]]; then
  pass "reviewed_sha_for(): an entry missing reviewed_sha returns None (empty)"
else
  fail "reviewed_sha_for(): expected empty for a missing reviewed_sha key, got '$missing_key_sha'"
fi

absent_pr_sha="$(pycall "state.reviewed_sha_for(state.load_state('$SHA_STATE'), '999')")"
if [[ -z "$absent_pr_sha" ]]; then
  pass "reviewed_sha_for(): a PR with no entry at all returns None (empty)"
else
  fail "reviewed_sha_for(): expected empty for an absent PR, got '$absent_pr_sha'"
fi

# is_ancestor(): real git fixture repo — an old commit is an ancestor of a later one; an
# unrelated/orphan commit is not — mirrors cli/review-gate's own force-push-detection ancestry
# check (git merge-base --is-ancestor), the actual invariant an incremental follow-up review
# needs (an EXISTENCE check alone isn't enough post-force-push).
ANCESTRY_REPO="$(mktemp -d)"
git -C "$ANCESTRY_REPO" init -q
git -C "$ANCESTRY_REPO" config user.email "test@example.com"
git -C "$ANCESTRY_REPO" config user.name "test"
echo "a" > "$ANCESTRY_REPO/f.txt"
git -C "$ANCESTRY_REPO" add f.txt
git -C "$ANCESTRY_REPO" commit -q -m first
FIRST_SHA="$(git -C "$ANCESTRY_REPO" rev-parse HEAD)"
echo "b" >> "$ANCESTRY_REPO/f.txt"
git -C "$ANCESTRY_REPO" commit -q -am second

is_ancestor_true="$(pycall "state.is_ancestor('$FIRST_SHA', 'HEAD', cwd='$ANCESTRY_REPO')")"
if [[ "$is_ancestor_true" == "True" ]]; then
  pass "is_ancestor(): an earlier commit on the same branch IS an ancestor of HEAD"
else
  fail "is_ancestor(): expected True, got '$is_ancestor_true'"
fi

ORIGINAL_BRANCH="$(git -C "$ANCESTRY_REPO" symbolic-ref --short HEAD)"
git -C "$ANCESTRY_REPO" checkout -q --orphan orphan-branch
git -C "$ANCESTRY_REPO" commit -q --allow-empty -m "orphan commit, unrelated history"
ORPHAN_SHA="$(git -C "$ANCESTRY_REPO" rev-parse HEAD)"
is_ancestor_false="$(pycall "state.is_ancestor('$ORPHAN_SHA', '$ORIGINAL_BRANCH', cwd='$ANCESTRY_REPO')")"
if [[ "$is_ancestor_false" == "False" ]]; then
  pass "is_ancestor(): an unrelated (orphan-branch) commit is NOT an ancestor — force-push/history-rewrite detection holds"
else
  fail "is_ancestor(): expected False for an unrelated commit, got '$is_ancestor_false'"
fi

rm -rf "$ANCESTRY_REPO"

# ---------------------------------------------------------------------------
# CRITICAL fix (adversarial review): a state-write FAILURE for a green verdict must fail this
# CLI shim's own exit code closed (nonzero), never silently exit 0 — the pre-fix `_update_cli`
# discarded update_state()'s outcome entirely and always returned 0. Live pre-fix reproduction:
# reverting `_update_cli` to `update_state(...); return 0` (unconditional) makes the FIRST check
# below FAIL (exits 0 despite the write having visibly failed) — verified locally before landing
# this fix. Skipped when running as root (POSIX permission checks are bypassed for root, same
# precondition tests/test_state.py's own chmod-555 fixtures guard against).
# ---------------------------------------------------------------------------
section "State-write failure fails closed (python -m pantheon.state update must exit nonzero)"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: running as root — POSIX permission checks are bypassed, precondition unmet"
else
  FAILCLOSED_DIR="$(mktemp -d)"
  FAILCLOSED_STATE="$FAILCLOSED_DIR/state.json"
  echo '{}' > "$FAILCLOSED_STATE"
  chmod 555 "$FAILCLOSED_DIR"

  py_update "green" "42" "deadbeefcafe" "$FAILCLOSED_STATE" >/dev/null 2>&1
  FAILCLOSED_STATUS=$?

  chmod 755 "$FAILCLOSED_DIR"  # restore so cleanup below can actually remove it
  rm -rf "$FAILCLOSED_DIR"

  if [[ "$FAILCLOSED_STATUS" -ne 0 ]]; then
    pass "python -m pantheon.state update: exits nonzero when the state directory is unwritable for a green verdict — fail-closed, matches bash's own abort-on-mv-failure behavior"
  else
    fail "python -m pantheon.state update: exited 0 despite a failed state write (state dir chmod 555) — this was the CRITICAL-3 gap: state-write failure was fail-OPEN"
  fi
fi

# ---------------------------------------------------------------------------
# Empty-state-file self-heal (medium finding, same review): real jq on genuinely empty input
# exits 0 with no output — bash's own SEEN_SHA read and write-side jq call both treat an empty
# state file as "no prior state," not a parse error (verified live below). Pre-fix, Python's
# jqjson.loads("") raised JqParseError like any other malformed content, so an empty state file
# could never self-repair (update_state() correctly refuses to overwrite content it judges
# malformed).
# ---------------------------------------------------------------------------
section "Empty state file self-heals (matches bash's own jq-on-empty-input behavior)"

EMPTY_STATE="$WORKDIR/state-empty.json"
: > "$EMPTY_STATE"  # genuinely 0 bytes

py_update "green" "42" "deadbeefcafe" "$EMPTY_STATE" >/dev/null 2>&1
EMPTY_UPDATE_STATUS=$?
empty_reviewed_sha="$(jq -r '.["42"].reviewed_sha // empty' "$EMPTY_STATE" 2>/dev/null)"

if [[ "$EMPTY_UPDATE_STATUS" -eq 0 && "$empty_reviewed_sha" == "deadbeefcafe" ]]; then
  pass "update_state(): a green outcome against a genuinely EMPTY existing state file self-heals (writes the new entry), matching bash's own jq-on-empty-input write behavior"
else
  fail "update_state(): did not self-heal an empty existing state file (status=$EMPTY_UPDATE_STATUS, reviewed_sha='$empty_reviewed_sha')"
fi

if command -v jq >/dev/null 2>&1; then
  live_empty_read="$(printf '' | jq -r '.["42"].reviewed_sha // empty')"
  live_empty_status=$?
  if [[ "$live_empty_status" -eq 0 && -z "$live_empty_read" ]]; then
    pass "live cross-check: real jq on empty input exits 0 with no output for the same SEEN_SHA-shaped query bash's own review-gate uses"
  else
    fail "live cross-check: real jq's empty-input behavior did not match what this fixture assumes (status=$live_empty_status, output='$live_empty_read')"
  fi
fi

echo
echo "state-persistence (python) fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
