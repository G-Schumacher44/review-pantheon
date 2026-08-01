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
# Round 3 (a further Codex P2 on the same PR): a symlink doesn't have to occupy the FULL
# requested path to matter — git's tree lookup never traverses a symlinked path COMPONENT, so a
# symlinked DIRECTORY partway through the path (`custom-personas -> real-personas`, with
# `real-personas/artemis.md` the real file) made `git ls-tree $base_sha --
# custom-personas/artemis.md` return nothing at all, misreading a real file as ordinary absence.
# pantheon_base_pinned_read below walks `cur` one path COMPONENT at a time for exactly this
# reason — see its own header comment for the walk/resolve/restart mechanics.
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
#
# Round-3 fix (Codex P2, PR #8): git's tree lookup does not traverse a symlinked path
# COMPONENT — `git ls-tree $base_sha -- <full/nested/path>` returns nothing at all (not the
# symlink, not an error) the instant any non-leaf component of that path is itself a mode-120000
# blob, even though the semantically-correct target genuinely exists in the tree. Round 2 only
# detected a symlink AT THE FULL REQUESTED PATH (the leaf case: `.github/custom-personas/
# artemis.md` itself being a symlink) — a symlinked DIRECTORY one level up (`custom-personas ->
# real-personas`, with `real-personas/artemis.md` real) silently read as ordinary absence
# instead. Fixed by walking `cur`'s path components one at a time via `git ls-tree` on each
# PREFIX (not the whole path in one shot): the first prefix — at any depth, leaf or
# intermediate — found to be a mode-120000 blob is resolved through the SAME target-relative-to-
# its-own-directory / normalize / escape-refuse logic round 2 already built (one code path, not
# a second copy, per this file's own no-duplication convention), substituted into `cur` together
# with whatever path still follows it, and the whole component walk restarts from the top —
# bounded by the same 32-hop counter, so a resolved substitution that turns out to contain
# ANOTHER symlinked component (nested dir-symlinks) is walked again rather than assumed resolved.
pantheon_base_pinned_read() {
  local base_sha="$1" path="$2" dest="$3" repo_dir="${4:-.}"
  local cur="$path" hops=0

  while :; do
    hops=$((hops + 1))
    if (( hops > 32 )); then
      echo "::error::pantheon: symlink chain resolving '$path' at base ${base_sha} exceeds 32 hops (cycle, or a deliberately pathological chain) — refusing to follow it." >&2
      return 1
    fi

    # Walk cur's path components left to right, ls-tree'ing each PREFIX (never the whole path
    # in one shot — see this function's header comment on why). Stops at the first prefix that
    # is a symlink (found_symlink=true, possibly the leaf itself) or once every component has
    # been consumed (found_symlink stays false — mode/prefix then describe the full path $cur).
    local prefix="" remaining="$cur" comp mode found_symlink=false
    while [[ -n "$remaining" ]]; do
      comp="${remaining%%/*}"
      if [[ "$remaining" == */* ]]; then
        remaining="${remaining#*/}"
      else
        remaining=""
      fi
      if [[ -z "$prefix" ]]; then
        prefix="$comp"
      else
        prefix="$prefix/$comp"
      fi

      mode="$(git -C "$repo_dir" ls-tree "$base_sha" -- "$prefix" 2>/dev/null | awk '{print $1}')"
      [[ -n "$mode" ]] || return 2 # this prefix doesn't exist at base — ordinary absence

      if [[ "$mode" == "120000" ]]; then
        found_symlink=true
        break
      fi
      # Anything else (a tree when more path remains, or — once remaining is empty — a blob)
      # just continues the walk; the case below handles the terminal mode once the walk ends.
    done

    if [[ "$found_symlink" != "true" ]]; then
      # No symlink anywhere along the path — every component was a plain tree/blob, and
      # $prefix == $cur (the walk consumed the whole path). $mode is the leaf's own mode.
      case "$mode" in
        100644 | 100755)
          if git -C "$repo_dir" show "${base_sha}:${cur}" > "$dest" 2>/dev/null; then
            return 0
          else
            return 2
          fi
          ;;
        *)
          # A tree (040000), gitlink/submodule (160000), or any other mode at the LEAF
          # position isn't readable content — treated as ordinary absence, the same as a path
          # that doesn't exist at all.
          return 2
          ;;
      esac
    fi

    # $prefix is the first symlinked component found (leaf or intermediate); $remaining is
    # whatever path (possibly empty, if $prefix was the leaf) still follows it. Resolve $prefix
    # exactly like round 2's leaf-only logic did — target relative to the symlink's OWN
    # directory, normalized, refused if it escapes the repo root — then substitute and restart.
    local target
    target="$(git -C "$repo_dir" show "${base_sha}:${prefix}" 2>/dev/null)" || return 2

    if [[ "$target" == /* ]]; then
      echo "::error::pantheon: symlink '$prefix' at base ${base_sha} has an absolute target '$target' — refusing (only relative, in-repo-resolving symlinks are followed; base-pinning never reads outside the repository)." >&2
      return 1
    fi

    local prefix_dir combined
    prefix_dir="${prefix%/*}"
    [[ "$prefix_dir" == "$prefix" ]] && prefix_dir="."
    if [[ "$prefix_dir" == "." ]]; then
      combined="$target"
    else
      combined="$prefix_dir/$target"
    fi

    local normalized
    if ! normalized="$(pantheon_normalize_repo_path "$combined")"; then
      echo "::error::pantheon: symlink '$prefix' at base ${base_sha} resolves to '$combined', which escapes the repository root — refusing to follow it (never falls back to reading it from the working tree)." >&2
      return 1
    fi

    if [[ -n "$remaining" ]]; then
      cur="$normalized/$remaining"
    else
      cur="$normalized"
    fi
  done
}
