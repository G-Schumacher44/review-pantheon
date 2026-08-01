#!/usr/bin/env bash
# bootstrap.sh — user-level, repo-independent install of the review-gate CLI.
#
# Usage:
#   bootstrap.sh [--prefix ~/.review-pantheon]
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
#   2. Via curl, no checkout:  curl -fsSL <raw-url-to-bootstrap.sh> | bash -s -- [--prefix ...]
#      This only works once review-pantheon is public on GitHub — see fetch_tarball() below.
#      Today (private repo) it fails loud with a clear message; it does not silently no-op.
#
# Idempotent: re-running with the same --prefix only touches files that changed. Same cmp-and-
# skip contract as install.sh's install_file — a destination file that differs from the
# shipped source (looks hand-edited) is left alone and reported skipped, never clobbered.
set -euo pipefail

die() { echo "bootstrap.sh: $*" >&2; exit 1; }
note() { echo "bootstrap.sh: $*"; }

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--prefix /abs/path]   (default: ~/.review-pantheon)

Installs the review-gate CLI (cli/review-gate, cli/lib/, cli/providers/, agents/) into the
prefix directory, independent of any target repo's checkout. Prints the one PATH line to add
yourself — this script never edits your shell rc.
EOF
}

REPO_OWNER="G-Schumacher44"
REPO_NAME="review-pantheon"
PREFIX="$HOME/.review-pantheon"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:-}"; shift 2 ;;
    --prefix=*) PREFIX="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

[[ -n "$PREFIX" ]] || die "--prefix requires a value"

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
# fetch_tarball — the curl-pipe path. GitHub's codeload "HEAD" ref resolves to whatever the
# repo's current default branch is, so this doesn't need to know or hardcode a branch name.
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

  # Defense-in-depth before extracting: list the archive first and reject any member path that
  # is absolute or contains `..` (path-traversal / write-outside-workdir shapes) rather than
  # trusting `tar -xzf` to sort it out. GitHub's own codeload tarballs won't ever contain these,
  # but the fetch above trusts an unauthenticated HTTP response, so this is a cheap belt-and-
  # braces check on untrusted input, not a fix for a known-malicious source.
  local listing
  listing="$(tar -tzf "$work/repo.tar.gz" 2>/dev/null)" \
    || { echo "bootstrap.sh: failed to list fetched tarball" >&2; return 1; }
  while IFS= read -r member; do
    [[ -z "$member" ]] && continue
    if [[ "$member" == /* || "$member" == *..* ]]; then
      echo "bootstrap.sh: refusing to extract tarball — unsafe member path '$member'" >&2
      return 1
    fi
  done <<<"$listing"

  tar -xzf "$work/repo.tar.gz" -C "$work" || { echo "bootstrap.sh: failed to extract fetched tarball" >&2; return 1; }

  local extracted
  extracted="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  if [[ -z "$extracted" || ! -d "$extracted/cli" || ! -d "$extracted/agents" ]]; then
    echo "bootstrap.sh: fetched tarball did not contain the expected cli/ and agents/ directories" >&2
    return 1
  fi

  printf '%s' "$extracted"
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
trap cleanup EXIT

if SRC_ROOT="$(detect_local_src)"; then
  note "installing from local checkout: $SRC_ROOT"
else
  SRC_ROOT="$(fetch_tarball)" || die "remote install failed (see above)"
  note "installing from fetched tarball: $SRC_ROOT"
fi

[[ -f "$SRC_ROOT/cli/review-gate" ]] || die "missing $SRC_ROOT/cli/review-gate"
[[ -f "$SRC_ROOT/cli/lib/verdict.sh" ]] || die "missing $SRC_ROOT/cli/lib/verdict.sh"
[[ -f "$SRC_ROOT/cli/lib/render_comment.sh" ]] || die "missing $SRC_ROOT/cli/lib/render_comment.sh"
[[ -f "$SRC_ROOT/cli/lib/execution.sh" ]] || die "missing $SRC_ROOT/cli/lib/execution.sh"
[[ -d "$SRC_ROOT/cli/providers" ]] || die "missing $SRC_ROOT/cli/providers"
[[ -d "$SRC_ROOT/agents" ]] || die "missing $SRC_ROOT/agents"

# ---------------------------------------------------------------------------
# Install — mirrors the source layout under $PREFIX (cli/review-gate, cli/lib/verdict.sh,
# cli/lib/render_comment.sh, cli/lib/execution.sh, cli/providers/*.sh, agents/*.md) so
# review-gate's own PANTHEON_ROOT-relative path resolution (agents/ and cli/providers/ next to
# it) works unmodified from the prefix, exactly as it does from an in-repo checkout.
# ---------------------------------------------------------------------------
SKIPPED=()

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

mkdir -p "$PREFIX/cli/lib" "$PREFIX/cli/providers" "$PREFIX/agents"

install_file "$SRC_ROOT/cli/review-gate" "$PREFIX/cli/review-gate"
chmod +x "$PREFIX/cli/review-gate"

install_file "$SRC_ROOT/cli/lib/verdict.sh" "$PREFIX/cli/lib/verdict.sh"
install_file "$SRC_ROOT/cli/lib/render_comment.sh" "$PREFIX/cli/lib/render_comment.sh"
install_file "$SRC_ROOT/cli/lib/execution.sh" "$PREFIX/cli/lib/execution.sh"

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
