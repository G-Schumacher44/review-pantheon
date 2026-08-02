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
