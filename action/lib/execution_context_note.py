#!/usr/bin/env python3
"""action/lib/execution_context_note.py — thin driver for
pantheon.execution.execution_context_note(), invoked by action/lib/build_prompt.sh.

Deliberately NOT invoked via `python3 -c '<code>'` (a live Codex P1 finding on this PR's own
prior fix): a composite-action step's cwd is the CONSUMING repo's checkout, and `python3 -c`
sets `sys.path[0]` to `""`, which Python resolves as the CURRENT WORKING DIRECTORY — placed
BEFORE any `PYTHONPATH` entry. A fork PR that commits its own top-level `pantheon/__init__.py` +
`pantheon/execution.py` would get THOSE files imported by `from pantheon import execution`
instead of the trusted package, forging whatever `execution_context_note()` returns (the exact
shadow class `pantheon.execution.resolve_console_script`'s own docstring, and this action's
`verdict.py`/`basepin.py`/`execution.py` (wrapper) invocations, already close by running a
trusted FILE via its own absolute path instead).

Running THIS file by absolute path (`python3 <path-to-this-file> <tier> <wrapper-path>`) closes
the same vector the same way: this script's own directory (`action/lib/`, part of
review-pantheon's own trusted checkout) becomes `sys.path[0]`, never the caller's cwd.
`PYTHONPATH` (set by the caller to review-pantheon's own repo root) supplies the entry
`from pantheon import execution` actually needs, and it is only ever consulted AFTER
`sys.path[0]` — which here is never attacker-influenced.

Usage: execution_context_note.py <tier> <wrapper-path>
Prints pantheon.execution.execution_context_note(tier, wrapper_path) to stdout, verbatim
(including its own trailing newline, or lack of one for "trusted").
"""

from __future__ import annotations

import sys

from pantheon import execution


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: execution_context_note.py <tier> <wrapper-path>", file=sys.stderr)
        return 2
    tier, wrapper_path = argv
    sys.stdout.write(execution.execution_context_note(tier, wrapper_path))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
