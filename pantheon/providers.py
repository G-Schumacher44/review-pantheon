"""pantheon/providers.py — provider lane dispatch (docs/PYTHON-PORT.md section 6).

Replaces ``cli/providers/{claude,codex,gemini,cursor}.sh`` — one function per lane, dispatched by
:func:`provider_run`, matching the spec's contract: ``provider_run(model, prompt_file) -> str``,
"prints/returns the agent's raw output, raises/returns nonzero on failure." This module raises
:class:`ProviderError` for the "nonzero" half (Python's own idiom for that contract) — every
caller (``pantheon.cli``'s ``run_agent``) catches it exactly the way ``cli/review-gate`` checks
``$provider_status -ne 0``, landing on UNVERIFIED, never a crash.

**Claude is the only integration-tested lane, same as v1** — ``codex``/``gemini``/``cursor`` are
best-effort (docs/CLI.md's "Provider switch" section, DESIGN.md's "Provider lanes"): each asserts
its own CLI is on ``PATH`` and is unverified against your installed version, and none of the
three consume ``allowed_tools`` at all (no readonly-tier tool-scoping mechanism in their own CLIs
as of v1, same disclosed gap the bash lanes carry). Every lane's subprocess call inherits the
AMBIENT environment (``env=None`` — not a constructed clean one) — this is deliberately NOT
``pantheon.execution``'s threat model: a provider CLI needs its own ambient auth/config
(``ANTHROPIC_API_KEY``, ``HOME``, a Claude Code OAuth token, etc.) to run at all, and this port
changes nothing about what environment it inherits, mirroring the bash lanes' own plain
``claude "${args[@]}"``-style invocation (no explicit ``env`` construction there either).

Fixture suites: none today — docs/PYTHON-PORT.md §9 notes this as a pre-existing coverage gap
(no ``test-providers.sh`` exists for the bash lanes either), not one this port introduces or is
obligated to close. ``pantheon.cli``'s own black-box exams exercise the ``claude`` lane's argv
construction indirectly via ``--dry-run`` (which never calls a provider) and via the
``PANTHEON_CLI``-parameterized suites where a real ``claude`` CLI happens to be on ``PATH``.
"""

from __future__ import annotations

import shutil
import subprocess
import sys

__all__ = [
    "ProviderError",
    "KNOWN_PROVIDERS",
    "default_allowed_tools",
    "provider_run",
    "main",
]


class ProviderError(Exception):
    """Raised whenever a provider lane fails — its CLI not found on ``PATH``, a nonzero exit, or
    a timeout. Mirrors bash's ``provider_run ... ; provider_status=$?`` contract: a caller
    (``pantheon.cli``'s ``run_agent``) catches this uniformly and lands on UNVERIFIED, the same
    branch ``cli/review-gate`` takes on ``$provider_status -ne 0``. ``output`` carries whatever
    text the failed invocation actually produced (a "CLI not found" message, partial merged
    stdout+stderr) — the same text bash's own ``raw_output="$( ... 2>&1)"`` capture would still
    hold even on a nonzero exit, kept here purely for a caller that wants it for logging; never
    required for correct fail-closed behavior (a caller that ignores it still lands on
    UNVERIFIED)."""

    def __init__(self, message: str, output: str = "") -> None:
        super().__init__(message)
        self.output = output


# The fixed four lanes — mirrors cli/providers/'s directory contents exactly (docs/CLI.md's
# `--provider <lane>` table). In bash, "unknown provider" is checked by file existence
# (`[[ -f "$PROVIDERS_DIR/$PROVIDER.sh" ]]`) — issue #13, deliberately not fixed by this port (see
# docs/PYTHON-PORT.md section 2's own "this port does not silently fix or relitigate that issue"
# line). This tuple is the Python-shaped equivalent of that same coverage: an enumerated dispatch
# table with no file to `source`, so there is no separate "does this name resolve to a script"
# check to have a character-class gap in — the same four names, checked the same way (presence in
# a fixed list), nothing hardened or relaxed relative to what bash already validates.
KNOWN_PROVIDERS: tuple[str, ...] = ("claude", "codex", "gemini", "cursor")

# The fallback --allowedTools value this module computes when a caller doesn't supply one — the
# Python-shaped equivalent of cli/providers/claude.sh's own fallback (`cd .../cli/lib && pwd`
# relative to that script's own location), which exists so this lane still fails safe (readonly,
# not open) when invoked directly, outside pantheon.cli. There's no standalone wrapper *script*
# path to point at in this port (pantheon.execution.run_readonly_wrapper is a Python function, not
# a file on disk) — this fallback instead points at that module's own CLI entry point
# (`python -m pantheon.execution wrapper`), the same shape tests/test-git-readonly-wrapper.sh's
# python mode already uses as its WRAPPER_CMD.
_FALLBACK_WRAPPER_CMD = f"{sys.executable} -m pantheon.execution wrapper"


def default_allowed_tools() -> str:
    """The readonly-tier fallback ``--allowedTools`` value (see this module's own docstring for
    why this exists and what it points at)."""
    return f"Read,Grep,Glob,Bash({_FALLBACK_WRAPPER_CMD} *)"


def _read_prompt(prompt_file: str) -> str:
    with open(prompt_file) as fh:
        return fh.read()


def _run(
    argv: list[str],
    *,
    input_text: str | None = None,
    timeout: float | None = None,
) -> str:
    """Runs ``argv``, inheriting the ambient environment (see this module's own docstring for
    why). Merges stdout+stderr into one text stream — mirrors bash's own
    ``raw_output="$(run_with_timeout ... provider_run "$MODEL" "$prompt_file" 2>&1)"`` capture in
    ``cli/review-gate``'s ``run_agent()``. Raises :class:`ProviderError` on a nonzero exit, a
    timeout, or a failure to even start the process (the executable vanishing between the
    ``shutil.which`` presence check and this call, say) — never lets a raw
    ``subprocess.CalledProcessError``/``OSError`` escape to a caller that only knows this module's
    own exception type."""
    try:
        result = subprocess.run(
            argv,
            input=input_text,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as e:
        output = e.output if isinstance(e.output, str) else (e.output or b"").decode("utf-8", errors="replace")
        raise ProviderError(f"{argv[0]} timed out after {timeout}s", output=output) from e
    except OSError as e:
        raise ProviderError(f"failed to execute {argv[0]}: {e}") from e

    if result.returncode != 0:
        raise ProviderError(f"{argv[0]} exited {result.returncode}", output=result.stdout or "")
    return result.stdout or ""


def _claude(model: str, prompt_file: str, allowed_tools: str, timeout: float | None) -> str:
    """Provider lane: Claude Code CLI. Default lane — the only one integration-tested (mirrors
    cli/providers/claude.sh). ``--permission-mode dontAsk`` (not "default"): Claude Code's own
    docs describe ``default`` mode as auto-approving reads only — everything else, including a
    tool call that DOES match ``--allowedTools``, still goes through a permission decision nothing
    can answer non-interactively outside a terminal; ``dontAsk`` is documented as the mode "for
    CI pipelines and scripts", auto-denying anything not pre-approved rather than hanging."""
    if shutil.which("claude") is None:
        raise ProviderError("'claude' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    tools = allowed_tools or default_allowed_tools()
    argv = ["claude", "-p", prompt, "--allowedTools", tools, "--permission-mode", "dontAsk"]
    if model:
        argv += ["--model", model]
    return _run(argv, timeout=timeout)


def _codex(model: str, prompt_file: str, allowed_tools: str, timeout: float | None) -> str:
    """Provider lane: Codex CLI. Best-effort — mirrors cli/providers/codex.sh's ``codex exec -``
    invocation, prompt piped via stdin."""
    if shutil.which("codex") is None:
        raise ProviderError("'codex' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = ["codex", "exec"]
    if model:
        argv += ["--model", model]
    argv.append("-")
    return _run(argv, input_text=prompt, timeout=timeout)


def _gemini(model: str, prompt_file: str, allowed_tools: str, timeout: float | None) -> str:
    """Provider lane: Gemini CLI. Best-effort — mirrors cli/providers/gemini.sh's ``gemini -p
    <prompt> [-m <model>]`` invocation."""
    if shutil.which("gemini") is None:
        raise ProviderError("'gemini' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = ["gemini", "-p", prompt]
    if model:
        argv += ["-m", model]
    return _run(argv, timeout=timeout)


def _cursor(model: str, prompt_file: str, allowed_tools: str, timeout: float | None) -> str:
    """Provider lane: Cursor CLI (``cursor-agent``). Best-effort — mirrors
    cli/providers/cursor.sh's ``cursor-agent -p <prompt> [--model <model>]`` invocation."""
    if shutil.which("cursor-agent") is None:
        raise ProviderError("'cursor-agent' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = ["cursor-agent", "-p", prompt]
    if model:
        argv += ["--model", model]
    return _run(argv, timeout=timeout)


_DISPATCH = {"claude": _claude, "codex": _codex, "gemini": _gemini, "cursor": _cursor}


def provider_run(
    provider: str,
    model: str,
    prompt_file: str,
    allowed_tools: str = "",
    timeout: float | None = None,
) -> str:
    """Dispatches to the named provider lane and returns its raw stdout (merged with stderr, see
    :func:`_run`). ``provider`` must be one of :data:`KNOWN_PROVIDERS` — an unrecognized name is
    the CALLER's validation responsibility (``pantheon.cli``, mirroring ``cli/review-gate``'s own
    ``[[ -f "$PROVIDERS_DIR/$PROVIDER.sh" ]]`` check before ever calling this — same order as
    bash: validated once, fast, before any network call). ``allowed_tools`` is consumed only by
    the ``claude`` lane (readonly-tier tool scoping — see :func:`_claude`); the other three ignore
    it, matching docs/CLI.md's disclosed "no readonly-tier tool restriction at all" gap for those
    lanes."""
    fn = _DISPATCH.get(provider)
    if fn is None:
        raise ProviderError(f"unknown provider lane '{provider}' (known: {', '.join(KNOWN_PROVIDERS)})")
    return fn(model, prompt_file, allowed_tools, timeout)


# ---------------------------------------------------------------------------------------------
# CLI — a thin black-box seam for ad hoc/manual verification (this module has no dedicated
# fixture suite, see this module's own docstring for why):
#   python -m pantheon.providers run <provider> <model> <prompt-file> [allowed-tools] [timeout]
# Prints the raw output on success (exit 0); prints the ProviderError message to stderr and
# exits 1 on failure.
# ---------------------------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) < 4 or argv[0] != "run":
        print(
            "usage: python -m pantheon.providers run <provider> <model> <prompt-file> [allowed-tools] [timeout]",
            file=sys.stderr,
        )
        return 2

    _, provider, model, prompt_file, *rest = argv
    allowed_tools = rest[0] if len(rest) > 0 else ""
    timeout = float(rest[1]) if len(rest) > 1 else None

    try:
        output = provider_run(provider, model, prompt_file, allowed_tools, timeout)
    except ProviderError as e:
        print(str(e), file=sys.stderr)
        if e.output:
            sys.stderr.write(e.output)
        return 1

    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
