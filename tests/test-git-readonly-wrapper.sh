#!/usr/bin/env bash
# tests/test-git-readonly-wrapper.sh — fixture test for pantheon/execution.py's `wrapper` CLI
# entry point (`python -m pantheon.execution wrapper ...`), the argv-validating read-only git
# wrapper (Codex P1 finding on the tiered-execution PR: a bare `Bash(git diff *)`-style
# permission-rule prefix has no understanding of git's own argument grammar, so it also permits
# `git diff --output=file` and `git diff --ext-diff` — neither read-only in any meaningful
# sense). This wrapper is the actual boundary; this test proves it refuses every hostile shape
# named in that finding (plus the general class it belongs to — any flag at all) and still
# accepts every legit invocation the personas are told to make.
#
# No test framework — plain bash, `bash tests/test-git-readonly-wrapper.sh` is the whole
# invocation (wired into .github/workflows/ci.yml and tests/test-setup-smoke.sh).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WRAPPER_CMD=(python3 -m pantheon.execution wrapper)
SRC_FILE="$ROOT/pantheon/execution.py"
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

section() { echo; echo "== $1 =="; }

section "Wrapper implementation itself"

if [[ -f "$SRC_FILE" ]]; then
  pass "pantheon/execution.py exists"
else
  fail "pantheon/execution.py MISSING — cannot run any further checks"
  echo
  echo "git-readonly-wrapper fixtures: $PASS passed, $FAIL failed"
  exit 1
fi

if python3 -c "import pantheon.execution" >/dev/null 2>&1; then
  pass "pantheon.execution is importable (python -m pantheon.execution wrapper ... is a valid CLI target)"
else
  fail "pantheon.execution is NOT importable — cannot run any further checks"
  echo
  echo "git-readonly-wrapper fixtures: $PASS passed, $FAIL failed"
  exit 1
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
  out="$(cd "$ROOT" && "${WRAPPER_CMD[@]}" "$@" 2>&1)"
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
  out="$(cd "$ROOT" && "${WRAPPER_CMD[@]}" "$@" 2>&1)"
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
  out="$(cd "$dir" && "${WRAPPER_CMD[@]}" "$@" 2>&1)"
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

zero_out="$(cd "$ROOT" && "${WRAPPER_CMD[@]}" 2>&1)"
zero_status=$?
if [[ $zero_status -ne 0 ]] && grep -q '^pantheon-git-readonly:' <<<"$zero_out"; then
  pass "zero arguments at all: refused ($zero_out)"
else
  fail "zero arguments at all: NOT refused (status=$zero_status, output: $zero_out)"
fi
refuse "git log --pager=less (pager override attempt)" log --pager=less
refuse "git show --textconv (external content filter)" show --textconv HEAD
refuse "git diff --exec-path=/tmp (relocates git's own helper search path)" diff --exec-path=/tmp

section "Hostile invocations — diff without a range (working-tree-touching forms)"

refuse "bare 'diff' (no arguments — compares working tree to index)" diff
refuse "'diff HEAD' (single ref, no range — compares working tree to that ref)" diff HEAD
refuse "'diff -- README.md' (no range, path only — still working-tree-touching)" diff -- README.md
refuse "'diff --' (bare caller-supplied pathspec separator, no other args)" diff --

section "Hostile invocations — caller-supplied '--' (Codex round 2 on issue #7)"

refuse "'diff -- <range>' (leading '--' shifts a validated range into pathspec position)" \
  diff -- "HEAD~1...HEAD"
refuse "'show -- HEAD' (caller-supplied '--' refused for every subcommand, not just diff)" \
  show -- HEAD
refuse "'log -- HEAD' (same, on log)" log -- HEAD
refuse "'status --' (same, on status)" status --

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

# Round 2 (Codex, issue #7): the 'range + -- pathspec separator + path' form this suite used to
# accept is now REFUSED outright — diff takes exactly one argument and the caller can never supply
# '--' at all (see the wrapper's EXEC/WRITE-SURFACE MATRIX 'caller-supplied --' row for why: a
# validated range re-forwarded alongside a caller-supplied '--' gets parsed by real git as a
# pathspec, not a revision, even though both sides independently resolve as real commits).
refuse_in() {
  local dir="$1" name="$2"; shift 2
  local out status
  out="$(cd "$dir" && "${WRAPPER_CMD[@]}" "$@" 2>&1)"
  status=$?
  if [[ $status -ne 0 ]] && grep -q '^pantheon-git-readonly:' <<<"$out"; then
    pass "$name: refused ($out)"
  else
    fail "$name: NOT refused (status=$status, output: $out)"
  fi
}
refuse_in "$SCRATCH_REPO" "git diff HEAD~1...HEAD -- file.txt (range + -- pathspec separator + path — no longer supported)" \
  diff "HEAD~1...HEAD" -- file.txt
refuse_in "$SCRATCH_REPO" "git diff HEAD~1...HEAD file.txt (range + a second positional, no '--' — still refused, diff takes exactly one argument)" \
  diff "HEAD~1...HEAD" file.txt

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
( cd "$DRIVER_REPO" && "${WRAPPER_CMD[@]}" diff "HEAD~1...HEAD" >/dev/null 2>&1 )
if [[ -f "$HELPER_FIRED_MARKER" ]]; then
  fail "configured external diff driver FIRED via a plain 'diff HEAD~1...HEAD' — --no-ext-diff/--no-textconv regression"
else
  pass "configured external diff driver did NOT fire — --no-ext-diff/--no-textconv forced by the wrapper closes it"
fi

( cd "$DRIVER_REPO" && "${WRAPPER_CMD[@]}" show HEAD >/dev/null 2>&1 )
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
( cd "$LOCKS_REPO" && "${WRAPPER_CMD[@]}" status >/dev/null 2>&1 )
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
( cd "$FSMON_REPO" && "${WRAPPER_CMD[@]}" status >/dev/null 2>&1 )
if [[ -f "$FSMON_MARKER" ]]; then
  fail "configured fsmonitor hook FIRED via a plain 'status' — core.fsmonitor=false override regression"
else
  pass "configured fsmonitor hook did NOT fire via 'status' — -c core.fsmonitor=false closes it"
fi

rm -f "$FSMON_MARKER"
( cd "$FSMON_REPO" && "${WRAPPER_CMD[@]}" diff "HEAD~1...HEAD" >/dev/null 2>&1 )
if [[ -f "$FSMON_MARKER" ]]; then
  fail "configured fsmonitor hook FIRED via 'diff HEAD~1...HEAD' — core.fsmonitor=false override regression"
else
  pass "configured fsmonitor hook did NOT fire via 'diff HEAD~1...HEAD' either"
fi

rm -f "$FSMON_MARKER" "$FSMON_HOOK"
rm -rf "$FSMON_REPO"

# ---------------------------------------------------------------------------
# Configured clean/smudge filter bypass (Codex P1, round 6). A `filter.<name>.clean` command
# (gitattributes' clean-filter mechanism — distinct from the ext-diff/textconv machinery closed
# above) converts a working-tree file's content before git compares it — but ONLY when the
# comparison actually touches the working tree (a bare `diff` or `diff <single-ref>`), never for
# a blob-to-blob range comparison. This fixture proves both halves: the filter DOES fire via the
# working-tree-touching forms this wrapper now refuses outright (covered by the "Hostile
# invocations — diff without a range" section above), and does NOT fire via the range form this
# wrapper still allows, even with the exact same filter configured in the exact same repo.
# ---------------------------------------------------------------------------
section "Configured clean/smudge filter bypass (working-tree-touching diff forms vs. a proper range)"

FILTER_REPO="$(mktemp -d)"
git -C "$FILTER_REPO" init -q
git -C "$FILTER_REPO" config user.email "test@example.com"
git -C "$FILTER_REPO" config user.name "test"
echo "a" > "$FILTER_REPO/file.dat"
git -C "$FILTER_REPO" add file.dat
git -C "$FILTER_REPO" commit -q -m "first"
echo "b" > "$FILTER_REPO/file.dat"
git -C "$FILTER_REPO" commit -q -am "second"

FILTER_MARKER="$(mktemp -u)"
rm -f "$FILTER_MARKER"
FILTER_SCRIPT="$(mktemp)"
cat > "$FILTER_SCRIPT" <<EOF
#!/bin/sh
touch "$FILTER_MARKER"
cat
EOF
chmod +x "$FILTER_SCRIPT"
git -C "$FILTER_REPO" config "filter.evilclean.clean" "$FILTER_SCRIPT"
echo "*.dat filter=evilclean" > "$FILTER_REPO/.gitattributes"
echo "modified working-tree content" > "$FILTER_REPO/file.dat"

# Negative control: RAW git, same repo, same filter, a bare 'diff' (working-tree-touching) MUST
# fire the marker — proving the fixture is live.
rm -f "$FILTER_MARKER"
( cd "$FILTER_REPO" && git diff >/dev/null 2>&1 )
if [[ -f "$FILTER_MARKER" ]]; then
  pass "negative control: RAW git (no wrapper) DOES fire the configured clean filter via a bare 'diff' — fixture is live"
else
  fail "negative control FAILED: raw git did not fire the configured clean filter at all — this fixture is not exercising anything"
fi

# The wrapper refuses the working-tree-touching form outright (see the "Hostile invocations —
# diff without a range" section above) — this just re-confirms the filter never runs as a
# consequence, using the same live repo/filter as the negative control above.
rm -f "$FILTER_MARKER"
( cd "$FILTER_REPO" && "${WRAPPER_CMD[@]}" diff >/dev/null 2>&1 ) || true
if [[ -f "$FILTER_MARKER" ]]; then
  fail "configured clean filter FIRED via the wrapper's bare 'diff' — should have been refused before git ever ran"
else
  pass "wrapper's bare 'diff' refusal means the configured clean filter never gets a chance to fire"
fi

# The range form the wrapper DOES allow must not trigger the filter either — it's a blob-to-blob
# comparison, never touching the (dirty) working-tree file the filter would otherwise convert.
rm -f "$FILTER_MARKER"
( cd "$FILTER_REPO" && "${WRAPPER_CMD[@]}" diff "HEAD~1...HEAD" >/dev/null 2>&1 )
if [[ -f "$FILTER_MARKER" ]]; then
  fail "configured clean filter FIRED via the wrapper's range-form 'diff HEAD~1...HEAD' — blob-to-blob diff should never touch the filter"
else
  pass "wrapper's range-form 'diff HEAD~1...HEAD' does not trigger the configured clean filter (blob-to-blob, no working-tree involvement)"
fi

rm -f "$FILTER_MARKER" "$FILTER_SCRIPT"
rm -rf "$FILTER_REPO"

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
( cd "$TRACE_REPO" && GIT_TRACE="$TRACE_TARGET" "${WRAPPER_CMD[@]}" status >/dev/null 2>&1 )
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
( cd "$TRACE2_REPO" && GIT_TRACE2_EVENT="$TRACE2_MARKER_DIR_WRAPPED" "${WRAPPER_CMD[@]}" status >/dev/null 2>&1 )
if [[ -n "$(ls -A "$TRACE2_MARKER_DIR_WRAPPED" 2>/dev/null)" ]]; then
  fail "GIT_TRACE2_EVENT populated a directory via the wrapper — trace-sink regression"
else
  pass "GIT_TRACE2_EVENT did NOT populate a directory via the wrapper — GIT_TRACE2_EVENT unset closes it"
fi

rm -rf "$TRACE2_REPO" "$TRACE2_MARKER_DIR_RAW" "$TRACE2_MARKER_DIR_WRAPPED"

# ---------------------------------------------------------------------------
# `..`-substring range spoofed by a same-named path (issue #7 checklist item 3 / Codex P1 on PR
# #5). The pre-fix wrapper's diff-range check was a substring test (`*..*`) — it accepted the
# STRING "foo..bar" as a "range" whether or not "foo" and "bar" were real revisions. A tracked
# working-tree file literally named `foo..bar`, with a configured clean filter, exploits exactly
# that: git's own disambiguation rule falls back to treating a token that doesn't resolve as a
# revision as a PATHSPEC when it names an existing path, so `diff foo..bar` becomes a working-tree
# diff of that one file — reopening the clean-filter path the original `..`-substring check was
# meant to close in the first place. The fix replaces the substring check with real revspec
# validation (`git rev-parse --verify --quiet <side>^{commit}` on both sides): "foo" and "bar"
# don't resolve to commits, so the wrapper refuses the whole invocation before git ever runs.
# ---------------------------------------------------------------------------
section "'..'-substring range spoofed by a same-named path (foo..bar as a tracked file + clean filter)"

SPOOF_REPO="$(mktemp -d)"
git -C "$SPOOF_REPO" init -q
git -C "$SPOOF_REPO" config user.email "test@example.com"
git -C "$SPOOF_REPO" config user.name "test"
printf 'a\n' > "$SPOOF_REPO/foo..bar"
git -C "$SPOOF_REPO" add -- "foo..bar"
git -C "$SPOOF_REPO" commit -q -m first

SPOOF_MARKER="$(mktemp -u)"
rm -f "$SPOOF_MARKER"
SPOOF_SCRIPT="$(mktemp)"
cat > "$SPOOF_SCRIPT" <<EOF
#!/bin/sh
touch "$SPOOF_MARKER"
cat
EOF
chmod +x "$SPOOF_SCRIPT"
git -C "$SPOOF_REPO" config "filter.evilspoof.clean" "$SPOOF_SCRIPT"
echo "foo..bar filter=evilspoof" > "$SPOOF_REPO/.gitattributes"
printf 'modified working-tree content\n' > "$SPOOF_REPO/foo..bar"

# Negative control: RAW git, same repo, same filter, `diff foo..bar` (git falls back to treating
# the unparseable "foo..bar" revision as the existing same-named pathspec) MUST fire the marker —
# proving the fixture is live, and reproducing exactly what the pre-fix wrapper's `*..*` substring
# check would have let straight through (the check has no idea "foo..bar" fails to resolve as a
# revision — it only sees the substring and accepts it, then forwards it verbatim to real git,
# which is precisely this raw-git call).
rm -f "$SPOOF_MARKER"
( cd "$SPOOF_REPO" && git diff "foo..bar" >/dev/null 2>&1 )
if [[ -f "$SPOOF_MARKER" ]]; then
  pass "negative control: RAW git (no wrapper) treats 'foo..bar' as the same-named PATH and fires the configured clean filter — fixture is live, and this is exactly what the pre-fix substring-only check would have forwarded to"
else
  fail "negative control FAILED: raw git did not fire the configured clean filter via 'diff foo..bar' at all — this fixture is not exercising anything, every assertion below is meaningless"
fi

# The current (fixed) wrapper must REFUSE this outright — "foo" and "bar" don't resolve to real
# commits via 'git rev-parse --verify --quiet', so it never reaches real git at all.
rm -f "$SPOOF_MARKER"
refuse_out="$(cd "$SPOOF_REPO" && "${WRAPPER_CMD[@]}" diff "foo..bar" 2>&1)"
refuse_status=$?
if [[ $refuse_status -ne 0 ]] && grep -q '^pantheon-git-readonly:' <<<"$refuse_out" && [[ ! -f "$SPOOF_MARKER" ]]; then
  pass "wrapper refuses 'diff foo..bar' (a tracked path, not a real revision range) before git ever runs — clean filter never fires ($refuse_out)"
else
  fail "wrapper did NOT refuse 'diff foo..bar' as expected (status=$refuse_status, marker present=$([[ -f "$SPOOF_MARKER" ]] && echo yes || echo no), output: $refuse_out) — '..'-substring-range regression"
fi

rm -f "$SPOOF_MARKER" "$SPOOF_SCRIPT"
rm -rf "$SPOOF_REPO"

# ---------------------------------------------------------------------------
# Caller-supplied '--' shifts a REVSPEC-VALIDATED range into pathspec position (Codex round 2 on
# issue #7, found against this PR's own round-1 fix). Revspec-verifying both sides of a range is
# NOT sufficient on its own: `git diff -- A..B`, forwarded verbatim by the round-1 wrapper, gets
# parsed by real git as a PURE PATHSPEC (because of the leading `--`), not as a revision — even
# though A and B independently resolve as real commits via `rev-parse --verify`. A tracked
# working-tree file literally named `<A>..<B>` (trivially constructable: any two real ancestor
# commit SHAs) plus a configured clean filter reopens the exact clean-filter RCE this wrapper
# exists to close, reached through argument POSITION (a caller-supplied `--`) rather than argument
# CONTENT. Fixed by never letting the caller supply `--` at all (any subcommand) and capping diff
# at exactly one positional argument, so there is no pathspec slot for the wrapper's own trailing
# `--` (appended after the validated range on exec) to ever scope onto.
# ---------------------------------------------------------------------------
section "Caller-supplied '--' shifts a validated range into pathspec position (Codex round 2)"

BOUNDARY_REPO="$(mktemp -d)"
git -C "$BOUNDARY_REPO" init -q
git -C "$BOUNDARY_REPO" config user.email "test@example.com"
git -C "$BOUNDARY_REPO" config user.name "test"
printf 'a\n' > "$BOUNDARY_REPO/a.txt"
git -C "$BOUNDARY_REPO" add a.txt
git -C "$BOUNDARY_REPO" commit -q -m first
BOUNDARY_SHA1="$(git -C "$BOUNDARY_REPO" rev-parse HEAD)"
printf 'b\n' > "$BOUNDARY_REPO/a.txt"
git -C "$BOUNDARY_REPO" commit -q -am second
BOUNDARY_SHA2="$(git -C "$BOUNDARY_REPO" rev-parse HEAD)"

BOUNDARY_SPOOF_PATH="${BOUNDARY_SHA1}..${BOUNDARY_SHA2}"
printf 'a\n' > "$BOUNDARY_REPO/$BOUNDARY_SPOOF_PATH"
git -C "$BOUNDARY_REPO" add -- "$BOUNDARY_SPOOF_PATH"
git -C "$BOUNDARY_REPO" commit -q -m "add spoof path"

BOUNDARY_MARKER="$(mktemp -u)"
rm -f "$BOUNDARY_MARKER"
BOUNDARY_SCRIPT="$(mktemp)"
cat > "$BOUNDARY_SCRIPT" <<EOF
#!/bin/sh
touch "$BOUNDARY_MARKER"
cat
EOF
chmod +x "$BOUNDARY_SCRIPT"
git -C "$BOUNDARY_REPO" config "filter.evilboundary.clean" "$BOUNDARY_SCRIPT"
echo "$BOUNDARY_SPOOF_PATH filter=evilboundary" > "$BOUNDARY_REPO/.gitattributes"
printf 'modified working-tree content\n' > "$BOUNDARY_REPO/$BOUNDARY_SPOOF_PATH"

# Negative control: RAW git, `--no-ext-diff --no-textconv -- <A..B>` (exactly what this PR's
# round-1 wrapper forwarded to for `diff -- <A..B>`) MUST fire the marker — proving both that the
# fixture is live AND that the round-1 wrapper (which only revspec-validated the range and let
# caller-supplied '--' straight through) was genuinely vulnerable to this shape.
rm -f "$BOUNDARY_MARKER"
( cd "$BOUNDARY_REPO" && git diff --no-ext-diff --no-textconv -- "$BOUNDARY_SPOOF_PATH" >/dev/null 2>&1 )
if [[ -f "$BOUNDARY_MARKER" ]]; then
  pass "negative control: RAW git 'diff -- <A..B>' (both sides real commits) parses it as a PATHSPEC, not a range, and fires the configured clean filter — fixture is live, and this is exactly what the round-1 wrapper forwarded to"
else
  fail "negative control FAILED: raw git did not fire the configured clean filter via 'diff -- <A..B>' at all — this fixture is not exercising anything, every assertion below is meaningless"
fi

# The current (round-2-fixed) wrapper must REFUSE 'diff -- <A..B>' outright — the caller can never
# supply '--' at all, for any subcommand.
rm -f "$BOUNDARY_MARKER"
boundary_out="$(cd "$BOUNDARY_REPO" && "${WRAPPER_CMD[@]}" diff -- "$BOUNDARY_SPOOF_PATH" 2>&1)"
boundary_status=$?
if [[ $boundary_status -ne 0 ]] && grep -q '^pantheon-git-readonly:' <<<"$boundary_out" && [[ ! -f "$BOUNDARY_MARKER" ]]; then
  pass "wrapper refuses 'diff -- <A..B>' (caller-supplied '--') before git ever runs — clean filter never fires ($boundary_out)"
else
  fail "wrapper did NOT refuse 'diff -- <A..B>' as expected (status=$boundary_status, marker present=$([[ -f "$BOUNDARY_MARKER" ]] && echo yes || echo no), output: $boundary_out) — caller-supplied-'--' regression"
fi

# Two-argument form (no explicit '--', just a second positional) must also be refused — diff
# takes exactly one argument, so there is no pathspec slot even without a caller-supplied '--'.
rm -f "$BOUNDARY_MARKER"
boundary_out2="$(cd "$BOUNDARY_REPO" && "${WRAPPER_CMD[@]}" diff "$BOUNDARY_SPOOF_PATH" "$BOUNDARY_SPOOF_PATH" 2>&1)"
boundary_status2=$?
if [[ $boundary_status2 -ne 0 ]] && grep -q '^pantheon-git-readonly:' <<<"$boundary_out2" && [[ ! -f "$BOUNDARY_MARKER" ]]; then
  pass "wrapper refuses a two-argument 'diff <A..B> <A..B>' — exactly-one-argument enforcement closes this even without an explicit '--' ($boundary_out2)"
else
  fail "wrapper did NOT refuse the two-argument form as expected (status=$boundary_status2, marker present=$([[ -f "$BOUNDARY_MARKER" ]] && echo yes || echo no), output: $boundary_out2)"
fi

# By contrast, the legit single-argument range form (same repo, same filter, no '--') must still
# work AND still not fire the filter — real git prefers the revision interpretation when both
# sides resolve and there's no '--' forcing pathspec position.
rm -f "$BOUNDARY_MARKER"
( cd "$BOUNDARY_REPO" && "${WRAPPER_CMD[@]}" diff "${BOUNDARY_SHA1}...${BOUNDARY_SHA2}" >/dev/null 2>&1 )
boundary_legit_status=$?
if [[ $boundary_legit_status -eq 0 ]] && [[ ! -f "$BOUNDARY_MARKER" ]]; then
  pass "wrapper still accepts the legit single-argument range form (no '--') and the filter does not fire"
else
  fail "wrapper's legit single-argument range form regressed (status=$boundary_legit_status, marker present=$([[ -f "$BOUNDARY_MARKER" ]] && echo yes || echo no))"
fi

rm -f "$BOUNDARY_MARKER" "$BOUNDARY_SCRIPT"
rm -rf "$BOUNDARY_REPO"

# ---------------------------------------------------------------------------
# GIT_REDIRECT_STDOUT / GIT_REDIRECT_STDERR (issue #7 checklist item 2). git's own docs describe
# these as a Git for Windows mechanism: set to an absolute path, git.exe redirects its own
# stdout/stderr handles there. On this platform's git, they are a documented no-op (confirmed
# below) — so unlike every other fixture in this file, there is no live marker-file proof
# available here; that's not a gap in this fixture, it's the honest shape of a Windows-only
# mechanism exercised from non-Windows CI. What CAN be verified on any platform: (1) the wrapper's
# source actually scrubs both variables, structurally, and (2) plain git on THIS platform really
# does ignore them (the "why no live proof" claim is itself checked, not just asserted).
# ---------------------------------------------------------------------------
section "GIT_REDIRECT_STDOUT / GIT_REDIRECT_STDERR (Git for Windows sinks — structural + platform note)"

# Python's _forced_env() builds the subprocess environment as a fresh dict, key by key — there
# is no "unset" statement to grep for; the structural proof is instead that GIT_REDIRECT_STDOUT/
# GIT_REDIRECT_STDERR are never among the keys it explicitly sets (neutralization by omission —
# see pantheon/execution.py's own module docstring, EXEC/WRITE-SURFACE MATRIX).
if grep -qE 'env\["GIT_REDIRECT_ST(DOUT|DERR)"\]' "$SRC_FILE"; then
  fail "pantheon/execution.py explicitly sets a GIT_REDIRECT_STDOUT/STDERR env key — issue #7 item 2 regression (these must stay absent by construction, never forwarded)"
else
  pass "pantheon/execution.py never sets GIT_REDIRECT_STDOUT/GIT_REDIRECT_STDERR (neutralized by omission — _forced_env() builds a fresh dict, not a copy of os.environ)"
fi

REDIRECT_REPO="$(mktemp -d)"
git -C "$REDIRECT_REPO" init -q
git -C "$REDIRECT_REPO" config user.email "test@example.com"
git -C "$REDIRECT_REPO" config user.name "test"
printf 'a\n' > "$REDIRECT_REPO/f.txt"
git -C "$REDIRECT_REPO" add f.txt
git -C "$REDIRECT_REPO" commit -q -m first

REDIRECT_MARKER="$(mktemp -u)"
rm -f "$REDIRECT_MARKER"
( cd "$REDIRECT_REPO" && GIT_REDIRECT_STDOUT="$REDIRECT_MARKER" git show HEAD --stat >/dev/null 2>&1 )
if [[ -f "$REDIRECT_MARKER" ]]; then
  pass "platform note: this platform's git DOES honor GIT_REDIRECT_STDOUT (unexpected — treat the scrub above as load-bearing here too, not just Windows insurance)"
else
  echo "NOTE this platform's git ignores GIT_REDIRECT_STDOUT (no marker file created) — matches git's own docs describing it as Windows-only; the live half of this fixture cannot fire here by design, the structural check above is the real assertion on this platform"
fi

rm -f "$REDIRECT_MARKER"
rm -rf "$REDIRECT_REPO"

# ---------------------------------------------------------------------------
# GIT_NO_LAZY_FETCH (issue #7 checklist item 1). In a partial clone (--filter=blob:none), reading
# an object git doesn't have locally normally triggers a silent on-demand fetch from the
# configured remote AND writes the fetched pack into .git/objects — a network round-trip and a
# write, from a subcommand this wrapper's whole premise is "no transport, no write." Reproduced
# live against a local file:// remote (exercises the identical lazy-fetch code path git uses for
# any remote, no real network required): a fresh bare partial clone, reading the tip blob with
# GIT_NO_LAZY_FETCH unset grows .git/objects; the wrapper (which forces GIT_NO_LAZY_FETCH=1) must
# fail closed instead — the read errors out, but nothing is fetched or written.
# ---------------------------------------------------------------------------
section "GIT_NO_LAZY_FETCH (partial-clone lazy fetch forced off, no object write on a missing blob)"

count_objects() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' '; }

LAZY_ORIGIN="$(mktemp -d)"
git -C "$LAZY_ORIGIN" init -q
git -C "$LAZY_ORIGIN" config user.email "test@example.com"
git -C "$LAZY_ORIGIN" config user.name "test"
git -C "$LAZY_ORIGIN" config uploadpack.allowFilter true
git -C "$LAZY_ORIGIN" config uploadpack.allowAnySHA1InWant true
printf 'big content\n' > "$LAZY_ORIGIN/big.txt"
git -C "$LAZY_ORIGIN" add big.txt
git -C "$LAZY_ORIGIN" commit -q -m first

LAZY_CLONE_RAW="$(mktemp -d)"
rm -rf "$LAZY_CLONE_RAW"
git clone -q --bare --filter=blob:none "file://$LAZY_ORIGIN" "$LAZY_CLONE_RAW" 2>/dev/null

before_raw="$(count_objects "$LAZY_CLONE_RAW/objects")"
( cd "$LAZY_CLONE_RAW" && env -u GIT_NO_LAZY_FETCH git cat-file -p "HEAD:big.txt" >/dev/null 2>&1 )
after_raw="$(count_objects "$LAZY_CLONE_RAW/objects")"
if [[ "$after_raw" -gt "$before_raw" ]]; then
  pass "negative control: RAW git (GIT_NO_LAZY_FETCH unset) lazy-fetches and WRITES the missing blob object on a plain read ($before_raw -> $after_raw objects in .git/objects) — fixture is live, matching the pre-fix wrapper (which set no such variable and forwarded straight to this same behavior)"
else
  fail "negative control FAILED: raw git did not grow .git/objects at all ($before_raw -> $after_raw) — this fixture is not exercising anything, the assertion below is meaningless"
fi

LAZY_CLONE_WRAP="$(mktemp -d)"
rm -rf "$LAZY_CLONE_WRAP"
git clone -q --bare --filter=blob:none "file://$LAZY_ORIGIN" "$LAZY_CLONE_WRAP" 2>/dev/null

before_wrap="$(count_objects "$LAZY_CLONE_WRAP/objects")"
( cd "$LAZY_CLONE_WRAP" && "${WRAPPER_CMD[@]}" show "HEAD:big.txt" >/dev/null 2>&1 )
after_wrap="$(count_objects "$LAZY_CLONE_WRAP/objects")"
if [[ "$after_wrap" == "$before_wrap" ]]; then
  pass "wrapper-run 'show HEAD:big.txt' against a partial clone with the blob missing left .git/objects unchanged ($before_wrap objects) — GIT_NO_LAZY_FETCH=1 forced by the wrapper closes the lazy-fetch write (the read itself fails closed, which is correct: no object, no fetch)"
else
  fail "wrapper-run 'show HEAD:big.txt' against a partial clone GREW .git/objects ($before_wrap -> $after_wrap) — GIT_NO_LAZY_FETCH regression"
fi

if grep -qF 'env["GIT_NO_LAZY_FETCH"] = "1"' "$SRC_FILE"; then
  pass "pantheon/execution.py's _forced_env() forces GIT_NO_LAZY_FETCH=1 unconditionally"
else
  fail "pantheon/execution.py does NOT force GIT_NO_LAZY_FETCH=1 anywhere — issue #7 item 1 unaddressed"
fi

rm -rf "$LAZY_ORIGIN" "$LAZY_CLONE_RAW" "$LAZY_CLONE_WRAP"

# ---------------------------------------------------------------------------
# Untrusted-checkout PATH-injection (Codex P1, python-mode only — the vector is specific to how
# pantheon/execution.py resolves the `git` binary; the bash wrapper's `exec git ...` has no
# equivalent TRUSTED_GIT_DIRS mechanism to test). Round 1 of this finding: a bare
# `shutil.which("git")` resolves a RELATIVE PATH entry (e.g. `.`), letting a PR-committed `./git`
# impostor run in place of the real binary. Round 2 (fresh evidence after round 1's fix): even an
# ABSOLUTE PATH entry is not automatically trustworthy — `PATH=$PWD/bin:/usr/bin` with a
# PR-committed `bin/git` executable names an absolute directory that is still INSIDE the
# untrusted checkout. Fixed by never consulting PATH (ambient, relative, or absolute) for this
# lookup at all — `_git_executable()` resolves ONLY from TRUSTED_GIT_DIRS, a fixed list of system
# directories a PR's own tracked content can never write to.
# ---------------------------------------------------------------------------
section "Untrusted-checkout PATH-injection (Codex P1 round 2 — an absolute-but-untrusted PATH entry)"

PATHINJ_REPO="$(mktemp -d)"
mkdir -p "$PATHINJ_REPO/bin"
git -C "$PATHINJ_REPO" init -q
git -C "$PATHINJ_REPO" config user.email "test@example.com"
git -C "$PATHINJ_REPO" config user.name "test"
echo "a" > "$PATHINJ_REPO/f.txt"
git -C "$PATHINJ_REPO" add -A
git -C "$PATHINJ_REPO" commit -q -m "first"

PATHINJ_MARKER="$(mktemp -u)"
rm -f "$PATHINJ_MARKER"
cat > "$PATHINJ_REPO/bin/git" <<EOF
#!/bin/sh
touch "$PATHINJ_MARKER"
exit 99
EOF
chmod +x "$PATHINJ_REPO/bin/git"

# Negative control: RAW PATH resolution (the exact mechanism a bare shutil.which("git") or a
# shell's own command lookup uses) DOES find the PR-committed impostor when its absolute
# directory is prepended to PATH — proving the fixture is live, and reproducing exactly what
# round 1's "reject relative, accept any absolute" fix remained vulnerable to.
rm -f "$PATHINJ_MARKER"
raw_which_out="$(cd "$PATHINJ_REPO" && PATH="$PATHINJ_REPO/bin:$PATH" command -v git)"
if [[ "$raw_which_out" == "$PATHINJ_REPO/bin/git" ]]; then
  pass "negative control: raw PATH resolution (command -v git) DOES select the PR-committed impostor when its absolute dir is prepended to PATH — fixture is live"
else
  fail "negative control FAILED: raw PATH resolution did not select the impostor (got '$raw_which_out') — this fixture is not exercising anything"
fi

# The wrapper itself must NOT execute the impostor (marker absent) and must still successfully
# run the real git (exit 0, real output) — TRUSTED_GIT_DIRS is consulted instead of PATH.
# Unconditional (not gated on the negative control above): these are the real, load-bearing
# assertions this whole fixture exists for, and must run on every invocation regardless of
# whether the negative control itself passed or failed — a structural bug once left them
# stranded inside the negative control's own `else` branch, so they silently never ran on the
# (normal, expected) success path. See this repo's own git history for the incident.
rm -f "$PATHINJ_MARKER"
pathinj_out="$(cd "$PATHINJ_REPO" && PATH="$PATHINJ_REPO/bin:$PATH" "${WRAPPER_CMD[@]}" status 2>&1)"
pathinj_status=$?
if [[ ! -f "$PATHINJ_MARKER" ]]; then
  pass "wrapper did NOT execute the PATH-injected impostor (marker absent) even with its absolute dir prepended to PATH"
else
  fail "wrapper EXECUTED the PATH-injected impostor (marker present) — TRUSTED_GIT_DIRS regression, the read-only boundary is bypassed"
fi
if [[ $pathinj_status -eq 0 ]] && ! grep -q '^pantheon-git-readonly:' <<<"$pathinj_out"; then
  pass "wrapper still ran the REAL git successfully (exit 0) despite the PATH-injection attempt"
else
  fail "wrapper did not run the real git successfully under PATH injection (status=$pathinj_status, output: $pathinj_out)"
fi

rm -f "$PATHINJ_MARKER"
rm -rf "$PATHINJ_REPO"

echo
echo "git-readonly-wrapper fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
