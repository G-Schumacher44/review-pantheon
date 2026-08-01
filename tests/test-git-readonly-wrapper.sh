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

# ---------------------------------------------------------------------------
# Configured external-diff-driver bypass (Codex P1, round 2 — fresh evidence after the flag-
# refusal fix above). Rejecting `--ext-diff` as an explicit argument doesn't stop a CONFIGURED
# driver from firing on a plain, validation-passing `diff`/`show`: a `.gitattributes` entry
# assigning a custom driver plus a `diff.<name>.command` config entry activates an external
# helper without the model ever typing `--ext-diff`. This fixture reproduces exactly that
# (Codex's own repro shape) against a real helper script and asserts it never runs.
# ---------------------------------------------------------------------------
section "Configured external-diff-driver bypass (attributes + config, no --ext-diff flag)"

DRIVER_REPO="$(mktemp -d)"
git -C "$DRIVER_REPO" init -q
git -C "$DRIVER_REPO" config user.email "test@example.com"
git -C "$DRIVER_REPO" config user.name "test"
echo "a" > "$DRIVER_REPO/file.foo"
git -C "$DRIVER_REPO" add file.foo
git -C "$DRIVER_REPO" commit -q -m "first"
echo "b" > "$DRIVER_REPO/file.foo"
git -C "$DRIVER_REPO" commit -q -am "second"

echo "*.foo diff=evil" > "$DRIVER_REPO/.gitattributes"
HELPER_FIRED_MARKER="$(mktemp -u)"
rm -f "$HELPER_FIRED_MARKER"
HELPER_SCRIPT="$(mktemp)"
cat > "$HELPER_SCRIPT" <<EOF
#!/bin/sh
touch "$HELPER_FIRED_MARKER"
EOF
chmod +x "$HELPER_SCRIPT"
git -C "$DRIVER_REPO" config "diff.evil.command" "$HELPER_SCRIPT"

# Negative control, proving this fixture is live (not green-by-construction): RAW git, same
# fixture repo, same configured driver, MUST fire the marker via a plain diff.
rm -f "$HELPER_FIRED_MARKER"
( cd "$DRIVER_REPO" && git diff "HEAD~1...HEAD" >/dev/null 2>&1 )
if [[ -f "$HELPER_FIRED_MARKER" ]]; then
  pass "negative control: RAW git (no wrapper) DOES fire the configured diff driver on 'diff' — fixture is live"
else
  fail "negative control FAILED: raw git did not fire the configured diff driver at all — this fixture is not exercising anything, every 'did not fire' result below is meaningless"
fi

rm -f "$HELPER_FIRED_MARKER"
( cd "$DRIVER_REPO" && "$WRAPPER" diff "HEAD~1...HEAD" >/dev/null 2>&1 )
if [[ -f "$HELPER_FIRED_MARKER" ]]; then
  fail "configured external diff driver FIRED via a plain 'diff HEAD~1...HEAD' — --no-ext-diff/--no-textconv regression"
else
  pass "configured external diff driver did NOT fire — --no-ext-diff/--no-textconv forced by the wrapper closes it"
fi

( cd "$DRIVER_REPO" && "$WRAPPER" show HEAD >/dev/null 2>&1 )
if [[ -f "$HELPER_FIRED_MARKER" ]]; then
  fail "configured external diff driver FIRED via a plain 'show HEAD' — --no-ext-diff/--no-textconv regression"
else
  pass "'show HEAD' does not trigger the configured external diff driver either"
fi

rm -f "$HELPER_FIRED_MARKER" "$HELPER_SCRIPT"
rm -rf "$DRIVER_REPO"

# ---------------------------------------------------------------------------
# Index-write hygiene (Codex P2): `git status` performs an optional index refresh that writes
# `.git/index` by default, contradicting this tier's "never mutates the index" framing.
# GIT_OPTIONAL_LOCKS=0 (forced by the wrapper) disables that. Asserts the index's mtime is
# byte-for-byte unchanged (not just "close enough") after a wrapper-run `status`.
# ---------------------------------------------------------------------------
section "Index-write hygiene (status must not touch .git/index)"

LOCKS_REPO="$(mktemp -d)"
git -C "$LOCKS_REPO" init -q
git -C "$LOCKS_REPO" config user.email "test@example.com"
git -C "$LOCKS_REPO" config user.name "test"
echo "a" > "$LOCKS_REPO/file.txt"
git -C "$LOCKS_REPO" add file.txt
git -C "$LOCKS_REPO" commit -q -m "first"

# GNU coreutils `-f` means "filesystem mode" (a completely different flag from BSD/macOS
# stat's "-f <format>") — `stat -f %m FILE` on GNU does NOT error, it silently stats the
# filesystem instead of the file and prints an unrelated multi-line report, so a
# `stat -f %m || stat -c %Y` fallback (BSD-first) never triggers on Linux; the GNU form must be
# tried first here, with the BSD form as the fallback (which BSD's stat, lacking `-c` at all,
# correctly errors out of, triggering `-f` in the other order). Caught by this repo's own Linux
# CI runner — this file's dev loop is macOS, where the BSD-first order looked fine.
stat_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

before="$(stat_mtime "$LOCKS_REPO/.git/index")"
sleep 1.2
( cd "$LOCKS_REPO" && "$WRAPPER" status >/dev/null 2>&1 )
after="$(stat_mtime "$LOCKS_REPO/.git/index")"

if [[ "$before" == "$after" ]]; then
  pass "wrapper-run 'status' left .git/index's mtime unchanged (GIT_OPTIONAL_LOCKS=0 closes the optional-refresh write)"
else
  fail "wrapper-run 'status' changed .git/index's mtime ($before -> $after) — GIT_OPTIONAL_LOCKS regression"
fi

rm -rf "$LOCKS_REPO"

# ---------------------------------------------------------------------------
# Configured fsmonitor-hook bypass (Codex P1, round 3 — fresh evidence again, on TWO
# subcommands). A pathname-valued `core.fsmonitor` (git's own docs: the path to an external
# fsmonitor hook command) ran on a validation-passing `status`, and on plain `diff` too —
# GIT_OPTIONAL_LOCKS=0 does nothing to stop it, a different mechanism entirely. This fixture
# reproduces exactly that (a real marker-writing helper set as core.fsmonitor) against both
# subcommands and asserts it never runs.
# ---------------------------------------------------------------------------
section "Configured fsmonitor-hook bypass (core.fsmonitor, no model-supplied flag)"

FSMON_REPO="$(mktemp -d)"
git -C "$FSMON_REPO" init -q
git -C "$FSMON_REPO" config user.email "test@example.com"
git -C "$FSMON_REPO" config user.name "test"
echo "a" > "$FSMON_REPO/file.txt"
git -C "$FSMON_REPO" add file.txt
git -C "$FSMON_REPO" commit -q -m "first"
echo "b" >> "$FSMON_REPO/file.txt"
git -C "$FSMON_REPO" commit -q -am "second"

FSMON_MARKER="$(mktemp -u)"
rm -f "$FSMON_MARKER"
FSMON_HOOK="$(mktemp)"
cat > "$FSMON_HOOK" <<EOF
#!/bin/sh
touch "$FSMON_MARKER"
EOF
chmod +x "$FSMON_HOOK"
git -C "$FSMON_REPO" config core.fsmonitor "$FSMON_HOOK"

# Negative control, proving this fixture is live (not green-by-construction): RAW git, in this
# exact same fixture repo with the exact same hook configured, MUST fire the marker. If it
# didn't, the fixture setup itself would be broken and every "did NOT fire" assertion below
# would be meaningless (passing for the wrong reason — no wrapper needed to get that result).
rm -f "$FSMON_MARKER"
( cd "$FSMON_REPO" && git status >/dev/null 2>&1 )
if [[ -f "$FSMON_MARKER" ]]; then
  pass "negative control: RAW git (no wrapper) DOES fire the configured fsmonitor hook on 'status' — fixture is live"
else
  fail "negative control FAILED: raw git did not fire the configured fsmonitor hook at all — this fixture is not exercising anything, every 'did not fire' result below is meaningless"
fi

rm -f "$FSMON_MARKER"
( cd "$FSMON_REPO" && "$WRAPPER" status >/dev/null 2>&1 )
if [[ -f "$FSMON_MARKER" ]]; then
  fail "configured fsmonitor hook FIRED via a plain 'status' — core.fsmonitor=false override regression"
else
  pass "configured fsmonitor hook did NOT fire via 'status' — -c core.fsmonitor=false closes it"
fi

rm -f "$FSMON_MARKER"
( cd "$FSMON_REPO" && "$WRAPPER" diff "HEAD~1...HEAD" >/dev/null 2>&1 )
if [[ -f "$FSMON_MARKER" ]]; then
  fail "configured fsmonitor hook FIRED via 'diff HEAD~1...HEAD' — core.fsmonitor=false override regression"
else
  pass "configured fsmonitor hook did NOT fire via 'diff HEAD~1...HEAD' either"
fi

rm -f "$FSMON_MARKER" "$FSMON_HOOK"
rm -rf "$FSMON_REPO"

# ---------------------------------------------------------------------------
# Trace-output-sink env vars (Codex P2, round 5). git's own docs define GIT_TRACE (and its
# siblings) as trace-output sinks — set to an absolute path, git APPENDS trace records there on
# EVERY invocation, no flag or config needed, just an inherited environment variable. Reproduces
# Codex's exact repro shape: point GIT_TRACE at a tracked file inside the repo and assert it does
# NOT grow (a negative control isn't needed here — unlike the config-driven fixtures above,
# there's no separate "did the mechanism fire at all" question; a byte-count comparison on a
# real file directly proves whether the write happened).
# ---------------------------------------------------------------------------
section "Trace-output-sink env vars (GIT_TRACE and siblings must not write to a tracked file)"

TRACE_REPO="$(mktemp -d)"
git -C "$TRACE_REPO" init -q
git -C "$TRACE_REPO" config user.email "test@example.com"
git -C "$TRACE_REPO" config user.name "test"
echo "tracked content" > "$TRACE_REPO/tracked-file"
git -C "$TRACE_REPO" add tracked-file
git -C "$TRACE_REPO" commit -q -m "first"

TRACE_TARGET="$TRACE_REPO/tracked-file"
before_size="$(wc -c < "$TRACE_TARGET" | tr -d ' ')"
( cd "$TRACE_REPO" && GIT_TRACE="$TRACE_TARGET" "$WRAPPER" status >/dev/null 2>&1 )
after_size="$(wc -c < "$TRACE_TARGET" | tr -d ' ')"

if [[ "$before_size" == "$after_size" ]]; then
  pass "GIT_TRACE pointed at a tracked file: wrapper-run 'status' left it byte-for-byte unchanged"
else
  fail "GIT_TRACE pointed at a tracked file: wrapper-run 'status' grew it ($before_size -> $after_size bytes) — trace-sink regression"
fi

rm -rf "$TRACE_REPO"

# GIT_TRACE2_EVENT's directory-sink form (git docs: a directory value creates a per-process file
# inside it) is a distinct code path from GIT_TRACE's plain-file form above — worth its own
# fixture, with a negative control (raw git DOES create a file there) proving this one is live
# too, matching the pattern the config-driven fixtures above use.
TRACE2_REPO="$(mktemp -d)"
git -C "$TRACE2_REPO" init -q
git -C "$TRACE2_REPO" config user.email "test@example.com"
git -C "$TRACE2_REPO" config user.name "test"
echo "a" > "$TRACE2_REPO/f.txt"
git -C "$TRACE2_REPO" add f.txt
git -C "$TRACE2_REPO" commit -q -m "first"

TRACE2_MARKER_DIR_RAW="$(mktemp -d)"
( cd "$TRACE2_REPO" && GIT_TRACE2_EVENT="$TRACE2_MARKER_DIR_RAW" git status >/dev/null 2>&1 )
if [[ -n "$(ls -A "$TRACE2_MARKER_DIR_RAW" 2>/dev/null)" ]]; then
  pass "negative control: RAW git (no wrapper) DOES populate a GIT_TRACE2_EVENT-pointed directory — fixture is live"
else
  fail "negative control FAILED: raw git did not populate the GIT_TRACE2_EVENT directory at all — this fixture is not exercising anything"
fi

TRACE2_MARKER_DIR_WRAPPED="$(mktemp -d)"
( cd "$TRACE2_REPO" && GIT_TRACE2_EVENT="$TRACE2_MARKER_DIR_WRAPPED" "$WRAPPER" status >/dev/null 2>&1 )
if [[ -n "$(ls -A "$TRACE2_MARKER_DIR_WRAPPED" 2>/dev/null)" ]]; then
  fail "GIT_TRACE2_EVENT populated a directory via the wrapper — trace-sink regression"
else
  pass "GIT_TRACE2_EVENT did NOT populate a directory via the wrapper — GIT_TRACE2_EVENT unset closes it"
fi

rm -rf "$TRACE2_REPO" "$TRACE2_MARKER_DIR_RAW" "$TRACE2_MARKER_DIR_WRAPPED"

echo
echo "git-readonly-wrapper fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
