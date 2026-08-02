"""pantheon/providers.py — provider lane dispatch (docs/PYTHON-PORT.md section 6).

Replaces ``cli/providers/{claude,codex,gemini,cursor}.sh`` — one function per lane, dispatched by
:func:`provider_run`, matching the spec's contract: ``provider_run(model, prompt_file) -> str``,
"prints/returns the agent's raw output, raises/returns nonzero on failure." This module raises
:class:`ProviderError` for the "nonzero" half (Python's own idiom for that contract) — every
caller (``pantheon.cli``'s ``run_agent``) catches it exactly the way ``cli/review-gate`` checks
``$provider_status -ne 0``, landing on UNVERIFIED, never a crash.

**Claude is the only integration-tested lane, same as v1** — ``codex``/``gemini``/``cursor`` are
best-effort (docs/CLI.md's "Provider switch" section, DESIGN.md's "Provider lanes"): each asserts
its own CLI is resolvable and is unverified against your installed version, and none of the
three consume ``allowed_tools`` at all (no readonly-tier tool-scoping mechanism in their own CLIs
as of v1, same disclosed gap the bash lanes carry).

**PATH resolution and the subprocess environment (hardened — a live self-hosted-gate finding on
this port's own PR).** An earlier version of this module resolved each provider CLI via
``shutil.which`` (the ambient PATH, unfiltered) and called ``subprocess.run`` with no explicit
``env=`` at all — the identical vulnerability class ``pantheon.cli``'s own git/gh calls were
found to have and fixed (see that module's docstring): a hostile PR checkout that widens PATH to
include a repository-controlled directory (e.g. a tracked ``bin/`` a maintainer's shell rc or a
locally-sourced ``.envrc`` picks up before running the gate) could get an attacker-planted
``claude``/``codex``/``gemini``/``cursor-agent`` executed instead of the real CLI — arguably
higher-value here than the git/gh vector, since under the ``trusted`` execution tier this is the
process that goes on to get full Bash. Fixed the same way in spirit, adapted for this module's
different constraint: unlike ``git``/``gh`` (near-universally installed via a system package
manager, so a small fixed directory allowlist works), a provider CLI is installed through many
different mechanisms (npm global, pipx, Homebrew, cargo, a user's own ``$HOME/.local/bin``, ...)
with no single fixed set of paths to allowlist instead. :func:`_filtered_path` therefore filters
the AMBIENT PATH structurally — dropping any entry that is relative, or that resolves inside the
current working directory (the exact checkout-relative vector above) — rather than replacing it
with a hardcoded directory list; every subprocess call in this module resolves the CLI from that
filtered PATH and receives an EXPLICITLY CONSTRUCTED environment (:func:`_provider_env`) whose
own ``PATH`` key is the same filtered value, never an implicit ``os.environ`` inherit. Every
other ambient key still passes through (a provider CLI genuinely needs its own broad ambient
auth/config — ``ANTHROPIC_API_KEY``, ``HOME``, a Claude Code OAuth token, locale settings, and
more than this module could enumerate item-by-item the way ``pantheon.cli``'s git/gh allowlist
does) — this is a deliberate, narrower fix than ``pantheon.cli``'s (closes the PATH-resolution
vector specifically, not a full clean-room environment), matching what this module's own
docstring already discloses about not being ``pantheon.execution``'s threat model.

Fixture suites: none today — docs/PYTHON-PORT.md §9 notes this as a pre-existing coverage gap
(no ``test-providers.sh`` exists for the bash lanes either), not one this port introduces or is
obligated to close. ``pantheon.cli``'s own black-box exams exercise the ``claude`` lane's argv
construction indirectly via ``--dry-run`` (which never calls a provider) and via the
``PANTHEON_CLI``-parameterized suites where a real ``claude`` CLI happens to be resolvable.
"""

from __future__ import annotations

import os
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


def _filtered_path() -> str:
    """The ambient ``PATH``, with any entry that is relative, or that resolves inside the
    current working directory, removed — see this module's own docstring for the vulnerability
    this closes (a hostile PR checkout widening PATH to include a repository-controlled
    directory). A relative entry is dropped outright (its meaning depends on the process's own
    cwd, which is exactly the untrusted-checkout ambiguity this exists to avoid); an absolute
    entry is dropped only when it resolves (``os.path.realpath``, following symlinks) to the
    current working directory itself or somewhere underneath it. Every OTHER absolute PATH entry
    — a system directory, a user's own tool-install directory, anything not inside this
    checkout — is preserved unchanged, since provider CLIs are installed through too many
    different mechanisms for a fixed directory allowlist (contrast
    ``pantheon.cli``'s/``pantheon.execution``'s ``TRUSTED_GIT_DIRS``, appropriate for git/gh
    specifically) to be practical here."""
    cwd = os.path.realpath(os.getcwd())
    kept: list[str] = []
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry or not os.path.isabs(entry):
            continue
        real_entry = os.path.realpath(entry)
        if real_entry == cwd or real_entry.startswith(cwd + os.sep):
            continue
        kept.append(entry)
    return os.pathsep.join(kept)


def _provider_env() -> dict[str, str]:
    """Explicitly constructed subprocess environment for every provider-CLI call — never an
    implicit ``os.environ`` passthrough (docs/PYTHON-PORT.md §5's "constructed clean env, never
    inherited" rule, applied the way this module's own docstring explains: PATH is the filtered
    value from :func:`_filtered_path`, closing the checkout-relative-PATH vector; every other
    ambient key is still copied through, since a provider CLI's own auth/config surface is far
    broader than this module can enumerate item-by-item)."""
    env = dict(os.environ)
    env["PATH"] = _filtered_path()
    return env


def _resolve_cli(name: str) -> str | None:
    """Resolves ``name`` from :func:`_filtered_path` — the checkout-filtered PATH, never the raw
    ambient one. Returns ``None`` (never raises) when not found, so each lane's own "CLI not
    found" :class:`ProviderError` message stays specific to that lane."""
    for entry in _filtered_path().split(os.pathsep):
        if not entry:
            continue
        candidate = os.path.join(entry, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _run(
    argv: list[str],
    *,
    input_text: str | None = None,
    timeout: float | None = None,
) -> str:
    """Runs ``argv`` (``argv[0]`` already resolved via :func:`_resolve_cli`, never a bare command
    name left for the child's own shell/exec lookup to re-resolve) with the explicitly
    constructed environment from :func:`_provider_env` — see this module's own docstring for why.
    Merges stdout+stderr into one text stream — mirrors bash's own
    ``raw_output="$(run_with_timeout ... provider_run "$MODEL" "$prompt_file" 2>&1)"`` capture in
    ``cli/review-gate``'s ``run_agent()``. Raises :class:`ProviderError` on a nonzero exit, a
    timeout, or a failure to even start the process (the executable vanishing between
    :func:`_resolve_cli` and this call, say) — never lets a raw
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
            env=_provider_env(),
            shell=False,
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
    claude_bin = _resolve_cli("claude")
    if claude_bin is None:
        raise ProviderError("'claude' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    tools = allowed_tools or default_allowed_tools()
    argv = [claude_bin, "-p", prompt, "--allowedTools", tools, "--permission-mode", "dontAsk"]
    if model:
        argv += ["--model", model]
    return _run(argv, timeout=timeout)


def _codex(model: str, prompt_file: str, allowed_tools: str, timeout: float | None) -> str:
    """Provider lane: Codex CLI. Best-effort — mirrors cli/providers/codex.sh's ``codex exec -``
    invocation, prompt piped via stdin."""
    codex_bin = _resolve_cli("codex")
    if codex_bin is None:
        raise ProviderError("'codex' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = [codex_bin, "exec"]
    if model:
        argv += ["--model", model]
    argv.append("-")
    return _run(argv, input_text=prompt, timeout=timeout)


def _gemini(model: str, prompt_file: str, allowed_tools: str, timeout: float | None) -> str:
    """Provider lane: Gemini CLI. Best-effort — mirrors cli/providers/gemini.sh's ``gemini -p
    <prompt> [-m <model>]`` invocation."""
    gemini_bin = _resolve_cli("gemini")
    if gemini_bin is None:
        raise ProviderError("'gemini' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = [gemini_bin, "-p", prompt]
    if model:
        argv += ["-m", model]
    return _run(argv, timeout=timeout)


def _cursor(model: str, prompt_file: str, allowed_tools: str, timeout: float | None) -> str:
    """Provider lane: Cursor CLI (``cursor-agent``). Best-effort — mirrors
    cli/providers/cursor.sh's ``cursor-agent -p <prompt> [--model <model>]`` invocation."""
    cursor_bin = _resolve_cli("cursor-agent")
    if cursor_bin is None:
        raise ProviderError("'cursor-agent' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = [cursor_bin, "-p", prompt]
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
