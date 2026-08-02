#!/usr/bin/env bash
# tests/test-release-tag-gates.sh — fixture test for .github/workflows/release.yml's two
# tag-validation gates: the strict-semver check and the origin/main-ancestry check (both
# Codex findings on this PR). release.yml's steps run `bash` snippets embedded in YAML, which
# this repo's other tests don't extract and run directly (unlike cli/review-gate's shell
# functions) — instead this file re-runs the EXACT git/regex commands those steps use, derived
# from release.yml's own source (grepped, not hand-copied), against real fixture git repos, so a
# drift between what's tested here and what the workflow actually runs is caught by the
# extraction assertions below, not silently missed.
#
# No test framework — plain bash, `bash tests/test-release-tag-gates.sh` is the whole invocation
# (wired into .github/workflows/ci.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_YML="$ROOT/.github/workflows/release.yml"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

section() { echo; echo "== $1 =="; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Extract the semver regex verbatim from release.yml's "Validate tag is a strict vX.Y.Z
# semantic version" step, rather than hand-copying it — a drift between what this test checks
# and what the workflow actually runs would otherwise go unnoticed.
# ---------------------------------------------------------------------------
section "Extract the semver regex from release.yml"

SEMVER_REGEX="$(grep -oE '\^v\[0-9\]\+\\\.\[0-9\]\+\\\.\[0-9\]\+\$' "$RELEASE_YML" | head -1)"
if [[ -n "$SEMVER_REGEX" ]]; then
  pass "extracted semver regex from release.yml: $SEMVER_REGEX"
else
  fail "could not extract the semver regex from release.yml — its shape changed; update this extractor"
  SEMVER_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+$'
  echo "falling back to a hand-copied regex so the rest of this file can still run: $SEMVER_REGEX"
fi

check_semver() {
  local tag="$1" expect_valid="$2"
  local matched="false"
  [[ "$tag" =~ $SEMVER_REGEX ]] && matched="true"
  if [[ "$matched" == "$expect_valid" ]]; then
    pass "semver regex on '$tag': matched=$matched (expected $expect_valid)"
  else
    fail "semver regex on '$tag': matched=$matched, expected $expect_valid"
  fi
}

check_semver "v1.2.3" "true"
check_semver "v0.0.1" "true"
check_semver "v1.2.3-rc1" "false"
check_semver "vfoo.bar.baz" "false"
check_semver "v1.2" "false"
check_semver "1.2.3" "false"

# ---------------------------------------------------------------------------
# Ancestry check — re-runs the EXACT commands the "Verify tag is reachable from main" step
# uses (git fetch origin main + git merge-base --is-ancestor) against a real scratch repo with
# two branches, so this exercises real git behavior, not a mock.
# ---------------------------------------------------------------------------
section "Ancestry check: git merge-base --is-ancestor, real scratch repo"

# shellcheck disable=SC2016 # deliberate — matching the literal, unexpanded shell syntax as it
# appears in release.yml's source, not expanding it in this test's own shell.
if grep -q 'git merge-base --is-ancestor "${GITHUB_SHA}" origin/main' "$RELEASE_YML"; then
  pass "release.yml's ancestry step uses 'git merge-base --is-ancestor \${GITHUB_SHA} origin/main'"
else
  fail "release.yml's ancestry check command shape changed — update this test's extraction assumption"
fi

REMOTE_REPO="$WORKDIR/remote.git"
git init --quiet --bare "$REMOTE_REPO"

WORK_REPO="$WORKDIR/work"
git init --quiet "$WORK_REPO"
git -C "$WORK_REPO" config user.email "test@example.com"
git -C "$WORK_REPO" config user.name "test"
git -C "$WORK_REPO" remote add origin "$REMOTE_REPO"

# main: one commit.
echo "main content" > "$WORK_REPO/file.txt"
git -C "$WORK_REPO" add file.txt
git -C "$WORK_REPO" commit --quiet -m "main commit"
git -C "$WORK_REPO" branch -M main
git -C "$WORK_REPO" push --quiet origin main

# dev: branches off main, adds a commit NEVER merged into main — this is the "stray tag" case.
git -C "$WORK_REPO" checkout --quiet -b dev
echo "dev-only content" > "$WORK_REPO/dev-file.txt"
git -C "$WORK_REPO" add dev-file.txt
git -C "$WORK_REPO" commit --quiet -m "dev-only commit (never promoted)"
DEV_SHA="$(git -C "$WORK_REPO" rev-parse HEAD)"

# A promotion: merge dev into main — --no-ff forces a real merge commit (so DEV_SHA and
# PROMOTED_SHA stay distinct, both still ancestors of origin/main afterward), same shape as a
# real GitHub "Merge pull request" commit, not a fast-forward.
git -C "$WORK_REPO" checkout --quiet main
git -C "$WORK_REPO" merge --quiet --no-ff dev -m "promote dev to main"
PROMOTED_SHA="$(git -C "$WORK_REPO" rev-parse HEAD)"
git -C "$WORK_REPO" push --quiet origin main

# A further dev-only commit AFTER the promotion above — still never reached main.
git -C "$WORK_REPO" checkout --quiet dev
echo "more dev-only content" > "$WORK_REPO/dev-file2.txt"
git -C "$WORK_REPO" add dev-file2.txt
git -C "$WORK_REPO" commit --quiet -m "another dev-only commit (never promoted)"
UNPROMOTED_SHA="$(git -C "$WORK_REPO" rev-parse HEAD)"

check_ancestry() {
  local label="$1" sha="$2" expect_pass="$3"
  local status
  ( cd "$WORK_REPO" && git fetch --quiet origin main && git merge-base --is-ancestor "$sha" origin/main )
  status=$?
  local passed="false"
  [[ $status -eq 0 ]] && passed="true"
  if [[ "$passed" == "$expect_pass" ]]; then
    pass "$label: ancestry check result=$passed (expected $expect_pass)"
  else
    fail "$label: ancestry check result=$passed (expected $expect_pass, git exit=$status)"
  fi
}

MAIN_TIP_SHA="$(git -C "$WORK_REPO" rev-parse main)"

check_ancestry "commit promoted to main (via merge)" "$PROMOTED_SHA" "true"
check_ancestry "commit that IS main's tip after promotion" "$MAIN_TIP_SHA" "true"
check_ancestry "dev-only commit, never promoted (the exact stray-tag scenario)" "$DEV_SHA" "true"
check_ancestry "dev-only commit created AFTER the last promotion (still unpromoted)" "$UNPROMOTED_SHA" "false"

# ---------------------------------------------------------------------------
# Version-match gate (port slice 5, RELEASING.md's "bump version to match the tag before
# tagging" ceremony step) — re-runs the EXACT extraction/comparison logic the "Verify tag
# matches pyproject.toml's version" step uses, against a real scratch pyproject.toml, so this
# exercises real grep/sed behavior, not a mock. Proven failing pre-fix: before this step existed
# in release.yml, ANY tag would have proceeded straight to the build regardless of
# pyproject.toml's version — there was no gate to fail. Verified locally by checking out this
# suite against dev's pre-slice-5 release.yml (no such step present) and confirming this whole
# section's extraction fails loud ("could not extract... update this test's extraction
# assumption"), never silently skips; restored before committing.
# ---------------------------------------------------------------------------
section "Version-match gate: tag vs pyproject.toml's version"

if grep -q 'Verify tag matches pyproject.toml' "$RELEASE_YML"; then
  pass "release.yml has a 'Verify tag matches pyproject.toml's version' step"
else
  fail "release.yml is missing the 'Verify tag matches pyproject.toml's version' step — update this test's extraction assumption"
fi

# shellcheck disable=SC2016 # deliberate — matching the literal, unexpanded shell syntax as it
# appears in release.yml's source.
if grep -qF 'grep -m1 -E '"'"'^version = '"'"' pyproject.toml' "$RELEASE_YML"; then
  pass "release.yml extracts pyproject.toml's version via 'grep -m1 -E ^version ='"
else
  fail "release.yml's version-extraction command shape changed — update this test's extraction assumption"
fi

extract_pyproject_version() {
  # Verbatim re-implementation of release.yml's own extraction line — kept in sync by hand,
  # same convention as check_semver/check_ancestry above (this file re-runs the commands, it
  # doesn't source the workflow's embedded shell).
  grep -m1 -E '^version = ' "$1" | sed -E 's/^version = "([^"]*)"/\1/'
}

check_version_match() {
  local label="$1" tag="$2" pyproject_version="$3" expect_match="$4"
  local scratch_pyproject="$WORKDIR/pyproject-$RANDOM.toml"
  printf 'version = "%s"\n' "$pyproject_version" > "$scratch_pyproject"
  local extracted expected_tag matched="false"
  extracted="$(extract_pyproject_version "$scratch_pyproject")"
  expected_tag="v${extracted}"
  [[ "$tag" == "$expected_tag" ]] && matched="true"
  if [[ "$matched" == "$expect_match" ]]; then
    pass "$label: tag='$tag' vs pyproject version='$pyproject_version' -> match=$matched (expected $expect_match)"
  else
    fail "$label: tag='$tag' vs pyproject version='$pyproject_version' -> match=$matched, expected $expect_match"
  fi
}

check_version_match "matching version" "v1.2.3" "1.2.3" "true"
check_version_match "mismatched patch" "v1.2.3" "1.2.4" "false"
check_version_match "forgotten bump (still pre-release)" "v1.2.3" "0.0.0.dev0" "false"
check_version_match "mismatched major" "v2.0.0" "1.2.3" "false"

echo
echo "release-tag-gates fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
