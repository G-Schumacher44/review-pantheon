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

import contextlib
import errno
import os
import stat
import sys
import tempfile

from pantheon import execution, jqjson

__all__ = [
    "bootstrap_state_file",
    "load_state",
    "load_state_or_raise",
    "StateFileMalformed",
    "reviewed_sha_for",
    "is_ancestor",
    "update_state",
    "main",
]


class StateFileMalformed(Exception):
    """Raised by :func:`load_state_or_raise` when ``state_file``'s EXISTING content is malformed
    — never silently folded into "no prior state" the way :func:`load_state`'s own
    fail-closed-to-``{}`` default is. A Codex review finding on this port's own PR: a caller
    that's about to read state for FOLLOW-UP-MODE DETECTION (``pantheon.cli``'s ``run_gate()``)
    needs a stricter contract than a display/no-crash read does — mirrors bash's own posture for
    this exact case: ``cli/review-gate``'s ``SEEN_SHA="$(jq -r ... "$STATE_FILE")"`` runs under
    ``set -euo pipefail``, so a malformed state file aborts the WHOLE SCRIPT right there, before
    any agent ever runs or any comment ever posts. Without the equivalent here, ``run_gate()``
    would silently treat a corrupted state file as "never reviewed," run every agent, and post a
    full-review comment — and since :func:`update_state` (correctly) refuses to overwrite
    malformed content, that failure never resolves: EVERY subsequent invocation repeats the
    exact same full review and posts ANOTHER duplicate comment, forever, until a human manually
    fixes the file. Write-side protection (never silently replacing malformed content) is
    necessary but not sufficient on its own without this read-side counterpart."""


def bootstrap_state_file(state_file: str) -> None:
    """Creates ``state_file`` holding ``{}`` if it doesn't already exist — mirrors
    ``cli/review-gate``'s unconditional
    ``[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"`` line, which runs before the
    dry-run/draft-skip branches are even reached (docs/CLI.md's own documented caveat: a
    ``--dry-run`` against a target repo that has never run the gate before still leaves a fresh,
    empty state file in the working tree). A no-op if the file already exists as a REGULAR file
    (or any non-symlink), regardless of its current content — this never overwrites an existing
    (possibly non-empty) state file.

    **Refuses a symlink at ``state_file`` outright, dangling or not — issue #21 P2, a Codex
    review finding on this port's own PR.** ``state_file`` lives in the TARGET repo's own working
    tree (this module's own docstring), which for a fork PR's CI run IS that PR's own checkout —
    100% attacker-controlled content, same threat model :mod:`pantheon.execution`'s whole module
    docstring opens with. A hostile PR that commits ``.review-gate-state.json`` as a DANGLING
    symlink (pointing at a path that doesn't exist, e.g. ``../../../etc/cron.d/evil``) defeats the
    pre-fix version of this check: ``os.path.exists()`` follows symlinks and returns False for a
    dangling one (the *target* doesn't exist), so the pre-fix ``if not os.path.exists(...): open(
    state_file, "w")`` line ran anyway — and a plain ``open(path, "w")`` on a dangling symlink is
    a WRITE-THROUGH-SYMLINK primitive: it creates the symlink's TARGET, not the symlink itself.
    Since :func:`bootstrap_state_file` runs unconditionally on every invocation (before the
    dry-run/draft-skip branches, per this docstring's own first paragraph), even a bare
    ``pantheon gate --dry-run`` against a hostile checkout would silently create an
    attacker-chosen file, seeded with the literal bytes ``"{}\\n"``.

    Fixed with an ``os.lstat()`` check (never follows a symlink) BEFORE any write attempt, PLUS
    ``os.O_NOFOLLOW`` on the actual creation call below — the two together close both halves of
    the TOCTOU window: ``lstat()`` catches a symlink already present at call time; ``O_NOFOLLOW``
    catches one planted by a racing process in the (tiny) window between that check and this
    function's own ``os.open()`` call, which would otherwise still resolve the race in the
    attacker's favor. Raises a plain ``OSError`` on refusal — deliberately not a new exception
    type: every existing caller (:func:`load_state`, :func:`load_state_or_raise`,
    :func:`update_state`) already catches ``OSError`` from this exact function uniformly (a
    write-protected directory, today) and reacts with its own already-correct fail-closed
    posture (empty state / :class:`StateFileMalformed` / a loud stderr warning, respectively) —
    the symlink-refusal case needs no different handling than any other "couldn't bootstrap the
    state file" failure already gets."""
    try:
        st = os.lstat(state_file)
    except FileNotFoundError:
        pass
    else:
        if stat.S_ISLNK(st.st_mode):
            raise OSError(
                errno.ELOOP,
                f"refusing to create/read {state_file}: it is a symlink (dangling or not) — "
                "a hostile checkout could otherwise have this bootstrap step write through it "
                "to an arbitrary target; symlinks at this path are never followed",
                state_file,
            )
        return  # exists, and is not a symlink -- no-op, same contract as before this fix

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        # TOCTOU close: refuses a symlink planted at this path AFTER the lstat() check above but
        # BEFORE this open() call — never present on this port's own dev/CI platforms lacking
        # O_NOFOLLOW (none do), but guarded rather than assumed, matching this port's own
        # "hasattr before using a platform-conditional os constant" posture elsewhere.
        flags |= os.O_NOFOLLOW
    fd = os.open(state_file, flags, 0o644)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("{}\n")


def load_state(state_file: str) -> dict:
    """Reads ``state_file``'s JSON content, bootstrapping it first (see
    :func:`bootstrap_state_file`) so a caller never has to special-case "file doesn't exist yet".
    A missing-after-bootstrap read, or content that fails to parse via ``pantheon.jqjson``, or
    content that parses to something other than a JSON object, all fail closed to ``{}`` — the
    same "no prior state" starting point a first-ever run already has, never a crash. Reads with
    an explicit ``encoding="utf-8"``/``errors="replace"`` — never the platform/locale default
    encoding (a Codex review finding on this port's own PR, originally caught on
    ``pantheon.cli``'s own file writes/reads: under a non-UTF-8 locale, an implicit
    platform-default decode can raise an uncaught ``UnicodeDecodeError`` that this function's
    own ``except OSError`` wouldn't catch — ``errors="replace"`` closes that structurally,
    matching this port's own established pattern for exactly this class of input). Also fails
    closed to ``{}`` (never raises) when even :func:`bootstrap_state_file` itself can't write a
    fresh ``{}`` into an unwritable directory — a Codex review finding on this port's own PR,
    companion to the identical fix on :func:`load_state_or_raise`: this function's whole contract
    is "never a crash", so a bootstrap failure gets the same treatment as every other failure
    mode already handled below, not a bare traceback."""
    try:
        bootstrap_state_file(state_file)
    except OSError:
        return {}
    try:
        with open(state_file, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError:
        return {}
    try:
        parsed = jqjson.loads(raw)
    except jqjson.JqParseError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def load_state_or_raise(state_file: str) -> dict:
    """Like :func:`load_state`, but raises :class:`StateFileMalformed` instead of failing
    closed to ``{}`` when ``state_file``'s EXISTING content fails to parse or isn't a JSON
    object — see that exception's own docstring for the full rationale. :func:`load_state`
    remains correct (and is NOT replaced) for a genuinely absent/freshly-bootstrapped file, and
    for any caller (a display path, a diagnostic) that doesn't need to distinguish "no state
    yet" from "state exists but is corrupted"; this function is for the one caller
    (``pantheon.cli``'s follow-up-mode detection) that does. Same explicit
    ``encoding="utf-8"``/``errors="replace"`` posture as :func:`load_state` — see that
    function's own docstring for why. Also raises :class:`StateFileMalformed` (rather than
    letting a raw ``OSError``/``PermissionError`` propagate past this function's own caller —
    ``pantheon.cli``'s ``main()`` only catches ``GateError``) when even
    :func:`bootstrap_state_file` itself can't write a fresh ``{}`` into an unwritable directory —
    a Codex review finding on this port's own PR: this is a real "can't verify" outcome, not a
    bug in this function, so it gets the same fail-closed treatment as any other unreadable/
    malformed state, not a bare traceback.

    **An EMPTY (or whitespace-only) existing file self-heals to ``{}`` instead of raising — a
    medium finding from an adversarial review, matching bash's own behavior exactly: real jq on
    genuinely empty input reads zero JSON documents and simply produces no output, exit 0 — NOT a
    parse error — verified live (``printf '' | jq -r '.["42"].reviewed_sha // empty'`` exits 0
    with no output; a real syntax error like ``printf 'not json' | jq ...`` exits 5). Bash's own
    ``SEEN_SHA="$(jq -r ... "$STATE_FILE")"`` under ``set -euo pipefail`` therefore does NOT abort
    on an empty state file (``$(...)`` on a command that exited 0 with empty stdout is just an
    empty string, no abort) — it reads as "no prior SHA," full review proceeds, and the NEXT
    green/yellow run's :func:`update_state` write (bash's own ``update_review_gate_state``, which
    the empty-input write-side check just below :func:`update_state`'s own docstring proves
    behaves identically) then populates the file normally. Pre-fix, this function routed an empty
    file through ``jqjson.loads("")`` like any other content, which raises :class:`JqParseError`
    (Python's ``json.loads("")`` is a genuine syntax error, unlike real jq's empty-input
    handling) — so an empty ``.review-gate-state.json`` (a plausible real-world shape: a manual
    ``touch``, an interrupted first write, a disk that truncated a partial write) hard-aborted
    EVERY invocation forever, since :func:`update_state` correctly refuses to ever overwrite
    malformed-looking existing content, meaning the file could never self-repair on its own. Only
    GENUINELY malformed non-empty content (a syntax error, a JSON array instead of an object) is
    still a real, intentional abort in both runtimes — real jq itself still exits 5 on those (see
    this function's own live-verification note above); this self-heal is narrowly scoped to the
    one input shape where jq's CLI-level "zero documents read" semantics and a strict
    text-parser's "empty string is a syntax error" semantics genuinely diverge."""
    try:
        bootstrap_state_file(state_file)
    except OSError as e:
        raise StateFileMalformed(f"failed to create {state_file}: {e}") from e
    try:
        with open(state_file, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as e:
        raise StateFileMalformed(f"failed to read {state_file}: {e}") from e
    if raw.strip() == "":
        return {}
    try:
        parsed = jqjson.loads(raw)
    except jqjson.JqParseError as e:
        raise StateFileMalformed(f"{state_file} is not valid JSON: {e}") from e
    if not isinstance(parsed, dict):
        raise StateFileMalformed(f"{state_file}'s content is not a JSON object")
    return parsed


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


def update_state(overall: str, pr_number: str, head_sha: str, state_file: str, workdir: str) -> bool:
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

    **Malformed EXISTING state must also be left untouched, never silently replaced** — a Codex
    review finding on this port's own PR. This function deliberately does NOT call
    :func:`load_state` (whose fail-closed-to-``{}`` behavior is correct for the READ side —
    "no prior state" is a safe default for follow-up-mode detection) — reusing it here would mean
    a state file corrupted by something other than this module (a disk error, a hand-edit, an
    interrupted write from a much older version) silently gets overwritten with a FRESH ``{}``
    plus only the current PR's entry, permanently destroying every other PR's previously recorded
    ``reviewed_sha``. Mirrors bash's own ``update_review_gate_state()`` exactly instead: its
    write is a single ``jq '...' "$state_file" > "$tmp_state"`` — if `jq`'s own read of
    ``$state_file`` fails to parse (a GENUINE syntax error — see the empty-file self-heal note
    below for the one input shape that is NOT a parse failure in either runtime), that command
    exits nonzero, the ``if`` takes bash's ``else`` branch, and NOTHING is written; the original
    (malformed) file is never touched. This function reads the file directly (not through
    ``load_state``) and takes the identical "leave it alone, warn loudly" branch on any genuine
    parse failure or non-object content.

    **An EMPTY (or whitespace-only) existing file self-heals — mirrors bash exactly, see
    :func:`load_state_or_raise`'s own docstring for the live jq verification.** Real jq's write
    query behaves identically on empty input to its read query: ``printf '' | jq --arg pr 42
    --arg sha abc '.[$pr] = {"reviewed_sha": $sha}'`` exits 0 and produces
    ``{"42":{"reviewed_sha":"abc"}}`` — jq auto-vivifies from an implicit ``null``/no-document
    starting point, the SAME "no prior state" default this function's own ``{}`` fallback gives
    an empty file below. Pre-fix, this function routed an empty existing file through
    ``jqjson.loads("")`` like any other content (a genuine :class:`~pantheon.jqjson.JqParseError`
    in Python, unlike real jq's empty-input handling), taking the warn-and-leave-untouched branch
    forever — since this function never overwrites content it judged malformed, an empty state
    file could never self-repair, diverging from bash's own graceful recovery on the identical
    input shape.

    **A write FAILURE for a green/yellow outcome — the write this function DID attempt — is now
    fail-closed to the CALLER via this function's own boolean return, correcting a docstring claim
    this function used to make that did not match bash's real behavior.** ``update_state()``
    itself still never RAISES (its caller, ``pantheon.cli``'s ``run_gate()``, has already posted
    the PR comment by the time this runs and needs to still complete cleanup regardless) — but a
    CRITICAL finding from an adversarial review, live-reproduced pre-fix (``chmod 555`` the state
    directory, a green verdict → this function warned to stderr and returned, and
    ``run_gate()``'s own exit code was computed purely from ``overall``, landing on 0 — a SILENT
    fail-open a caller had no way to detect), caught that this function's own docstring claimed
    parity with bash here that it did NOT actually have: real ``cli/review-gate`` calls
    ``update_review_gate_state "$OVERALL" ...`` as a bare top-level statement, not inside an
    ``if``-condition, under the whole script's ``set -euo pipefail`` — and that function's own
    ``mv "$tmp_state" "$state_file"`` line (unlike the ``jq ... > "$tmp_state"`` redirect that
    precedes it, which IS an if-condition and so IS errexit-exempt) is a plain body statement: if
    ``mv`` fails (the exact ``chmod 555`` shape above), ``errexit`` aborts the WHOLE SCRIPT right
    there, nonzero exit, before the ``case "$OVERALL" in green|yellow) exit 0 ;; ... esac`` block
    at the bottom is ever reached — bash's real posture is "the comment already posted, but a
    state-write failure still fails the RUN," not "a loud warning is enough." This function's
    return value — ``True`` when no write was needed (a red/unverified ``overall``) or the write
    succeeded, ``False`` when a write was ATTEMPTED (green/yellow) and failed — is exactly the
    signal ``run_gate()`` now checks to reproduce that same fail-closed outcome (a nonzero exit),
    without this function itself needing to raise from deep inside a write path whose own caller
    still has other cleanup to finish either way.

    Writes via a temp file created in ``state_file``'s OWN directory (never ``workdir`` — see
    this function's own body for why) + ``os.replace`` (atomic on POSIX, same write-then-move
    discipline as bash's own ``jq ... > "$tmp_state" && mv "$tmp_state" "$state_file"``, and
    always same-filesystem by construction, so it never needs `mv`'s own cross-device fallback)
    — never a direct in-place write that could leave a torn/partial file behind on a mid-write
    failure. A write failure (permissions, disk full, malformed existing content, ...) is always
    reported to stderr too — the boolean return doesn't replace that, it lets a caller ALSO act on
    it (see this docstring's own fail-closed-return paragraph above)."""
    if overall not in ("green", "yellow"):
        print(
            f"pantheon: overall verdict is {overall} — leaving {state_file} untouched so the "
            "next run retries the full PR (fail-closed: an UNVERIFIED/red result must never mark "
            "this head reviewed)",
            file=sys.stderr,
        )
        return True

    try:
        bootstrap_state_file(state_file)
    except OSError as e:
        print(
            f"pantheon: warning: comment posted but failed to create {state_file} for update: {e}",
            file=sys.stderr,
        )
        return False
    try:
        with open(state_file, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as e:
        print(
            f"pantheon: warning: comment posted but failed to read {state_file} for update: {e}",
            file=sys.stderr,
        )
        return False

    if raw.strip() == "":
        # Self-heal, matching bash's own write-side behavior on empty input — see this
        # function's own docstring for the live jq verification.
        state: dict = {}
    else:
        try:
            state = jqjson.loads(raw)
        except jqjson.JqParseError as e:
            print(
                f"pantheon: warning: comment posted but failed to update {state_file} — its "
                f"existing content is not valid JSON ({e}); leaving it untouched rather than "
                "overwriting it with a fresh, empty state",
                file=sys.stderr,
            )
            return False

        if not isinstance(state, dict):
            print(
                f"pantheon: warning: comment posted but failed to update {state_file} — its "
                "existing content is not a JSON object; leaving it untouched rather than "
                "overwriting it with a fresh, empty state",
                file=sys.stderr,
            )
            return False

    state[str(pr_number)] = {"reviewed_sha": head_sha}

    # The temp file is created NEXT TO state_file (its own directory), NOT inside `workdir` — a
    # finding from this repo's own self-hosted gate on this port's own PR: `workdir` is typically
    # a system temp directory (e.g. `tempfile.TemporaryDirectory()`, as `pantheon.cli` passes),
    # which can be a different filesystem/mount than the target repo checkout (a Docker CI
    # runner's tmpfs `/tmp` vs. a bind-mounted workspace, a `TMPDIR=/dev/shm` config, ...).
    # `os.replace()`/`os.rename()` raise `OSError(EXDEV)` on a cross-device rename with NO
    # fallback — unlike bash's `mv`, which transparently falls back to copy+unlink — so a
    # `workdir`-based temp file could silently fail to ever update `state_file`, defeating
    # follow-up mode (fail-safe to a full re-review, never data corruption, but silently, with
    # only a stderr warning). Fixed structurally, not by replicating `mv`'s fallback: a temp file
    # created in `state_file`'s OWN directory is, by construction, always on the SAME filesystem
    # as `state_file`, so `os.replace()` can never cross a device boundary here at all — the same
    # "closed by construction, not by enumerating fallbacks" posture this port already uses
    # elsewhere (e.g. `pantheon.execution`'s `TRUSTED_GIT_DIRS`). `workdir` is still accepted (API
    # and CLI-shim shape stability — see this module's own `python -m pantheon.state update`
    # entry point) but is no longer where this temp file is actually written.
    # tempfile.mkstemp() ITSELF (not just the subsequent write/replace) must be inside the guarded
    # path — a Codex review finding on this port's own PR: an earlier version called mkstemp()
    # BEFORE the try block, so a write-protected state_dir (the PR comment already posted, but
    # the target repo's own directory happens not to be writable) raised an uncaught
    # PermissionError here instead of the documented warning-only state-write failure — main()
    # only catches GateError, so this escaped as a bare traceback, and a retry could then post a
    # DUPLICATE comment (the unrecorded SHA makes the next run think nothing was ever reviewed).
    # tmp_path stays None until mkstemp actually succeeds, so the cleanup branch below can tell
    # "never created" (nothing to clean up) from "created, then something else failed."
    tmp_path: str | None = None
    try:
        state_dir = os.path.dirname(os.path.abspath(state_file)) or "."
        fd, tmp_path = tempfile.mkstemp(prefix=".review-gate-state-", suffix=".json.tmp", dir=state_dir)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(jqjson.dumps(state, indent=2))
            fh.write("\n")
        os.replace(tmp_path, state_file)
    except OSError as e:
        print(
            f"pantheon: warning: comment posted but failed to update {state_file}: {e}",
            file=sys.stderr,
        )
        # Best-effort cleanup; the warning above already reported the real failure.
        if tmp_path is not None:
            with contextlib.suppress(OSError):
                os.remove(tmp_path)
        return False

    return True


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
    # CRITICAL fix (adversarial review): this exit code used to be unconditionally 0, regardless
    # of whether update_state() actually succeeded — a black-box caller of this CLI shim (the
    # same shape tests/test-state-persistence-python.sh drives) had no way to observe a failed
    # write at all. Propagating update_state()'s own return here is what makes
    # `python -m pantheon.state update` fail closed (nonzero) exactly when bash's real
    # `update_review_gate_state` invocation would abort under `set -e` — see update_state()'s own
    # docstring for the full rationale.
    ok = update_state(overall, pr_number, head_sha, state_file, workdir)
    return 0 if ok else 1


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
