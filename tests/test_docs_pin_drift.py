"""The docs' hand-restated upstream pin must match action.yml's live pin.

Apollo on PR #86: the v1.0.191→v1.0.195 bump updated all five ``uses:`` call sites but left
SECURITY.md and DESIGN.md documenting the old SHA — the same restated-value drift class the
denied-commands docs test (test_security_md_denied_commands.py) closes for the deny list.
One source of truth: whatever full-SHA pin action.yml carries, every doc that names a pin
must name THAT one.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

_PIN_RE = re.compile(r"anthropics/claude-code-action@([0-9a-f]{40})\s*#\s*(v[0-9.]+)")


def _action_pin() -> tuple[str, str]:
    text = (ROOT / "action.yml").read_text(encoding="utf-8")
    pins = _PIN_RE.findall(text)
    assert pins, "action.yml: no full-SHA claude-code-action pin found — the pin convention changed?"
    shas = {sha for sha, _ in pins}
    versions = {ver for _, ver in pins}
    assert len(shas) == 1 and len(versions) == 1, (
        f"action.yml: call sites disagree on the pin ({shas} / {versions}) — "
        "every uses: line must carry the identical SHA and version comment"
    )
    return pins[0]


def test_docs_name_the_live_pin() -> None:
    sha, version = _action_pin()
    for doc in ("SECURITY.md", "DESIGN.md"):
        text = (ROOT / doc).read_text(encoding="utf-8")
        stale_shas = [m for m in re.findall(r"\b[0-9a-f]{40}\b", text) if m != sha]
        assert sha in text, (
            f"{doc}: does not name action.yml's live pin SHA {sha} — "
            "a pin bump left this doc's security-posture claim stale"
        )
        assert not stale_shas, f"{doc}: names SHA(s) {stale_shas} that are not the live pin {sha} — stale pin reference"
        assert version in text, f"{doc}: does not name the live pinned version {version}"
