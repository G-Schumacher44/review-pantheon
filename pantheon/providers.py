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
this port's own PR, then extended twice more by a follow-up Codex review wave on the fix
itself).** An earlier version of this module resolved each provider CLI via ``shutil.which``
(the ambient PATH, unfiltered) and called ``subprocess.run`` with no explicit ``env=`` at all —
the identical vulnerability class ``pantheon.cli``'s own git/gh calls were found to have and
fixed (see that module's docstring): a hostile PR checkout that widens PATH to include a
repository-controlled directory (e.g. a tracked ``bin/`` a maintainer's shell rc or a
locally-sourced ``.envrc`` picks up before running the gate) could get an attacker-planted
``claude``/``codex``/``gemini``/``cursor-agent`` executed instead of the real CLI — arguably
higher-value here than the git/gh vector, since under the ``trusted`` execution tier this is the
process that goes on to get full Bash. Closed in three rounds, each fixing a real gap the
previous round's fresh evidence exposed:

  1. :func:`_filtered_path` filters the AMBIENT PATH structurally — dropping any entry that is
     relative, or that resolves inside a TRUSTED ROOT (see below) — rather than replacing it
     with a hardcoded directory list (unlike ``git``/``gh``, near-universally installed via a
     system package manager, a provider CLI is installed through many different mechanisms — npm
     global, pipx, Homebrew, cargo, a user's own ``$HOME/.local/bin`` — with no single fixed set
     of paths to allowlist instead).
  2. Round 1 only excluded ``os.getcwd()`` — a Codex finding caught that this misses a
     repository-controlled PATH entry when the gate is launched from a NESTED directory inside
     the repo (e.g. ``/repo/src``, with a hostile ``/repo/bin`` on PATH: not beneath
     ``os.getcwd()``, so round 1's filter let it through). Every entry point into this module now
     accepts a ``repo_root`` parameter (``pantheon.cli`` passes its own resolved
     ``git rev-parse --show-toplevel`` result) and :func:`_filtered_path` excludes BOTH the cwd
     and the repo root, so a repo-controlled PATH entry is caught regardless of which directory
     inside the repo the gate happened to be launched from.
  3. :func:`_provider_env` originally began from a full ``dict(os.environ)`` copy (only PATH
     overridden) — contrary to docs/PYTHON-PORT.md §5's clean-environment requirement, and a
     Codex finding demonstrated the concrete exploit: an execution-bearing variable an attacker
     can set ahead of the launcher process (``NODE_OPTIONS=--require=/repo/payload.js``,
     ``PYTHONPATH``, ``LD_PRELOAD``, ...) would still reach a matching provider CLI even with
     PATH filtered and ``shell=False``, since PATH-filtering only stops WHICH BINARY runs, not
     what environment-driven code injection that binary's own runtime then loads. Fixed the same
     way ``pantheon.cli``'s git/gh calls already are: :data:`_PROVIDER_ENV_PASSTHROUGH_KEYS` is
     an explicit ALLOWLIST (locale/HOME/XDG dirs plus each lane's own documented or
     conventionally-used auth surface), never a blanket copy — a provider CLI's own runtime still
     needs SOME broad-ish auth/config surface (unlike git/gh's narrower allowlist), so this list
     is more generous than ``pantheon.cli``'s, but it is still an explicit, reviewable list, not
     "everything the launcher process happened to have set."

Every subprocess call in this module resolves the CLI from :func:`_filtered_path` and receives
the explicitly constructed environment from :func:`_provider_env` — never an implicit
``os.environ`` inherit, matching what this module's own docstring already discloses about not
being ``pantheon.execution``'s threat model (that module's fully bare-bones, git/gh-specific
env is not reused here; this is a deliberately narrower, provider-shaped clean-environment
construction).

**Process-group timeout termination (a fourth Codex-wave finding).** ``subprocess.run(...,
timeout=...)`` only terminates the DIRECT child process on a timeout — a provider CLI that itself
spawns tool subprocesses (exactly what an LLM-driving CLI's own tool-execution loop does) can
leave those descendants running past the timeout, still able to consume resources or touch the
checkout. Mirrors ``cli/review-gate``'s own ``run_with_timeout`` fallback (TERM the whole process
group, wait briefly, KILL if still alive): :func:`_run` starts each provider in its own session
(``start_new_session=True``, POSIX — creates a new process group too) so :func:`_terminate_group`
can signal the WHOLE group, not just the one PID ``subprocess.run`` would have reached.

Fixture suites: none today — docs/PYTHON-PORT.md §9 notes this as a pre-existing coverage gap
(no ``test-providers.sh`` exists for the bash lanes either), not one this port introduces or is
obligated to close. ``pantheon.cli``'s own black-box exams exercise the ``claude`` lane's argv
construction indirectly via ``--dry-run`` (which never calls a provider) and via the
``PANTHEON_CLI``-parameterized suites where a real ``claude`` CLI happens to be resolvable.

**Neutral launch cwd, never the PR checkout — the worst finding from an adversarial review
(CRITICAL-1), closed with three layered fixes.** PATH-filtering, the env allowlist, and the
process-group timeout above all assume the vulnerability enters through the SUBPROCESS'S OWN
ARGV/ENV — but a provider CLI's OWN STARTUP auto-discovers repo-local configuration from its
CURRENT WORKING DIRECTORY, entirely BEFORE any tool call and entirely OUTSIDE
``--allowedTools``'s reach: a PR-committed ``.mcp.json`` (Claude Code auto-loads and SPAWNS every
listed MCP server — arbitrary command execution, not a tool call this repo's own readonly-tier
scoping ever sees), a PR-committed ``.claude/settings.json`` (hooks that fire on tool events —
including on an ALLOWED ``Read``), or ``CLAUDE.md``/similar project-memory files (prompt content
a PR fully controls, injected before this repo's own persona framing ever runs). Every one of
these was reachable purely because this module launched the provider with ``cwd=repo_root`` — the
PR's own checkout — live-reproduced by the reviewer with a fake ``claude`` binary that printed
which MCP servers it would have spawned and confirmed a PR-committed hook would have fired on an
allowed ``Read`` tool call. Fixed with defense in depth, all three layers, none alone sufficient:

  1. **Neutral cwd.** Every provider now launches with ``cwd=neutral_cwd`` — a scratch directory
     ``pantheon.cli`` creates and owns (never the repo checkout, never anywhere inside it) —
     instead of ``cwd=repo_root``. A provider CLI's own startup-time config/MCP/hooks discovery
     scans ITS OWN cwd (and, for some tools, ancestor directories of it); a neutral, repo-free
     directory has nothing there to discover. The agent still reaches repo CONTENT exclusively
     through the readonly git wrapper (now told the real repo root via an explicit
     ``--repo-root`` flag baked into its own fixed Bash-tool prefix — see
     ``pantheon.cli._wrapper_invocation``'s own docstring) and explicit ``Read``/``Grep``/``Glob``
     calls against the repo root's own now-advertised absolute path (see
     ``pantheon.cli._build_prompt``) — exactly the design's stated intent (the wrapper is the
     ONLY sanctioned path back to the tree under ``readonly``), now actually true for the
     provider's OWN startup-time behavior too, not just its later tool calls.
  2. **``--bare`` on the claude lane (the only lane with a real, documented flag for this — see
     :func:`_claude`'s own docstring).** Verified against Claude Code's current official headless
     docs (code.claude.com/docs/en/headless): ``--bare`` "reduce[s] startup time by skipping
     auto-discovery of hooks, skills, plugins, MCP servers, auto memory, and CLAUDE.md" — the
     exact five vectors this finding named, in ONE documented flag, layered on top of (never
     instead of) the neutral-cwd fix above (belt-and-braces: even if a future code path
     regressed the cwd back toward the checkout, ``--bare`` still refuses local discovery).
     ``codex``/``gemini``/``cursor-agent`` have **no equivalent documented flag** as of this
     writing (researched against each CLI's current official docs before writing this — not
     assumed): this is a disclosed, honest residual exposure for those three best-effort lanes,
     not silently treated as closed — see DESIGN.md's "Security posture" for the same disclosure
     in the repo's own binding spec.
  3. **``_PROVIDER_ENV_PASSTHROUGH_KEYS`` re-audited.** Every key on that list already carried a
     specific, documented reason before this fix (see that data's own comment) — re-reviewed here
     specifically for "does this key exist ONLY because it's convenient, or because a named lane's
     documented auth/locale surface genuinely needs it": every key survived that re-read (each is
     tied to a specific lane's documented env-var auth mechanism, a POSIX locale/temp-dir
     convention every CLI here needs to run at all, or the proxy-transport fix a prior Codex wave
     already justified) — no key was removed, because none was found that exists WITHOUT a
     specific need, and removing a genuinely-needed auth key would just break that lane's real
     credential flow without closing anything (an execution-bearing variable like
     ``NODE_OPTIONS``/``LD_PRELOAD`` was never on this allowlist in the first place — that closure
     already existed, per round 3 above).
"""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import sys

from pantheon import execution

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
# not open) when invoked directly, outside pantheon.cli.
#
# Resolves the INSTALLED `pantheon-git-readonly` console script's own absolute path (see
# pyproject.toml's [project.scripts] entry) — mirrors pantheon.cli's own `_wrapper_invocation()`
# exactly; see that function's docstring for the full three-round rationale (round 1: `python -m
# pantheon.execution wrapper` is shadowable by a hostile checkout's own same-named file, because
# a provider now runs with the checkout as its cwd and `-m` prepends cwd to sys.path; round 2:
# `-I` closed that but broke `pip install --user`; round 3, this fix: a console script's own
# `sys.path[0]` is its OWN install directory, never the caller's cwd, closing the shadow with no
# `-I`-style collateral restriction).
_WRAPPER_SCRIPT_NAME = "pantheon-git-readonly"


def default_allowed_tools(repo_root: str | None = None) -> str:
    """The readonly-tier fallback ``--allowedTools`` value (see this module's own docstring for
    why this exists) — resolves :data:`_WRAPPER_SCRIPT_NAME`'s absolute path via
    ``pantheon.execution.resolve_console_script`` (checks both a venv's/system install's own
    scripts directory AND ``pip install --user``'s separate per-user one — never an ambient
    ``PATH`` lookup), falling back to the OLDER, unprotected ``python -m pantheon.execution
    wrapper`` form only when the console script genuinely isn't installed anywhere that function
    checks (a plain dev checkout — docs/PYTHON-PORT.md's own disclosed package-layout caveat for
    this slice), with a loud stderr warning every time that fallback fires.

    ``repo_root``, when given, is baked into the returned string as a fixed ``--repo-root``
    literal — a CRITICAL fix (adversarial review), mirroring ``pantheon.cli``'s own
    ``_wrapper_invocation()`` exactly (see that function's own docstring for the full rationale:
    providers no longer launch with the repo checkout as their own cwd, so the wrapper needs the
    real repo root told to it explicitly). Optional (default ``None``, omitting the flag
    entirely) so this function's existing zero-argument call shape keeps working for genuinely
    standalone use (this module's own ``python -m pantheon.providers run ...`` CLI, invoked with
    no ``repo-root`` positional) — the one case where no repo root is actually known yet."""
    candidate = execution.resolve_console_script(_WRAPPER_SCRIPT_NAME)
    repo_root_suffix = f" --repo-root {repo_root}" if repo_root else ""
    if candidate is not None:
        return f"Read,Grep,Glob,Bash({candidate} wrapper{repo_root_suffix} *)"
    print(
        f"pantheon: warning: the '{_WRAPPER_SCRIPT_NAME}' console script is not installed "
        "(checked alongside sys.executable and the per-user scripts directory) — falling back "
        "to 'python -m pantheon.execution wrapper', which does NOT close the "
        "checkout-directory-shadowing vector a real `pip install`/`pip install -e .` of this "
        "package closes. Run one of those to get the hardened path.",
        file=sys.stderr,
    )
    fallback_cmd = f"{sys.executable} -m pantheon.execution wrapper{repo_root_suffix}"
    return f"Read,Grep,Glob,Bash({fallback_cmd} *)"


def _read_prompt(prompt_file: str) -> str:
    with open(prompt_file, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# Explicit allowlist for _provider_env() — see this module's own docstring, round 3, for why a
# blanket `dict(os.environ)` copy was wrong (an execution-bearing variable an attacker can set
# ahead of the launcher process — NODE_OPTIONS, PYTHONPATH, LD_PRELOAD, ... — would still reach a
# matching provider CLI's own runtime even with PATH filtered and shell=False). More generous
# than pantheon.cli's own git/gh allowlist, deliberately: a provider CLI's own runtime genuinely
# needs a broader auth/config/locale surface than git/gh do, and only ``claude`` is
# integration-tested — codex/gemini/cursor's env-var surfaces are best-effort, same disclosed gap
# this module's own docstring already carries for their argv construction. Extend this list
# explicitly when a real, documented need shows up; never fall back to a blanket copy to "just
# make something work."
_PROVIDER_ENV_PASSTHROUGH_KEYS: tuple[str, ...] = (
    # Process/locale basics every one of these CLIs needs to run and print sane output.
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "TMPDIR",
    "TZ",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    # Claude Code CLI — the only integration-tested lane. Auth surface documented in
    # docs/SETUP.md's "Post-install checklist"/Way C auth table: CLAUDE_CODE_OAUTH_TOKEN or
    # ANTHROPIC_API_KEY (exactly one). CLAUDE_CONFIG_DIR is the CLI's own conventional config-dir
    # override. The Bedrock/Vertex vars are disclosed in docs/SETUP.md as "supported by
    # anthropics/claude-code-action itself... NOT wired through THIS repo's composite action" —
    # that disclosure is about the Action's `with:` inputs, not this CLI lane; a locally
    # configured `claude` CLI using them still needs them forwarded to behave the same way it
    # would run outside this gate.
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CONFIG_DIR",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_REGION",
    "AWS_DEFAULT_REGION",
    "AWS_PROFILE",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_PROJECT",
    "CLOUD_ML_REGION",
    # codex/gemini/cursor — best-effort lanes, no dedicated auth-surface doc in this repo; these
    # are each CLI's own conventional API-key env var name.
    "OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "CURSOR_API_KEY",
    # Proxy transport vars -- a Codex review finding on this port's own PR: `pantheon.cli`'s own
    # git/gh env already forwards these (dropping them broke `git fetch`/`gh pr view` behind a
    # corporate HTTP(S) proxy); every networked PROVIDER invocation needs the identical fix, or
    # a proxy-gated network still lets metadata/fetch through while every agent's own API call
    # fails and reads UNVERIFIED. Both cases forwarded (see `pantheon.cli`'s own comment on this
    # same allowlist for why).
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "all_proxy",
)

# Force-cleared in every constructed env this module builds (never merely omitted) — a Codex
# review finding on this port's own PR, companion to `pantheon.execution.resolve_console_script`'s
# own fix: `PYTHONUSERBASE` (among this whole family) is exactly the env var that let a hostile
# launcher redirect console-script resolution at a checked-out PR's own tree. This dict is
# already constructed fresh (never an `os.environ` copy), so these keys would already be ABSENT
# rather than forwarded to a provider CLI -- explicitly clearing them here means that guarantee
# doesn't rely on every future maintainer remembering to keep them off the allowlist, and closes
# the door for any Python process a provider CLI's own children might spawn too.
_PROVIDER_PYTHON_ENV_DEFENSIVE_CLEAR: dict[str, str] = {
    "PYTHONUSERBASE": "",
    "PYTHONPATH": "",
    "PYTHONHOME": "",
    "PYTHONSTARTUP": "",
    "PYTHONNOUSERSITE": "1",
}


def _filtered_path(repo_root: str | None = None) -> str:
    """The ambient ``PATH``, with any entry that is relative, or that resolves inside a TRUSTED
    ROOT, removed — see this module's own docstring for the vulnerability this closes (a hostile
    PR checkout widening PATH to include a repository-controlled directory) and for why this
    excludes BOTH the current working directory AND ``repo_root`` (round 2's fix: excluding only
    ``os.getcwd()`` misses a repo-controlled PATH entry when the gate is launched from a nested
    directory inside the repo, e.g. ``/repo/src`` with a hostile ``/repo/bin`` on PATH — not
    beneath ``os.getcwd()``, so it survived round 1's filter). ``repo_root`` is optional (this
    module's own standalone CLI, or a caller that hasn't resolved a repo root yet, gets cwd-only
    filtering — still strictly better than no filtering at all). A relative entry is dropped
    outright (its meaning depends on the process's own cwd, which is exactly the
    untrusted-checkout ambiguity this exists to avoid); an absolute entry is dropped only when it
    resolves (``os.path.realpath``, following symlinks) to one of the trusted roots themselves or
    somewhere underneath one. Every OTHER absolute PATH entry — a system directory, a user's own
    tool-install directory, anything not inside a trusted root — is preserved unchanged, since
    provider CLIs are installed through too many different mechanisms for a fixed directory
    allowlist (contrast ``pantheon.cli``'s/``pantheon.execution``'s ``TRUSTED_GIT_DIRS``,
    appropriate for git/gh specifically) to be practical here."""
    roots = [os.path.realpath(os.getcwd())]
    if repo_root:
        real_repo_root = os.path.realpath(repo_root)
        if real_repo_root not in roots:
            roots.append(real_repo_root)

    kept: list[str] = []
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry or not os.path.isabs(entry):
            continue
        real_entry = os.path.realpath(entry)
        if any(real_entry == root or real_entry.startswith(root + os.sep) for root in roots):
            continue
        kept.append(entry)
    return os.pathsep.join(kept)


def _provider_env(repo_root: str | None = None) -> dict[str, str]:
    """Explicitly constructed subprocess environment for every provider-CLI call — never an
    implicit ``os.environ`` passthrough, and never a blanket ``dict(os.environ)`` copy either
    (docs/PYTHON-PORT.md §5's "constructed clean env, never inherited" rule — see this module's
    own docstring, round 3, for the concrete exploit a blanket copy left open). ``PATH`` is the
    filtered value from :func:`_filtered_path` (``repo_root``-aware); every other key is copied
    one at a time from the explicit :data:`_PROVIDER_ENV_PASSTHROUGH_KEYS` allowlist, never in
    bulk."""
    env: dict[str, str] = {"PATH": _filtered_path(repo_root)}
    for key in _PROVIDER_ENV_PASSTHROUGH_KEYS:
        value = os.environ.get(key)
        if value is not None:
            env[key] = value
    env.update(_PROVIDER_PYTHON_ENV_DEFENSIVE_CLEAR)
    return env


def _resolve_cli(name: str, repo_root: str | None = None) -> str | None:
    """Resolves ``name`` from :func:`_filtered_path` (``repo_root``-aware) — the checkout-filtered
    PATH, never the raw ambient one. Returns ``None`` (never raises) when not found, so each
    lane's own "CLI not found" :class:`ProviderError` message stays specific to that lane."""
    for entry in _filtered_path(repo_root).split(os.pathsep):
        if not entry:
            continue
        candidate = os.path.join(entry, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _terminate_group(proc: subprocess.Popen) -> None:
    """TERM the whole process GROUP first (graceful), then unconditionally KILL the whole group
    too, after a short grace period — mirrors ``cli/review-gate``'s own ``run_with_timeout``
    fallback (TERM, wait ~5s, KILL) so a provider CLI's own spawned tool subprocesses are
    cleaned up too, not just the single direct child a bare ``proc.kill()`` would reach.
    Requires the process to have been started with ``start_new_session=True`` (see
    :func:`_run`), which makes its PID its own process group leader's PID too.

    The follow-up ``killpg(..., SIGKILL)`` fires REGARDLESS of whether ``proc.wait()`` (the
    LEADER's own exit) already succeeded within the grace period — a Codex review finding on
    this port's own PR, reproduced live: a provider whose LEADER exits promptly on SIGTERM but
    whose own spawned CHILD ignores or delays SIGTERM leaves that child alive, because
    ``proc.wait()`` only waits for the leader, not the whole group — an earlier version of this
    function only escalated to SIGKILL inside the ``except TimeoutExpired`` branch, so a leader
    that exited "on time" (even though a descendant it spawned did not) skipped the SIGKILL step
    entirely. A process group's ID stays valid as long as ANY member is still alive (the group
    is keyed to the leader's original PID even after the leader itself exits) — so sending
    SIGKILL to the group unconditionally, after the grace period, catches that remaining
    descendant every time; ``killpg`` on an already-fully-dead group is a harmless no-op
    (``ProcessLookupError``, suppressed below, same as every other signal in this function).
    Every signal here is best-effort: a process that already exited between our check and our
    signal is not an error (mirrors bash's own ``2>/dev/null || true`` posture for the identical
    race).

    Deliberately never calls ``os.getpgid(proc.pid)`` to look the group up -- a Codex review
    finding on this port's own PR, reproduced live: once the LEADER has exited and been reaped
    (which can happen before this function ever runs -- ``communicate(timeout=...)`` can still
    raise ``TimeoutExpired`` while blocked on a descendant that inherited the leader's stdout,
    well after the leader itself is gone), ``os.getpgid(proc.pid)`` raises
    ``ProcessLookupError`` even though the process GROUP (keyed to that same numeric ID) still
    has live members -- an earlier version of this function treated that lookup failure as "the
    whole group is gone" and returned immediately, leaving the surviving descendant unsignaled
    entirely. ``start_new_session=True`` (see :func:`_run`) makes the process group's ID equal
    to the leader's PID at spawn time, by construction -- a fixed fact that querying the (now
    possibly-reaped) leader can only fail to confirm, never actually needs re-deriving. Using
    ``proc.pid`` directly as the target ``killpg`` ID reaches every surviving group member
    regardless of whether the leader itself is still queryable."""
    pgid = proc.pid
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pgid, signal.SIGTERM)
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=5)
    with contextlib.suppress(ProcessLookupError, PermissionError):
        os.killpg(pgid, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=5)


def _run(
    argv: list[str],
    *,
    input_text: str | None = None,
    timeout: float | None = None,
    cwd: str | None = None,
    repo_root: str | None = None,
) -> str:
    """Runs ``argv`` (``argv[0]`` already resolved via :func:`_resolve_cli`, never a bare command
    name left for the child's own shell/exec lookup to re-resolve) with the explicitly
    constructed environment from :func:`_provider_env` — see this module's own docstring for why.
    ``cwd`` is a NEUTRAL scratch directory (``pantheon.cli``'s own, never the repo checkout —
    a CRITICAL fix, adversarial review: launching a provider with the repo checkout as its own
    cwd let its startup-time config/MCP/hooks auto-discovery reach PR-controlled content entirely
    outside ``--allowedTools``'s reach — see this module's own docstring for the full finding and
    fix). Started with ``start_new_session=True`` (POSIX) so :func:`_terminate_group` can reach the
    WHOLE process group on a timeout, not just this one PID (see this module's own docstring).
    Merges stdout+stderr into one text stream — mirrors bash's own
    ``raw_output="$(run_with_timeout ... provider_run "$MODEL" "$prompt_file" 2>&1)"`` capture in
    ``cli/review-gate``'s ``run_agent()``. Raises :class:`ProviderError` on a nonzero exit, a
    timeout, or a failure to even start the process (the executable vanishing between
    :func:`_resolve_cli` and this call, say) — never lets a raw
    ``subprocess.CalledProcessError``/``OSError`` escape to a caller that only knows this module's
    own exception type.

    Deliberately BINARY-mode (no ``text=True``/``encoding=``), not strict-UTF-8 text mode — a
    Codex review finding on this port's own PR: a provider CLI, or any tool subprocess IT spawns,
    can legitimately emit a non-UTF-8 byte (a binary tool's stray stderr output, a subtly
    mis-encoded terminal escape, ...), and strict text-mode decoding raises an uncaught
    ``UnicodeDecodeError`` from inside ``communicate()`` that neither this function nor its
    callers (``_run_agent()``/``main()``, both of which only know :class:`ProviderError`/
    :class:`GateError`) catch — the whole gate would exit with a bare traceback instead of the
    documented UNVERIFIED fail-closed result. Captured as raw bytes and decoded defensively
    (``errors="replace"``) instead, mirroring this port's own established pattern for exactly
    this class of input (``pantheon.verdict.main()``'s ``open(raw_file, errors="replace")``) —
    closed by construction (Python's strict decoder never runs on this path at all), not by
    adding one more ``except UnicodeDecodeError`` to the pile."""
    stdin_bytes = input_text.encode("utf-8", errors="replace") if input_text is not None else None

    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE if input_text is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=_provider_env(repo_root),
            cwd=cwd,
            shell=False,
            start_new_session=True,
        )
    except OSError as e:
        raise ProviderError(f"failed to execute {argv[0]}: {e}") from e

    try:
        stdout_bytes, _ = proc.communicate(input=stdin_bytes, timeout=timeout)
    except subprocess.TimeoutExpired:
        _terminate_group(proc)
        try:
            leftover_bytes, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            leftover_bytes = b""
        leftover = (leftover_bytes or b"").decode("utf-8", errors="replace")
        raise ProviderError(f"{argv[0]} timed out after {timeout}s", output=leftover) from None

    stdout = (stdout_bytes or b"").decode("utf-8", errors="replace")
    if proc.returncode != 0:
        raise ProviderError(f"{argv[0]} exited {proc.returncode}", output=stdout)
    return stdout


def _claude(
    model: str,
    prompt_file: str,
    allowed_tools: str,
    timeout: float | None,
    repo_root: str | None,
    neutral_cwd: str | None,
) -> str:
    """Provider lane: Claude Code CLI. Default lane — the only one integration-tested (mirrors
    cli/providers/claude.sh). ``--permission-mode dontAsk`` (not "default"): Claude Code's own
    docs describe ``default`` mode as auto-approving reads only — everything else, including a
    tool call that DOES match ``--allowedTools``, still goes through a permission decision nothing
    can answer non-interactively outside a terminal; ``dontAsk`` is documented as the mode "for
    CI pipelines and scripts", auto-denying anything not pre-approved rather than hanging.

    ``--bare`` — a CRITICAL fix (adversarial review), verified against Claude Code's current
    official headless-mode docs (code.claude.com/docs/en/headless) before adding, not assumed:
    documented to "reduce startup time by skipping auto-discovery of hooks, skills, plugins, MCP
    servers, auto memory, and CLAUDE.md" — closing, in one flag, every one of the config-discovery
    vectors this module's own docstring names, layered on top of (never instead of) launching from
    a neutral ``cwd`` (see :func:`_run`'s own docstring). The same doc discloses that bare mode
    skips OAuth/system-keychain login (only sees credentials passed explicitly) — a non-issue
    here, since :data:`_PROVIDER_ENV_PASSTHROUGH_KEYS` already forwards ``ANTHROPIC_API_KEY``/
    ``CLAUDE_CODE_OAUTH_TOKEN`` as explicit env vars, exactly the credential-passing shape bare
    mode is documented to still honor."""
    claude_bin = _resolve_cli("claude", repo_root)
    if claude_bin is None:
        raise ProviderError("'claude' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    tools = allowed_tools or default_allowed_tools(repo_root)
    argv = [claude_bin, "--bare", "-p", prompt, "--allowedTools", tools, "--permission-mode", "dontAsk"]
    if model:
        argv += ["--model", model]
    return _run(argv, timeout=timeout, cwd=neutral_cwd, repo_root=repo_root)


def _codex(
    model: str,
    prompt_file: str,
    allowed_tools: str,
    timeout: float | None,
    repo_root: str | None,
    neutral_cwd: str | None,
) -> str:
    """Provider lane: Codex CLI. Best-effort — mirrors cli/providers/codex.sh's ``codex exec -``
    invocation, prompt piped via stdin. No documented flag equivalent to the claude lane's
    ``--bare`` exists for this CLI as of this writing (researched against Codex's own official
    docs before landing this fix, not assumed) — this lane's own repo-local config/AGENTS.md
    auto-discovery is a disclosed, honest residual exposure the neutral ``cwd`` below narrows
    (nothing repo-local for it to discover in a scratch directory) but doesn't eliminate the way
    an explicit flag would; see this module's own docstring and DESIGN.md's "Security posture"."""
    codex_bin = _resolve_cli("codex", repo_root)
    if codex_bin is None:
        raise ProviderError("'codex' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = [codex_bin, "exec"]
    if model:
        argv += ["--model", model]
    argv.append("-")
    return _run(argv, input_text=prompt, timeout=timeout, cwd=neutral_cwd, repo_root=repo_root)


def _gemini(
    model: str,
    prompt_file: str,
    allowed_tools: str,
    timeout: float | None,
    repo_root: str | None,
    neutral_cwd: str | None,
) -> str:
    """Provider lane: Gemini CLI. Best-effort — mirrors cli/providers/gemini.sh's ``gemini -p
    <prompt> [-m <model>]`` invocation. No documented flag equivalent to the claude lane's
    ``--bare`` exists for this CLI as of this writing (researched against Gemini CLI's own
    official docs before landing this fix, not assumed) — same disclosed residual exposure as the
    codex lane above, narrowed but not eliminated by the neutral ``cwd`` below."""
    gemini_bin = _resolve_cli("gemini", repo_root)
    if gemini_bin is None:
        raise ProviderError("'gemini' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = [gemini_bin, "-p", prompt]
    if model:
        argv += ["-m", model]
    return _run(argv, timeout=timeout, cwd=neutral_cwd, repo_root=repo_root)


def _cursor(
    model: str,
    prompt_file: str,
    allowed_tools: str,
    timeout: float | None,
    repo_root: str | None,
    neutral_cwd: str | None,
) -> str:
    """Provider lane: Cursor CLI (``cursor-agent``). Best-effort — mirrors
    cli/providers/cursor.sh's ``cursor-agent -p <prompt> [--model <model>]`` invocation. No
    documented flag equivalent to the claude lane's ``--bare`` exists for this CLI as of this
    writing (its own official docs state it "honours the same `.cursor/rules/`, MCP servers... as
    the desktop editor" with no disclosed opt-out — researched before landing this fix, not
    assumed) — same disclosed residual exposure as the codex/gemini lanes above, narrowed but not
    eliminated by the neutral ``cwd`` below."""
    cursor_bin = _resolve_cli("cursor-agent", repo_root)
    if cursor_bin is None:
        raise ProviderError("'cursor-agent' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = [cursor_bin, "-p", prompt]
    if model:
        argv += ["--model", model]
    return _run(argv, timeout=timeout, cwd=neutral_cwd, repo_root=repo_root)


_DISPATCH = {"claude": _claude, "codex": _codex, "gemini": _gemini, "cursor": _cursor}


def provider_run(
    provider: str,
    model: str,
    prompt_file: str,
    allowed_tools: str = "",
    timeout: float | None = None,
    repo_root: str | None = None,
    neutral_cwd: str | None = None,
) -> str:
    """Dispatches to the named provider lane and returns its raw stdout (merged with stderr, see
    :func:`_run`). ``provider`` must be one of :data:`KNOWN_PROVIDERS` — an unrecognized name is
    the CALLER's validation responsibility (``pantheon.cli``, mirroring ``cli/review-gate``'s own
    ``[[ -f "$PROVIDERS_DIR/$PROVIDER.sh" ]]`` check before ever calling this — same order as
    bash: validated once, fast, before any network call). ``allowed_tools`` is consumed only by
    the ``claude`` lane (readonly-tier tool scoping — see :func:`_claude`); the other three ignore
    it, matching docs/CLI.md's disclosed "no readonly-tier tool restriction at all" gap for those
    lanes. ``repo_root``, when given (``pantheon.cli`` always passes its own resolved repo root),
    is used as an additional trusted root excluded from PATH resolution (see
    :func:`_filtered_path`) and threaded to the readonly-wrapper resolution helpers.

    ``neutral_cwd``, when given (``pantheon.cli`` always passes a scratch directory it created
    and owns), is the launched provider's own ``cwd`` — a CRITICAL fix (adversarial review): this
    used to be ``repo_root`` (mirroring ``cli/review-gate``'s own ``cd "$REPO_ROOT"`` posture),
    which let a provider's own startup-time config/MCP/hooks auto-discovery reach the PR's own
    checkout before any tool call ever ran — see this module's own docstring for the full finding
    and fix. Left ``None`` (the default), a caller gets the OLD behavior of inheriting this
    process's own cwd unmodified — acceptable for genuinely standalone, operator-invoked use
    (this module's own ``python -m pantheon.providers run ...`` CLI below, run at the operator's
    own discretion, not as part of reviewing untrusted PR content) but never how
    ``pantheon.cli``'s own gate run invokes this function."""
    fn = _DISPATCH.get(provider)
    if fn is None:
        raise ProviderError(f"unknown provider lane '{provider}' (known: {', '.join(KNOWN_PROVIDERS)})")
    return fn(model, prompt_file, allowed_tools, timeout, repo_root, neutral_cwd)


# ---------------------------------------------------------------------------------------------
# CLI — a thin black-box seam for ad hoc/manual verification (this module has no dedicated
# fixture suite, see this module's own docstring for why):
#   python -m pantheon.providers run <provider> <model> <prompt-file> [allowed-tools] [timeout] \
#       [repo-root] [neutral-cwd]
# Prints the raw output on success (exit 0); prints the ProviderError message to stderr and
# exits 1 on failure.
# ---------------------------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) < 4 or argv[0] != "run":
        print(
            "usage: python -m pantheon.providers run <provider> <model> <prompt-file> "
            "[allowed-tools] [timeout] [repo-root] [neutral-cwd]",
            file=sys.stderr,
        )
        return 2

    _, provider, model, prompt_file, *rest = argv
    allowed_tools = rest[0] if len(rest) > 0 else ""
    timeout = float(rest[1]) if len(rest) > 1 else None
    repo_root = rest[2] if len(rest) > 2 else None
    neutral_cwd = rest[3] if len(rest) > 3 else None

    try:
        output = provider_run(provider, model, prompt_file, allowed_tools, timeout, repo_root, neutral_cwd)
    except ProviderError as e:
        print(str(e), file=sys.stderr)
        if e.output:
            sys.stderr.write(e.output)
        return 1

    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
