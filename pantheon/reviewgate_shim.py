"""pantheon/reviewgate_shim.py — the `review-gate` compat shim (docs/PYTHON-PORT.md section 2).

**Slice 5 status update (deviation from this file's original "removed at Slice 5" plan, deliberate
and documented — see docs/PYTHON-PORT.md's Slice-5 status section):** `pantheon` is now THE CLI —
README.md/docs/CLI.md/docs/SETUP.md all document it as the current, canonical entry point as of
this slice. `review-gate` (this shim) ships ONE MORE RELEASE as a deprecated compat shim rather
than being removed outright alongside the rest of the bash CLI surface (`cli/review-gate`,
`cli/lib/*.sh`, `cli/providers/*.sh` — those ARE removed this slice, per the one-runtime endgame,
docs/PYTHON-PORT.md section 3) — so nothing already scripting against the `review-gate` binary
name breaks the moment this PR merges. It is removed in the release AFTER this one; every caller
should switch to `pantheon gate` now, not wait for the forced removal.

Deliberately NOT a wrapper around `cli/review-gate` (the bash script, which no longer exists as of
this slice) — this shim forwards into `pantheon.cli`, the same Python implementation `pantheon
gate` itself calls, so `PANTHEON_CLI=review-gate` (docs/PYTHON-PORT.md section 4's migration-exam
default) and `PANTHEON_CLI=pantheon` (settable to the installed `pantheon` binary) exercise the
identical code path — the whole point of a compat shim landing alongside the real port, not a
second implementation to keep in sync.
"""

from __future__ import annotations

import sys

from pantheon.cli import main as _pantheon_main

__all__ = ["main"]


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    print(
        "review-gate: DEPRECATED — this is a one-release compat shim forwarding to `pantheon "
        "gate`. `pantheon` is now the CLI (docs/CLI.md); switch to `pantheon gate` now — this "
        "shim is removed in the next release, per the one-runtime endgame (docs/PYTHON-PORT.md "
        "section 3).",
        file=sys.stderr,
    )
    return _pantheon_main(["gate", *argv])


if __name__ == "__main__":
    sys.exit(main())
