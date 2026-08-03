#!/usr/bin/env bash
# tests/test-setup-smoke.sh — clean-machine smoke test for the setup story: required
# binaries, the existing fixture suites, install.sh into a fresh scratch repo, bootstrap.sh
# into a fresh scratch prefix (and that the installed `pantheon` package resolves from there),
# and — only when a token and network are actually available — one full tokened
# `pantheon gate --pr <n> --dry-run` against a real public PR.
#
# No test framework — plain bash, `bash tests/test-setup-smoke.sh` is the whole invocation.
# Wired into .github/workflows/ci.yml (built and run inside Dockerfile.smoke, ubuntu:24.04, so
# it exercises real GNU coreutils and a real `timeout` — the non-fallback path this repo's
# macOS-based development can't exercise directly).
#
# Every stage that can run offline MUST pass for this script to exit 0. The one stage that
# needs a GitHub token and network is conditional: absent either, it's SKIPPED loudly (printed,
# with the reason, and does not fail the run) rather than silently omitted.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIPPED $1 -- $2"; SKIP=$((SKIP + 1)); }

section() { echo; echo "== $1 =="; }

# ---------------------------------------------------------------------------
# Stage 1 — required binaries. See docs/SETUP.md's Prerequisites table: bash/git/jq/gh are
# needed by every lane, python3 by the CLI and the Action's decider, curl/tar only by
# bootstrap.sh's remote-fetch path. shellcheck isn't a `pantheon` runtime dependency, but this
# repo's own CI lints every shell file with it, so it's checked here too (Dockerfile.smoke
# installs it explicitly for that reason).
# ---------------------------------------------------------------------------
section "Stage 1: required binaries"
for bin in bash git jq gh python3 curl tar shellcheck; do
  if command -v "$bin" >/dev/null 2>&1; then
    pass "binary present: $bin"
  else
    fail "binary present: $bin"
  fi
done

# ---------------------------------------------------------------------------
# Stage 2 — the existing fixture suites, unmodified.
# ---------------------------------------------------------------------------
section "Stage 2: existing fixture suites"
if bash "$ROOT/tests/test-verdict-decision-python.sh"; then
  pass "tests/test-verdict-decision-python.sh"
else
  fail "tests/test-verdict-decision-python.sh"
fi

if bash "$ROOT/tests/test-install.sh"; then
  pass "tests/test-install.sh"
else
  fail "tests/test-install.sh"
fi

if bash "$ROOT/tests/test-prompt-assembly-python.sh"; then
  pass "tests/test-prompt-assembly-python.sh"
else
  fail "tests/test-prompt-assembly-python.sh"
fi

if bash "$ROOT/tests/test-state-persistence-python.sh"; then
  pass "tests/test-state-persistence-python.sh"
else
  fail "tests/test-state-persistence-python.sh"
fi

if bash "$ROOT/tests/test-git-readonly-wrapper.sh"; then
  pass "tests/test-git-readonly-wrapper.sh (pantheon.execution)"
else
  fail "tests/test-git-readonly-wrapper.sh (pantheon.execution)"
fi

if bash "$ROOT/tests/test-execution-tier-python.sh"; then
  pass "tests/test-execution-tier-python.sh"
else
  fail "tests/test-execution-tier-python.sh"
fi

# ---------------------------------------------------------------------------
# Stage 2b — the `pantheon` Python package's own quality gates (ruff lint+format, mypy, pytest),
# run against a real, clean-machine `pip install` of the package (not just the dev-checkout
# `PYTHONPATH=` trick the other Python-port suites use) — proves the package actually installs
# and its `pantheon` console script resolves on PATH, on real Linux/GNU coreutils, not just this
# repo's macOS dev loop. ruff/mypy/pytest are build-time-only tooling (never a runtime
# [project.dependencies] entry — the stdlib-only runtime constraint is unaffected), installed
# into an isolated venv here so this stage never needs `--break-system-packages` against the
# container's system Python (Ubuntu 24.04 marks it externally-managed, PEP 668).
# ---------------------------------------------------------------------------
section "Stage 2b: pantheon Python package — pip install + ruff/mypy/pytest quality gates"

if ! command -v python3 >/dev/null 2>&1; then
  skip "pantheon package quality gates" "python3 not on PATH"
else
  VENV_DIR="$(mktemp -d)/venv"
  if python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
    pass "created an isolated venv for the pantheon package install"

    if "$VENV_DIR/bin/pip" install --quiet -e "$ROOT" ruff mypy pytest 2>/tmp/pip-install-err.$$; then
      pass "pip install -e . (plus ruff/mypy/pytest as build-time-only tooling) succeeded"

      if "$VENV_DIR/bin/pantheon" --help >/dev/null 2>&1; then
        pass "the installed 'pantheon' console script runs (--help exits 0)"
      else
        fail "the installed 'pantheon' console script failed to run"
      fi

      if ( cd "$ROOT" && "$VENV_DIR/bin/ruff" check pantheon/ tests/test_*.py ); then
        pass "ruff check pantheon/ tests/test_*.py is clean"
      else
        fail "ruff check pantheon/ tests/test_*.py reported findings"
      fi

      if ( cd "$ROOT" && "$VENV_DIR/bin/ruff" format --check pantheon/ tests/test_*.py ); then
        pass "ruff format --check pantheon/ tests/test_*.py is clean"
      else
        fail "ruff format --check pantheon/ tests/test_*.py reported unformatted files"
      fi

      if ( cd "$ROOT" && "$VENV_DIR/bin/mypy" ); then
        pass "mypy (pyproject.toml's [tool.mypy] config) is clean"
      else
        fail "mypy reported findings"
      fi

      if ( cd "$ROOT" && "$VENV_DIR/bin/pytest" -q ); then
        pass "pytest (the jqjson-matrix + pure-function-seam unit layer) passes"
      else
        fail "pytest reported failures"
      fi
    else
      fail "pip install -e . (plus ruff/mypy/pytest) failed (see /tmp/pip-install-err.$$)"
    fi
  else
    fail "could not create a venv for the pantheon package install"
  fi
  rm -rf "$(dirname "$VENV_DIR")"
fi

# ---------------------------------------------------------------------------
# Stage 3 — install.sh, all four flags, against a freshly git-init'ed scratch repo (not this
# repo's own checkout — a clean-machine install has no relationship to review-pantheon's tree).
# ---------------------------------------------------------------------------
section "Stage 3: install.sh --claude --cursor --codex --gemini against a fresh scratch repo"
SCRATCH_REPO="$(mktemp -d)"
git init --quiet "$SCRATCH_REPO"

if "$ROOT/install.sh" "$SCRATCH_REPO" --claude --cursor --codex --gemini >/dev/null; then
  pass "install.sh exits 0 against a fresh git-init scratch repo"
else
  fail "install.sh exited nonzero against a fresh git-init scratch repo"
fi

for f in \
  ".github/review-agents/artemis.md" \
  ".github/review-agents/pantheon/verdict.py" \
  ".github/review-agents/pantheon/execution.py" \
  ".github/workflows/review.yml" \
  "REVIEW_RULES.md" \
  ".claude/agents/artemis.md" \
  ".claude/commands/counsel.md" \
  ".cursor/agents/artemis.md" \
  ".agents/skills/artemis/SKILL.md" \
  ".gemini/commands/artemis.toml"
do
  if [[ -f "$SCRATCH_REPO/$f" ]]; then
    pass "install.sh: $f landed"
  else
    fail "install.sh: $f missing"
  fi
done

rm -rf "$SCRATCH_REPO"

# ---------------------------------------------------------------------------
# Stage 4 — bootstrap.sh into a fresh scratch prefix, and prove the installed `pantheon` package
# resolves its own agents/ and console scripts from THAT prefix (not from $ROOT) by invoking it
# with $ROOT nowhere on PATH or in the working directory. tests/test-bootstrap-release-e2e.sh
# covers the `--version`/release-fetch path's own prefix layout in more depth (including persona
# resolution from a real, non-editable site-packages install) — this stage is the plain,
# local-checkout install path.
# ---------------------------------------------------------------------------
section "Stage 4: bootstrap.sh into a fresh scratch prefix"
SCRATCH_PREFIX="$(mktemp -d)/.review-pantheon"

if "$ROOT/bootstrap.sh" --prefix "$SCRATCH_PREFIX" >/dev/null; then
  pass "bootstrap.sh exits 0 against a fresh scratch prefix"
else
  fail "bootstrap.sh exited nonzero against a fresh scratch prefix"
fi

for f in \
  "agents/artemis.md" \
  "venv/bin/pantheon" \
  "venv/bin/pantheon-git-readonly"
do
  if [[ -e "$SCRATCH_PREFIX/$f" ]]; then
    pass "bootstrap.sh: $f landed in prefix"
  else
    fail "bootstrap.sh: $f missing from prefix"
  fi
done

# Run it from an unrelated directory, via its absolute prefix path — proves the installed venv
# resolves correctly from a prefix install, not just from an in-repo checkout.
NEUTRAL_DIR="$(mktemp -d)"
PREFIX_HELP_OUT="$(cd "$NEUTRAL_DIR" && "$SCRATCH_PREFIX/venv/bin/pantheon" --help 2>&1)"
PREFIX_HELP_STATUS=$?
rm -rf "$NEUTRAL_DIR"

if [[ $PREFIX_HELP_STATUS -eq 0 ]] && grep -q "^usage: pantheon " <<<"$PREFIX_HELP_OUT"; then
  pass "bootstrap.sh: pantheon --help resolves from the prefix venv and runs"
else
  fail "bootstrap.sh: pantheon --help failed from the prefix (status=$PREFIX_HELP_STATUS): $PREFIX_HELP_OUT"
fi

rm -rf "$(dirname "$SCRATCH_PREFIX")"

# ---------------------------------------------------------------------------
# Stage 5 — the one tokened, networked stage: clone a small, stable public repo and run a full
# `pantheon gate --pr <n> --dry-run` against a real, pinned PR. Only runs when GH_TOKEN or
# GITHUB_TOKEN is set AND a real network probe against GitHub succeeds; either missing is a
# loud, non-fatal SKIP — this is the one stage a fully offline or sandboxed run can't do.
#
# Pinned target: octocat/Hello-World PR #10652 ("Add my practice note to README") — GitHub's
# own long-lived demo repo, a tiny closed (unmerged), single-line PR whose refs/pull/10652/head
# was verified reachable while writing this test. Chosen for size (fetches fast) and stability
# (a small, long-closed demo-repo PR is unlikely to ever be deleted or rewritten). Same
# conditional gating as everywhere else in this file (token + network), plus `pantheon.cli`
# needing to be importable — skipped loudly, not silently, when any of those isn't available.
# ---------------------------------------------------------------------------
section "Stage 5: tokened live dry-run against pantheon gate (conditional)"
SMOKE_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
PINNED_REPO="octocat/Hello-World"
PINNED_PR="10652"

if [[ -z "$SMOKE_TOKEN" ]]; then
  skip "tokened live dry-run (pantheon gate)" "no GH_TOKEN/GITHUB_TOKEN in the environment"
elif ! GH_TOKEN="$SMOKE_TOKEN" gh api rate_limit >/dev/null 2>&1; then
  skip "tokened live dry-run (pantheon gate)" "GH_TOKEN/GITHUB_TOKEN set but GitHub API is unreachable"
elif ! PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -c "import pantheon.cli" >/dev/null 2>&1; then
  skip "tokened live dry-run (pantheon gate)" "pantheon.cli is not importable"
else
  CLONE_DIR_PY="$(mktemp -d)"
  if GH_TOKEN="$SMOKE_TOKEN" git clone --quiet "https://github.com/${PINNED_REPO}.git" "$CLONE_DIR_PY" 2>/tmp/smoke-clone-err-py.$$; then
    pass "stage 5: cloned $PINNED_REPO"

    DRYRUN_OUT_PY="$(cd "$CLONE_DIR_PY" && GH_TOKEN="$SMOKE_TOKEN" PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -m pantheon.cli gate --pr "$PINNED_PR" --dry-run 2>&1)"
    DRYRUN_STATUS_PY=$?

    if [[ $DRYRUN_STATUS_PY -eq 0 || $DRYRUN_STATUS_PY -eq 1 ]]; then
      pass "stage 5: pantheon gate --pr $PINNED_PR --dry-run runs to completion (exit $DRYRUN_STATUS_PY)"
    else
      fail "stage 5: pantheon gate --pr $PINNED_PR --dry-run exited unexpectedly ($DRYRUN_STATUS_PY)"
    fi

    if grep -qE '\.prompt\.md"?$' <<<"$DRYRUN_OUT_PY"; then
      pass "stage 5: dry-run output shows a built prompt file (*.prompt.md)"
    else
      fail "stage 5: dry-run output missing a built prompt file path"
    fi

    if grep -q '\[dry-run\] would run: provider=' <<<"$DRYRUN_OUT_PY"; then
      pass "stage 5: dry-run output shows the would-be provider command"
    else
      fail "stage 5: dry-run output missing the would-be provider command line"
    fi

    if grep -q '\[dry-run\] would post this comment to PR #'"$PINNED_PR"'' <<<"$DRYRUN_OUT_PY" \
      && grep -q '| Agent | Verdict | Top finding |' <<<"$DRYRUN_OUT_PY"; then
      pass "stage 5: dry-run output shows the comment preview"
    else
      fail "stage 5: dry-run output missing the comment preview"
    fi
  else
    fail "stage 5: could not clone $PINNED_REPO (see /tmp/smoke-clone-err-py.$$)"
  fi
  rm -rf "$CLONE_DIR_PY"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "setup-smoke: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
