#!/usr/bin/env bash
# tests/test-action-refs.sh — asserts every file action.yml (the published composite action)
# references under `${{ github.action_path }}/...` actually exists in this repo, that the
# `anthropics/claude-code-action` pin is consistent between action.yml and the vendored
# action/review.yml, and that the `spec_file` input (spec-aware Apollo) is declared and wired
# ONLY into apollo's build-prompt step, not the other four agents'. All of that is things that
# would otherwise only surface at real-workflow-run time — action.yml can't be
# integration-tested until this repo is public (see DESIGN.md's "Published action" section), so
# this is the mechanical half of that verification that CAN run in CI today.
#
# No test framework — plain bash, `bash tests/test-action-refs.sh` is the whole invocation
# (also wired into .github/workflows/ci.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_YML="$ROOT/action.yml"
REVIEW_YML="$ROOT/action/review.yml"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

[[ -f "$ACTION_YML" ]] || { fail "action.yml exists"; echo "FAIL: $FAIL, PASS: $PASS"; exit 1; }
pass "action.yml exists"

# Every `${{ github.action_path }}/<relative-path>` reference in action.yml must resolve to a
# real file in this repo (the composite action never checks out its own repo — it IS the
# checkout, at github.action_path — so a typo'd path here is a silent runtime failure, not a
# YAML error).
refs="$(grep -oE '\$\{\{ *github\.action_path *\}\}/[A-Za-z0-9_./-]+' "$ACTION_YML" | sed -E 's#^\$\{\{ *github\.action_path *\}\}/##' | sort -u)"

if [[ -z "$refs" ]]; then
  fail "action.yml contains at least one github.action_path reference"
else
  pass "action.yml contains github.action_path references ($(printf '%s\n' "$refs" | wc -l | tr -d ' ') found)"
fi

while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  assert_path="$ROOT/$rel"
  if [[ -f "$assert_path" ]]; then
    pass "referenced file exists: $rel"
  else
    fail "referenced file MISSING: $rel (action.yml points at github.action_path/$rel)"
  fi
done <<< "$refs"

# Every referenced action/lib/*.sh and action/decide_verdict.py file must be executable-by-bash
# (bash -n) — belt and suspenders on top of ci.yml's repo-wide bash -n/shellcheck job, scoped
# to exactly the files this action depends on at runtime.
while IFS= read -r rel; do
  [[ "$rel" == *.sh ]] || continue
  if bash -n "$ROOT/$rel" 2>/dev/null; then
    pass "bash -n: $rel"
  else
    fail "bash -n FAILED: $rel"
  fi
done <<< "$refs"

# The anthropics/claude-code-action pin must be the same full commit SHA in both action.yml
# (the published action) and action/review.yml (the vendored one) — DESIGN.md's "Published
# action" section and action/review.yml's header comment both describe this as the same,
# verified pin; a drift here means one of the two files was updated without the other.
action_sha="$(grep -oE 'anthropics/claude-code-action@[0-9a-f]{40}' "$ACTION_YML" | head -1 | sed -E 's#.*@##')"
review_sha="$(grep -oE 'anthropics/claude-code-action@[0-9a-f]{40}' "$REVIEW_YML" | head -1 | sed -E 's#.*@##')"

if [[ -z "$action_sha" ]]; then
  fail "action.yml pins anthropics/claude-code-action to a full 40-char commit SHA"
else
  pass "action.yml pins anthropics/claude-code-action to a full commit SHA ($action_sha)"
fi

if [[ -z "$review_sha" ]]; then
  fail "action/review.yml pins anthropics/claude-code-action to a full 40-char commit SHA"
else
  pass "action/review.yml pins anthropics/claude-code-action to a full commit SHA ($review_sha)"
fi

if [[ -n "$action_sha" && -n "$review_sha" ]]; then
  if [[ "$action_sha" == "$review_sha" ]]; then
    pass "action.yml and action/review.yml pin the same claude-code-action SHA"
  else
    fail "action.yml ($action_sha) and action/review.yml ($review_sha) pin DIFFERENT claude-code-action SHAs"
  fi
fi

# Every anthropics/claude-code-action reference must use a full commit SHA, never a moving tag
# (v1, v1.0, latest, etc.) — that's the whole point of pinning; a tag reference here would
# quietly start running whatever that tag points to next, no error, no warning.
if grep -oE 'anthropics/claude-code-action@[A-Za-z0-9._-]+' "$ACTION_YML" "$REVIEW_YML" | grep -vqE '@[0-9a-f]{40}(\s|#|$)'; then
  fail "anthropics/claude-code-action@ reference found that is NOT a full 40-char commit SHA"
else
  pass "every anthropics/claude-code-action@ reference is a full commit SHA"
fi

# spec-aware Apollo (review-gate: "verify delivery against the governing spec") — action.yml
# must declare the `spec_file` input, and apollo's (only apollo's) build-prompt step must wire
# it through to build_prompt.sh via SPEC_FILE/SPEC_PRESENT env vars.
if grep -qE '^  spec_file:' "$ACTION_YML"; then
  pass "action.yml declares a spec_file input"
else
  fail "action.yml is missing a spec_file input"
fi

# Isolate apollo's "Build prompt (apollo)" step body (up to the next "- name:") and check it
# references SPEC_FILE/SPEC_PRESENT — scoped to that one step so a false pass can't come from a
# match anywhere else in the file (e.g. the resolve step, which computes but doesn't consume
# them the same way).
apollo_build_step="$(awk '
  /- name: Build prompt \(apollo\)/ { grab=1 }
  grab && /- name:/ && !/Build prompt \(apollo\)/ { exit }
  grab { print }
' "$ACTION_YML")"

if [[ -n "$apollo_build_step" ]] && grep -q 'SPEC_FILE:' <<<"$apollo_build_step" && grep -q 'SPEC_PRESENT:' <<<"$apollo_build_step"; then
  pass "action.yml's apollo build-prompt step references SPEC_FILE and SPEC_PRESENT"
else
  fail "action.yml's apollo build-prompt step does NOT reference SPEC_FILE/SPEC_PRESENT"
fi

# The non-apollo build-prompt steps must NOT set SPEC_FILE/SPEC_PRESENT — this feature is
# apollo-only by design (DESIGN.md, this feature's own rationale).
for other_agent in artemis socrates diogenes plato; do
  other_build_step="$(awk -v agent="$other_agent" '
    $0 ~ ("- name: Build prompt \\(" agent "\\)") { grab=1 }
    grab && /- name:/ && $0 !~ ("Build prompt \\(" agent "\\)") { exit }
    grab { print }
  ' "$ACTION_YML")"
  if [[ -n "$other_build_step" ]] && ! grep -q 'SPEC_FILE:' <<<"$other_build_step" && ! grep -q 'SPEC_PRESENT:' <<<"$other_build_step"; then
    pass "action.yml's $other_agent build-prompt step does NOT reference SPEC_FILE/SPEC_PRESENT (apollo-only)"
  else
    fail "action.yml's $other_agent build-prompt step unexpectedly references SPEC_FILE/SPEC_PRESENT, or the step could not be isolated"
  fi
done

# action.yml must declare the github_token input — passing the workflow token to
# claude-code-action explicitly is what lets consumers skip granting id-token: write (see
# DESIGN.md's "Security posture" and action/review.yml's header comment for why: claude-code-
# action's token.ts checks github_token FIRST and only falls back to its internal OIDC-token-
# exchange bootstrap when it's unset).
if grep -qE '^  github_token:' "$ACTION_YML"; then
  pass "action.yml declares a github_token input"
else
  fail "action.yml MISSING a github_token input declaration"
fi

# Every one of the five run-agent (claude-code-action) steps in action.yml must wire
# github_token through to the underlying action — one per agent (artemis, apollo, socrates,
# diogenes, plato), same count as the claude_code_oauth_token / anthropic_api_key wiring above.
action_github_token_wires="$(grep -cE 'github_token: \$\{\{ inputs\.github_token \}\}' "$ACTION_YML")"
if [[ "$action_github_token_wires" -eq 5 ]]; then
  pass "action.yml wires github_token into all 5 run-agent steps"
else
  fail "action.yml wires github_token into $action_github_token_wires run-agent step(s), expected 5"
fi

# action/review.yml (the vendored workflow) must also pass github_token through to
# claude-code-action, for the same id-token-avoidance reason.
if grep -qE 'github_token: \$\{\{ github\.token \}\}' "$REVIEW_YML"; then
  pass "action/review.yml wires github_token into its claude-code-action step"
else
  fail "action/review.yml MISSING github_token wiring on its claude-code-action step"
fi

echo
echo "PASS: $PASS, FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
