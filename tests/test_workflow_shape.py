"""The consumer-facing workflow shape is a security control, not a style preference.

Both documented install paths (``examples/review-gate.yml`` = Way C, and the workflow
``install.sh`` generates = Way A) currently carry four properties that keep a consumer's
run safe: the plain ``pull_request`` trigger, least-privilege permissions, a checkout that
does not persist credentials, and a fully SHA-pinned upstream action. Every one of those
is true today and nothing stopped it changing — this module makes them enforced.

Companion to ``tests/check_action_expressions.py`` (which guards action.yml's own
expressions) and to the tier assertions in ``test_providers.py`` /
``test-execution-tier-python.sh``.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FULL_SHA = re.compile(r"^[0-9a-f]{40}$")


def _way_c() -> str:
    return (ROOT / "examples" / "review-gate.yml").read_text(encoding="utf-8")


def _way_a() -> str:
    """The workflow install.sh writes into a consumer repo, extracted from its heredoc."""
    text = (ROOT / "install.sh").read_text(encoding="utf-8")
    # The generated workflow is the heredoc body written to $workflow_tmp. Anchored on the
    # workflow's own `name:` key so a change to surrounding shell can't silently make this
    # test read the wrong span (an empty/short span would make every assertion below vacuous).
    start = text.index("\nname: review-pantheon\n")
    end = text.index("\nEOF", start)
    body = text[start:end]
    assert "actions/checkout" in body and "on:" in body, (
        "extracted install.sh workflow span looks wrong — assertions would be vacuous"
    )
    return body


def _both() -> list[tuple[str, str]]:
    return [("Way C (examples/review-gate.yml)", _way_c()), ("Way A (install.sh)", _way_a())]


def test_trigger_is_plain_pull_request() -> None:
    """`pull_request` must be the ONLY trigger, not merely one of them.

    Same shape the permissions check had: asserting the wanted key is *present* lets any
    additional key through. A stub that keeps `pull_request:` and adds `push:` or
    `workflow_dispatch:` would pass a presence check, but those events carry no
    `github.event.pull_request`, which every step of action.yml reads its PR number and
    base/head SHAs from — so the action fails partway through rather than not running.
    """
    for name, body in _both():
        block = re.search(r"^on:\s*$(.*?)(?=^\S|\Z)", body, re.M | re.S)
        assert block, f"{name}: no top-level 'on:' block found"

        # Top-level event keys are the ones indented exactly one level; anything deeper
        # (a `types:` list, for instance) belongs to the event above it.
        events = re.findall(r"^  ([A-Za-z_]+):", block.group(1), re.M)
        assert events == ["pull_request"], (
            f"{name}: 'on:' must declare exactly ['pull_request'], found {events} — other "
            "events invoke action.yml without github.event.pull_request, which every step "
            "reads the PR number and base/head SHAs from"
        )


def test_unsafe_triggers_appear_nowhere() -> None:
    """pull_request_target / workflow_run give untrusted fork content base-repo secrets."""
    for name, body in _both():
        for unsafe in ("pull_request_target", "workflow_run"):
            assert unsafe not in body, f"{name}: unsafe trigger '{unsafe}' present"


def test_permissions_are_least_privilege() -> None:
    """Exact mapping, not a denylist.

    An earlier form asserted the two expected grants were present and blacklisted four
    specific over-broad ones — so a NEW grant (`issues: write`, `checks: write`, anything
    unanticipated) sailed through the very test introduced to prevent token-scope drift.
    A least-privilege check has to be an allowlist: parse the block and require it to
    contain exactly the two grants the gate needs, and nothing else.
    """
    expected = {"contents": "read", "pull-requests": "write"}

    for name, body in _both():
        block = re.search(r"^permissions:\s*$(.*?)(?=^\S|\Z)", body, re.M | re.S)
        assert block, f"{name}: no top-level 'permissions:' block found"

        granted: dict[str, str] = {}
        for line in block.group(1).splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = re.match(r"^\s+([A-Za-z-]+):\s*([A-Za-z-]+)\s*$", line)
            assert m, f"{name}: unparsed line in permissions block: {line!r}"
            granted[m.group(1)] = m.group(2)

        assert granted == expected, (
            f"{name}: permissions must be exactly {expected}, found {granted} — the gate needs "
            "contents:read to diff and pull-requests:write to post its verdict, and nothing "
            "more; any additional grant widens what a compromised run could reach"
        )


def test_checkout_does_not_persist_credentials() -> None:
    """EVERY checkout step, not "the file mentions it somewhere".

    Third instance of this shape in this file (permissions and triggers were the first two):
    a presence check passes as soon as one occurrence is right. A second `actions/checkout`
    added without the option would persist the token into `.git/config`, where the reviewer —
    which is not path-scoped — can read it. Parse the steps and require it on each one.
    """
    for name, body in _both():
        # Split on step boundaries ("- uses:" / "- name:" at list-item indentation).
        steps = re.split(r"^\s+-\s+(?=uses:|name:)", body, flags=re.M)
        checkouts = [st for st in steps if re.search(r"uses:\s*actions/checkout", st)]
        assert checkouts, f"{name}: no actions/checkout step found"

        for idx, step in enumerate(checkouts):
            assert re.search(r"^\s*persist-credentials:\s*false\s*$", step, re.M), (
                f"{name}: actions/checkout step #{idx + 1} does not set "
                "persist-credentials: false — that checkout writes the workflow token into "
                ".git/config, which the reviewer can read (Read/Grep/Glob are not path-scoped)"
            )


def test_action_tool_policy_is_asserted_for_both_tiers() -> None:
    """action.yml's tool policy, asserted — the claim used to be made and not kept.

    A comment in action.yml said the expression guard verified the action and Python tool
    policies agree. It does not: it never inspects ALLOWED_TOOLS, DENIED_TOOLS,
    --permission-mode or --disallowedTools, so deleting the action's --disallowedTools line
    left every suite green while silently reopening the built-in-command bypass. The CLI
    surface has had these assertions all along; this is the action surface catching up.
    """
    action = (ROOT / "action.yml").read_text(encoding="utf-8")

    assert re.search(r'readonly\)\s*\n\s*ALLOWED_TOOLS="Read,Grep,Glob,Bash\(\$GIT_WRAPPER \*\)"', action), (
        "readonly must scope Bash to the wrapper prefix with Read/Grep/Glob unrestricted"
    )
    assert re.search(r"trusted\)\s*\n\s*ALLOWED_TOOLS='Read,Grep,Glob,Bash'", action), "trusted must grant full Bash"
    # The deny list must be sourced from the single Python function, not duplicated in YAML.
    assert "disallowed-tools readonly" in action, (
        "readonly must source its deny list from pantheon/execution.py's disallowed-tools "
        "subcommand — a hand-copied YAML list is how the two surfaces drift apart"
    )
    assert re.search(r'trusted\)(?:.|\n)*?DENIED_TOOLS=""', action), "trusted must emit no deny list"
    # Both flags must actually reach claude_args, or the values above are decorative.
    assert "--permission-mode dontAsk" in action, (
        "without dontAsk, an unmatched tool call has no answer outside an interactive terminal"
    )
    assert re.search(r'--disallowedTools \\"\$DENIED_TOOLS\\"', action), (
        "DENIED_TOOLS must be passed through to claude_args — computing it and not passing it "
        "is the exact silent-reopen this test exists to catch"
    )


def test_upstream_action_is_sha_pinned() -> None:
    """A moving tag can change what code runs without any change landing here.

    The pin that matters lives in action.yml, not in the consumer stubs: those reference
    review-pantheon at the ``@v1`` moving tag on purpose (that is the documented install
    shape, and the tag is ours to move deliberately), while the third-party action we
    invoke on the consumer's runner must never move under them.
    """
    action = (ROOT / "action.yml").read_text(encoding="utf-8")
    refs = [ref for ref in re.findall(r"uses:\s*([^\s#]+)", action) if ref.startswith("anthropics/claude-code-action@")]
    assert refs, "action.yml no longer references anthropics/claude-code-action"
    for ref in refs:
        _, _, version = ref.partition("@")
        assert FULL_SHA.match(version), (
            f"'{ref}' must pin a full 40-character commit SHA — a tag can move under consumers"
        )
    assert len(set(refs)) == 1, f"action.yml pins more than one upstream revision: {set(refs)}"


def test_consumer_stubs_reference_this_action() -> None:
    """Sanity anchor: if a stub stopped invoking review-pantheon, every assertion above
    would still pass while testing a workflow that no longer runs the gate."""
    for name, body in _both():
        assert "review-pantheon@" in body, f"{name}: does not invoke review-pantheon"
