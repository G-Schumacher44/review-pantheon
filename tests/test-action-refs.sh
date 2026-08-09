#!/usr/bin/env bash
# tests/test-action-refs.sh — asserts every file action.yml (the published composite action)
# references under `${{ github.action_path }}/...` actually exists in this repo, and that the
# `spec_file` input (spec-aware Apollo) is declared and wired ONLY into apollo's build-prompt
# step, not the other four agents'. All of that is things that would otherwise only surface at
# real-workflow-run time — action.yml can't be integration-tested until this repo is public (see
# DESIGN.md's "Published action" section) — this is the mechanical half of that verification that
# CAN run in CI today.
#
# Retargeted by issue #36: this file used to ALSO cross-check action.yml against the vendored
# action/review.yml (a claude-code-action SHA-pin sync check, a --bare/scrub-step regression pair
# on both surfaces). That duplicate implementation was deleted — install.sh's Way A now generates
# a thin caller of action.yml instead of vendoring a second copy — so the cross-surface-sync
# checks had nothing left to compare and were removed rather than left comparing action.yml
# against itself. What replaced them: a check that install.sh's generated thin caller pins the
# SAME anthropics/claude-code-action-style discipline to review-pantheon itself — a full 40-char
# commit SHA, never a moving tag.
#
# No test framework — plain bash, `bash tests/test-action-refs.sh` is the whole invocation
# (also wired into .github/workflows/ci.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_YML="$ROOT/action.yml"
INSTALL_SH="$ROOT/install.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

[[ -f "$ACTION_YML" ]] || { fail "action.yml exists"; echo "FAIL: $FAIL, PASS: $PASS"; exit 1; }
pass "action.yml exists"

# Every action-relative path reference in action.yml must resolve to a real file in this repo
# (the composite action never checks out its own repo — it IS the checkout, at
# github.action_path — so a typo'd path here is a silent runtime failure, not a YAML error).
#
# Matches BOTH spellings: the `env:` binding `ACTION_PATH: ${{ github.action_path }}` consumed as
# `"$ACTION_PATH/..."` inside run: blocks (the required form — a security review established that
# `${{ }}` must never appear inside a run: script, since the expression engine substitutes before
# bash parses; see tests/check_action_expressions.py), and any surviving direct
# `${{ github.action_path }}/...` interpolation outside a run: block, which is still legal.
# shellcheck disable=SC2016  # the single quotes are the point: these are grep/sed REGEXES that
# must match the literal text `$ACTION_PATH` in action.yml, not expand a shell variable here.
refs="$( { grep -oE '\$\{\{ *github\.action_path *\}\}/[A-Za-z0-9_./-]+' "$ACTION_YML" | sed -E 's#^\$\{\{ *github\.action_path *\}\}/##'
           grep -oE '\$ACTION_PATH/[A-Za-z0-9_./-]+' "$ACTION_YML" | sed -E 's#^.ACTION_PATH/##'
           grep -oE '\$\{ACTION_PATH\}/[A-Za-z0-9_./-]+' "$ACTION_YML" | sed -E 's#^.\{ACTION_PATH\}/##'
         } | sort -u )"

if [[ -z "$refs" ]]; then
  fail "action.yml contains at least one action-path file reference"
else
  pass "action.yml contains action-path file references ($(printf '%s\n' "$refs" | wc -l | tr -d ' ') found)"
fi

# The env: binding itself must exist — otherwise every "$ACTION_PATH/..." above expands to
# "/..." at run time and every referenced file silently resolves to the filesystem root.
if grep -qE '^\s+ACTION_PATH: \$\{\{ *github\.action_path *\}\}\s*$' "$ACTION_YML"; then
  pass "action.yml binds ACTION_PATH from github.action_path in env:"
else
  fail "action.yml uses \$ACTION_PATH but never binds it to github.action_path in an env: block"
fi

while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  assert_path="$ROOT/$rel"
  # -e, not -f: `$ACTION_PATH/agents` is the bundled persona DIRECTORY, a legitimate reference.
  # The property under test is "this path exists in the repo the action ships as", not "it is a
  # regular file" — a missing path is a silent runtime failure either way.
  if [[ -f "$assert_path" ]]; then
    pass "referenced file exists: $rel"
  elif [[ -d "$assert_path" ]]; then
    pass "referenced directory exists: $rel/"
  else
    fail "referenced path MISSING: $rel (action.yml points at the action checkout's $rel)"
  fi
done <<< "$refs"

# Every referenced action/lib/*.sh file must be executable-by-bash
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

# The anthropics/claude-code-action pin must be a full 40-char commit SHA, never a moving tag
# (v1, v1.0, latest, etc.) — that's the whole point of pinning; a tag reference here would
# quietly start running whatever that tag points to next, no error, no warning.
action_sha="$(grep -oE 'anthropics/claude-code-action@[0-9a-f]{40}' "$ACTION_YML" | head -1 | sed -E 's#.*@##')"

if [[ -z "$action_sha" ]]; then
  fail "action.yml pins anthropics/claude-code-action to a full 40-char commit SHA"
else
  pass "action.yml pins anthropics/claude-code-action to a full commit SHA ($action_sha)"
fi

if grep -oE 'anthropics/claude-code-action@[A-Za-z0-9._-]+' "$ACTION_YML" | grep -vqE '@[0-9a-f]{40}(\s|#|$)'; then
  fail "anthropics/claude-code-action@ reference found in action.yml that is NOT a full 40-char commit SHA"
else
  pass "every anthropics/claude-code-action@ reference in action.yml is a full commit SHA"
fi

# install.sh's Way A generates a thin caller that pins THIS repo (G-Schumacher44/review-pantheon)
# to a full commit SHA, matching the exact discipline action.yml itself applies to
# anthropics/claude-code-action above — the whole point of issue #36's collapse was to inherit
# one consistent provenance story, not trade a moving tag for a different moving tag.
way_a_pin="$(grep -oE '^WAY_A_PIN_SHA="[0-9a-f]+"' "$INSTALL_SH" | grep -oE '[0-9a-f]+"$' | tr -d '"')"

if [[ -z "$way_a_pin" ]]; then
  fail "install.sh declares a WAY_A_PIN_SHA constant"
elif [[ "${#way_a_pin}" -eq 40 ]]; then
  pass "install.sh's WAY_A_PIN_SHA is a full 40-char commit SHA ($way_a_pin)"
else
  fail "install.sh's WAY_A_PIN_SHA is not a full 40-char commit SHA (got: $way_a_pin, ${#way_a_pin} chars)"
fi

# The generated workflow itself must reference review-pantheon by that same SHA — proving the
# constant is actually wired into the heredoc, not just declared and unused.
if [[ -n "$way_a_pin" ]] && grep -qF "G-Schumacher44/review-pantheon@\${WAY_A_PIN_SHA}" "$INSTALL_SH"; then
  pass "install.sh's generated workflow interpolates WAY_A_PIN_SHA into the review-pantheon uses: line"
else
  fail "install.sh's generated workflow does not reference \${WAY_A_PIN_SHA} in a G-Schumacher44/review-pantheon uses: line"
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
# DESIGN.md's "Security posture": claude-code-action's token.ts checks github_token FIRST and
# only falls back to its internal OIDC-token-exchange bootstrap when it's unset).
if grep -qE '^  github_token:' "$ACTION_YML"; then
  pass "action.yml declares a github_token input"
else
  fail "action.yml MISSING a github_token input declaration"
fi

# Every one of the five run-agent (claude-code-action) steps in action.yml must wire
# github_token through to the underlying action — one per agent (artemis, apollo, socrates,
# diogenes, plato).
action_github_token_wires="$(grep -cE 'github_token: \$\{\{ inputs\.github_token \}\}' "$ACTION_YML")"
if [[ "$action_github_token_wires" -eq 5 ]]; then
  pass "action.yml wires github_token into all 5 run-agent steps"
else
  fail "action.yml wires github_token into $action_github_token_wires run-agent step(s), expected 5"
fi

# ---------------------------------------------------------------------------------------------
# CRITICAL-1's config/MCP/hooks auto-discovery vector (adversarial review, round 8, live Artemis
# blocker on this PR's own self-hosted gate — corrected in round 9 after a P2 finding on the
# round-8 fix ITSELF). History, briefly (full writeup: action.yml's own "steps:"-level comment):
#   - Round 8 first fix: unconditional --bare in claude_args PLUS a hand-rolled `rm -rf .mcp.json
#     .claude CLAUDE.md` "scrub" step.
#   - --bare broke --json-schema-driven structured_output on this Action lane (a live
#     self-hosted-gate run failed both agents to UNVERIFIED) — reverted, asserted ABSENT below.
#   - The scrub step was DESTRUCTIVE to a CONSUMING repo's own workspace: a repo that legitimately
#     tracks `.claude/`/`CLAUDE.md`/`.mcp.json` and runs steps after this action in the same job
#     would find those files permanently deleted — a real P2, more serious than its badge, and
#     the opposite of this action's own "nothing is copied into the target repo" promise.
#   - Round 9 fix: REMOVED the scrub step entirely. `anthropics/claude-code-action`'s own pinned
#     source (`src/entrypoints/run.ts`, the SHA pinned above) already restores
#     `.claude`/`.mcp.json`/`.claude.json`/`.gitmodules`/`.ripgreprc`/`CLAUDE.md`/
#     `CLAUDE.local.md`/`.husky` from the PR's base branch, UNCONDITIONALLY for every PR-triggered
#     run — confirmed firing live in this repo's own self-check log (the exact console line):
#     `Restoring .claude, .mcp.json, .claude.json, .gitmodules, .ripgreprc, CLAUDE.md,
#     CLAUDE.local.md, .husky from origin/dev (PR head is untrusted)`. No code of this repo's own
#     mutates the consuming workspace for this vector at all — the safest possible fix.
# ---------------------------------------------------------------------------------------------

if grep -qE '^\s*--bare\s*$' "$ACTION_YML"; then
  fail "action.yml passes --bare in claude_args — this breaks --json-schema/structured_output on this Action surface (confirmed via a live self-hosted-gate failure); reverted deliberately, see the claude_args step's own comment"
else
  pass "action.yml does NOT pass --bare (would break --json-schema/structured_output on this Action surface — confirmed live)"
fi

# The scrub step must NOT exist (a round-9 regression guard, inverted from the round-8
# assertion this replaces): re-adding a hand-rolled workspace-mutating scrub step would reopen
# the exact adopter-data-loss bug round 9 closed, and is redundant with the native
# restore-config protection documented above.
if grep -qF 'name: Scrub Claude auto-discovery surface from the workspace' "$ACTION_YML"; then
  fail "action.yml has a 'Scrub Claude auto-discovery surface' step again — this class of fix was reverted for destroying a consuming repo's own tracked .claude//.mcp.json/CLAUDE.md; use claude-code-action's own native restore-config protection instead (see the steps:-level comment at the top of this file)"
else
  pass "action.yml does NOT scrub/mutate the workspace for the CRITICAL-1 vector (relies on claude-code-action's own native restore-config protection instead)"
fi

# Non-destructiveness, checked broadly, not just for the exact round-8 shape: action.yml may not
# contain a LIVE (non-comment) `rm -rf`/`rm -f`/`rm -r` (any form) targeting .mcp.json, .claude,
# or CLAUDE.md anywhere at all — this is the actual invariant the coordinator's round-9 finding
# cares about (adopter content must never be deleted by this repo's own code), not just "no step
# with this exact name". Comment lines are exempt (this file deliberately documents the reverted
# round-8 shape, `rm -rf .mcp.json .claude CLAUDE.md`, as HISTORY — a YAML `#`-prefixed line,
# after stripping leading whitespace, same convention `grep -v` filters elsewhere in this repo's
# own suites use for "this text describes past code, not live code").
destructive_hits="$(grep -nE 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]].*(\.mcp\.json|\.claude([^-]|$)|CLAUDE\.md)' "$ACTION_YML" | grep -vE ':[[:space:]]*#' || true)"
if [[ -n "$destructive_hits" ]]; then
  fail "action.yml contains a recursive rm targeting .mcp.json/.claude/CLAUDE.md — this would destroy a consuming repo's own tracked content:"
  while IFS= read -r line; do echo "    $line"; done <<<"$destructive_hits"
else
  pass "action.yml: no LIVE (non-comment) recursive rm targeting .mcp.json/.claude/CLAUDE.md anywhere in the file"
fi

echo
echo "PASS: $PASS, FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
