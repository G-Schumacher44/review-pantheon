#!/usr/bin/env bash
# tests/test-prompt-assembly.sh — prompt-assembly fixture test for the spec-aware Apollo
# feature (DESIGN.md's "House rules are pluggable" sibling: a governing spec file, wired the
# same only-if-exists way, but into Apollo's context ONLY).
#
# Two runtimes build a prompt's context block: action/lib/build_prompt.sh (the Action lane,
# shared by action.yml's five agent steps) and cli/review-gate's own build_prompt() function
# (the CLI lane, not factored into a separate file — see DESIGN.md's "Layout" section on why
# the two runtimes keep their prompt-build logic in different places). Neither had a dedicated
# test before this file. This script:
#   - Part A: calls action/lib/build_prompt.sh directly, with and without a spec file, for
#     apollo AND a non-apollo agent, asserting the context line appears/is absent correctly.
#   - Part B: exercises cli/review-gate's build_prompt() function itself — extracted verbatim
#     from the live script (never hand-copied — a drifted copy would defeat the point of this
#     test) — against fixture repo roots (spec present / absent / explicitly disabled),
#     asserting the same thing via the CLI code path.
#   - Cross-checks that both runtimes emit byte-identical wording for the line, per the task
#     this feature shipped under ("keep both runners' context wording identical").
#
# No test framework — plain bash, `bash tests/test-prompt-assembly.sh` is the whole invocation.
#
# shellcheck disable=SC2034 # many vars below are read only by the sourced/extracted
# build_prompt() function (see Part B), which shellcheck can't see through.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PROMPT_SH="$ROOT/action/lib/build_prompt.sh"
REVIEW_GATE="$ROOT/cli/review-gate"
AGENTS_DIR="$ROOT/agents"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
  local name="$1" file="$2"
  if grep -q -- 'Spec file:' "$file" 2>/dev/null; then
    pass "$name"
  else
    fail "$name (no 'Spec file:' line in $file)"
  fi
}

assert_absent() {
  local name="$1" file="$2"
  if grep -q -- 'Spec file:' "$file" 2>/dev/null; then
    fail "$name (found a 'Spec file:' line that should not be there in $file)"
  else
    pass "$name"
  fi
}

section() { echo; echo "== $1 =="; }

# ---------------------------------------------------------------------------
# Part A — action/lib/build_prompt.sh, called directly (the Action lane).
# ---------------------------------------------------------------------------
section "Part A: action/lib/build_prompt.sh"

WORKDIR_A="$(mktemp -d)"
trap 'rm -rf "$WORKDIR_A"' EXIT

common_env() {
  REPO_NAME="octo/demo" PR_NUMBER="1" PR_TITLE="test pr" \
  BASE_SHA="0000000000000000000000000000000000000000" \
  HEAD_SHA="1111111111111111111111111111111111111111" \
  BASE_REF="main" RULES_FILE="REVIEW_RULES.md" RULES_PRESENT="false" "$@"
}

# A1 — apollo, spec present -> line appears.
A1_OUT="$WORKDIR_A/a1.prompt.md"
common_env env SPEC_FILE="DESIGN.md" SPEC_PRESENT="true" \
  bash "$BUILD_PROMPT_SH" apollo "$AGENTS_DIR" "$A1_OUT" >/dev/null
assert_contains "build_prompt.sh: apollo + spec present -> line appears" "$A1_OUT"

# A2 — apollo, spec absent (SPEC_PRESENT unset -> defaults to false) -> line absent.
A2_OUT="$WORKDIR_A/a2.prompt.md"
common_env bash "$BUILD_PROMPT_SH" apollo "$AGENTS_DIR" "$A2_OUT" >/dev/null
assert_absent "build_prompt.sh: apollo + no spec file -> line absent (unchanged default)" "$A2_OUT"

# A3 — a NON-apollo agent (artemis), even with SPEC_FILE/SPEC_PRESENT set -> line absent.
# action.yml never actually sets these for artemis's build-prompt step; this proves the
# script's own gating is keyed on AGENT_NAME, not just on the env vars being present.
A3_OUT="$WORKDIR_A/a3.prompt.md"
common_env env SPEC_FILE="DESIGN.md" SPEC_PRESENT="true" \
  bash "$BUILD_PROMPT_SH" artemis "$AGENTS_DIR" "$A3_OUT" >/dev/null
assert_absent "build_prompt.sh: artemis + spec present -> line absent (apollo-only)" "$A3_OUT"

# ---------------------------------------------------------------------------
# Part B — cli/review-gate's build_prompt(), extracted verbatim from the live script (the CLI
# lane's own copy of this logic — not a separate file, see DESIGN.md's "Layout"). Extracting
# and sourcing the real function bodies means this test can't silently drift from what
# review-gate actually runs the way a hand-copied re-implementation could.
# ---------------------------------------------------------------------------
section "Part B: cli/review-gate's build_prompt() (CLI lane)"

extract_func() {
  local name="$1" file="$2"
  awk -v name="$name" '
    $0 ~ ("^" name "\\(\\) \\{") { grab=1 }
    grab { print }
    grab && /^}/ { exit }
  ' "$file"
}

FUNCS_FILE="$WORKDIR_A/review-gate-funcs.sh"
{
  extract_func "strip_frontmatter" "$REVIEW_GATE"
  echo
  extract_func "build_prompt" "$REVIEW_GATE"
} > "$FUNCS_FILE"

if [[ -s "$FUNCS_FILE" ]] && grep -q "^build_prompt() {" "$FUNCS_FILE" && grep -q "^strip_frontmatter() {" "$FUNCS_FILE"; then
  pass "extracted strip_frontmatter() and build_prompt() from cli/review-gate"
else
  fail "could not extract strip_frontmatter()/build_prompt() from cli/review-gate — review-gate's shape changed; update the extractor"
fi

# shellcheck disable=SC1090
source "$FUNCS_FILE"

die() { echo "test-stub die: $*" >&2; return 1; }

# Fixture repo roots — only what build_prompt() reads from disk: $REPO_ROOT/$CFG_SPEC_FILE and
# $REPO_ROOT/$CFG_RULES_FILE's existence.
FIXTURE_WITH_SPEC="$(mktemp -d)"
echo "spec content" > "$FIXTURE_WITH_SPEC/DESIGN.md"

FIXTURE_NO_SPEC="$(mktemp -d)"

# Shared context for every build_prompt() call below — read by the sourced build_prompt()
# function (extracted above), which shellcheck can't see through (hence this file's top-level
# SC2034 disable).
PR_NUMBER="1"
PR_TITLE="test pr"
DIFF_RANGE="refs/review-gate/base...refs/review-gate/head"
BASE_REF="main"
FOLLOWUP_NOTE=""
CFG_RULES_FILE="REVIEW_RULES.md"
WORKDIR="$WORKDIR_A"

# build_prompt() always writes to the fixed path $WORKDIR/<agent>.prompt.md (same name every
# call) — copy each result out under its own name immediately, or the next case's call
# overwrites the previous case's file before it's inspected.
B1_APOLLO_FILE="$WORKDIR_A/b1-apollo.prompt.md"
B1_ARTEMIS_FILE="$WORKDIR_A/b1-artemis.prompt.md"
B2_APOLLO_FILE="$WORKDIR_A/b2-apollo.prompt.md"
B3_APOLLO_FILE="$WORKDIR_A/b3-apollo.prompt.md"

# B1 — spec present, default spec_file — apollo gets the line, artemis does not (same
# fixture, proving the agent-scoping on the CLI path, not just the Action path).
REPO_ROOT="$FIXTURE_WITH_SPEC"
CFG_SPEC_FILE="DESIGN.md"
cp "$(build_prompt apollo)" "$B1_APOLLO_FILE"
assert_contains "review-gate build_prompt(): apollo + spec present -> line appears" "$B1_APOLLO_FILE"
cp "$(build_prompt artemis)" "$B1_ARTEMIS_FILE"
assert_absent "review-gate build_prompt(): artemis + spec present -> line absent (apollo-only)" "$B1_ARTEMIS_FILE"

# B2 — no spec file on disk, default spec_file="DESIGN.md" (nothing at that path) -> absent.
REPO_ROOT="$FIXTURE_NO_SPEC"
CFG_SPEC_FILE="DESIGN.md"
cp "$(build_prompt apollo)" "$B2_APOLLO_FILE"
assert_absent "review-gate build_prompt(): apollo + no spec file on disk -> line absent (unchanged default)" "$B2_APOLLO_FILE"

# B3 — spec file present on disk, but gate.conf disables it (spec_file= -> CFG_SPEC_FILE="")
# -> still absent, explicit disable wins over presence.
REPO_ROOT="$FIXTURE_WITH_SPEC"
CFG_SPEC_FILE=""
cp "$(build_prompt apollo)" "$B3_APOLLO_FILE"
assert_absent "review-gate build_prompt(): apollo + spec_file= disabled -> line absent even though DESIGN.md exists" "$B3_APOLLO_FILE"

# ---------------------------------------------------------------------------
# Cross-runner wording check — both runtimes must emit the identical line (this feature's own
# design rationale: "Keep both runners' context wording identical").
# ---------------------------------------------------------------------------
section "Cross-runner wording"

A1_LINE="$(grep -- 'Spec file:' "$A1_OUT" 2>/dev/null || true)"
B1_LINE="$(grep -- 'Spec file:' "$B1_APOLLO_FILE" 2>/dev/null || true)"

if [[ -n "$A1_LINE" && "$A1_LINE" == "$B1_LINE" ]]; then
  pass "action/lib/build_prompt.sh and cli/review-gate emit the identical Spec-file context line"
else
  fail "wording drift between runners — action: '$A1_LINE' vs cli: '$B1_LINE'"
fi

rm -rf "$FIXTURE_WITH_SPEC" "$FIXTURE_NO_SPEC"

echo
echo "PASS: $PASS, FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
