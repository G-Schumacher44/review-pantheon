"""pantheon/state.py — follow-up-mode state (docs/PYTHON-PORT.md section 6).

Replaces the ``update_review_gate_state()`` function and the ``SEEN_SHA``/ancestry logic
currently inline in ``cli/review-gate``. ``.review-gate-state.json`` lives at the TARGET repo's
root (the repo being gated, not this package's own checkout), shape
``{"<pr-number>": {"reviewed_sha": "<sha>"}}`` — see docs/CLI.md's ["The state / follow-up
model"](../docs/CLI.md#the-state--follow-up-model) for the full behavioral contract this module
implements:

  - Same head SHA already recorded -> the caller (``pantheon.cli``) treats the run as a no-op.
  - A different, newer head SHA recorded -> follow-up mode: the diff range narrows to
    ``<reviewed_sha>..<head_sha>``.
  - Force-push / rebase / history rewrite -> ancestry (:func:`is_ancestor`), not just existence,
    determines whether the recorded SHA is still a valid incremental base — an old SHA can remain
    a perfectly fetchable commit object without being an ancestor of the new head anymore.
  - **The recording rule is green/yellow-only, on purpose** — see :func:`update_state`'s own
    docstring for the fail-closed rationale this mirrors from ``cli/review-gate``'s
    ``update_review_gate_state()`` verbatim.

Every JSON parse/serialize in this module goes through ``pantheon.jqjson`` (docs/PYTHON-PORT.md's
"JSON boundary" section), never Python's own ``json`` module directly. Every git call goes
through ``pantheon.execution.run_git`` — this module is trusted, CLI-internal plumbing (not the
persona-facing Bash-tool surface ``pantheon.execution``'s argv-validating wrapper exists to
constrain), same posture ``pantheon.basepin`` already documents for why it calls into that same
hardened core directly rather than through the wrapper's argv gate. Unlike a base-pinned content
read, nothing here touches the network — ``git merge-base --is-ancestor`` is a purely local ref
comparison — so the hardened, PATH-restricted environment ``run_git`` constructs costs nothing
here and buys the same defense-in-depth ``pantheon.basepin`` already accepts.

Fixture suite: tests/test-state-persistence.sh (bash-internal in its original form — extracts
``update_review_gate_state()`` verbatim from ``cli/review-gate`` via the ``$FUNCS_FILE`` pattern).
Its black-box Python equivalent, per docs/PYTHON-PORT.md section 4, is
tests/test-state-persistence-python.sh, which drives this module the same way the original suite
drives the extracted bash function: via ``python -m pantheon.state update ...``.
"""

from __future__ import annotations

import os
import sys

from pantheon import execution, jqjson

__all__ = [
    "bootstrap_state_file",
    "load_state",
    "reviewed_sha_for",
    "is_ancestor",
    "update_state",
    "main",
]


def bootstrap_state_file(state_file: str) -> None:
    """Creates ``state_file`` holding ``{}`` if it doesn't already exist — mirrors
    ``cli/review-gate``'s unconditional
    ``[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"`` line, which runs before the
    dry-run/draft-skip branches are even reached (docs/CLI.md's own documented caveat: a
    ``--dry-run`` against a target repo that has never run the gate before still leaves a fresh,
    empty state file in the working tree). A no-op if the file already exists, regardless of its
    current content — this never overwrites an existing (possibly non-empty) state file."""
    if not os.path.exists(state_file):
        with open(state_file, "w") as fh:
            fh.write("{}\n")


def load_state(state_file: str) -> dict:
    """Reads ``state_file``'s JSON content, bootstrapping it first (see
    :func:`bootstrap_state_file`) so a caller never has to special-case "file doesn't exist yet".
    A missing-after-bootstrap read, or content that fails to parse via ``pantheon.jqjson``, or
    content that parses to something other than a JSON object, all fail closed to ``{}`` — the
    same "no prior state" starting point a first-ever run already has, never a crash."""
    bootstrap_state_file(state_file)
    try:
        with open(state_file) as fh:
            raw = fh.read()
    except OSError:
        return {}
    try:
        parsed = jqjson.loads(raw)
    except jqjson.JqParseError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def reviewed_sha_for(state: dict, pr_number: str) -> str | None:
    """``.[$pr].reviewed_sha // empty`` — mirrors ``cli/review-gate``'s
    ``SEEN_SHA="$(jq -r --arg pr "$PR_NUMBER" '.[$pr].reviewed_sha // empty' "$STATE_FILE")"``
    exactly: a missing PR entry, an entry that isn't an object, a missing ``reviewed_sha`` key, or
    a non-string/empty value all read as "no prior SHA recorded" (``None``) — jq's ``//`` operator
    treats ``null`` and ``false`` as the trigger for its default, and an empty string as the
    trigger for bash's own ``[[ -n "$SEEN_SHA" ]]`` follow-up check downstream; folding "non-string"
    into the same ``None`` result here keeps that fail-closed posture without a caller needing its
    own type check on top."""
    entry = state.get(str(pr_number))
    if not isinstance(entry, dict):
        return None
    sha = entry.get("reviewed_sha")
    return sha if isinstance(sha, str) and sha else None


def is_ancestor(candidate_sha: str, ref: str, cwd: str | None = None) -> bool:
    """``git merge-base --is-ancestor <candidate_sha> <ref>`` — mirrors ``cli/review-gate``'s
    force-push-detection check exactly: an EXISTENCE check alone (``git cat-file -e``) isn't
    enough, because after a force-push the old SHA can remain a perfectly valid, fetchable commit
    object without still being an ancestor of the new head — ancestry is the actual invariant a
    safe incremental (follow-up) review needs. Routed through ``pantheon.execution.run_git`` for
    the same constructed-clean-environment discipline every other git call in this port uses (see
    this module's own docstring for why that costs nothing on a purely local ref comparison)."""
    result = execution.run_git(["merge-base", "--is-ancestor", candidate_sha, ref], cwd=cwd)
    return result.returncode == 0


def update_state(overall: str, pr_number: str, head_sha: str, state_file: str, workdir: str) -> None:
    """Mirrors ``cli/review-gate``'s ``update_review_gate_state()`` exactly — including its own
    header comment's rationale, restated here: this write happens ONLY for a green/yellow overall
    outcome. A carried finding (from an external reviewer's finding on a sibling system, treated
    as our own): the pre-fix version of this write ran unconditionally after any successful
    ``gh pr comment`` post, regardless of the computed verdict — so an UNVERIFIED result (a
    transient provider timeout, a malformed model response, anything that legitimately deserves a
    full retry) still marked the head reviewed, and a follow-up run would then only re-review the
    incremental diff since that poisoned state instead of retrying the whole review. Fail-closed
    follow-up mode requires the opposite: a red or unverified outcome must leave the state file
    EXACTLY as it was, so the next run reviews the full PR again, not just what changed since a
    run that never actually gated anything.

    Writes via a temp file in ``workdir`` + ``os.replace`` (atomic on POSIX, same write-then-move
    discipline as bash's own ``jq ... > "$tmp_state" && mv "$tmp_state" "$state_file"``) — never a
    direct in-place write that could leave a torn/partial file behind on a mid-write failure. A
    write failure (permissions, disk full, ...) is reported to stderr but never raised — mirrors
    bash's own posture: the comment has already posted by the time this runs, so a state-write
    failure is a loud warning, not a reason to report the whole gate run as failed."""
    if overall not in ("green", "yellow"):
        print(
            f"pantheon: overall verdict is {overall} — leaving {state_file} untouched so the "
            "next run retries the full PR (fail-closed: an UNVERIFIED/red result must never mark "
            "this head reviewed)",
            file=sys.stderr,
        )
        return

    state = load_state(state_file)
    state[str(pr_number)] = {"reviewed_sha": head_sha}
    tmp_path = os.path.join(workdir, "state.json")
    try:
        with open(tmp_path, "w") as fh:
            fh.write(jqjson.dumps(state, indent=2))
            fh.write("\n")
        os.replace(tmp_path, state_file)
    except OSError as e:
        print(
            f"pantheon: warning: comment posted but failed to update {state_file}: {e}",
            file=sys.stderr,
        )


# ---------------------------------------------------------------------------------------------
# CLI — subcommand-dispatch shape mirroring pantheon.basepin/pantheon.execution's own module
# CLIs, for tests/test-state-persistence-python.sh's black-box equivalent (docs/PYTHON-PORT.md
# §4): ``python -m pantheon.state update <overall> <pr> <head-sha> <state-file> <workdir>``
# mirrors cli/review-gate's extracted ``update_review_gate_state()`` contract exactly.
# ---------------------------------------------------------------------------------------------


def _update_cli(argv: list[str]) -> int:
    if len(argv) != 5:
        print(
            "usage: python -m pantheon.state update <overall> <pr> <head-sha> <state-file> <workdir>",
            file=sys.stderr,
        )
        return 2
    overall, pr_number, head_sha, state_file, workdir = argv
    update_state(overall, pr_number, head_sha, state_file, workdir)
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "update":
        return _update_cli(argv[1:])
    print(
        "usage: python -m pantheon.state update <overall> <pr> <head-sha> <state-file> <workdir>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
