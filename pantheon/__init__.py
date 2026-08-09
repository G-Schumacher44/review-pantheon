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

try:
    __version__ = _version("review-pantheon")
except PackageNotFoundError:
    __version__ = "0.1.0+local"

__all__ = ["__version__"]
