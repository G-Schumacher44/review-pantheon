"""agents — the five canonical persona files (artemis/apollo/diogenes/plato/socrates .md),
DESIGN.md rule 4's single hand-maintained source, read directly by the bash CLI, install.sh,
bootstrap.sh, and action.yml/action/review.yml (as plain Markdown, this __init__.py is invisible
to all of them).

This file exists ONLY so setuptools can package this directory as ``pantheon.agents`` in the
wheel (see pyproject.toml's ``[tool.setuptools.package-dir]``: ``"pantheon.agents" = "agents"``)
— a Codex review finding on port slice 5's own PR: a real, non-editable ``pip``/``pipx`` install
of the ``pantheon`` package carried NO persona files at all before this fix, because
``pantheon/cli.py``'s ``_agents_dir()`` resolved ``agents/`` as a sibling of its own installed
location on disk, which is only true for a dev checkout, never a real site-packages install. See
``pantheon.cli._agents_dir()`` for the ``importlib.resources``-based loader this makes possible,
with a dev-checkout sibling-directory fallback for anyone still running from a raw checkout.

Deliberately empty otherwise — no code, no re-exports. Nothing imports from this package; it
exists purely so ``importlib.resources.files("pantheon.agents")`` can find the ``*.md`` files
installed alongside it.
"""

from __future__ import annotations
