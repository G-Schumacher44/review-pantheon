#!/usr/bin/env bash
# tests/test-base-pinned-read.sh — fixture tests for cli/lib/pantheon-base-pin.sh
# (pantheon_base_pinned_read / pantheon_normalize_repo_path), the symlink-safe base-pinned-read
# helper closing a round-2 Codex P2 finding on issue #6 (review-pantheon PR #8): a bare
# `git show $BASE_SHA:path` on a symlinked path returns the link TARGET STRING (git stores a
# tracked symlink as a mode-120000 blob), not the target file's content — a target repo with a
# symlinked custom persona (a real pattern: `.github/custom-personas/artemis.md ->
# ../../agents/artemis.md`, the exact example from Codex's own finding) got a broken prompt
# where the previous checkout-based read worked.
#
# Every fixture below uses REAL git repos with REAL filesystem symlinks (`ln -s`), committed,
# so `git ls-tree`/`git show` report the actual mode-120000 blobs this bug class depends on —
# not a simulation of what a symlink blob looks like.
#
# No test framework — plain bash, `bash tests/test-base-pinned-read.sh` is the whole invocation
# (wired into .github/workflows/ci.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/cli/lib/pantheon-base-pin.sh"

PASS=0
FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $1 =="; }

if [[ -f "$LIB" ]]; then
  pass "cli/lib/pantheon-base-pin.sh exists"
else
  fail "cli/lib/pantheon-base-pin.sh exists"
  echo; echo "PASS: $PASS, FAIL: $FAIL"; exit 1
fi

# shellcheck disable=SC1090
source "$LIB"

if declare -F pantheon_base_pinned_read >/dev/null && declare -F pantheon_normalize_repo_path >/dev/null; then
  pass "sourced pantheon_base_pinned_read and pantheon_normalize_repo_path"
else
  fail "could not source pantheon_base_pinned_read / pantheon_normalize_repo_path — the library's shape changed"
  echo; echo "PASS: $PASS, FAIL: $FAIL"; exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

git_fixture_repo() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture commit"
  git -C "$dir" rev-parse HEAD
}

# ---------------------------------------------------------------------------
# Part A — pantheon_normalize_repo_path unit fixtures (pure string manipulation, no git).
# ---------------------------------------------------------------------------
section "Part A: pantheon_normalize_repo_path"

check_normalize() {
  local label="$1" input="$2" expect_ok="$3" expect_value="${4:-}"
  local out rc=0
  out="$(pantheon_normalize_repo_path "$input")" || rc=$?
  if [[ "$expect_ok" == "true" ]]; then
    if [[ "$rc" -eq 0 && "$out" == "$expect_value" ]]; then
      pass "$label"
    else
      fail "$label (rc=$rc out='$out', expected ok with '$expect_value')"
    fi
  else
    if [[ "$rc" -ne 0 ]]; then
      pass "$label"
    else
      fail "$label (expected refusal, got ok with out='$out')"
    fi
  fi
}

check_normalize "plain relative path passes through unchanged" "a/b/c.md" true "a/b/c.md"
check_normalize "a/../b/c.md collapses to b/c.md" "a/../b/c.md" true "b/c.md"
check_normalize "./a/./b.md collapses to a/b.md" "./a/./b.md" true "a/b.md"
check_normalize "a/b/../../c.md collapses to c.md" "a/b/../../c.md" true "c.md"
check_normalize "a/../../b.md (climbs above root) is refused" "a/../../b.md" false
check_normalize "../a.md (climbs above root immediately) is refused" "../a.md" false
check_normalize "an absolute path is refused" "/etc/passwd" false
check_normalize "an empty path is refused" "" false
check_normalize "a path that fully collapses to nothing (./.) is refused" "./." false

# ---------------------------------------------------------------------------
# Part B — pantheon_base_pinned_read: regular file (no symlink involved) still works, same
# behavior a bare `git show` already had — this fix must not regress the common case.
# ---------------------------------------------------------------------------
section "Part B: pantheon_base_pinned_read — regular (non-symlinked) file"

FIXTURE_B="$WORKDIR/fixture-b"
mkdir -p "$FIXTURE_B/agents"
echo "REGULAR-PERSONA-CONTENT" > "$FIXTURE_B/agents/artemis.md"
FIXTURE_B_SHA="$(git_fixture_repo "$FIXTURE_B")"

B_OUT="$WORKDIR/b-out.txt"
if (cd "$FIXTURE_B" && pantheon_base_pinned_read "$FIXTURE_B_SHA" "agents/artemis.md" "$B_OUT"); then
  pass "regular file resolves (rc=0)"
else
  fail "regular file failed to resolve"
fi
if grep -q "REGULAR-PERSONA-CONTENT" "$B_OUT" 2>/dev/null; then
  pass "regular file's content reaches the destination"
else
  fail "regular file's content is missing from the destination"
fi

# ---------------------------------------------------------------------------
# Part C — the exact scenario Codex's finding named: a target repo's custom persona directory
# uses a symlink to the bundled canonical persona (`.github/custom-personas/artemis.md ->
# ../../agents/artemis.md`). Resolution must return the TARGET's content, never the raw
# link-target pathname string a bare `git show` returns on a mode-120000 blob.
# ---------------------------------------------------------------------------
section "Part C: pantheon_base_pinned_read — symlinked persona resolves to target content (Codex's exact example)"

FIXTURE_C="$WORKDIR/fixture-c"
mkdir -p "$FIXTURE_C/agents" "$FIXTURE_C/.github/custom-personas"
echo "BUNDLED-ARTEMIS-CONTENT" > "$FIXTURE_C/agents/artemis.md"
( cd "$FIXTURE_C/.github/custom-personas" && ln -s ../../agents/artemis.md artemis.md )
FIXTURE_C_SHA="$(git_fixture_repo "$FIXTURE_C")"

# Sanity check: confirm this really is a mode-120000 blob at base (i.e. the fixture actually
# exercises the bug class, not something that happened to work anyway).
C_MODE="$(cd "$FIXTURE_C" && git ls-tree "$FIXTURE_C_SHA" -- .github/custom-personas/artemis.md | awk '{print $1}')"
if [[ "$C_MODE" == "120000" ]]; then
  pass "fixture sanity check: the custom persona is really a mode-120000 (symlink) blob at base"
else
  fail "fixture sanity check FAILED: expected mode 120000, got '$C_MODE' — this fixture doesn't exercise the bug class"
fi

# Sanity check: a BARE git show returns the raw link-target string, not file content — proves
# the bug this fix closes is real, in this exact fixture, before asserting the fix itself.
C_BARE="$(cd "$FIXTURE_C" && git show "${FIXTURE_C_SHA}:.github/custom-personas/artemis.md" 2>/dev/null)"
if [[ "$C_BARE" == "../../agents/artemis.md" ]]; then
  pass "fixture sanity check: a bare 'git show' on the symlinked path returns the raw link-target string (the bug this fix closes)"
else
  fail "fixture sanity check: expected a bare 'git show' to return the raw link-target string '../../agents/artemis.md', got '$C_BARE'"
fi

C_OUT="$WORKDIR/c-out.txt"
C_RC=0
( cd "$FIXTURE_C" && pantheon_base_pinned_read "$FIXTURE_C_SHA" ".github/custom-personas/artemis.md" "$C_OUT" ) || C_RC=$?
if [[ "$C_RC" -eq 0 ]]; then
  pass "symlinked persona resolves (rc=0)"
else
  fail "symlinked persona failed to resolve (rc=$C_RC)"
fi
if grep -q "BUNDLED-ARTEMIS-CONTENT" "$C_OUT" 2>/dev/null; then
  pass "symlinked persona resolves to the TARGET file's content"
else
  fail "symlinked persona did not resolve to the target file's content"
fi
if grep -q "agents/artemis.md" "$C_OUT" 2>/dev/null; then
  fail "symlinked persona's resolved content still contains the raw link-target pathname (the bug is not closed)"
else
  pass "symlinked persona's resolved content does NOT contain the raw link-target pathname"
fi

# A short (2-hop) legitimate chain: a symlink to a symlink to a regular file, still within the
# repo — proves the chain-following loop itself works, not just single-hop resolution.
mkdir -p "$FIXTURE_C/.github/other-personas"
( cd "$FIXTURE_C/.github/other-personas" && ln -s ../custom-personas/artemis.md artemis.md )
git -C "$FIXTURE_C" add -A
git -C "$FIXTURE_C" commit -q -m "add a second-hop symlink"
FIXTURE_C2_SHA="$(git -C "$FIXTURE_C" rev-parse HEAD)"
C2_OUT="$WORKDIR/c2-out.txt"
if (cd "$FIXTURE_C" && pantheon_base_pinned_read "$FIXTURE_C2_SHA" ".github/other-personas/artemis.md" "$C2_OUT"); then
  pass "a 2-hop symlink chain (symlink -> symlink -> file) resolves"
else
  fail "a 2-hop symlink chain failed to resolve"
fi
if grep -q "BUNDLED-ARTEMIS-CONTENT" "$C2_OUT" 2>/dev/null; then
  pass "a 2-hop symlink chain resolves to the final target's content"
else
  fail "a 2-hop symlink chain did not resolve to the final target's content"
fi

# ---------------------------------------------------------------------------
# Part D — a symlink escaping the repository root must be REFUSED (rc=1), loud, never silently
# treated as absent and never followed to whatever the filesystem outside the repo happens to
# hold.
# ---------------------------------------------------------------------------
section "Part D: pantheon_base_pinned_read — symlink escaping the repo root is refused"

FIXTURE_D="$WORKDIR/fixture-d"
mkdir -p "$FIXTURE_D"
( cd "$FIXTURE_D" && ln -s ../../../../../../etc/passwd escape.md )
( cd "$FIXTURE_D" && ln -s /etc/passwd absolute.md )
echo "unrelated" > "$FIXTURE_D/README.md"
FIXTURE_D_SHA="$(git_fixture_repo "$FIXTURE_D")"

D1_OUT="$WORKDIR/d1-out.txt"
D1_RC=0
( cd "$FIXTURE_D" && pantheon_base_pinned_read "$FIXTURE_D_SHA" "escape.md" "$D1_OUT" ) 2>/dev/null || D1_RC=$?
if [[ "$D1_RC" -eq 1 ]]; then
  pass "a relative symlink climbing above the repo root is refused (rc=1, not silently absent)"
else
  fail "a relative symlink climbing above the repo root was NOT refused with rc=1 (got rc=$D1_RC)"
fi
if [[ ! -s "$D1_OUT" ]]; then
  pass "no content was written for the refused escaping symlink"
else
  fail "content was written despite the escaping symlink being refused"
fi

D2_OUT="$WORKDIR/d2-out.txt"
D2_RC=0
( cd "$FIXTURE_D" && pantheon_base_pinned_read "$FIXTURE_D_SHA" "absolute.md" "$D2_OUT" ) 2>/dev/null || D2_RC=$?
if [[ "$D2_RC" -eq 1 ]]; then
  pass "an absolute-target symlink is refused (rc=1, not silently absent)"
else
  fail "an absolute-target symlink was NOT refused with rc=1 (got rc=$D2_RC)"
fi

# An escaping symlink must be distinguishable from ordinary absence (rc=2) — a caller relying
# on this return code to decide "fail the whole run" vs. "silently treat as not-present-at-base"
# must never conflate the two.
if [[ "$D1_RC" -ne 2 && "$D2_RC" -ne 2 ]]; then
  pass "refused resolutions use a DIFFERENT return code (1) than ordinary absence (2) — a caller cannot conflate the two"
else
  fail "a refused resolution returned the same code as ordinary absence — a caller could silently swallow a refusal as absence"
fi

# ---------------------------------------------------------------------------
# Part E — ordinary absence (no symlink involved) is unaffected: still returns 2, the same
# "not present at base" outcome every base-pinned read already had, never REFUSED (1).
# ---------------------------------------------------------------------------
section "Part E: pantheon_base_pinned_read — ordinary absence is unaffected (rc=2, unchanged)"

E_OUT="$WORKDIR/e-out.txt"
E_RC=0
( cd "$FIXTURE_D" && pantheon_base_pinned_read "$FIXTURE_D_SHA" "does-not-exist.md" "$E_OUT" ) 2>/dev/null || E_RC=$?
if [[ "$E_RC" -eq 2 ]]; then
  pass "a path absent at base returns rc=2 (ordinary absence, unchanged)"
else
  fail "a path absent at base returned rc=$E_RC, expected 2"
fi

# A symlink whose target doesn't exist at base (a broken link) is also ordinary absence, not a
# refusal — there's legitimately nothing to read, same as any other absent file.
( cd "$FIXTURE_D" && ln -s nonexistent-target.md broken.md )
git -C "$FIXTURE_D" add -A
git -C "$FIXTURE_D" commit -q -m "add a broken symlink"
FIXTURE_D2_SHA="$(git -C "$FIXTURE_D" rev-parse HEAD)"
E2_OUT="$WORKDIR/e2-out.txt"
E2_RC=0
( cd "$FIXTURE_D" && pantheon_base_pinned_read "$FIXTURE_D2_SHA" "broken.md" "$E2_OUT" ) 2>/dev/null || E2_RC=$?
if [[ "$E2_RC" -eq 2 ]]; then
  pass "a symlink whose target is absent at base returns rc=2 (ordinary absence, not a refusal)"
else
  fail "a symlink whose target is absent at base returned rc=$E2_RC, expected 2"
fi

# ---------------------------------------------------------------------------
# Part F — chain-depth bound (reuses the 32-hop convention cli/review-gate's resolve_real_dir
# and bootstrap.sh already use for symlink-following elsewhere in this repo). A chain longer
# than the bound must be refused (rc=1) — never followed indefinitely, and never silently
# treated as absent.
# ---------------------------------------------------------------------------
section "Part F: pantheon_base_pinned_read — chain-depth bound"

FIXTURE_F="$WORKDIR/fixture-f"
mkdir -p "$FIXTURE_F"
echo "CHAIN-END-CONTENT" > "$FIXTURE_F/chain0.md"
prev="chain0.md"
i=1
while [ "$i" -le 40 ]; do
  ( cd "$FIXTURE_F" && ln -s "$prev" "chain${i}.md" )
  prev="chain${i}.md"
  i=$((i + 1))
done
FIXTURE_F_SHA="$(git_fixture_repo "$FIXTURE_F")"

F1_OUT="$WORKDIR/f1-out.txt"
F1_RC=0
( cd "$FIXTURE_F" && pantheon_base_pinned_read "$FIXTURE_F_SHA" "chain40.md" "$F1_OUT" ) 2>/dev/null || F1_RC=$?
if [[ "$F1_RC" -eq 1 ]]; then
  pass "a 40-hop symlink chain exceeds the depth bound and is refused (rc=1)"
else
  fail "a 40-hop symlink chain was NOT refused (got rc=$F1_RC) — the depth bound may be missing or too permissive"
fi

# A chain comfortably under the bound (10 hops) must still resolve — the bound isn't so tight
# it breaks a legitimate, if unusually long, chain.
F2_OUT="$WORKDIR/f2-out.txt"
F2_RC=0
( cd "$FIXTURE_F" && pantheon_base_pinned_read "$FIXTURE_F_SHA" "chain10.md" "$F2_OUT" ) 2>/dev/null || F2_RC=$?
if [[ "$F2_RC" -eq 0 ]]; then
  pass "a 10-hop symlink chain (well under the bound) resolves successfully"
else
  fail "a 10-hop symlink chain (well under the bound) failed to resolve (rc=$F2_RC)"
fi
if grep -q "CHAIN-END-CONTENT" "$F2_OUT" 2>/dev/null; then
  pass "a 10-hop symlink chain resolves to the final target's content"
else
  fail "a 10-hop symlink chain did not resolve to the final target's content"
fi

echo
echo "PASS: $PASS, FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
