#!/usr/bin/env bash
# tests/test-bootstrap-release.sh — fixture test for bootstrap.sh's --version / release-fetch
# additions: the release-asset URL builders, sha256_of/verify_checksum (checksum verification
# that must refuse BEFORE any extraction on mismatch — the curl-pipe lane otherwise installs
# whatever an unauthenticated HTTP response contains, with nothing to catch a truncated
# download or a tampered/stale response), and --version flag parsing/validation. Everything here
# runs OFFLINE — no real network call is made or required, including the "fails loud without
# network" case, which stubs `curl` to simulate a failure deterministically rather than
# depending on the sandbox's actual connectivity. See tests/test-bootstrap-release-e2e.sh for the
# happy-path integration test (real checksum match through to files landing in --prefix) this
# file deliberately does NOT cover — kept separate so a slow/flaky integration case can't block
# the fast, always-run unit suite below.
#
# bootstrap.sh is written so its function/constant definitions are sourceable (main() only runs
# when the script is EXECUTED, guarded by a BASH_SOURCE-vs-$0 check at the bottom of the file) —
# same "extract the real thing, don't hand-copy it" principle as
# tests/test-state-persistence.sh's update_review_gate_state() extraction, just via `source`
# instead of an awk extractor since bootstrap.sh's helpers are already free functions.
#
# No test framework — plain bash, `bash tests/test-bootstrap-release.sh` is the whole invocation
# (wired into .github/workflows/ci.yml and .github/workflows/release.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/bootstrap.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

section() { echo; echo "== $1 =="; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Source bootstrap.sh's function/constant definitions. Its own `set -euo pipefail` leaks into
# THIS shell on source (same process, not a subshell) — drop -e right after to match this test
# file's own convention (checked return codes via if/||, not abort-on-first-error); keep -u and
# pipefail.
# ---------------------------------------------------------------------------
section "Source bootstrap.sh (functions only — main() must NOT run)"

# shellcheck disable=SC1090
source "$BOOTSTRAP"
set +e
set -uo pipefail

if declare -F sha256_of >/dev/null && declare -F verify_checksum >/dev/null && declare -F fetch_release_tarball >/dev/null; then
  pass "sourced bootstrap.sh: sha256_of/verify_checksum/fetch_release_tarball are defined"
else
  fail "sourced bootstrap.sh: expected functions are missing — bootstrap.sh's shape changed"
fi

if [[ -z "${PREFIX:-}" && -z "${VERSION:-}" ]]; then
  pass "sourcing bootstrap.sh did NOT run main() (PREFIX/VERSION unset)"
else
  fail "sourcing bootstrap.sh appears to have run main() — PREFIX='${PREFIX:-}' VERSION='${VERSION:-}'"
fi

# ---------------------------------------------------------------------------
# Release-asset URL builders — pure, no I/O. Must match exactly what
# .github/workflows/release.yml publishes.
# ---------------------------------------------------------------------------
section "Release-asset URL builders"

TAG="v1.2.3"
EXP_TARBALL_NAME="review-pantheon-v1.2.3.tar.gz"
EXP_TARBALL_URL="https://github.com/G-Schumacher44/review-pantheon/releases/download/v1.2.3/review-pantheon-v1.2.3.tar.gz"
EXP_SUMS_URL="https://github.com/G-Schumacher44/review-pantheon/releases/download/v1.2.3/SHA256SUMS"

got_name="$(release_tarball_name "$TAG")"
if [[ "$got_name" == "$EXP_TARBALL_NAME" ]]; then
  pass "release_tarball_name: $got_name"
else
  fail "release_tarball_name: got '$got_name', expected '$EXP_TARBALL_NAME'"
fi

got_tarball_url="$(release_tarball_url "$TAG")"
if [[ "$got_tarball_url" == "$EXP_TARBALL_URL" ]]; then
  pass "release_tarball_url: $got_tarball_url"
else
  fail "release_tarball_url: got '$got_tarball_url', expected '$EXP_TARBALL_URL'"
fi

got_sums_url="$(release_sums_url "$TAG")"
if [[ "$got_sums_url" == "$EXP_SUMS_URL" ]]; then
  pass "release_sums_url: $got_sums_url"
else
  fail "release_sums_url: got '$got_sums_url', expected '$EXP_SUMS_URL'"
fi

# ---------------------------------------------------------------------------
# sha256_of — cross-checked against python3's hashlib (an independent implementation from
# whichever of sha256sum/shasum sha256_of itself shells out to), so this actually exercises the
# awk field-extraction logic, not just "the same binary agrees with itself".
# ---------------------------------------------------------------------------
section "sha256_of"

FIXTURE_FILE="$WORKDIR/fixture.txt"
printf 'review-pantheon release checksum fixture\n' > "$FIXTURE_FILE"

expected_hash="$(python3 -c "
import hashlib
with open('$FIXTURE_FILE', 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
")"
actual_hash="$(sha256_of "$FIXTURE_FILE")"

if [[ "$actual_hash" == "$expected_hash" && "$actual_hash" =~ ^[0-9a-f]{64}$ ]]; then
  pass "sha256_of matches python3 hashlib and is a bare 64-char hex digest ($actual_hash)"
else
  fail "sha256_of: got '$actual_hash', expected '$expected_hash'"
fi

# ---------------------------------------------------------------------------
# verify_checksum — happy path, both sha256sum's two-space format and shasum's binary-mode
# (leading '*') format, plus the mismatch and missing-entry refusal cases. This is the logic
# fetch_release_tarball calls BEFORE assert_safe_tar_listing/tar -xzf — see the structural check
# further down that proves that ordering directly from the source, not just by convention here.
# ---------------------------------------------------------------------------
section "verify_checksum — happy path"

SUMS_TWOSPACE="$WORKDIR/SHA256SUMS.twospace"
printf '%s  %s\n' "$expected_hash" "$(basename "$FIXTURE_FILE")" > "$SUMS_TWOSPACE"
if verify_checksum "$FIXTURE_FILE" "$SUMS_TWOSPACE"; then
  pass "verify_checksum: matching hash (sha256sum two-space format) verifies clean"
else
  fail "verify_checksum: matching hash (two-space format) unexpectedly failed"
fi

SUMS_BINARY="$WORKDIR/SHA256SUMS.binary"
printf '%s *%s\n' "$expected_hash" "$(basename "$FIXTURE_FILE")" > "$SUMS_BINARY"
if verify_checksum "$FIXTURE_FILE" "$SUMS_BINARY"; then
  pass "verify_checksum: matching hash (shasum binary-mode '*name' format) verifies clean"
else
  fail "verify_checksum: matching hash (binary-mode format) unexpectedly failed"
fi

section "verify_checksum — mismatch and missing-entry refusal"

SUMS_MISMATCH="$WORKDIR/SHA256SUMS.mismatch"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$(basename "$FIXTURE_FILE")" > "$SUMS_MISMATCH"
mismatch_err="$(verify_checksum "$FIXTURE_FILE" "$SUMS_MISMATCH" 2>&1 1>/dev/null)"
mismatch_status=$?
if [[ $mismatch_status -ne 0 ]] && grep -q "checksum mismatch" <<<"$mismatch_err"; then
  pass "verify_checksum: wrong hash returns nonzero and reports 'checksum mismatch'"
else
  fail "verify_checksum: wrong hash did not refuse as expected (status=$mismatch_status, stderr: $mismatch_err)"
fi

SUMS_NOENTRY="$WORKDIR/SHA256SUMS.noentry"
printf '%s  some-other-file.tar.gz\n' "$expected_hash" > "$SUMS_NOENTRY"
noentry_err="$(verify_checksum "$FIXTURE_FILE" "$SUMS_NOENTRY" 2>&1 1>/dev/null)"
noentry_status=$?
if [[ $noentry_status -ne 0 ]] && grep -q "no checksum entry" <<<"$noentry_err"; then
  pass "verify_checksum: no matching entry in SHA256SUMS returns nonzero and reports it"
else
  fail "verify_checksum: missing-entry case did not refuse as expected (status=$noentry_status, stderr: $noentry_err)"
fi

# verify_checksum itself never extracts anything (it's a pure compare) — "refuses before
# extraction" is a structural property of fetch_release_tarball's call order, checked next.
# ---------------------------------------------------------------------------
# Structural check — derived directly from bootstrap.sh's source (never hand-copied): inside
# fetch_release_tarball(), the verify_checksum call must appear BEFORE both tar invocations
# (assert_safe_tar_listing's tar -tzf and the tar -xzf extraction). Same "extract from the real
# file, don't just assert by convention" pattern tests/test-setup-smoke.sh's Stage 4a uses.
# ---------------------------------------------------------------------------
section "Structural: verify_checksum runs before any tar listing/extraction in fetch_release_tarball"

FUNC_BODY="$(awk '
  /^fetch_release_tarball\(\) \{/ { grab=1 }
  grab { print }
  grab && /^}/ { exit }
' "$BOOTSTRAP")"

if [[ -z "$FUNC_BODY" ]]; then
  fail "could not extract fetch_release_tarball() from bootstrap.sh — its shape changed; update this extractor"
else
  verify_line="$(grep -n 'verify_checksum ' <<<"$FUNC_BODY" | head -1 | cut -d: -f1)"
  tar_listing_line="$(grep -n 'assert_safe_tar_listing' <<<"$FUNC_BODY" | head -1 | cut -d: -f1)"
  tar_extract_line="$(grep -n 'tar -xzf' <<<"$FUNC_BODY" | head -1 | cut -d: -f1)"

  if [[ -n "$verify_line" && -n "$tar_listing_line" && -n "$tar_extract_line" \
        && "$verify_line" -lt "$tar_listing_line" && "$verify_line" -lt "$tar_extract_line" ]]; then
    pass "fetch_release_tarball: verify_checksum (line $verify_line) precedes tar listing (line $tar_listing_line) and extraction (line $tar_extract_line)"
  else
    fail "fetch_release_tarball: verify_checksum does not clearly precede tar listing/extraction (verify=$verify_line listing=$tar_listing_line extract=$tar_extract_line)"
  fi
fi

# ---------------------------------------------------------------------------
# --version flag parsing and validation — offline. Bad format must die immediately (before any
# network attempt); well-formed but nonexistent versions must fail loud via a stubbed, always-
# failing `curl` (so this is deterministic regardless of the sandbox's real connectivity), never
# silently no-op, and never leave anything installed in --prefix.
# ---------------------------------------------------------------------------
section "--version flag: format validation (offline, no network attempted)"

BAD_VERSION_PREFIX="$WORKDIR/bad-version-prefix"
bad_out="$("$BOOTSTRAP" --version notaversion --prefix "$BAD_VERSION_PREFIX" 2>&1)"
bad_status=$?
if [[ $bad_status -ne 0 ]] && grep -q "must look like vX.Y.Z" <<<"$bad_out"; then
  pass "--version notaversion: dies loud with a clear format message (status=$bad_status)"
else
  fail "--version notaversion: did not die as expected (status=$bad_status, output: $bad_out)"
fi
if [[ ! -e "$BAD_VERSION_PREFIX" ]]; then
  pass "--version notaversion: nothing was created under --prefix"
else
  fail "--version notaversion: --prefix was created despite the format rejection"
fi

section "--version flag: well-formed but unfetchable — fails loud, nothing installed (stubbed curl, no real network)"

# Isolated scratch copy of ONLY bootstrap.sh (no sibling pantheon/, agents/, or pyproject.toml)
# so detect_local_src() fails and the remote-fetch path is forced, exactly like the real
# curl|bash no-checkout case. (detect_local_src() checked for cli/ instead of pantheon/ before
# the bash CLI's removal in #29; that directory doesn't exist at all anymore.)
STANDALONE_DIR="$WORKDIR/standalone"
mkdir -p "$STANDALONE_DIR"
cp "$BOOTSTRAP" "$STANDALONE_DIR/bootstrap.sh"
chmod +x "$STANDALONE_DIR/bootstrap.sh"

# A `curl` stub that always reports failure, placed first on PATH — makes "no network" a
# deterministic test condition instead of depending on the sandbox's actual connectivity, and
# proves the resulting failure message names the URL fetch_release_tarball actually computed.
STUB_BIN="$WORKDIR/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Always "fails" the fetch: writes nothing, prints a fake non-200 status to stdout (the -w
# format bootstrap.sh's curl call requests), like an offline/DNS-failure curl would.
echo -n "000"
exit 0
STUB
chmod +x "$STUB_BIN/curl"

UNFETCHABLE_PREFIX="$WORKDIR/unfetchable-prefix"
unfetchable_out="$(PATH="$STUB_BIN:$PATH" "$STANDALONE_DIR/bootstrap.sh" --version v9.9.9 --prefix "$UNFETCHABLE_PREFIX" 2>&1)"
unfetchable_status=$?

EXP_STUB_URL="$(release_tarball_url "v9.9.9")"

if [[ $unfetchable_status -ne 0 ]]; then
  pass "--version v9.9.9 with a failing curl: exits nonzero (status=$unfetchable_status)"
else
  fail "--version v9.9.9 with a failing curl: exited 0 — should have failed loud"
fi

if grep -qF "$EXP_STUB_URL" <<<"$unfetchable_out"; then
  pass "--version v9.9.9: failure message names the constructed release tarball URL"
else
  fail "--version v9.9.9: failure message did not mention the expected URL ($EXP_STUB_URL); output: $unfetchable_out"
fi

if grep -q "remote release install failed" <<<"$unfetchable_out"; then
  pass "--version v9.9.9: fails loud via die(), not a silent no-op"
else
  fail "--version v9.9.9: missing the expected die() message; output: $unfetchable_out"
fi

if [[ ! -e "$UNFETCHABLE_PREFIX" || -z "$(find "$UNFETCHABLE_PREFIX" -type f 2>/dev/null)" ]]; then
  pass "--version v9.9.9: nothing was installed under --prefix after the failed fetch"
else
  fail "--version v9.9.9: --prefix contains files despite the fetch failing"
fi

echo
echo "bootstrap-release fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
