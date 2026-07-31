#!/usr/bin/env bash
# tests/test-prompt-assembly.sh — prompt-assembly fixture test for the spec-aware Apollo
# feature (DESIGN.md's "House rules are pluggable" sibling: a governing spec file, wired the
# same only-if-exists way, but into Apollo's context ONLY).
#
# THREE runtimes build a prompt's context block: action/lib/build_prompt.sh (the Action lane,
# shared by action.yml's five agent steps), cli/review-gate's own build_prompt() function (the
# CLI lane, not factored into a separate file — see DESIGN.md's "Layout" section on why the
# runtimes keep their prompt-build logic in different places), and action/review.yml's own
# inline "Build prompt" step (the vendored twin-gate matrix workflow's copy — a third, YAML-
# embedded copy of the same logic, not factored out into build_prompt.sh because review.yml
# runs standalone, checked out into a consumer repo with no action/lib/ alongside it). None had
# a dedicated test before this file. This script:
#   - Part A: calls action/lib/build_prompt.sh directly, with and without a spec file, for
#     apollo AND a non-apollo agent, asserting the context line appears/is absent correctly.
#   - Part B: exercises cli/review-gate's build_prompt() function itself — extracted verbatim
#     from the live script (never hand-copied — a drifted copy would defeat the point of this
#     test) — against fixture repo roots (spec present / absent / explicitly disabled),
#     asserting the same thing via the CLI code path.
#   - Part C: statically checks action/review.yml's inline "Build prompt" step — it's a
#     `run: |` shell block gated on $AGENT_NAME inside YAML, not a standalone script, so it
#     can't be sourced/executed like Parts A/B; instead this asserts the apollo+DESIGN.md
#     conditional is present and extracts the literal echoed line for the wording cross-check
#     below.
#   - Cross-checks that all three runtimes emit byte-identical wording for the line, per the
#     task this feature shipped under ("keep both runners' context wording identical") —
#     extended here to cover review.yml's inline copy too.
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
# Part C — action/review.yml's inline "Build prompt" step (the twin-gate matrix workflow's own
# copy of this logic — a third copy alongside build_prompt.sh and cli/review-gate's
# build_prompt(), per this file's header comment). This step is a `run: |` block embedded in
# YAML, keyed off $AGENT_NAME/$GITHUB_WORKSPACE at real-workflow-run time, so it can't be
# sourced or executed standalone the way Parts A/B are — this checks it structurally instead:
# isolate the step's body, assert the apollo+DESIGN.md conditional gating it, and pull out the
# literal echoed line for the wording cross-check below. review.yml hardcodes "DESIGN.md"
# (unlike the other two runtimes' $SPEC_FILE/$CFG_SPEC_FILE variables) since this vendored
# workflow has no gate.conf/spec_file input surface — see review.yml's own header comment.
# ---------------------------------------------------------------------------
section "Part C: action/review.yml's inline Build-prompt step"

REVIEW_YML="$ROOT/action/review.yml"

review_yml_build_step="$(awk '
  /- name: Build prompt/ { grab=1 }
  grab && /- name:/ && !/Build prompt/ { exit }
  grab { print }
' "$REVIEW_YML")"

# shellcheck disable=SC2016 # single-quoted on purpose — searching for the literal
# "$AGENT_NAME" text inside review.yml's shell block, not expanding a variable here.
if [[ -n "$review_yml_build_step" ]] && grep -qE '\[ "\$AGENT_NAME" = "apollo" \]' <<<"$review_yml_build_step" && grep -q 'DESIGN.md' <<<"$review_yml_build_step"; then
  pass "action/review.yml's Build-prompt step gates the spec-file line on AGENT_NAME=apollo + DESIGN.md presence"
else
  fail "action/review.yml's Build-prompt step is missing the apollo/DESIGN.md spec-file conditional"
fi

C1_LINE="$(grep -- 'Spec file:' <<<"$review_yml_build_step" | sed -E 's/^[[:space:]]*echo "(.*)"$/\1/')"
if [[ -n "$C1_LINE" ]]; then
  pass "action/review.yml's Build-prompt step echoes a 'Spec file: DESIGN.md (present...)' context line"
else
  fail "action/review.yml's Build-prompt step is missing the 'Spec file:' context line"
fi

# ---------------------------------------------------------------------------
# Cross-runner wording check — all three runtimes must emit the identical line (this feature's
# own design rationale: "Keep both runners' context wording identical" — extended here to a
# third runtime).
# ---------------------------------------------------------------------------
section "Cross-runner wording"

A1_LINE="$(grep -- 'Spec file:' "$A1_OUT" 2>/dev/null || true)"
B1_LINE="$(grep -- 'Spec file:' "$B1_APOLLO_FILE" 2>/dev/null || true)"

if [[ -n "$A1_LINE" && "$A1_LINE" == "$B1_LINE" ]]; then
  pass "action/lib/build_prompt.sh and cli/review-gate emit the identical Spec-file context line"
else
  fail "wording drift between runners — action: '$A1_LINE' vs cli: '$B1_LINE'"
fi

if [[ -n "$A1_LINE" && -n "$C1_LINE" && "$A1_LINE" == "$C1_LINE" ]]; then
  pass "action/lib/build_prompt.sh and action/review.yml's inline copy emit the identical Spec-file context line"
else
  fail "wording drift between runners — action/lib/build_prompt.sh: '$A1_LINE' vs action/review.yml: '$C1_LINE'"
fi

rm -rf "$FIXTURE_WITH_SPEC" "$FIXTURE_NO_SPEC"

echo
echo "PASS: $PASS, FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
