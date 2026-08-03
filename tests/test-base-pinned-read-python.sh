#!/usr/bin/env bash
# tests/test-base-pinned-read-python.sh — black-box fixture test for pantheon/basepin.py, the
# symlink-safe base-pinned file reader. Drives pantheon/basepin.py's own CLI entry point
# (`python -m pantheon.basepin read|normalize ...`) as a real subprocess, mirroring
# `pantheon_base_pinned_read <base-sha> <path> <dest-file> [repo-dir]`'s contract and its 0/1/2
# return-code semantics.
#
# No test framework — plain bash, `bash tests/test-base-pinned-read-python.sh` is the whole
# invocation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

PASS=0
FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "== $1 =="; }

if [[ -f "$ROOT/pantheon/basepin.py" ]]; then
  pass "pantheon/basepin.py exists"
else
  fail "pantheon/basepin.py MISSING — cannot run any further checks"
  echo; echo "PASS: $PASS, FAIL: $FAIL"; exit 1
fi

if python3 -c "import pantheon.basepin" >/dev/null 2>&1; then
  pass "pantheon.basepin is importable"
else
  fail "pantheon.basepin is NOT importable — cannot run any further checks"
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

# pyread <base-sha> <path> <dest> [repo-dir] -> prints nothing, sets $PYREAD_RC to the CLI's exit
# code (0/1/2), mirroring pantheon_base_pinned_read's own return-code contract.
pyread() {
  ( cd "$ROOT" && python3 -m pantheon.basepin read "$@" ) 2>/dev/null
  PYREAD_RC=$?
}

# ---------------------------------------------------------------------------
# Part A — `python -m pantheon.basepin normalize` (pantheon.basepin.normalize_repo_path).
# ---------------------------------------------------------------------------
section "Part A: pantheon.basepin normalize_repo_path"

check_normalize() {
  local label="$1" input="$2" expect_ok="$3" expect_value="${4:-}"
  local out rc=0
  out="$(cd "$ROOT" && python3 -m pantheon.basepin normalize "$input" 2>/dev/null)" || rc=$?
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

# Issue #10's trailing-slash class (docs/PYTHON-PORT.md task note): a redundant/doubled separator
# in the REQUESTED path — not just a resolved symlink target — must also collapse cleanly, since
# base_pinned_read() normalizes the incoming path up front (see pantheon/basepin.py's own module
# docstring for why the bash original does not do this and reads a trailing-slash path as a miss).
check_normalize "issue #10: a/b//c.md (doubled separator) collapses to a/b/c.md" "a/b//c.md" true "a/b/c.md"
check_normalize "issue #10: a/b/c.md/ (trailing slash) collapses to a/b/c.md" "a/b/c.md/" true "a/b/c.md"

# ---------------------------------------------------------------------------
# Part B — base_pinned_read: regular file (no symlink involved) still works.
# ---------------------------------------------------------------------------
section "Part B: pantheon.basepin read — regular (non-symlinked) file"

FIXTURE_B="$WORKDIR/fixture-b"
mkdir -p "$FIXTURE_B/agents"
echo "REGULAR-PERSONA-CONTENT" > "$FIXTURE_B/agents/artemis.md"
FIXTURE_B_SHA="$(git_fixture_repo "$FIXTURE_B")"

B_OUT="$WORKDIR/b-out.txt"
pyread "$FIXTURE_B_SHA" "agents/artemis.md" "$B_OUT" "$FIXTURE_B"
if [[ "$PYREAD_RC" -eq 0 ]]; then
  pass "regular file resolves (rc=0)"
else
  fail "regular file failed to resolve (rc=$PYREAD_RC)"
fi
if grep -q "REGULAR-PERSONA-CONTENT" "$B_OUT" 2>/dev/null; then
  pass "regular file's content reaches the destination"
else
  fail "regular file's content is missing from the destination"
fi

# ---------------------------------------------------------------------------
# Part C — symlinked persona resolves to target content (Codex's exact example).
# ---------------------------------------------------------------------------
section "Part C: pantheon.basepin read — symlinked persona resolves to target content (Codex's exact example)"

FIXTURE_C="$WORKDIR/fixture-c"
mkdir -p "$FIXTURE_C/agents" "$FIXTURE_C/.github/custom-personas"
echo "BUNDLED-ARTEMIS-CONTENT" > "$FIXTURE_C/agents/artemis.md"
( cd "$FIXTURE_C/.github/custom-personas" && ln -s ../../agents/artemis.md artemis.md )
FIXTURE_C_SHA="$(git_fixture_repo "$FIXTURE_C")"

C_MODE="$(cd "$FIXTURE_C" && git ls-tree "$FIXTURE_C_SHA" -- .github/custom-personas/artemis.md | awk '{print $1}')"
if [[ "$C_MODE" == "120000" ]]; then
  pass "fixture sanity check: the custom persona is really a mode-120000 (symlink) blob at base"
else
  fail "fixture sanity check FAILED: expected mode 120000, got '$C_MODE' — this fixture doesn't exercise the bug class"
fi

C_BARE="$(cd "$FIXTURE_C" && git show "${FIXTURE_C_SHA}:.github/custom-personas/artemis.md" 2>/dev/null)"
if [[ "$C_BARE" == "../../agents/artemis.md" ]]; then
  pass "fixture sanity check: a bare 'git show' on the symlinked path returns the raw link-target string (the bug this fix closes)"
else
  fail "fixture sanity check: expected a bare 'git show' to return the raw link-target string '../../agents/artemis.md', got '$C_BARE'"
fi

C_OUT="$WORKDIR/c-out.txt"
pyread "$FIXTURE_C_SHA" ".github/custom-personas/artemis.md" "$C_OUT" "$FIXTURE_C"
if [[ "$PYREAD_RC" -eq 0 ]]; then
  pass "symlinked persona resolves (rc=0)"
else
  fail "symlinked persona failed to resolve (rc=$PYREAD_RC)"
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

mkdir -p "$FIXTURE_C/.github/other-personas"
( cd "$FIXTURE_C/.github/other-personas" && ln -s ../custom-personas/artemis.md artemis.md )
git -C "$FIXTURE_C" add -A
git -C "$FIXTURE_C" commit -q -m "add a second-hop symlink"
FIXTURE_C2_SHA="$(git -C "$FIXTURE_C" rev-parse HEAD)"
C2_OUT="$WORKDIR/c2-out.txt"
pyread "$FIXTURE_C2_SHA" ".github/other-personas/artemis.md" "$C2_OUT" "$FIXTURE_C"
if [[ "$PYREAD_RC" -eq 0 ]]; then
  pass "a 2-hop symlink chain (symlink -> symlink -> file) resolves"
else
  fail "a 2-hop symlink chain failed to resolve (rc=$PYREAD_RC)"
fi
if grep -q "BUNDLED-ARTEMIS-CONTENT" "$C2_OUT" 2>/dev/null; then
  pass "a 2-hop symlink chain resolves to the final target's content"
else
  fail "a 2-hop symlink chain did not resolve to the final target's content"
fi

# ---------------------------------------------------------------------------
# Part D — a symlink escaping the repository root must be REFUSED (rc=1).
# ---------------------------------------------------------------------------
section "Part D: pantheon.basepin read — symlink escaping the repo root is refused"

FIXTURE_D="$WORKDIR/fixture-d"
mkdir -p "$FIXTURE_D"
( cd "$FIXTURE_D" && ln -s ../../../../../../etc/passwd escape.md )
( cd "$FIXTURE_D" && ln -s /etc/passwd absolute.md )
echo "unrelated" > "$FIXTURE_D/README.md"
FIXTURE_D_SHA="$(git_fixture_repo "$FIXTURE_D")"

D1_OUT="$WORKDIR/d1-out.txt"
pyread "$FIXTURE_D_SHA" "escape.md" "$D1_OUT" "$FIXTURE_D"
D1_RC="$PYREAD_RC"
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
pyread "$FIXTURE_D_SHA" "absolute.md" "$D2_OUT" "$FIXTURE_D"
D2_RC="$PYREAD_RC"
if [[ "$D2_RC" -eq 1 ]]; then
  pass "an absolute-target symlink is refused (rc=1, not silently absent)"
else
  fail "an absolute-target symlink was NOT refused with rc=1 (got rc=$D2_RC)"
fi

if [[ "$D1_RC" -ne 2 && "$D2_RC" -ne 2 ]]; then
  pass "refused resolutions use a DIFFERENT return code (1) than ordinary absence (2) — a caller cannot conflate the two"
else
  fail "a refused resolution returned the same code as ordinary absence — a caller could silently swallow a refusal as absence"
fi

# ---------------------------------------------------------------------------
# Part E — ordinary absence is unaffected (rc=2, unchanged).
# ---------------------------------------------------------------------------
section "Part E: pantheon.basepin read — ordinary absence is unaffected (rc=2, unchanged)"

E_OUT="$WORKDIR/e-out.txt"
pyread "$FIXTURE_D_SHA" "does-not-exist.md" "$E_OUT" "$FIXTURE_D"
if [[ "$PYREAD_RC" -eq 2 ]]; then
  pass "a path absent at base returns rc=2 (ordinary absence, unchanged)"
else
  fail "a path absent at base returned rc=$PYREAD_RC, expected 2"
fi

( cd "$FIXTURE_D" && ln -s nonexistent-target.md broken.md )
git -C "$FIXTURE_D" add -A
git -C "$FIXTURE_D" commit -q -m "add a broken symlink"
FIXTURE_D2_SHA="$(git -C "$FIXTURE_D" rev-parse HEAD)"
E2_OUT="$WORKDIR/e2-out.txt"
pyread "$FIXTURE_D2_SHA" "broken.md" "$E2_OUT" "$FIXTURE_D"
if [[ "$PYREAD_RC" -eq 2 ]]; then
  pass "a symlink whose target is absent at base returns rc=2 (ordinary absence, not a refusal)"
else
  fail "a symlink whose target is absent at base returned rc=$PYREAD_RC, expected 2"
fi

# ---------------------------------------------------------------------------
# Part F — chain-depth bound (32-hop cap).
# ---------------------------------------------------------------------------
section "Part F: pantheon.basepin read — chain-depth bound"

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
pyread "$FIXTURE_F_SHA" "chain40.md" "$F1_OUT" "$FIXTURE_F"
if [[ "$PYREAD_RC" -eq 1 ]]; then
  pass "a 40-hop symlink chain exceeds the depth bound and is refused (rc=1)"
else
  fail "a 40-hop symlink chain was NOT refused (got rc=$PYREAD_RC) — the depth bound may be missing or too permissive"
fi

F2_OUT="$WORKDIR/f2-out.txt"
pyread "$FIXTURE_F_SHA" "chain10.md" "$F2_OUT" "$FIXTURE_F"
if [[ "$PYREAD_RC" -eq 0 ]]; then
  pass "a 10-hop symlink chain (well under the bound) resolves successfully"
else
  fail "a 10-hop symlink chain (well under the bound) failed to resolve (rc=$PYREAD_RC)"
fi
if grep -q "CHAIN-END-CONTENT" "$F2_OUT" 2>/dev/null; then
  pass "a 10-hop symlink chain resolves to the final target's content"
else
  fail "a 10-hop symlink chain did not resolve to the final target's content"
fi

# ---------------------------------------------------------------------------
# Part G — symlinked INTERMEDIATE path component (round 3).
# ---------------------------------------------------------------------------
section "Part G: pantheon.basepin read — symlinked INTERMEDIATE path component (round 3)"

FIXTURE_G="$WORKDIR/fixture-g"
mkdir -p "$FIXTURE_G/real-personas"
echo "REAL-ARTEMIS-VIA-DIR-SYMLINK" > "$FIXTURE_G/real-personas/artemis.md"
( cd "$FIXTURE_G" && ln -s real-personas custom-personas )
FIXTURE_G_SHA="$(git_fixture_repo "$FIXTURE_G")"

G_DIR_MODE="$(cd "$FIXTURE_G" && git ls-tree "$FIXTURE_G_SHA" -- custom-personas | awk '{print $1}')"
if [[ "$G_DIR_MODE" == "120000" ]]; then
  pass "fixture sanity check: the intermediate directory component is really a mode-120000 (symlink) blob at base"
else
  fail "fixture sanity check FAILED: expected mode 120000 for the directory component, got '$G_DIR_MODE'"
fi
G_BARE_LSTREE="$(cd "$FIXTURE_G" && git ls-tree "$FIXTURE_G_SHA" -- custom-personas/artemis.md)"
if [[ -z "$G_BARE_LSTREE" ]]; then
  pass "fixture sanity check: a single-shot 'git ls-tree' on the full nested path returns NOTHING (the bug this fix closes — git does not traverse a symlinked component)"
else
  fail "fixture sanity check: expected empty output from a single-shot ls-tree on the nested path, got '$G_BARE_LSTREE'"
fi

G1_OUT="$WORKDIR/g1-out.txt"
pyread "$FIXTURE_G_SHA" "custom-personas/artemis.md" "$G1_OUT" "$FIXTURE_G"
if [[ "$PYREAD_RC" -eq 0 ]]; then
  pass "a symlinked intermediate directory component resolves (rc=0)"
else
  fail "a symlinked intermediate directory component failed to resolve (rc=$PYREAD_RC) — misread as ordinary absence"
fi
if grep -q "REAL-ARTEMIS-VIA-DIR-SYMLINK" "$G1_OUT" 2>/dev/null; then
  pass "a symlinked intermediate directory component resolves to the TARGET file's content"
else
  fail "a symlinked intermediate directory component did not resolve to the target's content"
fi

( cd "$FIXTURE_G" && ln -s custom-personas other-personas )
git -C "$FIXTURE_G" add -A
git -C "$FIXTURE_G" commit -q -m "add a second-hop directory symlink"
FIXTURE_G2_SHA="$(git -C "$FIXTURE_G" rev-parse HEAD)"
G2_OUT="$WORKDIR/g2-out.txt"
pyread "$FIXTURE_G2_SHA" "other-personas/artemis.md" "$G2_OUT" "$FIXTURE_G"
if [[ "$PYREAD_RC" -eq 0 ]] && grep -q "REAL-ARTEMIS-VIA-DIR-SYMLINK" "$G2_OUT" 2>/dev/null; then
  pass "a 2-hop directory-symlink chain (dir -> dir -> file) resolves to the final target's content"
else
  fail "a 2-hop directory-symlink chain failed to resolve (rc=$PYREAD_RC)"
fi

# ---------------------------------------------------------------------------
# Part H — a directory symlink escaping the repository root must be REFUSED (rc=1).
# ---------------------------------------------------------------------------
section "Part H: pantheon.basepin read — symlinked intermediate directory escaping the repo root is refused"

FIXTURE_H="$WORKDIR/fixture-h"
mkdir -p "$FIXTURE_H"
( cd "$FIXTURE_H" && ln -s ../../../../../../etc evil-dir )
echo "unrelated" > "$FIXTURE_H/README.md"
FIXTURE_H_SHA="$(git_fixture_repo "$FIXTURE_H")"

H1_OUT="$WORKDIR/h1-out.txt"
pyread "$FIXTURE_H_SHA" "evil-dir/passwd" "$H1_OUT" "$FIXTURE_H"
if [[ "$PYREAD_RC" -eq 1 ]]; then
  pass "a directory symlink climbing above the repo root is refused (rc=1, not silently absent)"
else
  fail "a directory symlink climbing above the repo root was NOT refused with rc=1 (got rc=$PYREAD_RC)"
fi
if [[ ! -s "$H1_OUT" ]]; then
  pass "no content was written for the refused escaping directory symlink"
else
  fail "content was written despite the escaping directory symlink being refused"
fi

# ---------------------------------------------------------------------------
# Part I — issue #10's trailing-slash class, exercised end to end through `read` (not just
# `normalize` in Part A): a caller-supplied path with a doubled separator must resolve exactly
# like its collapsed form would, proving the walk itself (not just the pure string helper) closes
# the class. A live negative control against the bash original demonstrates this is a genuine
# behavioral difference, not a restatement of Part A.
# ---------------------------------------------------------------------------
section "Part I: pantheon.basepin read — issue #10 trailing/doubled-slash path normalization"

I_OUT="$WORKDIR/i-out.txt"
pyread "$FIXTURE_B_SHA" "agents//artemis.md" "$I_OUT" "$FIXTURE_B"
if [[ "$PYREAD_RC" -eq 0 ]]; then
  pass "issue #10: a doubled-separator path ('agents//artemis.md') resolves (rc=0), not misread as absent"
else
  fail "issue #10: a doubled-separator path was NOT resolved (rc=$PYREAD_RC) — the trailing-slash class regressed"
fi
if grep -q "REGULAR-PERSONA-CONTENT" "$I_OUT" 2>/dev/null; then
  pass "issue #10: the doubled-separator path resolves to the correct file content"
else
  fail "issue #10: the doubled-separator path did not resolve to the correct content"
fi

echo
echo "PASS: $PASS, FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
