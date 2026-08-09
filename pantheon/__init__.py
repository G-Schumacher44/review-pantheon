"""pantheon — review-pantheon's Python CLI (v2 port).

This package is the Python port of review-pantheon's original bash CLI (``review-gate`` and
friends, removed in #29). Slice 2 shipped the first two real modules, ``pantheon.verdict`` and
``pantheon.render`` — see each module's own docstring for what it owns and which retired bash
file it replaces.

stdlib-only at runtime, Python >=3.9 — a hard constraint this whole package (every module under
it) must keep, not a default to relax later.
"""

from __future__ import annotations

# Single source of truth for the version string is pyproject.toml's [project].version — read it
# back via importlib.metadata instead of hand-copying the same literal into a second file, which
# is exactly the kind of two-places-drift DESIGN.md warns against elsewhere in this repo. When
# the package isn't installed (e.g. running straight out of a working tree/worktree without
# `pip install -e .` — a normal state, not an error condition), falls back to the current
# release literal with a `+local` suffix, so an uninstalled checkout's version never
# masquerades as a real pip-installed release in bug reports or --version output.
try:
    from importlib.metadata import PackageNotFoundError
    from importlib.metadata import version as _version
except ImportError:  # pragma: no cover — importlib.metadata is stdlib on Python >=3.8
    from importlib_metadata import (  # type: ignore[import-not-found,no-redef]
        PackageNotFoundError,
    )
    from importlib_metadata import version as _version  # type: ignore[no-redef]


def _fallback_version() -> str:
    """Uninstalled-checkout fallback: read pyproject.toml's version from the adjacent source
    tree (this path only runs when the package is NOT pip-installed, so pyproject.toml sits
    next to this package by construction) and mark it `+local` so it can never masquerade as a
    real installed release. Regex, not tomllib — tomllib is 3.11+ and this package supports
    3.9; an anchored key match on the [project] table's own line is enough for a fallback."""
    import os
    import re

    pyproject = os.path.join(os.path.dirname(__file__), "..", "pyproject.toml")
    try:
        with open(pyproject, encoding="utf-8") as fh:
            match = re.search(r'^version\s*=\s*"([^"]+)"', fh.read(), flags=re.MULTILINE)
    except OSError:
        match = None
    return f"{match.group(1)}+local" if match else "0+unknown"


try:
    __version__ = _version("review-pantheon")
except PackageNotFoundError:
    __version__ = _fallback_version()

__all__ = ["__version__"]
