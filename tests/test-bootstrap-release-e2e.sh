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
# identical explicit, enumerated CLI-surface file list (no globs) — so this also cross-checks
# that manifest still matches what bootstrap.sh's main() actually requires on disk.
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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

TAG="v8.8.8"
NAME="review-pantheon-${TAG}"
TARBALL_NAME="${NAME}.tar.gz"

# ---------------------------------------------------------------------------
# Build the fixture release tarball — same explicit manifest as release.yml's "Build versioned
# tarball" step (cli/, agents/, bootstrap.sh, install.sh, REVIEW_RULES.example.md,
# gate.conf.example, LICENSE, README.md), staged under a top-level review-pantheon-<tag>/ dir.
# ---------------------------------------------------------------------------
section "Build fixture release tarball (release.yml's manifest, verbatim)"

STAGE_ROOT="$WORKDIR/stage"
STAGE="$STAGE_ROOT/$NAME"
mkdir -p "$STAGE"
cp -R "$ROOT/cli" "$STAGE/cli"
cp -R "$ROOT/agents" "$STAGE/agents"
cp "$ROOT/bootstrap.sh" "$STAGE/bootstrap.sh"
cp "$ROOT/install.sh" "$STAGE/install.sh"
mkdir -p "$STAGE/action"
cp "$ROOT/action/decide_verdict.py" "$STAGE/action/decide_verdict.py"
cp "$ROOT/action/review.yml" "$STAGE/action/review.yml"
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
# Regression check for a Codex P1 finding on this PR: install.sh's default (no --user) mode
# reads $SCRIPT_DIR/action/decide_verdict.py and $SCRIPT_DIR/action/review.yml and dies loud if
# either is missing — a release tarball that ships install.sh without action/ ships a broken
# installer. Runs install.sh straight from the STAGED tree (pre-tar, same layout a real
# extraction produces) against a fresh scratch target, proving the manifest above is not just
# "the files are present" but "the shipped install.sh actually works."
# ---------------------------------------------------------------------------
section "install.sh runs successfully from the staged release tree (default mode)"

SCRATCH_TARGET="$WORKDIR/install-target"
mkdir -p "$SCRATCH_TARGET"
if install_out="$("$STAGE/install.sh" "$SCRATCH_TARGET" 2>&1)"; then
  pass "packaged install.sh exits 0 against a fresh scratch target"
else
  fail "packaged install.sh exited nonzero: $install_out"
fi

if [[ -f "$SCRATCH_TARGET/.github/review-agents/decide_verdict.py" && -f "$SCRATCH_TARGET/.github/workflows/review.yml" ]]; then
  pass "packaged install.sh installed decide_verdict.py and review.yml from the packaged action/ files"
else
  fail "packaged install.sh did not install the expected gate files: $install_out"
fi

# ---------------------------------------------------------------------------
# Standalone copy of bootstrap.sh (no sibling cli/agents dirs) — forces detect_local_src() to
# fail, exactly like the real curl|bash no-checkout case, so the remote-fetch path is what runs.
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

for f in \
  "cli/review-gate" \
  "cli/lib/verdict.sh" \
  "cli/lib/render_comment.sh" \
  "cli/lib/execution.sh" \
  "cli/lib/pantheon-git-readonly.sh" \
  "cli/lib/pantheon-base-pin.sh" \
  "cli/providers/claude.sh" \
  "agents/artemis.md"
do
  if [[ -f "$PREFIX_OK/$f" ]]; then
    pass "--version $TAG: $f landed in prefix"
  else
    fail "--version $TAG: $f MISSING from prefix"
  fi
done

if [[ -x "$PREFIX_OK/cli/review-gate" ]]; then
  pass "--version $TAG: cli/review-gate is executable in prefix"
else
  fail "--version $TAG: cli/review-gate is NOT executable in prefix"
fi

# Prove it's actually usable from the prefix, same shape as test-setup-smoke.sh's Stage 4 check.
NEUTRAL_DIR="$WORKDIR/neutral"
mkdir -p "$NEUTRAL_DIR"
help_out="$(cd "$NEUTRAL_DIR" && "$PREFIX_OK/cli/review-gate" --help 2>&1)"
help_status=$?
if [[ $help_status -eq 0 ]] && grep -q "^Usage: review-gate --pr" <<<"$help_out"; then
  pass "--version $TAG: installed review-gate --help resolves its lib/providers from the prefix and runs"
else
  fail "--version $TAG: installed review-gate --help failed (status=$help_status): $help_out"
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
