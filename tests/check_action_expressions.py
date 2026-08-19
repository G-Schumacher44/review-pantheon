#!/usr/bin/env python3
"""tests/check_action_expressions.py — the expression guard actionlint cannot provide.

Two defect classes, both found LIVE on this repo by a pre-flip security review, both on the same
three lines of the since-deleted vendored ``action/review.yml`` (issue #36 collapsed it into a
thin caller of ``action.yml`` — see DESIGN.md's "Published action" section):

1. **Double-quoted string literals inside ``${{ }}``.** The GitHub Actions expression grammar
   accepts SINGLE-quoted literals only. ``${{ x || "fallback" }}`` is rejected at queue time, so
   the workflow never runs at all — for every adopter, silently. actionlint does catch this one,
   but only for real *workflow* files: ``action.yml`` is composite-action metadata, which
   actionlint refuses outright (``"jobs" section is missing in workflow``), leaving the flagship
   published surface — the ``@v1`` path every non-vendoring adopter uses — with no coverage.

2. **``${{ }}`` interpolated into a ``run:`` block.** The expression engine substitutes BEFORE
   bash parses the script, so an interpolated value is not data, it is script text. When the value
   is model-authored prose (a finding's ``issue``, a ``top_finding``), a quote and a semicolon are
   remote code execution in a job holding ``CLAUDE_CODE_OAUTH_TOKEN``. Values must travel via
   ``env:`` and be read as ``"$VAR"``. actionlint does NOT catch this — verified, not assumed: its
   untrusted-input rule fires only for an allowlist of ``github.*`` contexts and never for
   ``steps.*.outputs.*``, which is precisely the vector that matters here.

Deliberately a plain-text scan rather than a YAML-aware walk: the property is syntactic (does an
expression appear inside a ``run:`` script at all), the failure mode is catastrophic-but-obvious,
and a scanner with no dependencies cannot itself break the build on a PyYAML version bump.

Exit 0 = clean, exit 1 = findings printed with file:line.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The one Action surface (since issue #36 deleted the vendored action/review.yml duplicate).
# action.yml is composite-action metadata that actionlint cannot parse — covering it here is the
# entire reason this file exists.
TARGETS = ("action.yml",)

EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)

# A `${{ }}` whose body contains a double-quoted literal. Single quotes are the only valid string
# delimiter in the expression grammar.
DQ_LITERAL = re.compile(r'"[^"]*"')

# Contexts that are safe to interpolate into a `run:` block because their values are structurally
# constrained by the workflow itself, not by a model or a PR author. `matrix.*` comes from the
# workflow's own matrix literal; `runner.*`/`env.*` are set by the runner or by us. Everything
# else — `steps.*.outputs.*`, `github.*`, `inputs.*`, `needs.*` — must go through `env:`.
SAFE_RUN_CONTEXTS = re.compile(r"^\s*(matrix\.[A-Za-z0-9_]+|runner\.[A-Za-z0-9_]+)\s*$")



def _run_block_spans(text: str) -> list[tuple[int, int]]:
    """Byte spans of every ``run:`` block's script body.

    A ``run:`` block starts at a ``run: |``/``run: >`` line and continues while lines are blank or
    indented deeper than the ``run:`` key itself — standard YAML block-scalar extent, which is all
    this needs to be to locate script text.
    """
    spans: list[tuple[int, int]] = []
    lines = text.split("\n")
    offsets: list[int] = []
    pos = 0
    for line in lines:
        offsets.append(pos)
        pos += len(line) + 1

    i = 0
    while i < len(lines):
        # SINGLE-LINE `run: cmd` counts too, not just block scalars. An earlier version of this
        # matched only `run: |`/`run: >`, so `run: echo "${{ ... }}"` — identical risk, different
        # YAML spelling — was never scanned, and the guard printed "clean" over six live
        # interpolations in action.yml. A check that cannot fail for half the syntax it claims to
        # cover is green by construction.
        # The negative lookahead must reject EVERY block-scalar header spelling, not just a bare
        # `|`/`>`. YAML allows an indentation indicator and a chomping indicator in either order
        # (`|-`, `|+`, `>-`, `|2`, `|2-`) and a trailing comment (`| # note`). An earlier version
        # matched only `[|>]\s*$`, so `run: |-` — the commonest spelling in real workflows — was
        # classified as a single-line command: the span recorded was the header line alone and the
        # BODY WAS NEVER SCANNED. That made this guard narrower than the version it replaced, in
        # the commit that claimed to widen it. tests/test_action_guard.py now pins every spelling.
        single = re.match(r"^(\s*)run:\s*(?![|>][0-9+-]*\s*(?:#.*)?$)\S", lines[i])
        if single:
            spans.append((offsets[i], offsets[i] + len(lines[i]) + 1))
            i += 1
            continue
        m = re.match(r"^(\s*)run:\s*[|>]", lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        start = offsets[i]
        j = i + 1
        while j < len(lines):
            line = lines[j]
            if line.strip() and (len(line) - len(line.lstrip())) <= indent:
                break
            j += 1
        end = offsets[j] if j < len(lines) else len(text)
        spans.append((start, end))
        i = j
    return spans


def _line_of(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def _rel(path: Path) -> str:
    """Repo-relative path for display, tolerating a fixture file outside the repo.

    Exists so this module can be exercised by its own test suite against planted-violation
    fixtures in a tmp dir — a guard with no self-test is the shape it was written to prevent.
    """
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def check(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    rel = _rel(path)
    findings: list[str] = []

    for m in EXPR.finditer(text):
        body = m.group(1)
        if DQ_LITERAL.search(body):
            findings.append(
                f"{rel}:{_line_of(text, m.start())}: double-quoted literal inside ${{{{ }}}} — the "
                f"expression grammar accepts single quotes ONLY, so GitHub rejects this file at "
                f"queue time and the workflow never runs: {m.group(0)[:110]}"
            )

    spans = _run_block_spans(text)
    for start, end in spans:
        for m in EXPR.finditer(text, start, end):
            body = m.group(1)
            if SAFE_RUN_CONTEXTS.match(body):
                continue
            findings.append(
                f"{rel}:{_line_of(text, m.start())}: ${{{{ }}}} interpolated into a run: block — "
                f"the expression engine substitutes BEFORE bash parses, so this value becomes "
                f'SCRIPT TEXT, not data. Pass it through `env:` and read it as "$VAR": '
                f"{m.group(0)[:110]}"
            )
    return findings


def check_no_pull_request_target(path: Path) -> list[str]:
    """``pull_request_target`` must never appear in either Action surface.

    It is the one change that would undo everything else in this repo. Unlike ``pull_request``,
    that trigger runs with the base repository's context and DOES expose ``secrets.*`` to a run
    whose subject is an outside contributor's diff. This gate's whole job is to fetch and process
    that diff, which makes it the textbook setup for handing a stranger's content a live
    credential.

    Crucially, every other control here — base-pinned personas and decider, the read-only git
    wrapper, the argv allowlist, the neutral provider cwd — sits BELOW the trigger. None of them
    can protect you from this choice, so none of them would fail if someone made it.

    It is an attractive mistake, not an obscure one: fork PRs cannot be gated (secrets are
    withheld), and ``pull_request_target`` is the first result anyone searching for a fix will
    find. So the prohibition is enforced here rather than written down and hoped for. See
    SECURITY.md's "Fork pull requests" section.

    No exemption is needed. An earlier draft carved one out for action.yml's own refusal step,
    which had to name the forbidden triggers in order to reject them; that step now allowlists
    ``pull_request`` instead of enumerating unsafe events, so it never spells the literal at all
    and the carve-out went with it. A guard with no exceptions is worth more than a guard with a
    defended one.
    """
    text = path.read_text(encoding="utf-8")
    rel = _rel(path)
    findings: list[str] = []

    lines = text.split("\n")

    for idx, line in enumerate(lines):
        i = idx + 1
        # Only actual USE counts, not the warnings in this repo telling you never to use it.
        # Anything after a `#` is a comment — inert in both YAML and bash, so a mention there is
        # documentation, not a trigger. (Contrast the `${{ }}` check above, which deliberately
        # does NOT skip comments: expression substitution happens before bash parses, so a value
        # containing a newline escapes the comment and becomes script. Different rule, because
        # the two are evaluated at different times.)
        code = re.split(r"(?:^|\s)#", line, maxsplit=1)[0]
        if "pull_request_target" not in code:
            continue
        findings.append(
            f"{rel}:{i}: `pull_request_target` is FORBIDDEN in this repo — "
            f"it exposes secrets to a run whose subject is an untrusted diff, and every other "
            f"control here sits below the trigger and cannot compensate. See SECURITY.md's "
            f'"Fork pull requests" section.'
        )
    return findings


def check_env_bindings(path: Path) -> list[str]:
    """Every step whose script reads ``$VAR`` for an action-context value must BIND that var in its
    own ``env:``.

    This is the other half of moving interpolations out of ``run:`` blocks. Move
    ``${{ github.action_path }}`` into ``env:`` but forget the binding on one step, and that step's
    ``"$ACTION_PATH/action/lib/build_prompt.sh"`` silently becomes ``"/action/lib/build_prompt.sh"``
    — an absolute path at the filesystem root. `set -u` does not save you: the var is *defined* as
    empty by the runner, not unset.

    Checked per STEP, not per file: a sibling step having the binding proves nothing about this one.
    """
    text = path.read_text(encoding="utf-8")
    rel = _rel(path)
    lines = text.split("\n")
    findings: list[str] = []

    # Step boundaries: a `- name:` at any indentation (composite steps and workflow steps differ).
    starts = [i for i, ln in enumerate(lines) if re.match(r"^\s*- name:", ln)]
    starts.append(len(lines))

    for k in range(len(starts) - 1):
        block = "\n".join(lines[starts[k] : starts[k + 1]])
        if "run:" not in block:
            continue
        for var in ("ACTION_PATH", "PERSONAS_DIR"):
            uses = re.search(rf"\${var}\b|\$\{{{var}\}}", block)
            if not uses:
                continue
            # The step that DEFINES the value (assigns it in its own script) needs no binding.
            if re.search(rf"^\s*{var}=", block, re.M):
                continue
            if not re.search(rf"^\s+{var}:\s", block, re.M):
                findings.append(
                    f"{rel}:{starts[k] + 1}: step reads ${var} but does not bind it in its own "
                    f"env: — it expands to the EMPTY STRING at run time, silently rewriting every "
                    f'"${var}/..." path to the filesystem root'
                )
    return findings


def main() -> int:
    all_findings: list[str] = []
    for target in TARGETS:
        path = REPO_ROOT / target
        if not path.exists():
            print(f"check_action_expressions: MISSING target {target}", file=sys.stderr)
            return 1
        all_findings.extend(check(path))
        all_findings.extend(check_env_bindings(path))
        all_findings.extend(check_no_pull_request_target(path))

    # The pull_request_target prohibition is repo-wide, not surface-specific: the one-word change
    # that voids the threat model is just as fatal in a NEW workflow file as in these two, and a
    # guard scoped to two paths would never see it.
    workflows = sorted(
        # BOTH extensions: GitHub accepts .yaml equally, and a guard whose whole purpose is to be
        # un-bypassable must not be bypassable by choosing the other spelling.
        set((REPO_ROOT / ".github" / "workflows").glob("*.yml"))
        | set((REPO_ROOT / ".github" / "workflows").glob("*.yaml"))
    )
    for wf in workflows:
        all_findings.extend(check_no_pull_request_target(wf))

    # The generated Way A workflow is an Action surface too — it just doesn't exist as a tracked
    # file (install.sh renders it from a heredoc). A pull_request_target planted in that template
    # would ship to every NEW install while every scan above stayed green, exactly the gap the
    # deleted action/review.yml never had because it was tracked (Codex finding on the collapse
    # PR). So: render it for real — run install.sh against a scratch dir — and scan the OUTPUT,
    # not the heredoc source, so the guard survives any future refactor of how the template is
    # produced. Render failure is itself a finding: a guard that can't see its surface must not
    # report the surface clean.
    scratch = Path(tempfile.mkdtemp(prefix="way-a-render-"))
    try:
        render = subprocess.run(
            ["bash", str(REPO_ROOT / "install.sh"), str(scratch)],
            capture_output=True,
            text=True,
        )
        rendered_wf = scratch / ".github" / "workflows" / "review.yml"
        if render.returncode != 0 or not rendered_wf.is_file():
            all_findings.append(
                "install.sh render for the generated-workflow scan failed "
                f"(exit {render.returncode}, {rendered_wf} exists={rendered_wf.is_file()}) — "
                "the Way A surface could not be checked, which is a failure, not a pass. stderr: "
                + render.stderr.strip()[-300:]
            )
        else:
            all_findings.extend(check_no_pull_request_target(rendered_wf))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    if all_findings:
        print("Action-expression guard FAILED:\n", file=sys.stderr)
        for f in all_findings:
            print(f"  {f}\n", file=sys.stderr)
        return 1

    print(f"check_action_expressions: clean ({', '.join(TARGETS)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
