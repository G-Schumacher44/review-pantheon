#!/usr/bin/env bash
# cli/lib/pantheon-base-pin.sh — symlink-safe base-pinned file reads.
#
# Every base-pinned read in this repo (issue #6's class statement, DESIGN.md's "Security
# posture") uses `git show <base-sha>:<path>` to read a file's content from the PR's BASE
# commit instead of the checked-out working tree. That's correct for a regular file, but a
# Codex P2 finding on PR #8 (this class's own follow-up round) caught the gap: git stores a
# symlink as a mode-120000 blob whose "content" is the link TARGET STRING, not the referenced
# file's bytes. `git show $BASE_SHA:path` on a symlinked path therefore returns a pathname, not
# persona/rules/decider content — for a target repo using symlinked custom personas (a
# legitimate pattern: `.github/custom-personas/artemis.md -> ../../agents/artemis.md`), the
# previously-working checkout-based read silently broke into a garbage prompt once base-pinning
# landed.
#
# pantheon_base_pinned_read resolves that: it detects a symlink via `git ls-tree`, follows the
# chain treating each target as a path RELATIVE TO THE SYMLINK'S OWN DIRECTORY (git's own
# semantics for a tracked symlink), normalizes it against the repo root using pure string
# manipulation only (no filesystem access — this is a git-tree-relative path, not a real one,
# so there is nothing to `realpath`), and refuses — loud, never silent — any resolution that
# would escape the repository root or exceed a bounded hop count. The resolved path is then
# read via `git show <base-sha>:<resolved-path>`, so provenance is preserved exactly the same
# way a non-symlinked base-pinned read already is: BASE commit content only, never the working
# tree, never a chain link outside the repo.
#
# Usage: pantheon_base_pinned_read <base-sha> <path> <dest-file> [repo-dir]
# <repo-dir> defaults to "." — every git call is routed through `git -C <repo-dir>` explicitly,
# not an implicit cwd, so behavior doesn't depend on whether the caller has already `cd`'d into
# the target repo.
# Return codes (distinct on purpose — see below):
#   0  resolved successfully; <dest-file> now holds the resolved BASE-commit content.
#   2  ORDINARY ABSENCE — <path> (or a link in its chain) does not exist at <base-sha>. Safe
#      for a caller to treat the same as "not present at base" for an only-if-exists file
#      (REVIEW_RULES.md, DESIGN.md) — this is the existing silent-skip behavior, unchanged.
#   1  REFUSED — a symlink in the chain resolves outside the repository root, has an absolute
#      target, or the chain exceeds the depth bound (a cycle, or a deliberately pathological
#      chain). This is NEVER equivalent to absence: a caller must fail the whole run loud on
#      this code, the same fail-closed posture base-pinning itself already uses for every other
#      refusal in this class (see DESIGN.md's "Security posture").
# An `::error::` line is printed to stderr on every code-1 refusal, naming exactly what was
# refused and why — the caller's own error message can (and should) reference "see the error
# above" rather than re-deriving the reason.
#
# Sourced by cli/review-gate (this repo's own file, PANTHEON_ROOT-trusted) and by action.yml's
# "Resolve gate configuration" step (from $ACTION_PATH/cli/lib/, this action's own trusted
# checkout — same pattern action/lib/build_prompt.sh already uses for cli/lib/execution.sh).
# action/review.yml (the vendored, no-cli/lib-available lane — see DESIGN.md's "Published
# action"/"Lane differences") cannot source this file at all — a target repo never gets a copy
# of cli/lib/ — so it carries its own hand-synced inline copy of the same two functions, the
# same shape this repo already accepts for build_prompt() (DESIGN.md's "Combined PR comment").
#
# Every caller already runs under `set -euo pipefail` of its own; this only guards against a
# future caller that doesn't (same defensive, non-fatal pattern cli/lib/render_comment.sh uses).
set -u 2>/dev/null || true

# pantheon_normalize_repo_path <path> — collapses "." and ".." components in a slash-separated,
# already-relative path using ONLY parameter expansion (no `set --`/word-splitting on untrusted
# content, which would also glob-expand any `*`/`?`/`[` a hostile symlink target could contain —
# the exact pitfall this function exists to avoid). Prints the normalized path on success. Fails
# (nonzero, nothing printed) on an absolute input, an empty input, or a ".." that would climb
# above the repo root — the repo root is component index zero; there is no parent to climb to.
pantheon_normalize_repo_path() {
  local input="$1"
  case "$input" in
    /*) return 1 ;;
    "") return 1 ;;
  esac

  local -a out=()
  local remaining="$input" part

  while [[ -n "$remaining" ]]; do
    part="${remaining%%/*}"
    if [[ "$remaining" == */* ]]; then
      remaining="${remaining#*/}"
    else
      remaining=""
    fi
    case "$part" in
      "" | ".") continue ;;
      "..")
        local n=${#out[@]}
        [[ "$n" -gt 0 ]] || return 1
        out=("${out[@]:0:$((n - 1))}")
        ;;
      *) out+=("$part") ;;
    esac
  done

  [[ ${#out[@]} -gt 0 ]] || return 1

  local joined="${out[0]}" i
  for ((i = 1; i < ${#out[@]}; i++)); do
    joined="$joined/${out[$i]}"
  done
  printf '%s' "$joined"
}

# pantheon_base_pinned_read <base-sha> <path> <dest-file> [repo-dir] — see this file's header
# for the full contract and return-code meanings. <repo-dir> defaults to "." (the caller's own
# cwd) — every `git` call below is routed through `git -C <repo-dir>` explicitly rather than
# relying on an implicit cwd, so this function behaves the same whether or not the caller has
# already `cd`'d into the target repo (cli/review-gate does; a GitHub Actions step's cwd is
# already $GITHUB_WORKSPACE by convention, so passing nothing there is equally correct).
pantheon_base_pinned_read() {
  local base_sha="$1" path="$2" dest="$3" repo_dir="${4:-.}"
  local cur="$path" hops=0

  while :; do
    hops=$((hops + 1))
    if (( hops > 32 )); then
      echo "::error::pantheon: symlink chain resolving '$path' at base ${base_sha} exceeds 32 hops (cycle, or a deliberately pathological chain) — refusing to follow it." >&2
      return 1
    fi

    local mode
    mode="$(git -C "$repo_dir" ls-tree "$base_sha" -- "$cur" 2>/dev/null | awk '{print $1}')"
    [[ -n "$mode" ]] || return 2 # not present at base — ordinary absence

    case "$mode" in
      120000)
        local target
        target="$(git -C "$repo_dir" show "${base_sha}:${cur}" 2>/dev/null)" || return 2

        if [[ "$target" == /* ]]; then
          echo "::error::pantheon: symlink '$cur' at base ${base_sha} has an absolute target '$target' — refusing (only relative, in-repo-resolving symlinks are followed; base-pinning never reads outside the repository)." >&2
          return 1
        fi

        local cur_dir combined
        cur_dir="${cur%/*}"
        [[ "$cur_dir" == "$cur" ]] && cur_dir="."
        if [[ "$cur_dir" == "." ]]; then
          combined="$target"
        else
          combined="$cur_dir/$target"
        fi

        local normalized
        if ! normalized="$(pantheon_normalize_repo_path "$combined")"; then
          echo "::error::pantheon: symlink '$cur' at base ${base_sha} resolves to '$combined', which escapes the repository root — refusing to follow it (never falls back to reading it from the working tree)." >&2
          return 1
        fi
        cur="$normalized"
        ;;
      100644 | 100755)
        if git -C "$repo_dir" show "${base_sha}:${cur}" > "$dest" 2>/dev/null; then
          return 0
        else
          return 2
        fi
        ;;
      *)
        # A tree (040000), gitlink/submodule (160000), or any other mode is not a readable file
        # or a symlink to one — treated as ordinary absence, the same as a path that doesn't
        # exist at all (there's nothing content-shaped to read).
        return 2
        ;;
    esac
  done
}
