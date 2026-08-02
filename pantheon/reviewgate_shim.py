"""pantheon/reviewgate_shim.py — the `review-gate` compat shim (docs/PYTHON-PORT.md section 2).

Ships alongside `pantheon` during the transition (Slices 2 through 4): a console-script entry
point (`review-gate`, wired in pyproject.toml's `[project.scripts]`) that forwards every argument
to `pantheon gate` unchanged, prints a one-line deprecation note to stderr, and exits with the
same code `pantheon gate` would. It exists so nothing that scripts against the `review-gate`
binary name breaks mid-port. Removed at Slice 5, alongside the rest of the bash CLI surface
(`cli/review-gate`, `cli/lib/*.sh`, `cli/providers/*.sh`).

Deliberately NOT a wrapper around `cli/review-gate` (the bash script) — this shim forwards into
`pantheon.cli`, the same Python implementation `pantheon gate` itself calls, so
`PANTHEON_CLI=review-gate` (docs/PYTHON-PORT.md section 4's migration-exam default) and
`PANTHEON_CLI=pantheon` (settable to the installed `pantheon` binary) exercise the identical code
path — the whole point of a compat shim landing alongside the real port, not a second
implementation to keep in sync.
"""

from __future__ import annotations

import sys

from pantheon.cli import main as _pantheon_main

__all__ = ["main"]


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    print(
        "review-gate: deprecated — this is a compat shim forwarding to `pantheon gate`; "
        "switch to `pantheon gate` directly (see docs/PYTHON-PORT.md). Removed at port Slice 5.",
        file=sys.stderr,
    )
    return _pantheon_main(["gate", *argv])


if __name__ == "__main__":
    sys.exit(main())
