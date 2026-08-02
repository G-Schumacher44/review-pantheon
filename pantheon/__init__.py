"""pantheon — review-pantheon's Python CLI (v2 port).

See docs/PYTHON-PORT.md for the binding spec this package implements. Slice 2 ships the first
two real modules, ``pantheon.verdict`` and ``pantheon.render`` — see docs/PYTHON-PORT.md section
6 ("Module layout") for what each module owns and which bash file(s) it replaces.

stdlib-only at runtime, Python >=3.9 — docs/PYTHON-PORT.md section 1 is the hard constraint this
whole package (every module under it) must keep, not a default to relax later.
"""
from __future__ import annotations

# Single source of truth for the version string is pyproject.toml's [project].version — read it
# back via importlib.metadata instead of hand-copying the same literal into a second file, which
# is exactly the kind of two-places-drift docs/PYTHON-PORT.md and DESIGN.md both warn against
# elsewhere in this repo. Falls back to the pyproject.toml skeleton's own pre-release literal
# when the package isn't installed (e.g. running straight out of a working tree/worktree without
# `pip install -e .` — that's the normal state of this repo mid-port, not an error condition).
try:
    from importlib.metadata import PackageNotFoundError, version as _version
except ImportError:  # pragma: no cover — importlib.metadata is stdlib on Python >=3.8
    from importlib_metadata import PackageNotFoundError, version as _version  # type: ignore[no-redef]

try:
    __version__ = _version("review-pantheon")
except PackageNotFoundError:
    __version__ = "0.0.0.dev0"

__all__ = ["__version__"]
