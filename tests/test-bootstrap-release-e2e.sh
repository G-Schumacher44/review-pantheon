#!/usr/bin/env bash
# tests/test-bootstrap-release-e2e.sh — integration test for bootstrap.sh's `--version` release-
# fetch path: a REAL fetch (via a stubbed `curl` serving local fixture bytes — no real network,
# same determinism rationale as tests/test-bootstrap-release.sh) that passes checksum
# verification and actually extracts and installs, plus the mismatch case all the way through to
# proving nothing lands in --prefix. tests/test-bootstrap-release.sh deliberately stops at
# testing verify_checksum/fetch_release_tarball's pieces in isolation — this file is what proves
# the whole success path (fetch -> verify -> list -> extract -> install) still works end to end,
# not just its individual parts (an Apollo finding on this PR: nothing else in the suite ever
# reached the success branch of fetch_release_tarball with a passing checksum).
#
# Builds its fixture "release" tarball the SAME way .github/workflows/release.yml does — the
# identical explicit, enumerated file list (no globs) — so this also cross-checks that manifest
# still matches what bootstrap.sh's main() actually requires on disk.
#
# No test framework — plain bash, `bash tests/test-bootstrap-release-e2e.sh` is the whole
# invocation (wired into .github/workflows/ci.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

section() { echo; echo "== $1 =="; }

WORKDIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$WORKDIR" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
trap 'rm -rf "$WORKDIR"' EXIT

TAG="v8.8.8"
NAME="review-pantheon-${TAG}"
TARBALL_NAME="${NAME}.tar.gz"

# ---------------------------------------------------------------------------
# Build the fixture release tarball — same explicit manifest as release.yml's "Build versioned
# tarball" step (agents/, skills/, pantheon/, pyproject.toml, bootstrap.sh, install.sh,
# REVIEW_RULES.example.md, gate.conf.example, LICENSE, README.md), staged under a top-level
# review-pantheon-<tag>/ dir. No action/ entry — issue #36 deleted the vendored
# action/review.yml; install.sh's Way A now GENERATES its thin-caller workflow instead of
# reading a shipped copy, so there is nothing under action/ for a release tarball to carry.
# ---------------------------------------------------------------------------
section "Build fixture release tarball (release.yml's manifest, verbatim)"

STAGE_ROOT="$WORKDIR/stage"
STAGE="$STAGE_ROOT/$NAME"
mkdir -p "$STAGE"
cp -R "$ROOT/agents" "$STAGE/agents"
cp -R "$ROOT/skills" "$STAGE/skills"
cp -R "$ROOT/pantheon" "$STAGE/pantheon"
cp "$ROOT/pyproject.toml" "$STAGE/pyproject.toml"
cp "$ROOT/bootstrap.sh" "$STAGE/bootstrap.sh"
cp "$ROOT/install.sh" "$STAGE/install.sh"
cp "$ROOT/REVIEW_RULES.example.md" "$STAGE/REVIEW_RULES.example.md"
cp "$ROOT/gate.conf.example" "$STAGE/gate.conf.example"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/README.md" "$STAGE/README.md"

ASSETS="$WORKDIR/assets"
mkdir -p "$ASSETS"
if tar -czf "$ASSETS/$TARBALL_NAME" -C "$STAGE_ROOT" "$NAME"; then
  pass "built fixture tarball $TARBALL_NAME"
else
  fail "could not build fixture tarball — aborting, nothing further can run"
  echo "bootstrap-release-e2e fixtures: $PASS passed, $FAIL failed"
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$ASSETS" && sha256sum "$TARBALL_NAME" > SHA256SUMS )
else
  ( cd "$ASSETS" && shasum -a 256 "$TARBALL_NAME" > SHA256SUMS )
fi
pass "generated real SHA256SUMS for the fixture tarball"

# ---------------------------------------------------------------------------
# Regression check for a Codex P1 finding on this repo's history (pre-#36): install.sh's default
# (no --user) mode used to read $SCRIPT_DIR/action/review.yml and the vendored pantheon/
# package, and died loud if either was missing — a release tarball that shipped install.sh
# without them shipped a broken installer. Since issue #36, install.sh GENERATES its
# thin-caller workflow instead of reading a shipped copy, and vendors no pantheon/ package at
# all — so the regression this guards against now is a release tarball whose install.sh dies for
# ANY reason (a missing agents//skills/ dir, say) when run from the staged tree. Runs install.sh
# straight from the STAGED tree (pre-tar, same layout a real extraction produces) against a
# fresh scratch target, proving the manifest above is not just "the files are present" but "the
# shipped install.sh actually works."
# ---------------------------------------------------------------------------
section "install.sh runs successfully from the staged release tree (default mode)"

SCRATCH_TARGET="$WORKDIR/install-target"
mkdir -p "$SCRATCH_TARGET"
if install_out="$("$STAGE/install.sh" "$SCRATCH_TARGET" 2>&1)"; then
  pass "packaged install.sh exits 0 against a fresh scratch target"
else
  fail "packaged install.sh exited nonzero: $install_out"
fi

if [[ -f "$SCRATCH_TARGET/.github/review-agents/artemis.md" && -f "$SCRATCH_TARGET/.github/workflows/review.yml" && ! -e "$SCRATCH_TARGET/.github/review-agents/pantheon" ]]; then
  pass "packaged install.sh installed personas + generated review.yml, vendored no pantheon/ package"
else
  fail "packaged install.sh did not install the expected gate files: $install_out"
fi

# ---------------------------------------------------------------------------
# Standalone copy of bootstrap.sh (no sibling agents/pantheon dirs) — forces detect_local_src()
# to fail, exactly like the real curl|bash no-checkout case, so the remote-fetch path is what
# runs.
# ---------------------------------------------------------------------------
STANDALONE="$WORKDIR/standalone"
mkdir -p "$STANDALONE"
cp "$ROOT/bootstrap.sh" "$STANDALONE/bootstrap.sh"
chmod +x "$STANDALONE/bootstrap.sh"

# curl stub: serves the local fixture bytes for the exact URLs fetch_release_tarball computes,
# honoring `-o <file>` and printing the `-w '%{http_code}'` status — no real network involved.
STUB_BIN="$WORKDIR/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<STUB
#!/usr/bin/env bash
out=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  if [[ "\${args[i]}" == "-o" ]]; then
    out="\${args[i+1]}"
  fi
done
url="\${args[-1]}"
case "\$url" in
  */${TARBALL_NAME}) cp "\$CURL_STUB_ASSETS/${TARBALL_NAME}" "\$out"; echo -n "200" ;;
  */SHA256SUMS) cp "\$CURL_STUB_ASSETS/SHA256SUMS" "\$out"; echo -n "200" ;;
  *) echo -n "000" ;;
esac
STUB
chmod +x "$STUB_BIN/curl"

# ---------------------------------------------------------------------------
# Happy path — checksum matches, full install succeeds.
# ---------------------------------------------------------------------------
section "--version $TAG happy path — real checksum-verified fetch, extract, install"

PREFIX_OK="$WORKDIR/prefix-ok"
happy_out="$(CURL_STUB_ASSETS="$ASSETS" PATH="$STUB_BIN:$PATH" "$STANDALONE/bootstrap.sh" --version "$TAG" --prefix "$PREFIX_OK" 2>&1)"
happy_status=$?

if [[ $happy_status -eq 0 ]]; then
  pass "--version $TAG: bootstrap.sh exits 0"
else
  fail "--version $TAG: bootstrap.sh exited $happy_status: $happy_out"
fi

if grep -q "checksum verified for $TARBALL_NAME" <<<"$happy_out"; then
  pass "--version $TAG: checksum-verified message printed"
else
  fail "--version $TAG: missing checksum-verified message: $happy_out"
fi

# bootstrap.sh no longer copies a bare agents/*.md tree into $PREFIX -- pantheon.cli._agents_dir()
# resolves personas from the installed package's own package data (proved below), so a second,
# unused on-disk copy was dead weight. Prove the venv install is actually usable from the prefix,
# same shape as
# test-setup-smoke.sh's Stage 4 check.
NEUTRAL_DIR="$WORKDIR/neutral"
mkdir -p "$NEUTRAL_DIR"

# ---------------------------------------------------------------------------
# The pantheon package venv — bootstrap.sh creates a venv under --prefix and pip-installs the
# package fetched/extracted above into it. Proves the whole real path: a venv landed under the
# prefix, `pantheon`/`pantheon-git-readonly` console scripts exist there, `pantheon --help`
# actually runs, and pantheon.execution's own wrapper-adjacency resolution (issue #21 P1) finds
# pantheon-git-readonly correctly from this real, non-mocked install (no sys.executable
# monkeypatching here — this is the real thing).
# ---------------------------------------------------------------------------
section "--version $TAG: the pantheon package venv installs under --prefix and runs"

if [[ -x "$PREFIX_OK/venv/bin/pantheon" ]]; then
  pass "--version $TAG: \$PREFIX/venv/bin/pantheon exists and is executable"
else
  fail "--version $TAG: \$PREFIX/venv/bin/pantheon is MISSING or not executable"
fi

if [[ -x "$PREFIX_OK/venv/bin/pantheon-git-readonly" ]]; then
  pass "--version $TAG: \$PREFIX/venv/bin/pantheon-git-readonly exists and is executable"
else
  fail "--version $TAG: \$PREFIX/venv/bin/pantheon-git-readonly is MISSING or not executable"
fi

# NO_COLOR: Python 3.14's argparse colorizes --help, and it honors FORCE_COLOR even when
# stdout is a pipe. A contributor with FORCE_COLOR set in their shell would otherwise get
# ANSI escapes wrapped around "usage:" and this anchored grep would fail on a perfectly
# healthy install. CI does not set it, so the breakage only ever shows up locally — the
# environment-dependent-test shape this repo keeps finding.
pantheon_help_out="$(cd "$NEUTRAL_DIR" && NO_COLOR=1 "$PREFIX_OK/venv/bin/pantheon" --help 2>&1)"
pantheon_help_status=$?
if [[ $pantheon_help_status -eq 0 ]] && grep -q "^usage: pantheon " <<<"$pantheon_help_out"; then
  pass "--version $TAG: installed pantheon --help runs from the prefix venv"
else
  fail "--version $TAG: installed pantheon --help failed (status=$pantheon_help_status): $pantheon_help_out"
fi

# Persona resolution from the REAL, non-editable venv install -- a Codex review finding on this
# port's own PR: `pip install "$SRC_ROOT"` (this bootstrap.sh step, non-editable) packages only
# `pantheon*` unless pyproject.toml's package-data mapping carries agents/*.md along too, and
# pantheon.cli._agents_dir() resolved agents/ as a SIBLING of its own installed location on
# disk -- true for a dev checkout, never for a real site-packages install. Without the fix,
# --help still exits 0 (it never touches personas) but every real `pantheon gate` run would fail
# at prompt construction with "no persona file". Run from $NEUTRAL_DIR (no source checkout
# anywhere nearby) to prove the installed copy is genuinely self-contained.
pantheon_agents_out="$(cd "$NEUTRAL_DIR" && "$PREFIX_OK/venv/bin/python3" -c "
from pantheon import cli
d = cli._agents_dir()
print(d)
print((d / 'artemis.md').is_file())
" 2>&1)"
if grep -q "^True$" <<<"$pantheon_agents_out" && grep -qF "$PREFIX_OK/venv" <<<"$pantheon_agents_out"; then
  pass "--version $TAG: installed pantheon package resolves agents/artemis.md from its own site-packages (no source checkout needed)"
else
  fail "--version $TAG: installed pantheon package could NOT resolve agents/artemis.md from the venv install: $pantheon_agents_out"
fi

# ---------------------------------------------------------------------------
# Mismatch path, end to end — same fetch, but SHA256SUMS is wrong. Must refuse before
# extraction: bootstrap.sh exits nonzero and --prefix is never created/populated.
# ---------------------------------------------------------------------------
section "--version $TAG mismatch path — corrupt SHA256SUMS refuses before extraction, empty prefix"

ASSETS_BAD="$WORKDIR/assets-bad"
mkdir -p "$ASSETS_BAD"
cp "$ASSETS/$TARBALL_NAME" "$ASSETS_BAD/$TARBALL_NAME"
echo "0000000000000000000000000000000000000000000000000000000000000000  ${TARBALL_NAME}" > "$ASSETS_BAD/SHA256SUMS"

PREFIX_BAD="$WORKDIR/prefix-bad"
mismatch_out="$(CURL_STUB_ASSETS="$ASSETS_BAD" PATH="$STUB_BIN:$PATH" "$STANDALONE/bootstrap.sh" --version "$TAG" --prefix "$PREFIX_BAD" 2>&1)"
mismatch_status=$?

if [[ $mismatch_status -ne 0 ]]; then
  pass "--version $TAG (corrupt sums): bootstrap.sh exits nonzero"
else
  fail "--version $TAG (corrupt sums): bootstrap.sh exited 0 — should have refused"
fi

if grep -q "checksum mismatch" <<<"$mismatch_out"; then
  pass "--version $TAG (corrupt sums): reports checksum mismatch"
else
  fail "--version $TAG (corrupt sums): missing checksum-mismatch message: $mismatch_out"
fi

if [[ ! -e "$PREFIX_BAD" || -z "$(find "$PREFIX_BAD" -type f 2>/dev/null)" ]]; then
  pass "--version $TAG (corrupt sums): nothing installed under --prefix"
else
  fail "--version $TAG (corrupt sums): --prefix contains files despite the checksum mismatch"
fi

echo
echo "bootstrap-release-e2e fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
