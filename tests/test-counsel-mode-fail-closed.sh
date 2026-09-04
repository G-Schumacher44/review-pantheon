#!/usr/bin/env bash
# tests/test-counsel-mode-fail-closed.sh — the negative control for issue #95's central
# invariant: counsel mode (`mode: counsel` on the Action) must NEVER produce a failing check,
# even when every counsel agent fails to return a verdict at all. The fail-closed rule ("a
# missing or unparseable verdict reads as NOT GATED, never as a pass" — DESIGN.md rule 2) is a
# GATE property; this suite proves it does not leak into the advisory lane as a job-failing exit
# code the way it correctly does for gate mode.
#
# Drives action/lib/combine_verdicts.sh directly (real subprocess, the same script action.yml's
# "Build and post combined comment" step calls) rather than the composite action itself — GitHub
# Actions' own step/job semantics can't be exercised outside a real runner, but this script's own
# exit code is exactly what determines whether the composite action's "combine" step fails, so a
# real invocation of it is the correct unit boundary for this claim (see action.yml's own comment
# on that step's `continue-on-error` for why this script itself was already the last line of
# defense before this issue existed).
#
# Avoids `mktemp` (bare/no-template BSD `mktemp` ignores `$TMPDIR`, which is directly hostile to
# a locked-down `$TMPDIR`-only sandbox — a real environment constraint, not a style choice) — uses
# `mkdir -p` under `${TMPDIR:-/tmp}` instead, exactly like this suite's own runner does.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMBINE="$ROOT/action/lib/combine_verdicts.sh"

PASS=0
FAIL=0

WORKDIR="${TMPDIR:-/tmp}/pantheon-counsel-negctrl-$$"
mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# -------------------------------------------------------------------------------------------
# Negative control: every counsel agent "failed" (no *_COLOR env at all — exactly what an
# unset decide-verdict output looks like after a resolve/build-prompt step errors under
# counsel mode's continue-on-error carve-out). combine_verdicts.sh must still exit 0.
# -------------------------------------------------------------------------------------------
run1="$WORKDIR/run1"
mkdir -p "$run1"
out1="$(
  cd "$ROOT" && env -i \
    PATH="$PATH" \
    RUNNER_TEMP="$run1" \
    MODE=counsel \
    POST_COMMENT=false \
    HEAD_SHA=deadbeefcafe \
    bash "$COMBINE" "socrates diogenes plato" 2>&1
)"
rc1=$?

if [[ "$rc1" -eq 0 ]]; then
  pass "combine_verdicts.sh exits 0 under MODE=counsel with every agent unset (the negative control)"
else
  fail "combine_verdicts.sh exited $rc1 under MODE=counsel with every agent unset — counsel mode can fail a check"
fi

if grep -qF 'advisory, not a gate' <<<"$out1"; then
  pass "counsel comment carries the advisory banner"
else
  fail "counsel comment is missing the advisory banner: $out1"
fi

if grep -qF 'UNVERIFIED' <<<"$out1"; then
  pass "counsel comment still reports the real (fail-closed) per-agent verdict — UNVERIFIED, not silently hidden"
else
  fail "counsel comment does not show the expected UNVERIFIED verdict: $out1"
fi

if [[ "$(grep -c 'advisory, not a gate' <<<"$out1")" -eq 1 ]]; then
  pass "advisory banner appears exactly once (not duplicated by a re-run-shaped bug)"
else
  fail "advisory banner appears an unexpected number of times: $out1"
fi

# -------------------------------------------------------------------------------------------
# A red counsel verdict must ALSO exit 0 — "never a red check" means whatever color the panel
# lands on, not just the unverified/error case above.
# -------------------------------------------------------------------------------------------
run2="$WORKDIR/run2"
mkdir -p "$run2"
out2="$(
  cd "$ROOT" && env -i \
    PATH="$PATH" \
    RUNNER_TEMP="$run2" \
    MODE=counsel \
    POST_COMMENT=false \
    HEAD_SHA=deadbeefcafe \
    SOCRATES_COLOR=red \
    SOCRATES_VERDICT=BLOCKER \
    SOCRATES_TOP='this is a real blocker-shaped finding' \
    DIOGENES_COLOR=green \
    DIOGENES_VERDICT=CLEAN \
    PLATO_COLOR=green \
    PLATO_VERDICT=CLEAN \
    bash "$COMBINE" "socrates diogenes plato" 2>&1
)"
rc2=$?

if [[ "$rc2" -eq 0 ]]; then
  pass "combine_verdicts.sh exits 0 under MODE=counsel with a RED agent verdict"
else
  fail "combine_verdicts.sh exited $rc2 under MODE=counsel with a red verdict — counsel mode can fail a check"
fi

if grep -qF 'this is a real blocker-shaped finding' <<<"$out2"; then
  pass "a red finding still reaches the counsel comment (advisory means non-blocking, not hidden)"
else
  fail "the red finding's own text did not reach the comment: $out2"
fi

# -------------------------------------------------------------------------------------------
# Issue #102, finding 2: with no PR_NUMBER (every workflow_dispatch counsel run — there is no PR
# to comment on), the rendered verdict must ALSO reach $GITHUB_STEP_SUMMARY, not just the raw
# step log — the "job log/step summary" promise DESIGN.md's "counsel mode" section and this
# action's own `mode` input description make.
# -------------------------------------------------------------------------------------------
run4="$WORKDIR/run4"
mkdir -p "$run4"
summary4="$WORKDIR/step-summary4.md"
: > "$summary4"
out4="$(
  cd "$ROOT" && env -i \
    PATH="$PATH" \
    RUNNER_TEMP="$run4" \
    GITHUB_STEP_SUMMARY="$summary4" \
    MODE=counsel \
    POST_COMMENT=true \
    HEAD_SHA=deadbeefcafe \
    SOCRATES_COLOR=green \
    SOCRATES_VERDICT=CLEAN \
    DIOGENES_COLOR=green \
    DIOGENES_VERDICT=CLEAN \
    PLATO_COLOR=yellow \
    PLATO_VERDICT=ADVISORY \
    PLATO_TOP='a step-summary-shaped finding marker' \
    bash "$COMBINE" "socrates diogenes plato" 2>&1
)"
rc4=$?

if [[ "$rc4" -eq 0 ]]; then
  pass "combine_verdicts.sh exits 0 with PR_NUMBER unset and GITHUB_STEP_SUMMARY set"
else
  fail "combine_verdicts.sh exited $rc4 with PR_NUMBER unset and GITHUB_STEP_SUMMARY set"
fi

if grep -qF 'PR_NUMBER is not set' <<<"$out4"; then
  pass "still warns that comment-posting was skipped (no PR to post to)"
else
  fail "expected the 'PR_NUMBER is not set' warning, got: $out4"
fi

if [[ -s "$summary4" ]] && grep -qF 'a step-summary-shaped finding marker' "$summary4"; then
  pass "rendered verdict markdown was appended to \$GITHUB_STEP_SUMMARY when PR_NUMBER is empty"
else
  fail "\$GITHUB_STEP_SUMMARY is missing the rendered verdict — got: $(cat "$summary4" 2>/dev/null)"
fi

if grep -qF 'advisory, not a gate' "$summary4" 2>/dev/null; then
  pass "the counsel advisory banner reached \$GITHUB_STEP_SUMMARY too, not just the job log"
else
  fail "\$GITHUB_STEP_SUMMARY is missing the counsel advisory banner"
fi

# -------------------------------------------------------------------------------------------
# Regression pin: gate mode (MODE unset, matching every pre-#95 invocation of this script) gets
# NO banner and is byte-for-byte what render_comment alone would have produced — mode's addition
# must not touch existing gate-mode output at all.
# -------------------------------------------------------------------------------------------
run3="$WORKDIR/run3"
mkdir -p "$run3"
out_gate="$(
  cd "$ROOT" && env -i \
    PATH="$PATH" \
    RUNNER_TEMP="$run3" \
    POST_COMMENT=false \
    HEAD_SHA=deadbeefcafe \
    ARTEMIS_COLOR=green \
    ARTEMIS_VERDICT=CLEAN \
    APOLLO_COLOR=green \
    APOLLO_VERDICT=CLEAN \
    bash "$COMBINE" "artemis apollo" 2>&1
)"
rc_gate=$?

if [[ "$rc_gate" -eq 0 ]]; then
  pass "gate-mode (MODE unset) invocation still exits 0 on a clean panel"
else
  fail "gate-mode invocation exited $rc_gate unexpectedly"
fi

if grep -qF 'advisory, not a gate' <<<"$out_gate"; then
  fail "gate-mode (MODE unset) output carries the counsel banner — mode's addition changed gate-mode output"
else
  pass "gate-mode (MODE unset) output carries no counsel banner — unchanged"
fi

direct_render="$(
  cd "$ROOT" && PYTHONPATH="$ROOT" ARTEMIS_COLOR=green ARTEMIS_VERDICT=CLEAN APOLLO_COLOR=green APOLLO_VERDICT=CLEAN \
    python3 "$ROOT/pantheon/render.py" comment deadbeefcafe artemis apollo
)"
if [[ "$out_gate" == *"$direct_render"* ]]; then
  pass "gate-mode comment body matches pantheon.render's own output byte-for-byte (no banner, no reformatting)"
else
  fail "gate-mode comment body diverges from pantheon.render's direct output"
fi

echo
echo "counsel-mode-fail-closed fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
