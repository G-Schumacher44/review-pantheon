"""pantheon/basepin.py — symlink-safe base-pinned file reads. Replaces
cli/lib/pantheon-base-pin.sh.

Every base-pinned read in this repo (issue #6's class statement, DESIGN.md's "Security posture")
uses ``git show <base-sha>:<path>`` to read a file's content from the PR's BASE commit instead of
the checked-out working tree — never the working tree, so a hostile PR cannot smuggle a rewritten
persona/rules/decider file past the reviewer just by editing it in the PR's own diff. That's
correct for a regular file, but git stores a symlink as a mode-120000 blob whose "content" is the
link TARGET STRING, not the referenced file's bytes — a bare ``git show`` on a symlinked path
therefore returns a pathname, not the real content, for a target repo using symlinked custom
personas (a legitimate pattern: ``.github/custom-personas/artemis.md ->
../../agents/artemis.md``).

``base_pinned_read()`` resolves that: it detects a symlink via ``git ls-tree``, follows the
chain treating each target as a path RELATIVE TO THE SYMLINK'S OWN DIRECTORY (git's own semantics
for a tracked symlink), normalizes it against the repo root using pure string manipulation only
(no filesystem access — this is a git-tree-relative path, not a real one), and refuses — loud,
never silent — any resolution that would escape the repository root or exceed a bounded hop
count (32, same bound as the bash original and this repo's other symlink-following call sites).
The resolved path is then read via ``git show <base-sha>:<resolved-path>``, so provenance is
preserved exactly the same way a non-symlinked base-pinned read already is.

A symlink doesn't have to occupy the FULL requested path to matter: git's tree lookup never
traverses a symlinked path COMPONENT, so a symlinked DIRECTORY partway through the path
(``custom-personas -> real-personas``, with ``real-personas/artemis.md`` the real file) makes a
single-shot ``git ls-tree $base_sha -- custom-personas/artemis.md`` return nothing at all,
misreading a real file as ordinary absence. ``base_pinned_read()`` below walks the requested path
one component at a time for exactly this reason — see ``_walk_prefix_mode()``.

Return-code contract (kept from the bash original — a caller distinguishes these, not just a
boolean):
  0  resolved successfully; content is available.
  2  ORDINARY ABSENCE — <path> (or a link in its chain) does not exist at <base-sha>. Safe for a
     caller to treat as "not present at base" for an only-if-exists file — the existing
     silent-skip behavior, unchanged.
  1  REFUSED — a symlink in the chain resolves outside the repository root, has an absolute
     target, or the chain exceeds the depth bound (a cycle, or a deliberately pathological
     chain). NEVER equivalent to absence: a caller must fail the whole run loud on this code.

Issue #10's trailing-slash item, closed here (not just tracked): the bash original's component
walk operates on the CALLER-SUPPLIED path verbatim, without first collapsing redundant
separators — a ``personas_path`` ending in ``/`` (or a path containing a doubled ``//``
anywhere) builds a component list containing an empty segment, and ``git ls-tree`` on a
trailing-slash-terminated pathspec lists a TREE'S CHILDREN rather than the tree entry itself,
which reads back as a spurious miss (git's own "directory-slice" pathspec behavior, not a bug in
git). ``base_pinned_read()`` below normalizes the REQUESTED path itself through
``normalize_repo_path()`` — the exact same collapse-"."/collapse-".."/reject-empty-components
logic already used for resolved symlink targets — before the walk ever begins, so
``dir//file.md`` and ``dir/file.md/`` both normalize to ``dir/file.md`` up front. The bash
original only ever normalized a *resolved symlink target*, never the caller's own input path;
this is a genuine behavioral closure of docs/PYTHON-PORT.md's cited class, not a restatement of
the existing symlink-target normalization.

Every ``git`` call below goes through ``pantheon.execution.run_git()`` — the same constructed-
clean-environment, GLOBAL_OVERRIDES-carrying core the readonly wrapper uses (see
``pantheon.execution``'s module docstring) — even though ``ls-tree`` is not on that wrapper's
four-subcommand allowlist. This module is trusted, CLI-internal plumbing (not the persona-facing
Bash-tool surface the wrapper's argv gate exists to constrain), so it calls ``git`` directly
through the shared hardened core rather than through ``run_readonly_wrapper()``'s argv gate —
same environment discipline, no subcommand restriction, exactly mirroring how
cli/lib/pantheon-base-pin.sh calls ``git -C <repo_dir> ls-tree``/``show`` directly rather than
routing through cli/lib/pantheon-git-readonly.sh.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from typing import Optional

from pantheon import execution

__all__ = [
    "REFUSED",
    "ABSENT",
    "OK",
    "BasePinnedReadResult",
    "normalize_repo_path",
    "base_pinned_read",
    "main",
]

OK = 0
ABSENT = 2
REFUSED = 1

MAX_HOPS = 32


@dataclass
class BasePinnedReadResult:
    status: int  # OK (0) / REFUSED (1) / ABSENT (2)
    content: Optional[bytes] = None
    error: Optional[str] = None


def normalize_repo_path(path: str) -> Optional[str]:
    """Collapses "." and ".." components in a slash-separated, already-relative path using pure
    string manipulation (no filesystem access — a git-tree-relative path, not a real one).
    Returns the normalized path on success, or None on failure: an absolute input, an empty
    input, a ".." that would climb above the repo root (the repo root is component index zero;
    there is no parent to climb to), or an input that fully collapses to nothing (e.g. "./.").
    Mirrors cli/lib/pantheon-base-pin.sh's pantheon_normalize_repo_path exactly.
    """
    if not path or path.startswith("/"):
        return None

    out: list[str] = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not out:
                return None
            out.pop()
        else:
            out.append(part)

    if not out:
        return None

    return "/".join(out)


def _ls_tree_mode(base_sha: str, path: str, repo_dir: str) -> Optional[str]:
    result = execution.run_git(["ls-tree", base_sha, "--", path], cwd=repo_dir)
    if result.returncode != 0:
        return None
    line = result.stdout.decode("utf-8", errors="replace").strip()
    if not line:
        return None
    # `<mode> <type> <sha>\t<name>` — the mode is the first whitespace-delimited field.
    return line.split()[0] if line.split() else None


def _walk_prefix_mode(base_sha: str, cur: str, repo_dir: str):
    """Walks ``cur``'s path components left to right, ls-tree'ing each PREFIX (never the whole
    path in one shot). Returns (prefix, mode, remaining, found_symlink) — stops at the first
    prefix that is a symlink (mode "120000", possibly the leaf itself) or once every component
    has been consumed. Returns (None, None, None, False) if any prefix along the way is absent
    at base (ordinary absence, the caller returns ABSENT).
    """
    components = cur.split("/")
    prefix = ""
    for i, comp in enumerate(components):
        prefix = comp if not prefix else f"{prefix}/{comp}"
        mode = _ls_tree_mode(base_sha, prefix, repo_dir)
        if mode is None:
            return None, None, None, False
        if mode == "120000":
            remaining = "/".join(components[i + 1 :])
            return prefix, mode, remaining, True
    return prefix, mode, "", False


def base_pinned_read(
    base_sha: str, path: str, repo_dir: str = "."
) -> BasePinnedReadResult:
    """See this module's docstring for the full contract and return-code meanings. <repo_dir>
    defaults to "." — every git call is routed through pantheon.execution.run_git(cwd=repo_dir),
    not an implicit process cwd, so behavior doesn't depend on whether the caller has already
    chdir'd into the target repo.
    """
    normalized = normalize_repo_path(path)
    if normalized is None:
        # An unresolvable REQUESTED path (absolute, empty, climbs above root, or fully collapses
        # to nothing) is ordinary absence, not a refusal — there is no legitimate way to have
        # been asked for this path, the same posture the bash original applies to a symlink
        # TARGET that fails to normalize into a refusal (escape) vs. this being the caller's own
        # input, which is closer to "not a real path at all" than "an attacker-controlled escape
        # attempt" in the common case (a config value with a stray trailing slash, issue #10).
        return BasePinnedReadResult(status=ABSENT, error=f"'{path}' does not normalize to a valid in-repo path")

    cur = normalized
    hops = 0

    while True:
        hops += 1
        if hops > MAX_HOPS:
            msg = (
                f"pantheon: symlink chain resolving '{path}' at base {base_sha} exceeds "
                f"{MAX_HOPS} hops (cycle, or a deliberately pathological chain) — refusing to "
                "follow it."
            )
            print(f"::error::{msg}", file=sys.stderr)
            return BasePinnedReadResult(status=REFUSED, error=msg)

        prefix, mode, remaining, found_symlink = _walk_prefix_mode(base_sha, cur, repo_dir)
        if prefix is None:
            return BasePinnedReadResult(status=ABSENT, error=f"'{cur}' absent at base {base_sha}")

        if not found_symlink:
            # No symlink anywhere along the path — every component was a plain tree/blob, and
            # prefix == cur (the walk consumed the whole path). `mode` is the leaf's own mode.
            if mode in ("100644", "100755"):
                result = execution.run_git(["show", f"{base_sha}:{cur}"], cwd=repo_dir)
                if result.returncode == 0:
                    return BasePinnedReadResult(status=OK, content=result.stdout)
                return BasePinnedReadResult(status=ABSENT, error=f"'git show' failed for '{cur}'")
            # A tree (040000), gitlink/submodule (160000), or any other mode at the LEAF
            # position isn't readable content — treated as ordinary absence.
            return BasePinnedReadResult(status=ABSENT, error=f"'{cur}' is not a regular file at base {base_sha} (mode {mode})")

        # `prefix` is the first symlinked component found (leaf or intermediate); `remaining` is
        # whatever path (possibly empty) still follows it. Resolve `prefix` — target relative to
        # the symlink's OWN directory, normalized, refused if it escapes the repo root — then
        # substitute and restart.
        target_result = execution.run_git(["show", f"{base_sha}:{prefix}"], cwd=repo_dir)
        if target_result.returncode != 0:
            return BasePinnedReadResult(status=ABSENT, error=f"symlink target unreadable for '{prefix}'")
        target = target_result.stdout.decode("utf-8", errors="replace").rstrip("\n")

        if target.startswith("/"):
            msg = (
                f"pantheon: symlink '{prefix}' at base {base_sha} has an absolute target "
                f"'{target}' — refusing (only relative, in-repo-resolving symlinks are followed; "
                "base-pinning never reads outside the repository)."
            )
            print(f"::error::{msg}", file=sys.stderr)
            return BasePinnedReadResult(status=REFUSED, error=msg)

        prefix_dir = prefix.rsplit("/", 1)[0] if "/" in prefix else "."
        combined = target if prefix_dir == "." else f"{prefix_dir}/{target}"

        normalized_target = normalize_repo_path(combined)
        if normalized_target is None:
            msg = (
                f"pantheon: symlink '{prefix}' at base {base_sha} resolves to '{combined}', "
                "which escapes the repository root — refusing to follow it (never falls back to "
                "reading it from the working tree)."
            )
            print(f"::error::{msg}", file=sys.stderr)
            return BasePinnedReadResult(status=REFUSED, error=msg)

        cur = f"{normalized_target}/{remaining}" if remaining else normalized_target


# ---------------------------------------------------------------------------------------------
# CLI — subcommand-dispatch shape mirroring pantheon.execution's "wrapper" CLI, for
# tests/test-base-pinned-read.sh's Python-native black-box equivalent (docs/PYTHON-PORT.md §4):
#
#   python -m pantheon.basepin read <base-sha> <path> <dest-file> [repo-dir]
#     — mirrors cli/lib/pantheon-base-pin.sh's `pantheon_base_pinned_read` contract exactly:
#       writes resolved content to <dest-file>, exits 0/1/2 (see this module's docstring).
#   python -m pantheon.basepin normalize <path>
#     — mirrors `pantheon_normalize_repo_path`: prints the normalized path and exits 0 on
#       success, prints nothing and exits 1 on refusal.
# ---------------------------------------------------------------------------------------------


def _read_cli(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            "usage: python -m pantheon.basepin read <base-sha> <path> <dest-file> [repo-dir]",
            file=sys.stderr,
        )
        return 2

    base_sha, path, dest = argv[0], argv[1], argv[2]
    repo_dir = argv[3] if len(argv) > 3 else "."

    result = base_pinned_read(base_sha, path, repo_dir)
    if result.status == OK:
        with open(dest, "wb") as fh:
            fh.write(result.content or b"")
    return result.status


def _normalize_cli(argv: list[str]) -> int:
    if len(argv) != 1:
        print("usage: python -m pantheon.basepin normalize <path>", file=sys.stderr)
        return 2
    normalized = normalize_repo_path(argv[0])
    if normalized is None:
        return 1
    print(normalized)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "read":
        return _read_cli(argv[1:])
    if argv and argv[0] == "normalize":
        return _normalize_cli(argv[1:])
    print(
        "usage: python -m pantheon.basepin read <base-sha> <path> <dest-file> [repo-dir]\n"
        "       python -m pantheon.basepin normalize <path>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
