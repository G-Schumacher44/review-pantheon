#!/usr/bin/env python3
"""decide_verdict.py — DEPRECATED, one-release compat shim (port slice 5 absorption,
docs/PYTHON-PORT.md section 3's "one runtime endgame").

This file is no longer the canonical implementation of review-pantheon's verdict-decision rule —
that logic now lives in `pantheon/verdict.py`, ONE Python implementation shared by both lanes
that used to each carry their own copy (the CLI's `cli/lib/verdict.sh`, retired this slice, and
this file). `action.yml` and the vendored `action/review.yml` both now invoke
`python3 -m pantheon.verdict` directly instead of this file — see action.yml's "Decide verdict
(<agent>)" steps and action/review.yml's own "Decide verdict" step, both of which now resolve a
base-pinned copy of the `pantheon` package (its `__init__.py`/`jqjson.py`/`verdict.py` — the only
three files `pantheon.verdict` actually imports) rather than a base-pinned copy of this file.

**Why this file still exists at all, and for how long:** `install.sh` still vendors it into a
target repo at `.github/review-agents/decide_verdict.py` for ONE MORE RELEASE, purely so nothing
that scripts against `decide_verdict.py`'s own argv contract directly (rather than through
`action/review.yml`, which no longer calls it) breaks the moment this PR merges. It is removed
outright in the release AFTER this one, alongside `review-gate`'s own compat shim
(`pantheon.reviewgate_shim`) — both on the identical one-release compat window, both documented
in docs/PYTHON-PORT.md's Slice-5 status section. Nothing new should depend on this file; use
`python3 -m pantheon.verdict <expected-agent> <raw-output-file>` (or `import pantheon.verdict`)
instead.

This shim is a THIN forward, not a reimplementation — it locates the real `pantheon` package
(checking, in order, its own directory and its own directory's parent — see
`_locate_pantheon_package()` below, which covers both this file's OWN repo-root-relative location
and the vendored-into-a-target-repo location `install.sh` installs it at) and delegates straight
into `pantheon.verdict.main()`, so there is exactly one implementation of the decision rule to
keep correct, not two that can drift the way this file and `cli/lib/verdict.sh` already did
before this slice retired that comparison entirely.
"""

from __future__ import annotations

import os
import sys


def _locate_pantheon_package() -> str | None:
    """Returns the directory that should be prepended to sys.path so `import pantheon` resolves
    the real package, or None if neither of the two locations this shim knows about has one.
    Checked, in order:

      1. This file's OWN directory — the shape `install.sh` vendors into a target repo at
         `.github/review-agents/`: `decide_verdict.py` and a `pantheon/` package directory land
         as SIBLINGS there (mirrors the vendored personas/wrapper's own flat layout).
      2. This file's directory's PARENT — this repo's own layout: `action/decide_verdict.py`
         sits one level below the repo root, where the real `pantheon/` package lives (a sibling
         of `action/`, not of this file itself).
    """
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (here, os.path.dirname(here)):
        if os.path.isfile(os.path.join(candidate, "pantheon", "__init__.py")):
            return candidate
    return None


_pkg_dir = _locate_pantheon_package()
if _pkg_dir is not None and _pkg_dir not in sys.path:
    sys.path.insert(0, _pkg_dir)

try:
    from pantheon.verdict import main as _pantheon_verdict_main
except ImportError as _import_error:  # pragma: no cover — only reachable if vendoring broke
    _pantheon_verdict_main = None
    _pantheon_import_error = _import_error


def main() -> int:
    if _pantheon_verdict_main is None:
        print(
            "decide_verdict.py: DEPRECATED compat shim — could not locate the 'pantheon' "
            f"package (checked alongside and one directory above this file): {_pantheon_import_error}. "
            "This shim delegates to `pantheon.verdict`; if you vendored decide_verdict.py without "
            "also vendoring the pantheon/ package next to it, re-run install.sh.",
            file=sys.stderr,
        )
        return 2
    print(
        "decide_verdict.py: DEPRECATED — this is a one-release compat shim forwarding to "
        "`python3 -m pantheon.verdict`. Nothing in this repo's own workflows calls this file "
        "directly anymore (docs/PYTHON-PORT.md section 3); it is removed in the next release.",
        file=sys.stderr,
    )
    return _pantheon_verdict_main(sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
