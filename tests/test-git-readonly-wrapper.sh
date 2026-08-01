#!/usr/bin/env bash
# tests/test-git-readonly-wrapper.sh — fixture test for cli/lib/pantheon-git-readonly.sh, the
# argv-validating read-only git wrapper (Codex P1 finding on the tiered-execution PR: a bare
# `Bash(git diff *)`-style permission-rule prefix has no understanding of git's own argument
# grammar, so it also permits `git diff --output=file` and `git diff --ext-diff` — neither
# read-only in any meaningful sense). This wrapper is the actual boundary; this test proves it
# refuses every hostile shape named in that finding (plus the general class it belongs to — any
# flag at all) and still accepts every legit invocation the personas are told to make.
#
# No test framework — plain bash, `bash tests/test-git-readonly-wrapper.sh` is the whole
# invocation (wired into .github/workflows/ci.yml and tests/test-setup-smoke.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/cli/lib/pantheon-git-readonly.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

section() { echo; echo "== $1 =="; }

section "Wrapper file itself"

if [[ -f "$WRAPPER" ]]; then
  pass "cli/lib/pantheon-git-readonly.sh exists"
else
  fail "cli/lib/pantheon-git-readonly.sh MISSING — cannot run any further checks"
  echo
  echo "git-readonly-wrapper fixtures: $PASS passed, $FAIL failed"
  exit 1
fi

if [[ -x "$WRAPPER" ]]; then
  pass "cli/lib/pantheon-git-readonly.sh is executable"
else
  fail "cli/lib/pantheon-git-readonly.sh is NOT executable"
fi

# ---------------------------------------------------------------------------
# Fixtures run against a REAL git repo (this checkout) so "legit" invocations exercise the real
# `exec git ...` tail, not just argv validation in isolation.
# ---------------------------------------------------------------------------

# refuse <name> <args...> — asserts the wrapper exits nonzero and prints its own
# "pantheon-git-readonly:" refusal prefix (not a bare git error, which would mean the hostile
# argv reached the real git binary instead of being caught by validation).
refuse() {
  local name="$1"; shift
  local out status
  out="$(cd "$ROOT" && "$WRAPPER" "$@" 2>&1)"
  status=$?
  if [[ $status -ne 0 ]] && grep -q '^pantheon-git-readonly:' <<<"$out"; then
    pass "$name: refused ($out)"
  else
    fail "$name: NOT refused (status=$status, output: $out)"
  fi
}

# accept <name> <args...> — asserts the wrapper exits 0 (the real git command it wraps
# succeeded) and its output does NOT carry the wrapper's own refusal prefix. Runs in $ROOT
# (this checkout) — fine for subcommands that don't need a specific ref to exist (status, bare
# log/show against HEAD).
accept() {
  local name="$1"; shift
  local out status
  out="$(cd "$ROOT" && "$WRAPPER" "$@" 2>&1)"
  status=$?
  if [[ $status -eq 0 ]] && ! grep -q '^pantheon-git-readonly:' <<<"$out"; then
    pass "$name: accepted (exit 0, real git ran)"
  else
    fail "$name: NOT accepted (status=$status, output: $out)"
  fi
}

# accept_in <dir> <name> <args...> — same as accept(), but runs in <dir> instead of $ROOT. Used
# for range-based fixtures (`HEAD~1...HEAD`) that need a guaranteed-real parent commit — $ROOT is
# whatever depth this checkout happens to be (a CI runner's default `actions/checkout@v4` is a
# shallow, single-commit clone, so `HEAD~1` doesn't exist there even though it does on a full
# local clone); a dedicated two-commit scratch repo makes this fixture depth-independent.
accept_in() {
  local dir="$1" name="$2"; shift 2
  local out status
  out="$(cd "$dir" && "$WRAPPER" "$@" 2>&1)"
  status=$?
  if [[ $status -eq 0 ]] && ! grep -q '^pantheon-git-readonly:' <<<"$out"; then
    pass "$name: accepted (exit 0, real git ran)"
  else
    fail "$name: NOT accepted (status=$status, output: $out)"
  fi
}

section "Hostile invocations — the exact vector Codex named"

refuse "git diff --output=<file> (documented by git itself as writing to a file)" \
  diff --output=/tmp/pantheon-wrapper-test-pwned
refuse "git diff --ext-diff (spawns an arbitrary external helper)" \
  diff --ext-diff
refuse "git show --ext-diff" \
  show --ext-diff HEAD
refuse "git log --output=<file>" \
  log --output=/tmp/pantheon-wrapper-test-pwned2

section "Hostile invocations — the general class (any flag at all, any subcommand)"

refuse "git diff -c core.pager=curl (global-config-shaped token as a diff arg)" \
  diff -c core.pager=curl
refuse "-c as the subcommand position itself (global-flag injection before a subcommand)" \
  -c core.pager=curl diff
refuse "disallowed subcommand: push" push origin main
refuse "disallowed subcommand: commit" commit -m pwned
refuse "disallowed subcommand: checkout" checkout -f
refuse "disallowed subcommand: config" config --global core.pager curl
refuse "empty-string subcommand" ""

zero_out="$(cd "$ROOT" && "$WRAPPER" 2>&1)"
zero_status=$?
if [[ $zero_status -ne 0 ]] && grep -q '^pantheon-git-readonly:' <<<"$zero_out"; then
  pass "zero arguments at all: refused ($zero_out)"
else
  fail "zero arguments at all: NOT refused (status=$zero_status, output: $zero_out)"
fi
refuse "git log --pager=less (pager override attempt)" log --pager=less
refuse "git show --textconv (external content filter)" show --textconv HEAD
refuse "git diff --exec-path=/tmp (relocates git's own helper search path)" diff --exec-path=/tmp

section "Legit invocations — exactly what DESIGN.md rule 1 tells personas to use"

accept "git status" status
accept "git log (bare, no flags)" log
accept "git log HEAD (bare ref, no flags)" log HEAD
accept "git show HEAD:README.md (ref:path)" show "HEAD:README.md"

# Range-based fixtures (`HEAD~1...HEAD`) run against a dedicated two-commit scratch repo, not
# $ROOT — see accept_in()'s own comment for why $ROOT's checkout depth can't be relied on here.
SCRATCH_REPO="$(mktemp -d)"
git -C "$SCRATCH_REPO" init -q
git -C "$SCRATCH_REPO" config user.email "test@example.com"
git -C "$SCRATCH_REPO" config user.name "test"
echo "first" > "$SCRATCH_REPO/file.txt"
git -C "$SCRATCH_REPO" add file.txt
git -C "$SCRATCH_REPO" commit -q -m "first commit"
echo "second" >> "$SCRATCH_REPO/file.txt"
git -C "$SCRATCH_REPO" commit -q -am "second commit"

accept_in "$SCRATCH_REPO" "git diff HEAD~1...HEAD (bare range)" diff "HEAD~1...HEAD"
accept_in "$SCRATCH_REPO" "git diff HEAD~1...HEAD -- file.txt (range + -- pathspec separator + path)" \
  diff "HEAD~1...HEAD" -- file.txt

rm -rf "$SCRATCH_REPO"

echo
echo "git-readonly-wrapper fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
