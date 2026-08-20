"""tests/test_security_md_denied_commands.py — SECURITY.md's prose list vs. the live source.

SECURITY.md's "The built-in bypass, and what now closes it" section hand-restates, in prose, the
same 15 command names that live as code in ``pantheon.execution.DENIED_BUILTIN_BASH_COMMANDS`` —
docs need to stay readable prose, so the enumeration itself is not derived at doc-render time, but
nothing PREVIOUSLY asserted the two stayed in sync (issue #78's third instance of the same drift
class as ``tests/check_action_expressions.py``'s ``check_env_bindings`` and
``tests/test-execution-tier-python.sh``'s deny-list loop). A contributor who adds or removes an
entry from the code list without updating the doc — or vice versa — now fails this test instead of
shipping a doc that silently drifts from the behavior it describes.

Checked in BOTH directions: a name in the code but missing from the doc (an addition nobody
documented) and a name in the doc but absent from the code (a doc that overclaims what's actually
denied) are equally a drift, so both fail.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from pantheon import execution

REPO_ROOT = Path(__file__).resolve().parent.parent
SECURITY_MD = REPO_ROOT / "SECURITY.md"

# The command list lives in one sentence under this heading, as a run of backtick-wrapped, single
# lowercase words — anchored to exactly that sentence (not the whole paragraph, let alone the
# whole file) so unrelated backtick terms nearby (`--allowedTools` two sentences earlier, and
# `readonly` — a TIER name, not a command — in the very next sentence) can never be mistaken for a
# denied-command name.
_SECTION_HEADING = "### The built-in bypass, and what now closes it"
_LIST_SENTENCE_END = "Under `readonly`"


def _documented_denied_commands() -> list[str]:
    text = SECURITY_MD.read_text(encoding="utf-8")
    start = text.index(_SECTION_HEADING) + len(_SECTION_HEADING)
    end = text.index(_LIST_SENTENCE_END, start)
    paragraph = text[start:end]
    # Single lowercase-word backtick spans only — excludes flag-shaped (`--allowedTools`) and
    # ENV-VAR-shaped (`GIT_OPTIONAL_LOCKS`) or mixed-case (`readonly`) backtick terms that share
    # this paragraph but are not command names.
    return re.findall(r"`([a-z]+)`", paragraph)


def test_security_md_documented_commands_match_the_live_deny_list_exactly() -> None:
    documented = _documented_denied_commands()
    assert documented, (
        "no backtick-wrapped command names found under the 'built-in bypass' heading — section renamed or reformatted?"
    )

    documented_set = set(documented)
    live_set = set(execution.DENIED_BUILTIN_BASH_COMMANDS)

    missing_from_docs = live_set - documented_set
    extra_in_docs = documented_set - live_set

    assert not missing_from_docs, (
        f"pantheon.execution.DENIED_BUILTIN_BASH_COMMANDS has {sorted(missing_from_docs)} that "
        "SECURITY.md's 'built-in bypass' section does not mention — the doc now UNDERCLAIMS what "
        "readonly actually denies. Add the name(s) to that paragraph."
    )
    assert not extra_in_docs, (
        f"SECURITY.md's 'built-in bypass' section names {sorted(extra_in_docs)} which is not in "
        "pantheon.execution.DENIED_BUILTIN_BASH_COMMANDS — the doc now OVERCLAIMS what readonly "
        "actually denies. Remove the name(s) from that paragraph or add them to the live list."
    )


def test_security_md_documented_commands_have_no_duplicates() -> None:
    documented = _documented_denied_commands()
    assert len(documented) == len(set(documented)), (
        f"SECURITY.md's 'built-in bypass' section names a command more than once: {documented}"
    )
