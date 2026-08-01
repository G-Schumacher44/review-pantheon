#!/usr/bin/env bash
# bootstrap.sh — user-level, repo-independent install of the review-gate CLI.
#
# Usage:
#   bootstrap.sh [--prefix ~/.review-pantheon] [--version vX.Y.Z]
#
# install.sh vendors review-pantheon's files INTO a target repo (so its CI checkout can see
# them). This script is the other lane: it puts the review-gate CLI itself somewhere on your
# machine ONCE — no footprint in any target repo — and you point PATH at it. From then on,
# `review-gate --pr <n>` works from inside any repo with a gh-authenticated remote, same as
# the in-repo `cli/review-gate` does. It does not touch your shell rc file; it prints the one
# line you add yourself.
#
# Two ways to run this:
#   1. From a local checkout:  ./bootstrap.sh [--prefix ...]
#   2. Via curl, no checkout:  curl -fsSL <raw-url-to-bootstrap.sh> | bash -s -- [--prefix ...] [--version vX.Y.Z]
#      This only works once review-pantheon is public on GitHub — see fetch_tarball() below.
#      Today (private repo) it fails loud with a clear message; it does not silently no-op.
#
# --version vX.Y.Z (remote-fetch path only — see RELEASING.md at repo root for how tags get
# cut): pulls the RELEASE tarball .github/workflows/release.yml built and published for that
# tag (review-pantheon-<tag>.tar.gz), instead of a fresh tarball of the current dev HEAD. It
# also fetches that release's SHA256SUMS and verifies the tarball's checksum BEFORE extracting
# anything — die loud on mismatch, refusing to touch the archive. This closes the security
# audit's LOW finding on unpinned/unverified remote fetches: --version pins to an immutable,
# checksummed artifact instead of trusting whatever a moving ref currently resolves to. Omit
# --version and the remote-fetch path keeps its original behavior — a fresh tarball of dev's
# current HEAD via GitHub's codeload endpoint, i.e. it TRACKS dev, unpinned and unchecksummed
# (codeload doesn't publish a checksum manifest for arbitrary-ref tarballs the way a Release
# does). A local-checkout run (form 1 above) ignores --version entirely — you already have a
# real checkout at whatever commit it's at, there's nothing to fetch.
#
# Idempotent: re-running with the same --prefix only touches files that changed. Same cmp-and-
# skip contract as install.sh's install_file — a destination file that differs from the
# shipped source (looks hand-edited) is left alone and reported skipped, never clobbered.
#
# No new dependencies beyond curl/tar (remote-fetch path only, unchanged) and sha256sum OR
# shasum for checksum verification — every mainstream platform ships at least one of those two
# (GNU coreutils sha256sum on Linux, shasum on stock macOS/BSD); both are handled, neither is a
# new install requirement.
set -euo pipefail

die() { echo "bootstrap.sh: $*" >&2; exit 1; }
note() { echo "bootstrap.sh: $*"; }

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--prefix /abs/path] [--version vX.Y.Z]
  (default prefix: ~/.review-pantheon; default version: none — tracks dev HEAD)

Installs the review-gate CLI (cli/review-gate, cli/lib/, cli/providers/, agents/) into the
prefix directory, independent of any target repo's checkout. Prints the one PATH line to add
yourself — this script never edits your shell rc.

--version vX.Y.Z pins the remote-fetch (curl | bash, no local checkout) path to a tagged,
checksummed release instead of dev's current HEAD — see this script's header comment.
EOF
}

REPO_OWNER="G-Schumacher44"
REPO_NAME="review-pantheon"

# ---------------------------------------------------------------------------
# Symlink-safe directory resolution — shared shape with the fix in cli/review-gate. Plain
# `dirname "${BASH_SOURCE[0]}"` breaks if this script is itself invoked through a symlink
# (e.g. run from a symlinked clone); this follows the link chain to the real file first.
# Deliberately not GNU `readlink -f` / coreutils `realpath` — neither ships on stock macOS.
#
# This is a DELIBERATE copy of cli/review-gate's resolver. bootstrap.sh must remain a single
# self-contained file because the curl|bash path fetches it alone, so it cannot source a
# shared lib — keep the two copies in sync by hand when either changes.
# ---------------------------------------------------------------------------
resolve_real_dir() {
  local src="$1"
  local hops=0
  while [[ -h "$src" ]]; do
    hops=$((hops + 1))
    if (( hops > 32 )); then
      echo "bootstrap.sh: resolve_real_dir: symlink chain exceeds 32 hops (cycle?) at '$src'" >&2
      exit 1
    fi
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

# detect_local_src — prints the repo root IF this script is running from inside a real
# review-pantheon checkout (cli/ and agents/ present as siblings). Fails (no output, nonzero)
# when read from a pipe (curl | bash leaves BASH_SOURCE[0] unset) or when run standalone
# without those directories alongside it.
detect_local_src() {
  local src="${BASH_SOURCE[0]:-}"
  [[ -n "$src" && -f "$src" ]] || return 1
  local dir
  dir="$(resolve_real_dir "$src")" || return 1
  [[ -d "$dir/cli" && -d "$dir/agents" && -f "$dir/cli/review-gate" ]] || return 1
  printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# fetch_tarball — the curl-pipe path, dev-HEAD lane (no --version given). GitHub's codeload
# "HEAD" ref resolves to whatever the repo's current default branch is, so this doesn't need to
# know or hardcode a branch name.
#
# Only works once review-pantheon is public: verified while writing this against the real
# repo — both https://codeload.github.com/G-Schumacher44/review-pantheon/tar.gz/HEAD and the
# refs/heads/main equivalent return HTTP 404 unauthenticated while the repo is private. That
# failure is caught below and reported with a clear next step, not masked as success.
# ---------------------------------------------------------------------------
fetch_tarball() {
  local url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/HEAD"
  command -v curl >/dev/null 2>&1 || { echo "bootstrap.sh: curl is required to bootstrap without a local checkout" >&2; return 1; }
  command -v tar >/dev/null 2>&1 || { echo "bootstrap.sh: tar is required to bootstrap without a local checkout" >&2; return 1; }

  local work
  work="$(mktemp -d)" || return 1
  FETCH_WORKDIR="$work"

  echo "bootstrap.sh: no local checkout detected — fetching $REPO_OWNER/$REPO_NAME from $url" >&2

  local http_status
  http_status="$(curl -sL -w '%{http_code}' -o "$work/repo.tar.gz" "$url" 2>/dev/null)" || http_status="000"

  if [[ "$http_status" != "200" || ! -s "$work/repo.tar.gz" ]]; then
    {
      echo "bootstrap.sh: could not fetch $url (HTTP $http_status)."
      echo "bootstrap.sh: review-pantheon is not public yet, so the curl-pipe install path"
      echo "bootstrap.sh: doesn't work today — this is expected, not a bug. Clone it and run"
      echo "bootstrap.sh: bootstrap.sh from the checkout instead:"
      echo "bootstrap.sh:   git clone https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
      echo "bootstrap.sh:   ./${REPO_NAME}/bootstrap.sh --prefix $PREFIX"
    } >&2
    return 1
  fi

  assert_safe_tar_listing "$work/repo.tar.gz" || return 1
  tar -xzf "$work/repo.tar.gz" -C "$work" || { echo "bootstrap.sh: failed to extract fetched tarball" >&2; return 1; }

  local extracted
  extracted="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [[ -z "$extracted" || ! -d "$extracted/cli" || ! -d "$extracted/agents" ]]; then
    echo "bootstrap.sh: fetched tarball did not contain the expected cli/ and agents/ directories" >&2
    return 1
  fi

  printf '%s' "$extracted"
}

# ---------------------------------------------------------------------------
# assert_safe_tar_listing <tarball> — defense-in-depth before extracting: lists the archive
# first and rejects any member path that is absolute or contains `..` (path-traversal / write-
# outside-workdir shapes) rather than trusting `tar -xzf` to sort it out. Shared by both
# fetch_tarball (codeload) and fetch_release_tarball (release asset) below — GitHub's own
# tarballs won't ever contain these, but both fetches trust an unauthenticated HTTP response, so
# this is a cheap belt-and-braces check on untrusted input, not a fix for a known-malicious
# source.
# ---------------------------------------------------------------------------
assert_safe_tar_listing() {
  local tarball="$1"
  local listing
  listing="$(tar -tzf "$tarball" 2>/dev/null)" \
    || { echo "bootstrap.sh: failed to list fetched tarball" >&2; return 1; }
  local member
  while IFS= read -r member; do
    [[ -z "$member" ]] && continue
    if [[ "$member" == /* || "$member" == *..* ]]; then
      echo "bootstrap.sh: refusing to extract tarball — unsafe member path '$member'" >&2
      return 1
    fi
  done <<<"$listing"
}

# ---------------------------------------------------------------------------
# Release-asset URL builders — pure functions (no I/O), factored out so they're unit-testable
# without a network call. Must match exactly what .github/workflows/release.yml publishes:
# review-pantheon-<tag>.tar.gz + SHA256SUMS as sibling assets on the tag's GitHub Release.
# ---------------------------------------------------------------------------
release_tarball_name() { printf 'review-pantheon-%s.tar.gz' "$1"; }
release_base_url() { printf 'https://github.com/%s/%s/releases/download/%s' "$REPO_OWNER" "$REPO_NAME" "$1"; }
release_tarball_url() { printf '%s/%s' "$(release_base_url "$1")" "$(release_tarball_name "$1")"; }
release_sums_url() { printf '%s/SHA256SUMS' "$(release_base_url "$1")"; }

# ---------------------------------------------------------------------------
# sha256_of <file> — prints the file's sha256 hex digest. Handles both sha256sum (GNU
# coreutils — Linux, this repo's release.yml runner) and shasum -a 256 (stock macOS, which has
# no sha256sum) — no new dependency either way, one of the two ships everywhere this script
# realistically runs.
# ---------------------------------------------------------------------------
sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo "bootstrap.sh: neither sha256sum nor shasum found — cannot verify checksum" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# verify_checksum <file> <sums_file> — looks up <file>'s basename in <sums_file> (standard
# `sha256sum`/`shasum -a 256` output format: "<hex>  <filename>", two spaces, or a leading `*`
# on the filename for binary mode — awk's default whitespace field-split handles both, and
# comparing $2 against both "name" and "*name" covers the marker) and compares against the
# file's actual digest. Returns nonzero on ANY mismatch or missing-entry case WITHOUT touching
# the file otherwise — callers must check the return before extracting anything.
# ---------------------------------------------------------------------------
verify_checksum() {
  local file="$1" sums_file="$2"
  local name expected actual

  [[ -f "$file" ]] || { echo "bootstrap.sh: file not found for checksum verification: $file" >&2; return 1; }
  [[ -f "$sums_file" ]] || { echo "bootstrap.sh: checksum manifest not found: $sums_file" >&2; return 1; }

  name="$(basename "$file")"
  expected="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$sums_file")"
  [[ -n "$expected" ]] || { echo "bootstrap.sh: no checksum entry for $name in $sums_file" >&2; return 1; }

  actual="$(sha256_of "$file")" || return 1

  if [[ "$actual" != "$expected" ]]; then
    echo "bootstrap.sh: checksum mismatch for $name" >&2
    echo "bootstrap.sh:   expected: $expected" >&2
    echo "bootstrap.sh:   actual:   $actual" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# fetch_release_tarball <version> — the curl-pipe path when --version is given: pulls the
# RELEASE tarball release.yml built for that tag, plus its SHA256SUMS, and verifies the
# tarball's checksum BEFORE any extraction (verify_checksum's failure return is checked and
# returned from BEFORE assert_safe_tar_listing/tar -xzf run — a checksum mismatch never reaches
# the archive). See this file's header comment for why this only applies to the --version lane
# (fetch_tarball's dev-HEAD codeload tarball has no equivalent published checksum to pin to).
# ---------------------------------------------------------------------------
fetch_release_tarball() {
  local version="$1"
  local tarball_name tarball_url sums_url
  tarball_name="$(release_tarball_name "$version")"
  tarball_url="$(release_tarball_url "$version")"
  sums_url="$(release_sums_url "$version")"

  command -v curl >/dev/null 2>&1 || { echo "bootstrap.sh: curl is required to bootstrap without a local checkout" >&2; return 1; }
  command -v tar >/dev/null 2>&1 || { echo "bootstrap.sh: tar is required to bootstrap without a local checkout" >&2; return 1; }

  local work
  work="$(mktemp -d)" || return 1
  FETCH_WORKDIR="$work"

  echo "bootstrap.sh: fetching release $version — $tarball_url" >&2

  local http_status
  http_status="$(curl -sL -w '%{http_code}' -o "$work/$tarball_name" "$tarball_url" 2>/dev/null)" || http_status="000"
  if [[ "$http_status" != "200" || ! -s "$work/$tarball_name" ]]; then
    {
      echo "bootstrap.sh: could not fetch $tarball_url (HTTP $http_status)."
      echo "bootstrap.sh: check that $version is a real, published release:"
      echo "bootstrap.sh:   https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
    } >&2
    return 1
  fi

  echo "bootstrap.sh: fetching checksum manifest — $sums_url" >&2
  local sums_status
  sums_status="$(curl -sL -w '%{http_code}' -o "$work/SHA256SUMS" "$sums_url" 2>/dev/null)" || sums_status="000"
  if [[ "$sums_status" != "200" || ! -s "$work/SHA256SUMS" ]]; then
    {
      echo "bootstrap.sh: could not fetch $sums_url (HTTP $sums_status)."
      echo "bootstrap.sh: refusing to install an unverifiable release tarball."
    } >&2
    return 1
  fi

  verify_checksum "$work/$tarball_name" "$work/SHA256SUMS" \
    || { echo "bootstrap.sh: refusing to extract $tarball_name — checksum verification failed" >&2; return 1; }
  # NOTE: stderr, not note() — this function's stdout is captured via command substitution
  # (SRC_ROOT="$(fetch_release_tarball ...)" in main()), so anything this function writes to
  # stdout other than the final extracted-path printf below would corrupt that return value.
  echo "bootstrap.sh: checksum verified for $tarball_name" >&2

  assert_safe_tar_listing "$work/$tarball_name" || return 1
  tar -xzf "$work/$tarball_name" -C "$work" || { echo "bootstrap.sh: failed to extract fetched tarball" >&2; return 1; }

  local extracted
  extracted="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [[ -z "$extracted" || ! -d "$extracted/cli" || ! -d "$extracted/agents" ]]; then
    echo "bootstrap.sh: fetched release tarball did not contain the expected cli/ and agents/ directories" >&2
    return 1
  fi

  printf '%s' "$extracted"
}

# install_file <src> <dest> — same cmp-and-skip contract as install.sh's install_file: a
# dest that already exists and differs from src is left alone and reported, not clobbered.
install_file() {
  local src="$1" dest="$2"
  if [[ -f "$dest" ]]; then
    if cmp -s "$src" "$dest"; then
      return 0
    fi
    SKIPPED+=("$dest")
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  note "installed $dest"
}

FETCH_WORKDIR=""
cleanup() {
  # Preserve the script's real exit status: an EXIT trap's own last command result otherwise
  # silently becomes the script's exit status — here that would mean a fully successful,
  # local-checkout run (FETCH_WORKDIR left empty, so the `[[ ... ]] && rm -rf` short-circuits
  # false) reports exit 1 despite doing everything right.
  local status=$?
  [[ -n "$FETCH_WORKDIR" && -d "$FETCH_WORKDIR" ]] && rm -rf "$FETCH_WORKDIR"
  return "$status"
}

# ---------------------------------------------------------------------------
# main — everything above this point is pure function/constant definitions, safe to `source`
# for unit-testing (e.g. tests/test-bootstrap-release.sh sources this file to exercise
# sha256_of/verify_checksum/release_*_url in isolation, with no network and no side effects,
# because the guard below only calls main when the script is EXECUTED, not sourced).
# ---------------------------------------------------------------------------
main() {
  PREFIX="$HOME/.review-pantheon"
  VERSION=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix) PREFIX="${2:-}"; shift 2 ;;
      --prefix=*) PREFIX="${1#*=}"; shift ;;
      --version) VERSION="${2:-}"; shift 2 ;;
      --version=*) VERSION="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done

  [[ -n "$PREFIX" ]] || die "--prefix requires a value"
  if [[ -n "$VERSION" && ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "--version must look like vX.Y.Z (got: $VERSION) — same shape as the tags release.yml builds from"
  fi

  trap cleanup EXIT

  if SRC_ROOT="$(detect_local_src)"; then
    note "installing from local checkout: $SRC_ROOT"
    [[ -z "$VERSION" ]] || note "--version $VERSION ignored — running from a local checkout, nothing to fetch"
  elif [[ -n "$VERSION" ]]; then
    SRC_ROOT="$(fetch_release_tarball "$VERSION")" || die "remote release install failed (see above)"
    note "installing from fetched release $VERSION: $SRC_ROOT"
  else
    SRC_ROOT="$(fetch_tarball)" || die "remote install failed (see above)"
    note "installing from fetched tarball (tracking dev): $SRC_ROOT"
  fi

  [[ -f "$SRC_ROOT/cli/review-gate" ]] || die "missing $SRC_ROOT/cli/review-gate"
  [[ -f "$SRC_ROOT/cli/lib/verdict.sh" ]] || die "missing $SRC_ROOT/cli/lib/verdict.sh"
  [[ -f "$SRC_ROOT/cli/lib/render_comment.sh" ]] || die "missing $SRC_ROOT/cli/lib/render_comment.sh"
  [[ -f "$SRC_ROOT/cli/lib/execution.sh" ]] || die "missing $SRC_ROOT/cli/lib/execution.sh"
  [[ -f "$SRC_ROOT/cli/lib/pantheon-git-readonly.sh" ]] || die "missing $SRC_ROOT/cli/lib/pantheon-git-readonly.sh"
  [[ -f "$SRC_ROOT/cli/lib/pantheon-base-pin.sh" ]] || die "missing $SRC_ROOT/cli/lib/pantheon-base-pin.sh"
  [[ -d "$SRC_ROOT/cli/providers" ]] || die "missing $SRC_ROOT/cli/providers"
  [[ -d "$SRC_ROOT/agents" ]] || die "missing $SRC_ROOT/agents"

  # -------------------------------------------------------------------------
  # Install — mirrors the source layout under $PREFIX (cli/review-gate, cli/lib/verdict.sh,
  # cli/lib/render_comment.sh, cli/lib/execution.sh, cli/lib/pantheon-git-readonly.sh,
  # cli/lib/pantheon-base-pin.sh, cli/providers/*.sh, agents/*.md) so review-gate's own
  # PANTHEON_ROOT-relative path resolution
  # (agents/ and cli/providers/ next to it) works unmodified from the prefix, exactly as it does
  # from an in-repo checkout.
  #
  # This manifest (the required-file checks above and the install_file calls below) is
  # hand-maintained and has already gone stale once — cli/lib/execution.sh landed without being
  # added here, so every bootstrap install broke at `source cli/lib/execution.sh` until a
  # follow-up commit caught it (a Codex P1 finding on this PR). tests/test-setup-smoke.sh's
  # Stage 4a now derives its own expected file list directly from cli/review-gate's `source`
  # lines (never hand-copied) and asserts every one of them landed in a fresh bootstrap prefix, so
  # the NEXT new cli/lib/*.sh file this repo adds fails CI here instead of silently recurring.
  # -------------------------------------------------------------------------
  SKIPPED=()

  mkdir -p "$PREFIX/cli/lib" "$PREFIX/cli/providers" "$PREFIX/agents"

  install_file "$SRC_ROOT/cli/review-gate" "$PREFIX/cli/review-gate"
  chmod +x "$PREFIX/cli/review-gate"

  install_file "$SRC_ROOT/cli/lib/verdict.sh" "$PREFIX/cli/lib/verdict.sh"
  install_file "$SRC_ROOT/cli/lib/render_comment.sh" "$PREFIX/cli/lib/render_comment.sh"
  install_file "$SRC_ROOT/cli/lib/execution.sh" "$PREFIX/cli/lib/execution.sh"
  install_file "$SRC_ROOT/cli/lib/pantheon-git-readonly.sh" "$PREFIX/cli/lib/pantheon-git-readonly.sh"
  chmod +x "$PREFIX/cli/lib/pantheon-git-readonly.sh"
  install_file "$SRC_ROOT/cli/lib/pantheon-base-pin.sh" "$PREFIX/cli/lib/pantheon-base-pin.sh"

  for f in "$SRC_ROOT"/cli/providers/*.sh; do
    install_file "$f" "$PREFIX/cli/providers/$(basename "$f")"
  done

  for f in "$SRC_ROOT"/agents/*.md; do
    install_file "$f" "$PREFIX/agents/$(basename "$f")"
  done

  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    note "left unchanged (differs from shipped version — looks customized):"
    for f in "${SKIPPED[@]}"; do
      note "  - $f"
    done
  fi

  cat <<EOF

review-pantheon CLI installed to $PREFIX

Add it to your PATH (this script does not edit your shell rc for you):

  export PATH="$PREFIX/cli:\$PATH"

Then, from inside any repo with a gh-authenticated remote:

  review-gate --pr <number> --dry-run

That runs entirely offline of any provider — it fetches real PR metadata, builds the real
prompts, and prints the would-be provider command and comment without calling a model or
posting anything. See docs/SETUP.md in review-pantheon for the full walkthrough.

Note: gate.conf and REVIEW_RULES.md are read from the TARGET repo you run review-gate in, not
from $PREFIX — copy gate.conf.example there yourself if you want non-default settings.
EOF
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
