"""tests/test_state.py — pytest unit layer for pantheon.state's cross-filesystem write safety
(docs/PYTHON-PORT.md section 4's port slice 4 deliverable).

Deliberately NOT a re-run of tests/test-state-persistence-python.sh's own scenarios (the
green/yellow-recording rule, malformed-state protection, load_state/reviewed_sha_for/
is_ancestor) — that suite already covers those as a black box. This file covers one property
that suite can't cheaply express: WHERE update_state()'s temp file gets created, which is what a
finding from this repo's own self-hosted gate on this port's own PR caught — an earlier version
wrote the temp file into the CALLER-supplied `workdir` (typically a system temp directory, e.g.
`tempfile.TemporaryDirectory()`, as `pantheon.cli` passes), which can be a different filesystem/
mount than the target repo checkout; `os.replace()` raises `OSError(EXDEV)` with no fallback on
a cross-device rename (unlike bash's `mv`, which transparently falls back to copy+unlink),
silently breaking follow-up-mode state persistence. Fixed structurally: the temp file is now
created in `state_file`'s OWN directory, which is always on the same filesystem as `state_file`
by construction, so a cross-device rename can never happen at all.
"""

from __future__ import annotations

import os

import pytest

from pantheon import state


def test_update_state_writes_its_temp_file_next_to_state_file_not_in_workdir(tmp_path) -> None:
    # workdir and the state file's own directory are deliberately DIFFERENT directories — the
    # exact shape that exposed the cross-filesystem bug (a workdir on one mount, state_file's
    # directory on another).
    workdir = tmp_path / "workdir"
    workdir.mkdir()
    state_dir = tmp_path / "repo-checkout"
    state_dir.mkdir()
    state_file = state_dir / ".review-gate-state.json"
    state_file.write_text("{}")

    state.update_state("green", "42", "deadbeefcafe", str(state_file), str(workdir))

    assert os.listdir(workdir) == []
    # Only the final state file remains in its own directory — no leftover temp file.
    assert os.listdir(state_dir) == [".review-gate-state.json"]
    assert state.reviewed_sha_for(state.load_state(str(state_file)), "42") == "deadbeefcafe"


def test_update_state_cleans_up_its_temp_file_on_a_write_failure(tmp_path, monkeypatch) -> None:
    workdir = tmp_path / "workdir"
    workdir.mkdir()
    state_dir = tmp_path / "repo-checkout"
    state_dir.mkdir()
    state_file = state_dir / ".review-gate-state.json"
    state_file.write_text("{}")

    def _raise_replace(*args, **kwargs):
        raise OSError("simulated cross-device failure")

    monkeypatch.setattr(state.os, "replace", _raise_replace)

    state.update_state("green", "42", "deadbeefcafe", str(state_file), str(workdir))

    # The original file is untouched (the simulated failure happened before the swap), and no
    # leftover .json.tmp file was left behind in state_dir.
    assert state_file.read_text() == "{}"
    leftovers = [f for f in os.listdir(state_dir) if f != ".review-gate-state.json"]
    assert leftovers == []


# ---------------------------------------------------------------------------------------------
# load_state_or_raise() / StateFileMalformed -- the read-side counterpart to update_state()'s
# own write-side protection (a Codex review finding on this port's own PR): without this,
# pantheon.cli's follow-up-mode read (via the permissive load_state()) would silently treat a
# malformed state file as "no prior state," run every agent, and post a full-review comment --
# and since update_state() correctly refuses to ever overwrite that malformed file, EVERY
# subsequent invocation would repeat the exact same thing, forever (a duplicate-comment loop).
# Mirrors bash's own posture: cli/review-gate's SEEN_SHA="$(jq -r ... "$STATE_FILE")" runs under
# `set -euo pipefail`, aborting the whole script on a malformed read.
# ---------------------------------------------------------------------------------------------


def test_load_state_or_raise_returns_well_formed_state(tmp_path) -> None:
    state_file = tmp_path / "state.json"
    state_file.write_text('{"42": {"reviewed_sha": "deadbeef"}}')
    assert state.load_state_or_raise(str(state_file)) == {"42": {"reviewed_sha": "deadbeef"}}


def test_load_state_or_raise_bootstraps_a_missing_file_to_empty_dict(tmp_path) -> None:
    state_file = tmp_path / "state.json"
    assert state.load_state_or_raise(str(state_file)) == {}
    assert state_file.exists()


def test_load_state_or_raise_raises_on_malformed_json(tmp_path) -> None:
    state_file = tmp_path / "state.json"
    state_file.write_text("not valid json at all { { {")

    with pytest.raises(state.StateFileMalformed, match="not valid JSON"):
        state.load_state_or_raise(str(state_file))


def test_load_state_or_raise_raises_on_non_object_content(tmp_path) -> None:
    state_file = tmp_path / "state.json"
    state_file.write_text("[1, 2, 3]")

    with pytest.raises(state.StateFileMalformed, match="not a JSON object"):
        state.load_state_or_raise(str(state_file))


def test_load_state_still_fails_closed_to_empty_dict_for_the_same_malformed_content(tmp_path) -> None:
    # load_state() itself is UNCHANGED (still permissive) -- this is the documented contrast
    # load_state_or_raise() exists alongside, not a replacement.
    state_file = tmp_path / "state.json"
    state_file.write_text("not valid json at all { { {")
    assert state.load_state(str(state_file)) == {}


# ---------------------------------------------------------------------------------------------
# bootstrap_state_file() in an UNWRITABLE directory -- a Codex review finding on this port's own
# PR: bootstrap_state_file()'s own open() call, unguarded at each of its three call sites, let a
# raw PermissionError/OSError propagate all the way past pantheon.cli's main() (which only
# catches GateError) as a bare traceback instead of a clean, fail-closed exit. Each call site now
# wraps its own bootstrap_state_file() call according to that site's OWN existing contract for
# an OSError on the READ side just below it -- load_state_or_raise() raises StateFileMalformed
# (already caught by pantheon.cli's run_gate() and converted to GateError -- unchanged, existing
# wiring from an earlier wave), load_state() fails closed to {}, update_state() warns and
# returns.
# ---------------------------------------------------------------------------------------------


def _unwritable_dir(tmp_path):
    if os.geteuid() == 0:
        pytest.skip("running as root -- POSIX permission checks are bypassed, precondition unmet")
    d = tmp_path / "unwritable"
    d.mkdir()
    d.chmod(0o500)  # read + execute, no write
    return d


def test_bootstrap_state_file_raises_oserror_on_an_unwritable_directory_live(tmp_path) -> None:
    # Precondition proof, not the fix itself: confirms bootstrap_state_file()'s own open() call
    # genuinely raises OSError/PermissionError under this condition on this platform, live and
    # unmocked -- so the three wrapped call sites below are closing a REAL gap.
    unwritable = _unwritable_dir(tmp_path)
    state_file = unwritable / "state.json"
    with pytest.raises(OSError):
        state.bootstrap_state_file(str(state_file))


def test_load_state_or_raise_fails_closed_to_state_file_malformed_on_an_unwritable_directory(tmp_path) -> None:
    unwritable = _unwritable_dir(tmp_path)
    state_file = unwritable / "state.json"

    with pytest.raises(state.StateFileMalformed, match="failed to create"):
        state.load_state_or_raise(str(state_file))


def test_load_state_fails_closed_to_empty_dict_on_an_unwritable_directory(tmp_path) -> None:
    unwritable = _unwritable_dir(tmp_path)
    state_file = unwritable / "state.json"

    assert state.load_state(str(state_file)) == {}


def test_update_state_warns_and_returns_on_an_unwritable_directory_never_raises(tmp_path, capsys) -> None:
    unwritable = _unwritable_dir(tmp_path)
    state_file = unwritable / "state.json"

    state.update_state("green", "42", "deadbeefcafe", str(state_file), str(tmp_path))

    captured = capsys.readouterr()
    assert "failed to create" in captured.err


# ---------------------------------------------------------------------------------------------
# Symlink refusal at bootstrap -- issue #21 P2 (docs/PYTHON-PORT.md's port slice 5). The
# pre-fix bootstrap_state_file() used `if not os.path.exists(state_file): open(state_file, "w")`
# -- os.path.exists() follows symlinks and reads False for a DANGLING one (the target doesn't
# exist), so that condition was True and the open() ran anyway. A plain open(path, "w") on a
# dangling symlink is a write-THROUGH-symlink primitive: it creates the symlink's TARGET, not
# the symlink itself. Since bootstrap_state_file() runs unconditionally on every invocation
# (before --dry-run's own skip branches), a hostile PR checkout committing
# ".review-gate-state.json" as a dangling symlink could make a bare `pantheon gate --dry-run`
# silently create an attacker-chosen file.
#
# Proven failing pre-fix: reverting bootstrap_state_file()'s body to
# `if not os.path.exists(state_file): open(state_file, "w").write("{}\n")` and re-running
# test_bootstrap_state_file_refuses_a_dangling_symlink below makes it FAIL -- the dangling
# symlink's target gets created with "{}\n" instead of the function raising OSError. Verified
# locally by temporarily reverting pantheon/state.py to that pre-fix body and re-running this
# file with `pytest tests/test_state.py -k dangling_symlink -q`; restored before committing.
# ---------------------------------------------------------------------------------------------


def test_bootstrap_state_file_refuses_a_dangling_symlink(tmp_path) -> None:
    checkout = tmp_path / "hostile-checkout"
    checkout.mkdir()
    target = tmp_path / "planted-by-attacker.json"  # parent dir (tmp_path) exists — a real
    # write-through would succeed here pre-fix; only a genuine dangling-symlink refusal stops it
    state_file = checkout / ".review-gate-state.json"
    os.symlink(str(target), str(state_file))
    assert not target.exists()  # dangling: the symlink's target does not exist

    with pytest.raises(OSError):
        state.bootstrap_state_file(str(state_file))

    # The would-be write-through-symlink primitive never fired: the target directory was never
    # even created, let alone seeded with "{}\n".
    assert not target.exists()
    # The symlink itself is untouched too.
    assert os.path.islink(state_file)


def test_bootstrap_state_file_refuses_a_symlink_pointing_at_a_real_file(tmp_path) -> None:
    # Non-dangling case: the symlink's target DOES already exist. Refused too -- this function's
    # contract is "never follow a symlink at this path", not "only refuse when the target is
    # missing".
    checkout = tmp_path / "hostile-checkout"
    checkout.mkdir()
    real_target = tmp_path / "some-other-real-file.json"
    real_target.write_text('{"already": "here"}')
    state_file = checkout / ".review-gate-state.json"
    os.symlink(str(real_target), str(state_file))

    with pytest.raises(OSError):
        state.bootstrap_state_file(str(state_file))

    # The real target file is untouched -- never opened/truncated through the symlink.
    assert real_target.read_text() == '{"already": "here"}'


def test_load_state_fails_closed_to_empty_dict_on_a_dangling_symlink(tmp_path) -> None:
    # load_state()'s own fail-closed-to-{} contract (never a crash) extends to this refusal --
    # a caller on the display/no-crash path degrades to "no prior state", same as any other
    # bootstrap failure.
    checkout = tmp_path / "hostile-checkout"
    checkout.mkdir()
    target = tmp_path / "planted-by-attacker.json"  # parent dir (tmp_path) exists — a real
    # write-through would succeed here pre-fix; only a genuine dangling-symlink refusal stops it
    state_file = checkout / ".review-gate-state.json"
    os.symlink(str(target), str(state_file))

    assert state.load_state(str(state_file)) == {}
    assert not target.exists()


def test_load_state_or_raise_fails_closed_to_state_file_malformed_on_a_dangling_symlink(tmp_path) -> None:
    checkout = tmp_path / "hostile-checkout"
    checkout.mkdir()
    target = tmp_path / "planted-by-attacker.json"  # parent dir (tmp_path) exists — a real
    # write-through would succeed here pre-fix; only a genuine dangling-symlink refusal stops it
    state_file = checkout / ".review-gate-state.json"
    os.symlink(str(target), str(state_file))

    with pytest.raises(state.StateFileMalformed, match="failed to create"):
        state.load_state_or_raise(str(state_file))
    assert not target.exists()


def test_update_state_warns_and_returns_on_a_dangling_symlink_never_raises_never_writes(tmp_path, capsys) -> None:
    checkout = tmp_path / "hostile-checkout"
    checkout.mkdir()
    target = tmp_path / "planted-by-attacker.json"  # parent dir (tmp_path) exists — a real
    # write-through would succeed here pre-fix; only a genuine dangling-symlink refusal stops it
    state_file = checkout / ".review-gate-state.json"
    os.symlink(str(target), str(state_file))

    state.update_state("green", "42", "deadbeefcafe", str(state_file), str(tmp_path))

    captured = capsys.readouterr()
    assert "failed to create" in captured.err
    assert not target.exists()
    assert os.path.islink(state_file)
