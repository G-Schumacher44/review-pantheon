"""pantheon/providers.py — provider lane dispatch.

Replaces the retired bash CLI's per-lane provider scripts (``claude.sh``, ``codex.sh``,
``gemini.sh``, ``cursor.sh`` — removed in #29) — one function per lane, dispatched by
:func:`provider_run`, matching the dispatcher contract: ``provider_run(provider, model, prompt_file, ...) -> str``,
"prints/returns the agent's raw output, raises/returns nonzero on failure." This module raises
:class:`ProviderError` for the "nonzero" half (Python's own idiom for that contract) — every
caller (``pantheon.cli``'s ``run_agent``) catches it exactly the way the retired bash CLI's
``review-gate`` checked ``$provider_status -ne 0``, landing on UNVERIFIED, never a crash.

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
     overridden) — contrary to this module's own clean-environment requirement, and a
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
checkout. Mirrors the retired bash CLI's ``review-gate`` script's own ``run_with_timeout``
fallback (removed in #29; TERM the whole process group, wait briefly, KILL if still alive):
:func:`_run` starts each provider in its own session
(``start_new_session=True``, POSIX — creates a new process group too) so :func:`_terminate_group`
can signal the WHOLE group, not just the one PID ``subprocess.run`` would have reached.

Fixture suites: no dedicated black-box suite — a disclosed, pre-existing gap the retired bash
lanes shared too (no ``test-providers.sh`` existed for them either), not one this port
introduces. ``tests/test_providers.py`` is the pytest unit layer that covers this module
directly: argv construction, PATH resolution (:func:`_filtered_path`'s repo-root-aware
checkout-relative-entry filtering), environment construction (:func:`_provider_env`'s allowlist,
never a blanket ``os.environ`` copy), :class:`ProviderError`'s fail-closed behavior (CLI absent,
nonzero exit, timeout), and :func:`_terminate_group` firing on a timeout — every case
monkeypatches ``_resolve_cli``/``subprocess.Popen`` rather than shelling out to a real provider
CLI. ``pantheon.cli``'s own black-box exams additionally exercise the ``claude`` lane's argv
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
  2. **``--bare`` on the claude lane — DROPPED entirely (issue #26 item 3, a live re-gate
     finding on the same PR that added ``--json-schema``; see :func:`_claude`'s own docstring for
     the full history).** Was CONDITIONALLY passed for a time (present only when an explicit
     ``ANTHROPIC_API_KEY``/``CLAUDE_CODE_OAUTH_TOKEN`` was set — the documented
     "reduce startup time by skipping auto-discovery of hooks, skills, plugins, MCP servers, auto
     memory, and CLAUDE.md" hardening, code.claude.com/docs/en/headless), layered on top of
     (never instead of) the neutral-cwd fix above. Removed once this lane also started passing
     ``--json-schema``: this repo's own committed history already shows that exact flag pair
     breaking ``structured_output`` on the sibling Action lane, and this module's own
     "verified live, never assumed" discipline could not re-confirm compatibility on this lane's
     own invocation shape without a credential unavailable in the environment the removal was
     authored in — schema enforcement (item 3's whole purpose) wins over an already-disclosed
     "genuinely redundant defense-in-depth" layer; the neutral cwd stays the PRIMARY, unconditional
     control, unaffected either way.
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

**The cwd contract, enumerated — every behavior anywhere in this port that used to implicitly
assume "the provider's own process cwd == the repo checkout", decided explicitly, not
rediscovered one Codex round at a time.** A live Codex review on the round that introduced the
neutral cwd above found THREE more instances of this exact assumption (P1 on the claude lane's
own auth, P1 on the codex lane's own repo-presence check, P1 on trusted-mode's own command
rooting) after the first pass only closed the ORIGINAL exfiltration vector — this is the
enumeration that review asked for, so the next reader sees the contract instead of re-deriving
it finding by finding. Each entry: the behavior, whether it genuinely depends on cwd == checkout,
and how it's resolved.

  - **claude's startup-time config/MCP/hooks auto-discovery** — YES, the original vulnerability.
    Resolved: neutral cwd, unconditional under the ``readonly`` tier (round 1 above).
  - **claude's OAuth/system-keychain login** (``claude auth login``, docs/SETUP.md's Way C) — NO,
    keychain auth is tied to the user account, not cwd; moot now that ``--bare`` is dropped
    entirely (issue #26 item 3 — see :func:`_claude`'s own docstring), so Claude Code's own
    normal (keychain-capable) startup always runs on this lane regardless of credential source.
  - **codex's non-interactive "am I in a git repository" guard** — YES, `codex exec` refuses to
    run at all outside a git repository. Resolved: ``--skip-git-repo-check``, unconditional,
    since this lane always launches from the neutral cwd (see :func:`_codex`).
  - **gemini/cursor-agent's own config auto-discovery** — disclosed, unverified; no documented
    opt-out flag exists for either CLI as of this writing (checked, not assumed). Left as the
    honest residual exposure round 2 above and DESIGN.md's "Security posture" already disclose —
    narrowed (nothing repo-local in a neutral scratch dir to discover) but not eliminated.
  - **Trusted-mode's own bare ``git diff``/``git show``/``git log`` instructions** — YES, those
    are relative-to-cwd commands, not ``-C``-scoped. Resolved: trusted mode roots the provider's
    cwd at ``ctx.repo_root`` itself, restoring the pre-fix behavior for this ONE tier only (see
    ``pantheon.cli._run_agent``'s own ``provider_cwd`` selection) — safe because trusted mode is
    an explicit opt-in for content the operator ALREADY trusts (never a fork PR — DESIGN.md's
    "Security posture") and already grants full, unrestricted Bash, so neutral-cwd protects
    nothing additional there in the first place.
  - **readonly tier's Read/Grep/Glob tool calls against the checkout** — YES, those tools take a
    path argument, not implicitly "the cwd". Resolved: the prompt's own Run-context block now
    advertises the repo root's ABSOLUTE path explicitly (``pantheon.cli._build_prompt``), paired
    with an instruction that findings must still cite repo-RELATIVE paths (belt-and-suspenders on
    top of ``pantheon.render``'s own mechanical redaction, see that module's own docstring).
  - **readonly tier's readonly-git-wrapper invocation** — YES, the wrapper used to resolve the
    repo via :func:`os.getcwd`. Resolved: ``--repo-root <repo_root>``, shell-quoted
    (:func:`shlex.quote`), baked into the fixed Bash-tool permission prefix itself (see
    ``pantheon.cli._wrapper_invocation`` and ``pantheon.execution._wrapper_cli``).
  - **``pantheon.cli``'s OWN gate.conf/rules/spec reads** (base-pinned or working-tree) — NO,
    these run in the TRUSTED orchestrator process itself (``pantheon.cli``'s own ``_git``/
    ``basepin`` calls), never inside a launched provider subprocess at all — repo_root/cwd are
    already passed EXPLICITLY to every one of these calls, unaffected by this whole fix.
  - **PATH resolution for the provider CLI binary itself** (``_filtered_path``/``_resolve_cli``)
    — NO, computed in the TRUSTED orchestrator process before the child is ever spawned;
    ``_filtered_path`` already excludes ``os.getcwd()``/``repo_root`` explicitly, independent of
    whatever the CHILD's own eventual cwd turns out to be.

Every entry above is now a deliberate, documented decision — either the repo root is passed
EXPLICITLY (the wrapper, Read/Grep/Glob, codex's repo-check opt-out), the behavior is correctly
rootless (PATH resolution, ``pantheon.cli``'s own config reads), or the gap is an honestly
disclosed residual (gemini/cursor). None of these should need rediscovering by a future review
the way three of them were on this one.

**The SAME contract, applied to the provider's ENV, not just its cwd (adversarial review, round
6, Codex P1 — proof this list needed a sibling, not that it was wrong).** Everything above
enumerates cwd-dependent behavior; it says nothing about a provider CLI's own env-var-driven
config resolution — a SEPARATE door to the identical exfiltration vector, reopened when
``_provider_env`` forwarded ``CLAUDE_CONFIG_DIR`` from ambient env unconditionally even after
neutral cwd closed the cwd door. :data:`_PROVIDER_ENV_PASSTHROUGH_KEYS`'s own header comment is
that list's enumeration, in the identical spirit — every key classified PATH-SHAPED (needs a
containment check, or a non-env resolution for ``HOME``) or not, so a NEW key added to that
allowlist in the future has an obvious place to make the same call explicitly instead of
defaulting to a blind passthrough.
"""

from __future__ import annotations

import contextlib
import os
import shlex
import signal
import subprocess
import sys

from pantheon import execution, jqjson, verdict

__all__ = [
    "ProviderError",
    "KNOWN_PROVIDERS",
    "VERDICT_JSON_SCHEMA",
    "default_allowed_tools",
    "provider_run",
    "trusted_roots",
    "resolves_inside_a_trusted_root",
    "main",
]


class ProviderError(Exception):
    """Raised whenever a provider lane fails — its CLI not found on ``PATH``, a nonzero exit, or
    a timeout. Mirrors bash's ``provider_run ... ; provider_status=$?`` contract: a caller
    (``pantheon.cli``'s ``run_agent``) catches this uniformly and lands on UNVERIFIED, the same
    branch the retired bash CLI's ``review-gate`` script took on ``$provider_status -ne 0``
    (removed in #29). ``output`` carries whatever
    text the failed invocation actually produced (a "CLI not found" message, partial merged
    stdout+stderr) — the same text bash's own ``raw_output="$( ... 2>&1)"`` capture would still
    hold even on a nonzero exit, kept here purely for a caller that wants it for logging; never
    required for correct fail-closed behavior (a caller that ignores it still lands on
    UNVERIFIED)."""

    def __init__(self, message: str, output: str = "") -> None:
        super().__init__(message)
        self.output = output


# The fixed four lanes — mirrors the retired bash CLI's per-lane provider script directory
# contents exactly (removed in #29; docs/CLI.md's `--provider <lane>` table). In bash, "unknown
# provider" was checked by file existence (`[[ -f "$PROVIDERS_DIR/$PROVIDER.sh" ]]`) — issue #13,
# deliberately not fixed by this port. This tuple is the Python-shaped equivalent of that same
# coverage: an enumerated dispatch table with no file to `source`, so there is no separate "does
# this name resolve to a script" check to have a character-class gap in — the same four names,
# checked the same way (presence in a fixed list), nothing hardened or relaxed relative to what
# bash already validates.
KNOWN_PROVIDERS: tuple[str, ...] = ("claude", "codex", "gemini", "cursor")

# The fallback --allowedTools value this module computes when a caller doesn't supply one — the
# Python-shaped equivalent of the retired bash CLI's `claude.sh` provider script's own fallback
# (removed in #29; `cd .../lib && pwd` relative to that script's own location), which exists so
# this lane still fails safe (readonly, not open) when invoked directly, outside pantheon.cli.
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

# The verdict-contract JSON Schema (DESIGN.md's "Verdict contract") — the SAME schema text
# action.yml/action/review.yml already pass to claude-code-action's own `claude_args` via
# `--json-schema` (kept byte-identical deliberately, not re-derived, so every surface that can
# enforce a schema at all enforces the identical one). Issue #26 item 3: the CLI (Python) lane
# used to invoke `claude -p ...` and merely HOPE the model ended with a trailing JSON object,
# relying entirely on pantheon.verdict's own trailing-JSON-extraction fallback — the flag this
# constant is used with (`--json-schema`, confirmed present via `claude --help`) exists and the
# two GitHub Action surfaces already use it; this module's own `_claude()` now does too.
#
# THE SCHEMA MIRRORS THE DECISION SURFACE ONLY — it must never be stricter than
# `pantheon.verdict.decide()`, or a verdict the binding contract ACCEPTS becomes UNVERIFIED
# (fail-closed in the WRONG direction: a real, reviewable result reported as NOT GATED). So it is
# strict on what decide() branches on (agent/verdict/has_blocker/findings + severity) and permits
# every JSON type on the five display fields, which decide() ignores and the render layer
# sanitizes. DESIGN.md's "Verdict contract" owns the full rationale and the incident history —
# this is the pointer, not a second copy of the story.
#
# The display fields stay DECLARED (with a permissive type union) rather than omitted from
# `properties` entirely: omitting them would express "unconstrained" more tersely, but declaring
# them is what tells the model these keys are expected at all. A finding with no `file`/`line` is
# a much weaker finding, and the schema is the strongest shape signal the generation gets.
# Permissive-but-declared keeps the guidance without reintroducing the strictness.
#
# THREE copies, not two: this constant, `action.yml`'s `JSON_SCHEMA`, and `action/review.yml`'s
# INLINE `--json-schema '...'` argument, which has NO variable name — a grep for `JSON_SCHEMA`
# finds two and reports the third absent, which is how it once drifted a revision behind. The
# byte-identity test searches by content for that reason. Change one, change all three (#32
# tracks deriving them from this constant instead).
VERDICT_JSON_SCHEMA = (
    '{"type":"object","properties":{"agent":{"type":"string"},"verdict":{"type":"string"},'
    '"has_blocker":{"type":"boolean"},"findings":{"type":"array","items":{"type":"object",'
    '"properties":{"severity":{"type":"string"},"file":{"type":["string","number","boolean",'
    '"object","array","null"]},"line":{"type":["string","number","boolean","object","array",'
    '"null"]},"issue":{"type":["string","number","boolean","object","array","null"]},"scenario":{'
    '"type":["string","number","boolean","object","array","null"]}},"required":["severity"]}},'
    '"summary":{"type":["string","number","boolean","object","array","null"]}},"required":['
    '"agent","verdict","has_blocker","findings","summary"]}'
)


def _extract_structured_output(envelope_text: str) -> str:
    """Post-processes the claude lane's `--output-format json` envelope (issue #26 item 3):
    with `--json-schema` also passed, that envelope carries a `structured_output` key holding
    the schema-VALIDATED object itself (confirmed live: `claude -p ... --json-schema '<schema>'
    --output-format json` prints one JSON object to stdout with both a `result` string field AND
    a separate, already-parsed `structured_output` object field) — this function is what makes
    that shape a drop-in replacement for the OLD raw-text-and-hope-for-trailing-JSON output every
    caller of :func:`provider_run` already expects (``pantheon.verdict.decide()``, unchanged by
    this fix, still does its own trailing-JSON-extraction/parse/validate pass on whatever string
    this function returns).

    Re-serializes `structured_output` via :func:`pantheon.jqjson.dumps` (never a bare
    ``json.dumps`` — this port's own JSON-boundary rule) when present, so
    ``pantheon.verdict.extract_last_json``'s own suffix scan finds exactly one trailing JSON
    object, the schema-validated one, with nothing else around it to confuse the scan.

    Falls back to `envelope_text` UNCHANGED — never raises, never substitutes a synthetic error
    object — when no trailing JSON object can be isolated at all, that object has no
    `structured_output` key (schema validation failed, e.g. `is_error: true` with the CLI's own
    "did not return structured_output" message in `result`), or that key is JSON `null`:
    `pantheon.verdict.decide()` then runs its OWN trailing-JSON-extraction pass on that text,
    which is `required-keys`-checked against the verdict contract's five required keys — the
    outer envelope's own keys (`type`, `subtype`, `session_id`, `usage`, ...) never happen to
    satisfy that set, so this correctly lands on UNVERIFIED ("verdict JSON missing required
    keys") rather than a lucky false match, matching the same fail-closed posture the pre-#26
    raw-text lane already had for any other malformed provider output.

    **Isolates the envelope via :func:`pantheon.verdict.extract_last_json` FIRST, never a bare
    whole-text :func:`pantheon.jqjson.loads` — a P2 finding from a live Codex review on this PR.**
    ``_run()``'s own contract merges stdout AND stderr into one text stream (mirroring bash's own
    ``2>&1`` capture — see that function's own docstring); a SUCCESSFUL claude invocation can
    still emit an unrelated warning/diagnostic line on stderr, which lands BEFORE the JSON
    envelope in that merged text. A bare ``jqjson.loads(envelope_text)`` on the WHOLE merged text
    then fails ("Extra data"/leading-garbage — the envelope's own JSON is no longer the only
    content), and this function's own fallback returned the RAW merged text unchanged in that
    case — which then let ``pantheon.verdict.decide()``'s OWN trailing-JSON-extraction still find
    and parse the outer envelope object (a real, complete JSON document, still the LAST thing in
    the text), landing on the SAME "verdict JSON missing required keys" UNVERIFIED a genuinely
    malformed response gets — discarding a perfectly valid, schema-conformant verdict over a
    harmless stderr line, exactly the class of readonly-tier fragility issue #26 is about. Fixed
    by reusing the identical rightmost-parseable-`{`-suffix scan ``pantheon.verdict.decide()``
    already applies to every OTHER provider lane's raw output, applied here FIRST to isolate the
    envelope object itself before this function's own ``structured_output`` extraction runs —
    one shared algorithm, not a second copy of the same judgment call."""
    candidate = verdict.extract_last_json(envelope_text)
    if not candidate:
        return envelope_text
    try:
        envelope = jqjson.loads(candidate)
    except jqjson.JqParseError:
        return envelope_text
    if not isinstance(envelope, dict):
        return envelope_text
    structured = envelope.get("structured_output")
    if structured is None:
        return envelope_text
    return jqjson.dumps(structured, ensure_ascii=False)


def default_allowed_tools(repo_root: str | None = None) -> str:
    """The readonly-tier fallback ``--allowedTools`` value (see this module's own docstring for
    why this exists) — resolves :data:`_WRAPPER_SCRIPT_NAME`'s absolute path via
    ``pantheon.execution.resolve_console_script`` (checks both a venv's/system install's own
    scripts directory AND ``pip install --user``'s separate per-user one — never an ambient
    ``PATH`` lookup), falling back to the OLDER, unprotected ``python -m pantheon.execution
    wrapper`` form only when the console script genuinely isn't installed anywhere that function
    checks (a plain dev checkout — a disclosed package-layout caveat for this slice), with a loud
    stderr warning every time that fallback fires.

    ``repo_root``, when given, is baked into the returned string as a fixed ``--repo-root``
    literal — a CRITICAL fix (adversarial review), mirroring ``pantheon.cli``'s own
    ``_wrapper_invocation()`` exactly (see that function's own docstring for the full rationale:
    providers no longer launch with the repo checkout as their own cwd, so the wrapper needs the
    real repo root told to it explicitly), INCLUDING shell-quoting it (:func:`shlex.quote`) — a
    P2 finding from a live Codex review on ``pantheon.cli``'s own copy of this same embedding,
    fixed identically here so this fallback doesn't reopen the same whitespace-in-checkout-path
    bug for standalone use. Optional (default ``None``, omitting the flag entirely) so this
    function's existing zero-argument call shape keeps working for genuinely standalone use (this
    module's own ``python -m pantheon.providers run ...`` CLI, invoked with no ``repo-root``
    positional) — the one case where no repo root is actually known yet."""
    candidate = execution.resolve_console_script(_WRAPPER_SCRIPT_NAME)
    repo_root_suffix = f" --repo-root {shlex.quote(repo_root)}" if repo_root else ""
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
#
# EVERY key on this list is a security boundary (adversarial review, round 6, Codex P1 —
# reopened CRITICAL-1 through a DIFFERENT door than the one already closed: not the provider's
# cwd this time, but its ENV). Two mutually-exclusive categories, both audited below per-key:
#
#   PATH-SHAPED keys (a provider CLI — or the config-loading library underneath it, per the
#   XDG Base Directory spec many of these CLIs honor as a fallback even without their OWN
#   explicit override set — treats the value as a directory/file to READ CONFIG, MCP-server
#   definitions, or hooks FROM at startup): forwarding one blindly from ambient env recreates
#   CRITICAL-1's original exfiltration vector exactly, just one hop later — a hostile checkout's
#   own env-loading mechanism (a `.envrc`, an environment-setting CI step reading repo content,
#   ANY way a checkout can influence the parent process's env before this module runs — the same
#   disclosed vector `pantheon.execution.real_home_dir`'s own docstring already names) pointing
#   one of these AT a directory inside the checkout would let the provider CLI's own NORMAL
#   startup load attacker-controlled MCP servers/hooks, entirely outside `--allowedTools`'s
#   reach. These are listed in :data:`_PATH_SHAPED_ENV_KEYS` below and go through
#   :func:`_safe_path_env_value` — verified (via :func:`resolves_inside_a_trusted_root`) to
#   resolve OUTSIDE the repo root/cwd before being forwarded; a value that resolves INSIDE either
#   is dropped (never forwarded, loudly), regardless of how it got set. ``HOME`` specifically is
#   never even READ from ambient env at all — see :func:`_provider_env`'s own body for why a
#   validate-or-drop check isn't strong enough for that one specifically.
#
#   NON-path keys (opaque credential values, locale/region/profile-name strings, proxy URLs):
#   these have no filesystem "resolves inside the checkout" meaning at all — a string like an
#   API key or a locale tag can't be redirected at a directory the way a path can. Forwarded
#   as-is, audited below to confirm none of them is secretly path-shaped in some CLI's own docs.
_PROVIDER_ENV_PASSTHROUGH_KEYS: tuple[str, ...] = (
    # --- Process/locale basics every one of these CLIs needs to run and print sane output ---
    # HOME: PATH-SHAPED, see _PATH_SHAPED_ENV_KEYS below — never read from ambient env at all.
    "HOME",
    "USER",  # a username STRING (not a path) — printed/logged by some CLIs, never resolved as one.
    "LOGNAME",  # same as USER — POSIX's older name for the identical username string.
    "LANG",  # a locale tag ("en_US.UTF-8") — a string, not a filesystem path.
    "LC_ALL",  # same shape as LANG.
    "LC_CTYPE",  # same shape as LANG.
    "TERM",  # a terminal-type STRING ("xterm-256color") — not a path.
    # TMPDIR: PATH-SHAPED (where temp files land) — see _PATH_SHAPED_ENV_KEYS below.
    "TMPDIR",
    # TZ can rarely be a tzfile path (":/usr/share/zoneinfo/...") on some POSIX systems, but a
    # hijacked TZ only ever corrupts DISPLAYED timestamps — no config/MCP/hook loading, no
    # capability grant, not the CRITICAL-1 vector class this audit is scoped to. Left as a plain
    # passthrough on that basis (a real path-shaped USE would be cosmetic-only, not exploitable).
    "TZ",
    # XDG_CONFIG_HOME/XDG_CACHE_HOME/XDG_DATA_HOME/XDG_STATE_HOME: PATH-SHAPED (the XDG Base
    # Directory spec's own config/cache/data/state ROOTS — several of these provider CLIs fall
    # back to computing a path under one of these, or under HOME, when their OWN dedicated
    # override is unset) — see _PATH_SHAPED_ENV_KEYS below.
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    # --- Claude Code CLI — the only integration-tested lane ---
    # Auth surface documented in docs/SETUP.md's "Post-install checklist"/Way C auth table:
    # CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY (exactly one) — opaque credential VALUES, not
    # paths; there is nothing to "resolve inside the checkout" about a bearer token string. The
    # Bedrock/Vertex vars are disclosed in docs/SETUP.md as "supported by
    # anthropics/claude-code-action itself... NOT wired through THIS repo's composite action" —
    # that disclosure is about the Action's `with:` inputs, not this CLI lane; a locally
    # configured `claude` CLI using them still needs them forwarded to behave the same way it
    # would run outside this gate.
    "ANTHROPIC_API_KEY",
    "CLAUDE_CODE_OAUTH_TOKEN",
    # CLAUDE_CONFIG_DIR: PATH-SHAPED — the CLI's own conventional config-dir override, and the
    # ORIGINAL live vector this whole round-6 audit closes (Claude's own current headless docs:
    # verified against code.claude.com before this fix, not assumed). See
    # _PATH_SHAPED_ENV_KEYS below.
    "CLAUDE_CONFIG_DIR",
    "CLAUDE_CODE_USE_BEDROCK",  # a boolean-flag string ("1"/"true") — not a path.
    "CLAUDE_CODE_USE_VERTEX",  # same shape as CLAUDE_CODE_USE_BEDROCK.
    "AWS_ACCESS_KEY_ID",  # an opaque credential VALUE — not a path.
    "AWS_SECRET_ACCESS_KEY",  # an opaque credential VALUE — not a path.
    "AWS_SESSION_TOKEN",  # an opaque credential VALUE — not a path.
    "AWS_REGION",  # a region-name STRING ("us-east-1") — not a path.
    "AWS_DEFAULT_REGION",  # same shape as AWS_REGION.
    # AWS_PROFILE names a SECTION inside ~/.aws/credentials|config by NAME, not by path — it
    # can't itself point anywhere; the FILES it indexes into are HOME-anchored, and HOME is now
    # always the passwd-resolved real value (see _provider_env's own body), never ambient.
    "AWS_PROFILE",
    # GOOGLE_APPLICATION_CREDENTIALS: PATH-SHAPED (a service-account-key FILE path) — a hijacked
    # value here doesn't leak secrets OUT so much as let an attacker SUBSTITUTE their own
    # credentials for the review run's GCP identity; still "points into the checkout" per this
    # audit's own rule, so it gets the identical containment check. See _PATH_SHAPED_ENV_KEYS
    # below.
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_CLOUD_PROJECT",  # a project-ID STRING — not a path.
    "CLOUD_ML_REGION",  # a region-name STRING — not a path.
    # --- codex/gemini/cursor — best-effort lanes, no dedicated auth-surface doc in this repo ---
    # Each is that CLI's own conventional API-key env var name — opaque credential VALUES, not
    # paths. NOTE (this audit's own "sweep their docs" sweep, verified live, not assumed): each
    # of these three CLIs ALSO has its own config-dir override — CODEX_HOME (defaults to
    # ~/.codex), GEMINI_CONFIG_DIR (defaults to ~/.gemini or ~/.config/gemini), CURSOR_CONFIG_DIR
    # (defaults to ~/.cursor) — but NONE of the three is on this passthrough list today, so none
    # is currently forwarded/exploitable; if one is ever added, it MUST go through
    # :data:`_PATH_SHAPED_ENV_KEYS`/:func:`_safe_path_env_value` like CLAUDE_CONFIG_DIR, never as
    # a plain passthrough.
    "OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "CURSOR_API_KEY",
    # --- Proxy transport vars ---
    # a Codex review finding on this port's own PR: `pantheon.cli`'s own git/gh env already
    # forwards these (dropping them broke `git fetch`/`gh pr view` behind a corporate HTTP(S)
    # proxy); every networked PROVIDER invocation needs the identical fix, or a proxy-gated
    # network still lets metadata/fetch through while every agent's own API call fails and reads
    # UNVERIFIED. URLs, not filesystem paths — "resolves inside the checkout" has no meaning for
    # a proxy URL; a hijacked proxy value is a DIFFERENT (network-MITM) risk class, already
    # implicitly accepted for the same reason `pantheon.cli`'s own identical allowlist accepts it
    # (out of scope for this specific containment-check fix, not a "still open" finding of it).
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "all_proxy",
)

# PATH-SHAPED keys from the allowlist above that need the containment check
# (:func:`resolves_inside_a_trusted_root`) before being forwarded — see the allowlist's own
# header comment for the full rationale. ``HOME`` is deliberately NOT in this set: a
# validate-or-drop check is weaker than never reading the ambient value in the first place (a
# value could resolve OUTSIDE the repo root today and still have been set by the exact same
# hostile env-loading mechanism this whole audit is about — the containment check only proves
# "not currently pointed at the checkout", not "not attacker-influenced at all") — HOME instead
# gets :func:`pantheon.execution.real_home_dir`'s OS-level (pwd database) resolution, which
# cannot be redirected by any environment variable at all, matching the stronger guarantee that
# function already gives the readonly git wrapper.
_PATH_SHAPED_ENV_KEYS: frozenset[str] = frozenset(
    {
        "CLAUDE_CONFIG_DIR",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "TMPDIR",
        "GOOGLE_APPLICATION_CREDENTIALS",
    }
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


def trusted_roots(repo_root: str | None = None) -> list[str]:
    """The realpath-resolved directories a checkout-controlled value must never resolve inside —
    the current working directory ALWAYS, plus ``repo_root`` when given (round 2's fix on
    :func:`_filtered_path`, factored out here so :func:`_provider_env`'s own containment check —
    round 6 — shares the identical root set rather than each caller keeping its own copy of the
    same security-critical list). See :func:`_filtered_path`'s own docstring for why BOTH are
    needed (cwd alone misses a repo-controlled entry when launched from a nested directory).

    **Public (not ``_``-prefixed) specifically so ``pantheon.cli`` can reuse it too** (adversarial
    review, round 7, Codex P1 — CRITICAL-1's neutral-cwd control reopened a THIRD way:
    ``tempfile.TemporaryDirectory()`` honors ambient ``TMPDIR``, so a hostile checkout exporting
    it could put the "neutral" provider cwd back inside the repository. ``pantheon.cli.run_gate``
    uses this same root set, together with :func:`resolves_inside_a_trusted_root`, to verify the
    neutral workdir it creates actually resolves outside every trusted root before using it —
    fail-closed if not, rather than trusting a fixed temp-base choice alone to be sufficient."""
    roots = [os.path.realpath(os.getcwd())]
    if repo_root:
        real_repo_root = os.path.realpath(repo_root)
        if real_repo_root not in roots:
            roots.append(real_repo_root)
    return roots


def resolves_inside_a_trusted_root(path: str, roots: list[str]) -> bool:
    """Whether ``path`` (realpath-resolved, following symlinks — never compared as a raw
    string) is one of ``roots`` or lives somewhere underneath one. Shared by
    :func:`_filtered_path` (a PATH entry) and :func:`_safe_path_env_value` (a path-shaped env
    var's value) — the same "resolves inside a trusted root" test, one implementation."""
    real_path = os.path.realpath(path)
    return any(real_path == root or real_path.startswith(root + os.sep) for root in roots)


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
    roots = trusted_roots(repo_root)
    kept: list[str] = []
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        if not entry or not os.path.isabs(entry):
            continue
        if resolves_inside_a_trusted_root(entry, roots):
            continue
        kept.append(entry)
    return os.pathsep.join(kept)


def _safe_path_env_value(key: str, value: str, roots: list[str]) -> str | None:
    """Returns ``value`` unchanged when it resolves OUTSIDE every trusted root — an operator's
    own, legitimate override (a real ``CLAUDE_CONFIG_DIR`` for a second account, say) — or
    ``None`` (never forwarded) when it resolves INSIDE one, logging a loud warning either way a
    value gets dropped. This is a validate-or-DROP gate, not a hard abort of the whole gate run:
    every key routed through this is an OPTIONAL override (see :data:`_PATH_SHAPED_ENV_KEYS`'s
    own header comment) whose absence just falls back to that provider CLI's own default — dropping
    the hostile value, rather than aborting, is the correct fail-closed shape here (deny the
    CAPABILITY the hostile value would have granted, without taking down an otherwise-legitimate
    run over an env var most callers never even set). A relative ``value`` is realpath-resolved
    against THIS process's own cwd by :func:`resolves_inside_a_trusted_root` — the common case
    (the gate is invoked from inside the repo checkout) naturally lands it under the cwd trusted
    root already in ``roots``, so no separate relative-path special-case is needed."""
    if resolves_inside_a_trusted_root(value, roots):
        print(
            f"pantheon: warning: ambient {key} resolves inside a trusted root (the working "
            "directory or the repo checkout) — refusing to forward it to the provider CLI (would "
            "reopen the config/MCP/hook-loading exfiltration vector CRITICAL-1 closed, through "
            f"the process's own environment instead of its cwd); {key} is omitted this run",
            file=sys.stderr,
        )
        return None
    return value


def _provider_env(repo_root: str | None = None) -> dict[str, str]:
    """Explicitly constructed subprocess environment for every provider-CLI call — never an
    implicit ``os.environ`` passthrough, and never a blanket ``dict(os.environ)`` copy either
    (this module's own "constructed clean env, never inherited" rule — see the module docstring,
    round 3, for the concrete exploit a blanket copy left open). ``PATH`` is the
    filtered value from :func:`_filtered_path` (``repo_root``-aware); every other key is copied
    one at a time from the explicit :data:`_PROVIDER_ENV_PASSTHROUGH_KEYS` allowlist, never in
    bulk.

    **``HOME`` and every PATH-SHAPED key get extra treatment (adversarial review, round 6, Codex
    P1 — reopened CRITICAL-1 through this function's ENV construction, not the cwd CRITICAL-1's
    original fix already closed).** ``HOME`` is NEVER read from ambient env at all — resolved via
    :func:`pantheon.execution.real_home_dir` (the passwd database), the identical fix already
    applied to the readonly git wrapper's own env for the same hijack class, now shared rather
    than re-derived here. Every key in :data:`_PATH_SHAPED_ENV_KEYS` (``CLAUDE_CONFIG_DIR`` and
    the rest — see that set's own header comment) is passed through :func:`_safe_path_env_value`
    first: a value that resolves inside the cwd or ``repo_root`` is dropped, never forwarded,
    regardless of how it got set."""
    env: dict[str, str] = {"PATH": _filtered_path(repo_root)}

    real_home = execution.real_home_dir()
    if real_home:
        env["HOME"] = real_home

    roots = trusted_roots(repo_root)
    for key in _PROVIDER_ENV_PASSTHROUGH_KEYS:
        if key == "HOME":
            continue  # handled above — never read from ambient env at all, see this function's own docstring.
        value = os.environ.get(key)
        if value is None:
            continue
        if key in _PATH_SHAPED_ENV_KEYS:
            value = _safe_path_env_value(key, value, roots)
            if value is None:
                continue
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
    too, after a short grace period — mirrors the retired bash CLI's ``review-gate`` script's own
    ``run_with_timeout`` fallback (removed in #29; TERM, wait ~5s, KILL) so a provider CLI's own
    spawned tool subprocesses are cleaned up too, not just the single direct child a bare
    ``proc.kill()`` would reach.
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
    merge_stderr: bool = True,
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
    Raises :class:`ProviderError` on a nonzero exit, a timeout, or a failure to even start the
    process (the executable vanishing between :func:`_resolve_cli` and this call, say) — never
    lets a raw ``subprocess.CalledProcessError``/``OSError`` escape to a caller that only knows
    this module's own exception type.

    ``merge_stderr`` (default ``True``, preserving the ORIGINAL behavior for every EXISTING call
    site — codex/gemini/cursor all still get one merged stdout+stderr text, mirroring the retired
    bash CLI's own
    ``raw_output="$(run_with_timeout ... provider_run "$MODEL" "$prompt_file" 2>&1)"`` capture in
    ``review-gate``'s ``run_agent()`` (removed in #29): a live Codex review finding (P2) on this
    PR's own ``--json-schema`` fix (issue #26 item 3) — a stderr diagnostic line landing AFTER the claude
    lane's own clean JSON envelope on a merged stream defeats
    ``pantheon.verdict.extract_last_json``'s own trailing-JSON scan, which requires NOTHING after
    the JSON object's own closing brace; a LEADING stderr line doesn't break that scan (the
    envelope is still the rightmost, complete-with-nothing-after candidate), but a TRAILING one
    does, discarding a perfectly valid, schema-conformant verdict. ``--output-format json`` is
    specifically claude's own MACHINE-READABLE mode — mixing its stdout with unrelated stderr
    diagnostics on one stream defeats that mode's whole purpose. When ``merge_stderr=False``
    (the claude lane's own call, see :func:`_claude`), stdout and stderr are captured on TWO
    SEPARATE pipes: only stdout is ever returned on the success path (never contaminated by a
    stray stderr line, leading OR trailing) — a nonzero exit's :class:`ProviderError` still
    carries BOTH streams concatenated in ``output`` (the SAME diagnostic shape every caller
    already expects, unaffected by which mode produced it).

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
    stderr_target = subprocess.STDOUT if merge_stderr else subprocess.PIPE

    try:
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE if input_text is not None else None,
            stdout=subprocess.PIPE,
            stderr=stderr_target,
            env=_provider_env(repo_root),
            cwd=cwd,
            shell=False,
            start_new_session=True,
        )
    except OSError as e:
        raise ProviderError(f"failed to execute {argv[0]}: {e}") from e

    try:
        stdout_bytes, stderr_bytes = proc.communicate(input=stdin_bytes, timeout=timeout)
    except subprocess.TimeoutExpired:
        _terminate_group(proc)
        try:
            leftover_stdout, leftover_stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            leftover_stdout, leftover_stderr = b"", b""
        leftover = (leftover_stdout or b"").decode("utf-8", errors="replace") + (leftover_stderr or b"").decode(
            "utf-8", errors="replace"
        )
        raise ProviderError(f"{argv[0]} timed out after {timeout}s", output=leftover) from None

    stdout = (stdout_bytes or b"").decode("utf-8", errors="replace")
    stderr = (stderr_bytes or b"").decode("utf-8", errors="replace") if not merge_stderr else ""
    if proc.returncode != 0:
        raise ProviderError(f"{argv[0]} exited {proc.returncode}", output=stdout + stderr)
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
    the retired bash CLI's ``claude.sh`` provider script, removed in #29). ``--permission-mode
    dontAsk`` (not "default"): Claude Code's own
    docs describe ``default`` mode as auto-approving reads only — everything else, including a
    tool call that DOES match ``--allowedTools``, still goes through a permission decision nothing
    can answer non-interactively outside a terminal; ``dontAsk`` is documented as the mode "for
    CI pipelines and scripts", auto-denying anything not pre-approved rather than hanging.

    **``--bare`` is NO LONGER PASSED, on any credential path — DROPPED, not merely made
    conditional, as of issue #26 item 3's ``--json-schema`` addition below (a live re-gate
    finding, Artemis P1/should_fix, on this same PR).** An EARLIER version of this lane passed
    ``--bare`` conditionally (present only when an explicit ``ANTHROPIC_API_KEY``/
    ``CLAUDE_CODE_OAUTH_TOKEN`` credential was set — the documented "reduce startup time by
    skipping auto-discovery of hooks, skills, plugins, MCP servers, auto memory, and CLAUDE.md"
    hardening, code.claude.com/docs/en/headless, layered on top of the neutral ``cwd`` below).
    That conditional was correct FOR ITS OWN TIME, but this repo's own committed history
    (``DESIGN.md``'s "Security posture", the pinned SHA both Action surfaces trust) already
    documents a LIVE, REPRODUCED failure of ``--bare`` combined with ``--json-schema``-driven
    structured output on the sibling GitHub Action lane — a real self-hosted-gate run failed
    both agents to UNVERIFIED with ``##[error]--json-schema was provided but Claude did not
    return structured_output``, and ``--bare`` was removed from that lane specifically because
    of it, permanently, never re-added. This module's own live-verification discipline could not
    re-confirm whether the IDENTICAL combination reproduces on THIS lane's own
    ``--output-format json`` (non-streaming) mode specifically (the Action lane's own failure was
    observed under its different, streaming invocation shape) — no explicit
    ``ANTHROPIC_API_KEY``/``CLAUDE_CODE_OAUTH_TOKEN`` credential was available to test with in
    the environment this fix was authored in, and minting one (``claude setup-token``) requires
    interactive browser auth this environment cannot complete. Given direct, first-party evidence
    of the SAME flag pair breaking structured output once already in this repo, and given item
    3's own reason for existing (unattended/CI runs — precisely the case an explicit credential,
    and therefore the old conditional's own ``--bare`` trigger, implies) is exactly the scenario
    that would silently degrade to UNVERIFIED if the conflict reproduces here too, the safe,
    evidence-led call is: schema enforcement wins, unconditionally, and ``--bare`` is dropped
    rather than risk defeating item 3's entire purpose on an unverified combination. This does
    NOT reopen CRITICAL-1's own vulnerability: the neutral ``cwd`` below (layer 1 of that fix)
    was always the PRIMARY, unconditional control — ``--bare`` was always disclosed as
    "genuinely redundant defense-in-depth on top of that, not the primary control" (see this
    docstring's own prior revisions in git history) — and :func:`_provider_env`'s own
    :data:`_PATH_SHAPED_ENV_KEYS` containment check (``CLAUDE_CONFIG_DIR`` included) is
    unaffected by ``--bare``'s presence either way. A future contributor who CAN empirically
    re-verify ``--bare`` + ``--json-schema`` compatibility on this exact non-streaming
    ``--output-format json`` shape (a real credential, a real live run) is the only path back to
    re-adding it — this repo's own "verified live, not assumed" discipline applies to REMOVING a
    control just as much as adding one, and this removal itself is exactly that: evidence-led,
    not merely cautious.

    ``cwd`` is a neutral scratch directory (never the repo checkout — see :func:`_run`'s own
    docstring for the full CRITICAL-1 finding and fix) — the unconditional, primary control this
    whole startup-discovery vector actually closes.

    **``--json-schema``/``--output-format json`` — issue #26 item 3.** Every other lane
    (codex/gemini/cursor, none of which expose an equivalent flag as of this writing — see this
    module's own docstring's per-lane disclosures) and this lane's own PRE-fix behavior relied
    entirely on ``pantheon.verdict``'s trailing-JSON-extraction scan to find a verdict object
    somewhere in the model's raw text output — hope, not enforcement. ``claude --help`` documents
    ``--json-schema <schema>``, and the two GitHub Action surfaces (``action.yml``,
    ``action/review.yml``) already pass an identical schema via ``claude_args`` and read the
    result from ``structured_output``. Confirmed live (this fix's own investigation, a real
    ``claude -p ... --json-schema '<schema>' --output-format json`` invocation, WITHOUT
    ``--bare``): stdout is ONE JSON envelope object carrying a ``structured_output`` key holding
    the schema-validated object itself — :func:`_extract_structured_output` (see its own
    docstring) turns that envelope into the same plain, trailing-JSON-object text shape
    ``pantheon.verdict.decide()`` already expects from every OTHER lane, so that decision function
    itself needed no change at all: both runtimes (this CLI lane and the Action's own
    ``structured_output``-driven lane) now enforce the IDENTICAL schema and feed the IDENTICAL
    decision function, whether or not either enforces it at the CLI-flag level.

    **Streams captured SEPARATELY (``merge_stderr=False``) — a live Codex review finding (P2) on
    this same PR.** A merged stdout+stderr stream (this module's own DEFAULT, still used by every
    OTHER lane) lets a harmless stderr diagnostic landing AFTER the JSON envelope defeat
    :func:`pantheon.verdict.extract_last_json`'s own trailing-scan, discarding a perfectly valid
    verdict — see :func:`_run`'s own docstring for the full finding and fix; this lane is the
    ONE caller that opts into the separated-stream path, since it's the only lane whose output is
    a single, machine-readable JSON envelope in the first place."""
    claude_bin = _resolve_cli("claude", repo_root)
    if claude_bin is None:
        raise ProviderError("'claude' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    tools = allowed_tools or default_allowed_tools(repo_root)
    argv = [claude_bin, "-p", prompt, "--allowedTools", tools, "--permission-mode", "dontAsk"]
    if model:
        argv += ["--model", model]
    argv += ["--output-format", "json", "--json-schema", VERDICT_JSON_SCHEMA]
    envelope = _run(argv, timeout=timeout, cwd=neutral_cwd, repo_root=repo_root, merge_stderr=False)
    return _extract_structured_output(envelope)


def _codex(
    model: str,
    prompt_file: str,
    allowed_tools: str,
    timeout: float | None,
    repo_root: str | None,
    neutral_cwd: str | None,
) -> str:
    """Provider lane: Codex CLI. Best-effort — mirrors the retired bash CLI's ``codex.sh``
    provider script's ``codex exec -`` invocation (removed in #29), prompt piped via stdin. No
    documented flag equivalent to the claude lane's
    ``--bare`` exists for this CLI as of this writing (researched against Codex's own official
    docs before landing this fix, not assumed) — this lane's own repo-local config/AGENTS.md
    auto-discovery is a disclosed, honest residual exposure the neutral ``cwd`` below narrows
    (nothing repo-local for it to discover in a scratch directory) but doesn't eliminate the way
    an explicit flag would; see this module's own docstring and DESIGN.md's "Security posture".

    ``--skip-git-repo-check`` — a P1 finding from a live Codex review on this PR: `codex exec`
    refuses to run at all outside a git repository unless this flag is passed (verified against
    `codex exec --help` and Codex CLI's own current docs — "Not inside a trusted directory and
    --skip-git-repo-check was not specified"). Since this lane now ALWAYS launches from the
    neutral scratch ``cwd`` (CRITICAL-1's own fix, deliberately never a git repository — see this
    module's own docstring), omitting this flag would silently break every codex-configured gate
    run, landing on UNVERIFIED for every PR rather than actually reviewing anything. The flag
    only bypasses codex's own non-interactive repository GUARD for this one invocation — it does
    not widen its sandbox, grant additional trust, or change anything this module's own
    PATH-filtering/env-allowlist/process-isolation controls."""
    codex_bin = _resolve_cli("codex", repo_root)
    if codex_bin is None:
        raise ProviderError("'codex' CLI not found on PATH")

    prompt = _read_prompt(prompt_file)
    argv = [codex_bin, "exec", "--skip-git-repo-check"]
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
    """Provider lane: Gemini CLI. Best-effort — mirrors the retired bash CLI's ``gemini.sh``
    provider script's ``gemini -p <prompt> [-m <model>]`` invocation (removed in #29). No
    documented flag equivalent to the claude lane's
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
    """Provider lane: Cursor CLI (``cursor-agent``). Best-effort — mirrors the retired bash
    CLI's ``cursor.sh`` provider script's ``cursor-agent -p <prompt> [--model <model>]``
    invocation (removed in #29). No documented flag equivalent to the claude lane's ``--bare``
    exists for this CLI as of this
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
    the CALLER's validation responsibility (``pantheon.cli``, mirroring the retired bash CLI's
    ``review-gate``'s own ``[[ -f "$PROVIDERS_DIR/$PROVIDER.sh" ]]`` check (removed in #29)
    before ever calling this — same order as
    bash: validated once, fast, before any network call). ``allowed_tools`` is consumed only by
    the ``claude`` lane (readonly-tier tool scoping — see :func:`_claude`); the other three ignore
    it, matching docs/CLI.md's disclosed "no readonly-tier tool restriction at all" gap for those
    lanes. ``repo_root``, when given (``pantheon.cli`` always passes its own resolved repo root),
    is used as an additional trusted root excluded from PATH resolution (see
    :func:`_filtered_path`) and threaded to the readonly-wrapper resolution helpers.

    ``neutral_cwd``, when given (``pantheon.cli`` always passes a scratch directory it created
    and owns), is the launched provider's own ``cwd`` — a CRITICAL fix (adversarial review): this
    used to be ``repo_root`` (mirroring the retired bash CLI's ``review-gate``'s own
    ``cd "$REPO_ROOT"`` posture, removed in #29),
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
