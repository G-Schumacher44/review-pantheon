"""pantheon/execution.py — tiered tool-execution policy (readonly default, trusted opt-in) AND
the argv-validating read-only git call construction. Replaces the retired bash CLI's
``execution.sh`` AND ``pantheon-git-readonly.sh`` (removed in #29) — merged into one module
because in Python the tiering decision and the safe-call construction are the same structural
concern, not two files coordinating through a permission string.

Why this exists (ported unchanged from the bash originals' own rationale): every agent runs
against content that, on a fork PR, is 100% attacker-controlled. A blanket ``Bash`` tool set
turns "prompt injection steers the model" into "prompt injection runs an arbitrary shell
command". `readonly` (the default everywhere this repo invokes a provider) restricts Bash to a
read-only git wrapper so an agent literally cannot execute anything beyond inspecting the diff;
`trusted` restores full Bash and is an explicit, documented opt-in for own-repo/trusted-author
use only.

Bash v1's read-only tier works by *forcing* a list of flags and env vars onto every wrapped git
call and by refusing any argument that looks like a flag, because a prefix-matched
``Bash(git diff *)`` permission rule has no understanding of git's own argument grammar. Python
replaces that string-discipline with STRUCTURE: an argv **list** passed to
``subprocess.run(..., shell=False)`` is never re-interpreted by a shell at all, and every
subcommand's allowlist is enumerated in code (``READONLY_SUBCOMMANDS`` plus that subcommand's own
:data:`SAFE_FLAGS_FOR_SUBCOMMAND` entry) rather than pattern-matched. Note this is default-deny
but NOT "no caller flag ever reaches git": issue #26 replaced the original blanket flag refusal —
which made the tier unusable, since the personas are told to run ``git diff --stat`` and friends —
with a narrow, per-subcommand allowlist, so a fixed set of presentation flags (``--stat``,
``--name-only``, ``-U<n>``, ``--find-renames``, …) DOES pass through. See ARGV VALIDATION below for
the exact rule. That closes the whole class of prefix-match/flag-injection findings by
construction — it does not excuse skipping verification; every row below still needs its own
provable closure (tests/test-git-readonly-wrapper.sh, which targets this module via
``python -m pantheon.execution wrapper ...``).

ARGV VALIDATION (the caller's argv — build_readonly_argv()):
  - subcommand (argv[0]) must be exactly one of: diff, show, log, status.
  - every remaining argument is either a PLAIN VALUE (a ref, a path, a range like
    ``base...head`` — never ``-``-prefixed) or a flag on that subcommand's own SAFE-FLAG
    ALLOWLIST (:data:`SAFE_FLAGS_FOR_SUBCOMMAND` / :data:`_UNIFIED_CONTEXT_RE`) — issue #26: a
    blanket "no flags of any kind" rule closed every option-injection vector but also closed
    the feature itself (an agent reaching for ``--stat``/``--name-only``/``-U0``/``--oneline``
    got refused every time and gave up, emitting prose instead of a verdict). The allowlist is
    still DEFAULT-DENY — any ``-``-prefixed token not on the relevant subcommand's own set
    (``-c``, ``--exec*``, ``--output*``, ``--ext-diff``, ``--textconv``, ``--upload-pack``, and
    every other flag not enumerated) is refused exactly as before. The bare ``--`` pathspec
    separator is STILL never permitted from the caller, on any subcommand — the wrapper owns
    that boundary itself (see below); it is not, and can never become, an "allowed flag".
  - ``diff`` additionally requires its one positional argument to be a real revision range
    (``A..B`` or ``A...B``) where BOTH sides independently resolve via
    ``git rev-parse --verify --quiet <side>^{commit}`` — containing the substring ``..`` is
    necessary but not sufficient (a tracked path literally named ``foo..bar`` also contains it).
  - ``diff`` accepts EXACTLY ONE positional argument — no second positional, no pathspec, ever;
    the wrapper appends its OWN trailing ``--`` after the validated range on exec, so nothing
    caller-supplied can ever land in pathspec position (closes the Codex-round-2 "caller-supplied
    `--` shifts a validated range into pathspec position" finding structurally, not by a second
    special case for ``--``).

EXEC/WRITE-SURFACE MATRIX — mirrors the retired bash CLI's ``pantheon-git-readonly.sh`` (removed
in #29) own header table row for row. "PY" column names the exact mechanism in this module that
closes it.

  VECTOR                              NEUTRALIZED BY (bash)              PY (this module)
  -----------------------------------  ----------------------------------  --------------------------------
  diff.external / attribute-scoped     --no-ext-diff (forced flag)         build_readonly_argv(): appends
    diff.<d>.command                                                         "--no-ext-diff" for diff/show
  diff.<driver>.textconv               --no-textconv (same)                build_readonly_argv(): appends
                                                                              "--no-textconv" for diff/show
  filter.<name>.clean/smudge           diff restricted to a proper range   validate_diff_range(): a bare/
    (gitattributes clean filter)         (blob-to-blob never touches the     single-ref diff is refused
                                          working tree)                      outright (no working-tree form
                                                                              ever reaches real git)
  `..`-substring range spoofed by a    each side resolved via rev-parse    validate_diff_range()/
    same-named path                      --verify --quiet <side>^{commit}    _verify_commit(): real revspec
                                                                              check, not a substring test
  Caller-supplied `--` shifts a        caller can never supply `--`;       build_readonly_argv(): a bare
    validated range into pathspec       diff takes exactly one positional   '--' is refused for every
    position                                                                subcommand, unconditionally,
                                                                              before the safe-flag allowlist
                                                                              (issue #26) is even consulted;
                                                                              diff capped at
                                                                              len(positionals) == 1;
                                                                              wrapper's own trailing "--"
                                                                              appended on exec
  core.fsmonitor (hook pathname)       -c core.fsmonitor=false             GLOBAL_OVERRIDES tuple
  Optional index-lock write            GIT_OPTIONAL_LOCKS=0                _forced_env(): env["GIT_OPTIONAL_LOCKS"]="0"
  Partial-clone lazy fetch             GIT_NO_LAZY_FETCH=1 (forced env)    _forced_env(): env["GIT_NO_LAZY_FETCH"]="1"
  core.pager / $PAGER                  GIT_PAGER=cat, PAGER=cat,           _forced_env(): GIT_PAGER/PAGER;
                                          -c core.pager=cat                  GLOBAL_OVERRIDES: core.pager=cat
  core.editor / $EDITOR                GIT_EDITOR=true,                    _forced_env(): GIT_EDITOR/
                                          GIT_SEQUENCE_EDITOR=true,           GIT_SEQUENCE_EDITOR;
                                          -c core.editor=true                 GLOBAL_OVERRIDES: core.editor=true
  log.showSignature + gpg.program      -c log.showSignature=false          GLOBAL_OVERRIDES tuple
  GIT_TRACE and siblings               unset (trace-output-sink vars)      _forced_env(): never populated —
                                                                              built from scratch, so absence
                                                                              IS the closure (see below)
  GIT_REDIRECT_STDOUT/STDERR           unset (Windows-only sink, same     _forced_env(): never populated,
                                          class as GIT_TRACE*)                same reasoning
  core.hooksPath (standard hooks)      -c core.hooksPath=/dev/null         GLOBAL_OVERRIDES tuple
  gc.auto / maintenance.auto           -c gc.auto=0 -c maintenance.auto=false GLOBAL_OVERRIDES tuple
  GIT_CONFIG / GIT_CONFIG_PARAMETERS   unset (closes GIT_CONFIG_COUNT/     _forced_env(): env is built key
    / GIT_CONFIG_COUNT                   KEY_<n>/VALUE_<n> mechanism too)    -by-key from an empty dict —
                                                                              none of these keys are ever
                                                                              copied from os.environ, so the
                                                                              whole numbered-config-injection
                                                                              mechanism is unreachable by
                                                                              construction, not by an unset
                                                                              statement enumerating each name

  Every row's "PY" column boils down to one structural fact: ``_forced_env()`` builds the
  subprocess environment as a **new dict containing only the keys this module explicitly sets**
  — PATH is pinned to :data:`TRUSTED_GIT_DIRS` and HOME is pinned via :func:`real_home_dir`
  (the passwd-database account home, never the ambient ``HOME`` env var — a Codex finding fixed
  this after an earlier version of this comment called HOME a safely-forwardable ambient value;
  it isn't, once a launcher environment can set it, the same class of hijack
  :func:`_default_user_scripts_dir` was independently fixed for). Nothing from ``os.environ`` is
  passed through implicitly, PATH and HOME included. Bash's
  ``unset FOO`` and Python's "never put FOO in the dict" are the same closure; the Python version
  additionally closes any FUTURE trace/redirect/config-injection variable git's docs might add
  later, since the default posture is "absent unless this module put it there", not "present
  unless explicitly unset".

NOT REACHABLE — same reasoning as the retired bash CLI's ``pantheon-git-readonly.sh`` (removed in
#29; see its own "NOT REACHABLE" section): core.sshCommand/credential.helper/protocol.*.allow (no
networked subcommand on the allowlist), difftool.*/merge.tool (separate subcommands, not
allowlisted), git aliases (require pre-existing local/global config write access this wrapper
does not grant).

What this does NOT claim to fix: same disclosure as the bash wrapper's own header — this module
closes every git-side vector above; it says nothing about how the CALLER (a persona-driving CLI)
enforces that this is the only code path capable of running a subprocess at all. That is the
CLI's own ``--allowedTools``/``--permission-mode`` wiring, landing in ``cli.py``.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import sysconfig
from collections.abc import Sequence

try:
    import pwd  # POSIX only — absent on Windows, guarded below, never assumed present.
except ImportError:  # pragma: no cover — no Windows CI leg in this port's own test matrix.
    pwd = None  # type: ignore[assignment]

__all__ = [
    "WrapperRefused",
    "READONLY_SUBCOMMANDS",
    "SAFE_FLAGS_FOR_SUBCOMMAND",
    "GLOBAL_OVERRIDES",
    "run_git",
    "build_readonly_argv",
    "run_readonly_wrapper",
    "allowed_tools_for",
    "validate_execution",
    "execution_context_note",
    "resolve_console_script",
    "real_home_dir",
    "main",
]


class WrapperRefused(Exception):
    """Raised on any fail-closed refusal — the Python equivalent of the bash wrapper's
    ``die()``/``exit 1``. Every call site that can refuse (build_readonly_argv,
    validate_diff_range, run_git's executable lookup) raises this, never returns a sentinel, so a
    caller cannot forget to check a return value and silently proceed on a refusal.
    """


# subcommand (argv[0]) must be exactly one of these four — DESIGN.md rule 1's own set, unchanged
# from the retired bash CLI's ``pantheon-git-readonly.sh`` case statement (removed in #29).
READONLY_SUBCOMMANDS: tuple[str, ...] = ("diff", "show", "log", "status")

# --------------------------------------------------------------------------------------------
# Per-subcommand safe-flag allowlist (issue #26) — every flag here is READ-ONLY (no
# write/exec/config surface of its own; each one only changes how the ALREADY-restricted diff/
# log/status output is FORMATTED) and is a flag agents genuinely reach for when reviewing a
# diff. Anything not listed here is refused exactly like before — this widens the allowlist, it
# does not relax the "no flag reaches real git unless this module names it" default-deny
# posture. Every existing attack fixture in tests/test-git-readonly-wrapper.sh stays refused
# (none of the historically-refused flags — -c, --exec-path, --output=, --ext-diff, --textconv,
# --pager=, --upload-pack, ... — are added to any set below).
#
# Flags shared by every diff-shaped subcommand (diff/show/log all print a diff body): pure
# output-formatting toggles, nothing that spawns a helper, writes a file, or touches config.
_DIFFSTAT_FLAGS: frozenset[str] = frozenset(
    {
        "--stat",  # summary of insertions/deletions per file
        "--numstat",  # machine-readable version of --stat
        "--name-only",  # changed paths only
        "--name-status",  # changed paths + A/M/D status
        "--no-color",  # disables ANSI color codes (never a write/exec surface)
        "--find-renames",  # rename detection heuristic — read-only, no external helper
    }
)

# -U<n> / --unified=<n> (context-line count) — value is BAKED INTO the flag token itself (never
# a separate argv slot), so there is no "is the next token the value or a new positional"
# ambiguity for build_readonly_argv() to resolve; validated the same way every other single-
# purpose refusal in this module is, by regex, not by consuming an adjacent argv slot.
_UNIFIED_CONTEXT_RE = re.compile(r"^-U\d+$|^--unified=\d+$")

SAFE_FLAGS_FOR_SUBCOMMAND: dict[str, frozenset[str]] = {
    "diff": _DIFFSTAT_FLAGS,
    "show": _DIFFSTAT_FLAGS,
    "log": _DIFFSTAT_FLAGS | frozenset({"--oneline"}),
    # NOT "--no-color": a self-hosted-gate finding (Artemis, live) caught that real `git status`
    # has no such flag at all -- verified live, `git status --no-color` -> `error: unknown
    # option 'no-color'` (exit 129). Never needed anyway: this wrapper's own git subprocess has
    # no controlling TTY (subprocess.run, no PAGER-interactive session), and git already
    # auto-detects a non-TTY stdout and disables color output on its own for every subcommand.
    "status": frozenset({"--short", "-s", "--porcelain"}),
}

# Subcommands whose diff body -U<n>/--unified=<n> is meaningful ("show" and "log" both print a
# diff body when the underlying commit has one; "status" never prints a diff body at all).
_UNIFIED_CONTEXT_SUBCOMMANDS: frozenset[str] = frozenset({"diff", "show", "log"})


def _is_safe_flag(subcommand: str, arg: str) -> bool:
    """True if `arg` (already known to be `-`-prefixed) is on `subcommand`'s own safe-flag
    allowlist above. The caller-supplied bare `--` pathspec separator is deliberately NEVER
    matched here — see build_readonly_argv()'s own handling of it, which refuses it before this
    function is ever consulted."""
    if arg in SAFE_FLAGS_FOR_SUBCOMMAND.get(subcommand, frozenset()):
        return True
    return subcommand in _UNIFIED_CONTEXT_SUBCOMMANDS and bool(_UNIFIED_CONTEXT_RE.match(arg))


# GLOBAL_OVERRIDES are ``-c key=value`` pairs THIS MODULE writes and controls itself — distinct
# from the caller's argv (which build_readonly_argv() has already rejected any '-'-prefixed
# token from). Applied to every subcommand, not scoped to any one — fsmonitor/hooksPath/pager/
# editor/signature-verification/maintenance are all properties of the repository scan or git's
# own startup, not of any one subcommand. Mirrors the retired bash CLI's
# ``pantheon-git-readonly.sh`` GLOBAL_OVERRIDES array line for line (removed in #29).
#
# `-c diff.external=` (an empty value) was tested and REJECTED in the bash original: git
# interprets an empty diff.external as "run a program named nothing", which errors out and
# breaks diff entirely rather than disabling it. --no-ext-diff (forced in build_readonly_argv())
# already fully covers that config key on its own, so no `-c` override for it is used here either.
GLOBAL_OVERRIDES: tuple[str, ...] = (
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.pager=cat",
    "-c",
    "core.editor=true",
    "-c",
    "log.showSignature=false",
    "-c",
    "gc.auto=0",
    "-c",
    "maintenance.auto=false",
)

# TRUSTED_GIT_DIRS — the ONLY directories `git` is ever resolved from. NOT the ambient PATH, in
# any form. Codex fresh-evidence P1 (round 2 on this same finding): even after restricting
# lookup to ABSOLUTE PATH entries, PATH itself can still name a directory INSIDE the untrusted
# checkout (e.g. `PATH=$PWD/bin:/usr/bin` with a PR-committed `bin/git` executable) — the
# wrapper's cwd is the checked-out PR's own tree for every persona-facing invocation, so
# "absolute" alone is not "trusted". Fixed by never consulting PATH (ambient or otherwise) for
# this lookup at all: a fixed, hardcoded list of system directories a PR's own tracked content
# can never write to, first-existing-and-executable wins. No config knob to widen this list —
# adding one would just relocate the same trust decision to yet another attacker-reachable input
# (gate.conf is itself base-pinned for exactly this reason elsewhere in this repo).
TRUSTED_GIT_DIRS: tuple[str, ...] = (
    "/usr/bin",
    "/bin",
    "/usr/local/bin",
    "/opt/homebrew/bin",
)

_git_executable_cache: str | None = None


def _forced_env() -> dict[str, str]:
    """Builds the constructed-clean subprocess environment from scratch — see this module's
    docstring EXEC/WRITE-SURFACE MATRIX for the full row-by-row mapping. Never returns
    ``os.environ`` or a copy of it; every key present is explicitly set here. PATH is pinned to
    TRUSTED_GIT_DIRS (never the ambient PATH) so a child process git itself spawns (there are
    none on the readonly allowlist today, but this is the same "never inherit, always construct"
    posture as every other key here) inherits nothing attacker-reachable either.

    Explicitly force-clears the whole Python-interpreter-redirection env family
    (``PYTHONUSERBASE``/``PYTHONPATH``/``PYTHONHOME``/``PYTHONSTARTUP``, plus
    ``PYTHONNOUSERSITE=1`` set defensively) — a Codex review finding on this port's own PR,
    companion to :func:`resolve_console_script`'s own fix: even though this dict is already
    constructed fresh (never an ``os.environ`` copy, so these keys are already ABSENT rather
    than forwarded), any downstream Python process this git invocation's own children might
    spawn should never be able to fall back to inheriting one of these from further up an
    ambient parent chain either. Absent-by-omission and explicitly-cleared read the same to a
    child that just reads its own environ, but this way the guarantee doesn't depend on every
    future maintainer remembering to keep these off the allowlist.

    ``HOME`` is pinned via :func:`real_home_dir` (the passwd-database account home), never the
    ambient ``os.environ.get("HOME")`` — a second-round Codex finding on this same PR, same
    "never trust an env-derived HOME" principle :func:`_default_user_scripts_dir` was fixed for:
    forwarding a hijacked ambient ``HOME`` into this constructed env would let a hostile
    launcher point git's own config resolution at an attacker-controlled ``~/.gitconfig``, the
    identical class of injection this module's ``GLOBAL_OVERRIDES``/forced-env posture exists to
    close everywhere else."""
    env: dict[str, str] = {}
    env["PATH"] = os.pathsep.join(TRUSTED_GIT_DIRS)
    home = real_home_dir()
    if home:
        env["HOME"] = home
    env["GIT_PAGER"] = "cat"
    env["PAGER"] = "cat"
    env["GIT_EDITOR"] = "true"
    env["GIT_SEQUENCE_EDITOR"] = "true"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_NO_LAZY_FETCH"] = "1"
    env["PYTHONUSERBASE"] = ""
    env["PYTHONPATH"] = ""
    env["PYTHONHOME"] = ""
    env["PYTHONSTARTUP"] = ""
    env["PYTHONNOUSERSITE"] = "1"
    return env


def _git_executable() -> str:
    """Resolves the real `git` binary from TRUSTED_GIT_DIRS ONLY — never from PATH, ambient or
    otherwise (see that tuple's own comment for why "absolute" is not the same bar as "trusted").
    Resolved once and memoized (module-level cache, populated lazily on first use rather than at
    import time, so importing this module doesn't require git to be present) — every subsequent
    call and every subprocess invocation in this module uses the SAME absolute path, not a fresh
    lookup that could be raced or influenced between calls.
    """
    global _git_executable_cache
    if _git_executable_cache is not None:
        return _git_executable_cache

    for directory in TRUSTED_GIT_DIRS:
        candidate = os.path.join(directory, "git")
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            _git_executable_cache = candidate
            return candidate

    raise WrapperRefused(
        "git executable not found in any trusted directory ("
        + ", ".join(TRUSTED_GIT_DIRS)
        + ") — the ambient PATH is never consulted for this lookup"
    )


def run_git(
    args: Sequence[str],
    cwd: str | None = None,
    timeout: float | None = None,
) -> subprocess.CompletedProcess:
    """Low-level, TRUSTED git invocation core: constructs the clean env (_forced_env()) and
    prepends GLOBAL_OVERRIDES to every call. Shared by the persona-facing
    ``run_readonly_wrapper()`` below AND by ``pantheon.basepin``'s own trusted plumbing
    (``git ls-tree`` / ``git show``) — see basepin.py's module docstring for why base-pinned
    reads go through this shared hardened core rather than through the argv-validating
    ``run_readonly_wrapper()`` (``ls-tree`` is not on the four-subcommand allowlist at all, and
    basepin.py is trusted CLI-internal code, not the persona-facing Bash-tool surface this
    wrapper's argv gate exists to constrain).
    """
    argv = [_git_executable(), *GLOBAL_OVERRIDES, *args]
    return subprocess.run(
        argv,
        cwd=cwd,
        env=_forced_env(),
        shell=False,
        capture_output=True,
        timeout=timeout,
    )


def _verify_commit(side: str, cwd: str | None) -> bool:
    # Belt-and-braces, same as the bash original: a side beginning with '-' can never be a legal
    # ref name, so refuse it outright rather than ever handing an attacker-controlled,
    # dash-prefixed string to `git rev-parse` as an argument.
    if side.startswith("-"):
        return False
    result = run_git(
        ["rev-parse", "--verify", "--quiet", f"{side}^{{commit}}"],
        cwd=cwd,
    )
    return result.returncode == 0


def validate_diff_range(args: Sequence[str], cwd: str | None = None) -> str:
    """Structural range verification for ``diff``'s one positional argument — mirrors
    the retired bash CLI's ``pantheon-git-readonly.sh`` diff-range block line for line (removed
    in #29). Returns the validated
    range string on success; raises WrapperRefused otherwise. Never a substring/pattern check:
    each side is independently confirmed to be a real commit via
    ``git rev-parse --verify --quiet <side>^{commit}`` before diff is ever allowed to run.
    """
    if len(args) != 1:
        raise WrapperRefused(
            "diff takes EXACTLY one argument — a revision range like 'base...head' — got "
            f"{len(args)} (this wrapper does not accept a second positional argument or a "
            "pathspec on diff, regardless of a '..'-containing first argument)"
        )

    first = args[0]
    range_left = range_right = ""
    if "..." in first:
        range_left, _, range_right = first.partition("...")
    elif ".." in first:
        range_left, _, range_right = first.partition("..")

    if not range_left or not range_right:
        raise WrapperRefused(
            "diff requires a range argument containing '..' or '...' (e.g. 'base...head') — a "
            "bare 'diff', a single ref, or a bare path compares against the working tree, which "
            "this wrapper does not allow (working-tree comparisons can trigger a configured "
            "clean/smudge filter)"
        )

    for side in (range_left, range_right):
        if not _verify_commit(side, cwd):
            raise WrapperRefused(
                f"diff range argument '{first}' does not resolve to two real commits ('{side}' "
                "failed 'git rev-parse --verify --quiet') — this wrapper requires a genuine "
                "revision range, not a working-tree path or pathspec that merely contains '..'"
            )

    return first


def build_readonly_argv(argv: Sequence[str], cwd: str | None = None) -> list[str]:
    """Validates the caller's FULL argv (the model's own typed command) per the
    EXEC/WRITE-SURFACE MATRIX in this module's docstring, and returns the argv to hand to
    ``run_git()`` for the real invocation (excluding the git binary and GLOBAL_OVERRIDES — those
    are ``run_git``'s job). Raises WrapperRefused on any refusal.

    Every ``-``-prefixed token is split into two buckets: a POSITIONAL never starts with ``-``
    (a ref, a path, a range) and a FLAG must be on ``subcommand``'s own safe-flag allowlist
    (:func:`_is_safe_flag`, issue #26) — anything ``-``-prefixed that ISN'T on that allowlist is
    refused exactly like the pre-#26 "no flags at all" behavior, including the caller-supplied
    bare ``--`` pathspec separator, which is refused UNCONDITIONALLY, on every subcommand, before
    the allowlist check even runs (the wrapper owns the ``--`` boundary itself — see the module
    docstring's "Caller-supplied `--`" matrix row; it is not, and can never become, an "allowed
    flag" the way ``--stat``/``-U<n>`` now are).
    """
    if not argv:
        raise WrapperRefused("no subcommand given (expected one of: diff, show, log, status)")

    subcommand, *rest = argv

    if subcommand not in READONLY_SUBCOMMANDS:
        raise WrapperRefused(f"subcommand '{subcommand}' is not on the read-only allowlist (diff, show, log, status)")

    flags: list[str] = []
    positionals: list[str] = []
    for arg in rest:
        if arg == "--":
            raise WrapperRefused(
                "the '--' pathspec separator is never permitted from the caller, on any "
                "subcommand — the wrapper owns the '--' boundary itself"
            )
        if arg.startswith("-"):
            if _is_safe_flag(subcommand, arg):
                flags.append(arg)
                continue
            raise WrapperRefused(
                f"argument '{arg}' is not on the safe-flag allowlist for '{subcommand}' (see "
                "SAFE_FLAGS_FOR_SUBCOMMAND) — this wrapper allows plain refs/paths/ranges plus "
                "a fixed set of read-only formatting flags only, and no caller-supplied '--' "
                "pathspec separator either"
            )
        positionals.append(arg)

    if subcommand == "diff":
        validated_range = validate_diff_range(positionals, cwd=cwd)
        # The wrapper's OWN trailing '--', never a caller-influenced one — see the module
        # docstring's "Caller-supplied `--`" matrix row.
        return ["diff", *flags, "--no-ext-diff", "--no-textconv", validated_range, "--"]

    if subcommand == "show":
        return ["show", *flags, "--no-ext-diff", "--no-textconv", *positionals]

    if subcommand == "log":
        # Codex review finding (P1) on this PR's own safe-flag allowlist: `-U<n>`/`--unified=<n>`
        # on `log` git's own docs say IMPLIES `--patch` — so allowing it here makes `log` a
        # SECOND diff-producing subcommand, alongside `diff`/`show`, that needed the identical
        # `--no-ext-diff`/`--no-textconv` forcing those two already get; `log` was missing it
        # entirely pre-fix. Verified live before landing this fix: a two-commit repo with
        # `*.evil diff=pwn` + a configured `diff.pwn.textconv` fires the configured helper via
        # `log -U0 HEAD~1..HEAD` on the pre-fix wrapper. Forced unconditionally (not only when a
        # unified-context flag is present) — harmless no-op for a `log` call that never produces
        # a patch body at all, matching `diff`/`show`'s own unconditional forcing.
        return ["log", *flags, "--no-ext-diff", "--no-textconv", *positionals]

    return [subcommand, *flags, *positionals]


def run_readonly_wrapper(argv: Sequence[str], cwd: str | None = None) -> subprocess.CompletedProcess:
    """The persona-facing entry point — the Python equivalent of the retired bash CLI's whole
    ``pantheon-git-readonly.sh "$@"`` body (removed in #29). Validates argv, then runs the real
    git call through the same hardened core basepin.py uses.
    """
    built = build_readonly_argv(argv, cwd=cwd)
    return run_git(built, cwd=cwd)


# ---------------------------------------------------------------------------------------------
# Tier resolution — replaces the retired bash CLI's ``execution.sh`` three functions (removed in
# #29). Names and semantics kept
# identical (pantheon_allowed_tools_for -> allowed_tools_for, etc.) modulo the pantheon_ prefix,
# which Python's module namespace already provides (``execution.allowed_tools_for``).
# ---------------------------------------------------------------------------------------------


def allowed_tools_for(tier: str, wrapper_path: str = "") -> str:
    """Prints (returns) the --allowedTools value for <tier>. <wrapper_path> is ignored for
    "trusted" (full Bash needs no wrapper). Mirrors the retired bash CLI's ``execution.sh``
    pantheon_allowed_tools_for byte for byte (removed in #29), including its fail-safe
    fallback: any tier that is not literally "trusted" resolves to the readonly-shaped value —
    this function is only ever called after validate_execution() has already rejected an
    unrecognized value, so in practice this only ever sees "readonly", but a caller that skips
    validation still fails safe (read-only), not open.
    """
    if tier == "trusted":
        return "Read,Grep,Glob,Bash"
    return f"Read,Grep,Glob,Bash({wrapper_path} *)"


def validate_execution(value: str) -> bool:
    """True if <value> is "readonly" or "trusted", False otherwise. Mirrors the retired bash
    CLI's ``execution.sh`` pantheon_validate_execution exactly (removed in #29; case-sensitive,
    exact match — "READONLY", "Trusted", "readonly " (trailing space), and "read-only" are all
    rejected).
    """
    return value in ("readonly", "trusted")


def execution_context_note(tier: str, wrapper_path: str) -> str:
    """Prints (returns) a run-context note telling the agent HOW to reach read-only git this run
    (or "" for "trusted", which needs no substitute instruction). Mirrors the retired bash CLI's
    ``execution.sh`` pantheon_execution_context_note's wording exactly (removed in #29), including
    the trailing newline the bash heredoc produces.
    """
    if tier == "trusted":
        return ""
    return (
        "- Execution: readonly — Bash is restricted to a read-only git wrapper this run, not "
        "raw `git`.\n"
        f"  Use `{wrapper_path} diff|show|log|status <plain refs/paths/ranges>` in place of\n"
        "  `git diff|show|log|status` (e.g. "
        f"`{wrapper_path} diff <range>`, `{wrapper_path} show <ref>:<path>`).\n"
        "  A small set of read-only formatting flags is also allowed, e.g. "
        f"`{wrapper_path} diff --stat <range>`,\n"
        f"  `{wrapper_path} diff --name-only <range>`, `{wrapper_path} diff -U0 <range>`, "
        f"`{wrapper_path} log --oneline`,\n"
        f"  `{wrapper_path} status --short` — every OTHER flag, and any other subcommand, is "
        "refused, so this is\n"
        "  the only Bash invocation available. No other command execution is possible this "
        "run.\n"
    )


def real_home_dir() -> str | None:
    """The REAL account home directory for the process's current UID, resolved via the POSIX
    passwd database (``pwd.getpwuid(os.getuid()).pw_dir``) — NEVER via
    ``os.path.expanduser("~")`` or any other mechanism that reads the ``HOME`` environment
    variable. Codex review finding on this port's own PR (a second round on issue #21 P1's own
    fix, live in the same file): ``os.path.expanduser("~")`` on POSIX reads ``HOME`` FIRST,
    falling back to the passwd database only when ``HOME`` is unset — a launcher environment
    that can set ``HOME`` (a repo-local ``.envrc``/environment loader is the disclosed vector,
    but any mechanism that lets a hostile checkout influence the parent process's environment
    before this CLI runs qualifies) could point it AT a directory inside that same hostile
    checkout, letting a PR-committed ``<hijacked-HOME>/.local/bin/pantheon-git-readonly`` be
    resolved by :func:`_default_user_scripts_dir` below and then trusted as the SOLE allowed
    Bash-tool prefix for the readonly execution tier — recreating exactly the class of hole the
    already-removed ``PYTHONUSERBASE`` lookup was closed for, just one environment variable over.
    ``pwd.getpwuid(os.getuid()).pw_dir`` is a kernel/system-level fact about the CURRENT
    PROCESS's real UID — it is not read from, and cannot be redirected by, any environment
    variable, matching :data:`TRUSTED_GIT_DIRS`'s own "fixed, not attacker-redirectable" posture.
    Also used by :func:`_forced_env` to pin the ``HOME`` this module's own git subprocess calls
    receive, for the identical reason — never the ambient (potentially hijacked) ``HOME``.

    **Public (not ``_``-prefixed) specifically so ``pantheon.providers`` can reuse it too**
    (adversarial review, round 6, Codex P1 — reopened CRITICAL-1 through a DIFFERENT door: a
    provider CLI's own env, not its cwd). ``pantheon.providers._provider_env()`` used to forward
    the ambient ``HOME`` straight to every provider-CLI subprocess — the identical hijack class
    this function was built to close for the readonly git wrapper, just never applied to the
    broader provider-CLI env construction. Both call sites now share this ONE resolution instead
    of each carrying its own copy of the same security-critical logic.

    Returns ``None`` (never raises, never falls back to ``os.path.expanduser``) when this lookup
    itself fails — no ``pwd`` module (Windows), or no passwd entry for this UID (some minimal/
    scratch container users) — rather than silently degrading to a weaker resolution."""
    if pwd is None:
        return None
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except (KeyError, OSError):
        return None


def _default_user_scripts_dir() -> str | None:
    """Computes the DEFAULT ``pip install --user`` console-script directory (issue #21 P1, the
    same "no config knob to widen this list" posture applied to the ``--user`` layout) —
    WITHOUT reading ``PYTHONUSERBASE``, ``HOME``, or any other environment
    variable naming a filesystem location, to compute it. This is Python's own DEFAULT per-user
    base formula, replicated by hand from a value this process cannot have redirected:
    :func:`real_home_dir` (the passwd-database account home — see that function's own docstring
    for why ``os.path.expanduser("~")``/``HOME`` are never trusted for this, a second-round
    Codex finding on this same fix).

    History: an EARLIER version of :func:`resolve_console_script` consulted
    ``sysconfig.get_path("scripts", scheme=f"{os.name}_user")`` directly to support
    ``pip install --user`` — a Codex review finding caught that this resolves through
    ``PYTHONUSERBASE``, an ordinary env var a hostile launcher can point AT a checked-out PR's
    own tree, so that lookup was removed outright (see git history / this module's own past
    revisions). Issue #21 P1 (slice 5): removing the lookup left EVERY real ``pip install --user``
    layout unresolved, and the caller's own fallback (``python -m pantheon.execution wrapper``,
    invoked with a hostile checkout as cwd) reopens the exact ``-m``-prepends-cwd-to-sys.path
    shadow vector ``resolve_console_script``'s own adjacent-only check exists to close — "fall
    back to the unsafe form" is not an acceptable resolution for a layout `pipx`/`pip --user`
    make real. This function closes that the same way :data:`TRUSTED_GIT_DIRS` closes the
    analogous git-lookup problem: compute the trusted location from a FIXED formula the
    environment cannot move, rather than either trusting an attacker-influenced env var or
    silently degrading to a weaker code path. The FIRST version of this fix used
    ``os.path.expanduser("~")`` for the "fixed formula" — itself still HOME-env-influenced, a
    second Codex finding on this same PR; :func:`real_home_dir` closes that too.

    ``sysconfig.get_config_var("PYTHONFRAMEWORK")`` (used below to detect a macOS
    python.org/Apple framework build, whose per-user base is ``~/Library/Python/X.Y`` instead of
    ``~/.local``) is a BUILD-TIME constant compiled into this interpreter — not the
    environment-configurable ``sysconfig.get_path(..., scheme=..._user)`` call the vulnerability
    above was about — so consulting it here does not reopen that hole (also verified structurally
    by tests/test_execution.py's ``test_never_consults_sysconfig_get_path`` fixture, which patches
    ``sysconfig.get_path`` — not ``get_config_var`` — to fail loud if ever called).

    Returns ``None`` on a platform/account shape this port does not special-case (Windows; or a
    UID with no resolvable passwd-database home) — :func:`resolve_console_script`'s
    adjacent-only check is the only lookup performed in that case, same as before this fix."""
    if os.name != "posix":
        return None
    home = real_home_dir()
    if not home:
        return None
    if sys.platform == "darwin" and sysconfig.get_config_var("PYTHONFRAMEWORK"):
        return os.path.join(home, "Library", "Python", f"{sys.version_info.major}.{sys.version_info.minor}")
    return os.path.join(home, ".local")


def resolve_console_script(name: str) -> str | None:
    """Resolves an installed console script's own absolute path. Checks TWO fixed locations, in
    order, both immune to environment redirection:

      1. ``os.path.dirname(sys.executable)`` — where a venv's, `pipx`'s, or an ordinary
         system-wide install's console scripts land, alongside ``python``/``pip``/``pantheon``
         themselves. The same resolution discipline :data:`TRUSTED_GIT_DIRS`/
         :func:`_git_executable` already use for ``git`` itself: a location fixed by how THIS
         interpreter process was launched, never anything derived from the live environment.
      2. :func:`_default_user_scripts_dir`'s ``bin`` subdirectory — the DEFAULT ``pip install
         --user`` console-script location (issue #21 P1), computed from HOME by a fixed formula
         that never reads ``PYTHONUSERBASE`` — see that function's own docstring for the full
         "resolve safely, don't fail open OR silently degrade" rationale and the vulnerability
         history it fixes.

    Shared by ``pantheon.cli``'s ``_wrapper_invocation()`` and ``pantheon.providers``'
    ``default_allowed_tools()`` — both resolve the readonly execution tier's own
    ``pantheon-git-readonly`` console script this way (see ``pyproject.toml``'s
    ``[project.scripts]`` entry).

    An operator who has set a NON-default ``PYTHONUSERBASE`` (a real, legitimate customization)
    is not covered by check 2 above — that stays an explicit, narrower miss than the
    vulnerability this function refuses to reopen; a caller's own fallback path (loud warning,
    weaker guarantee) still applies to that edge case, same as to a genuine dev-checkout/no-install
    case. Returns ``None`` (never raises) when not found at either location, so a caller can
    decide its own fallback rather than this function guessing one."""
    candidate = os.path.join(os.path.dirname(sys.executable), name)
    if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
        return candidate
    user_base = _default_user_scripts_dir()
    if user_base is not None:
        candidate = os.path.join(user_base, "bin", name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


# ---------------------------------------------------------------------------------------------
# CLI — exists purely to give tests/test-git-readonly-wrapper.sh a black-box subprocess target
# with the exact same shape as the retired bash wrapper script (removed in #29):
# ``python -m pantheon.execution wrapper <subcommand> [args...]`` behaves like
# ``pantheon-git-readonly.sh <subcommand> [args...]`` — same "pantheon-git-readonly: <reason>"
# refusal prefix on stderr, same exit codes, same passthrough of the real git call's stdout/
# stderr/exit code on success.
# ---------------------------------------------------------------------------------------------


def _wrapper_cli(argv: list[str]) -> int:
    """Parses an OPTIONAL leading ``--repo-root <path>`` (a CRITICAL fix, adversarial review)
    before handing the rest of ``argv`` to :func:`build_readonly_argv`'s own four-subcommand
    validation — ``--repo-root`` is a WRAPPER-LEVEL option, never a git subcommand argument, so
    it must be stripped here rather than reaching that validation (which refuses ANY
    ``-``-prefixed token uniformly, including this one).

    Why this exists: ``pantheon.cli``'s ``_wrapper_invocation()`` now bakes the caller's real
    repo root into the wrapper invocation string it embeds as the ONE allowed Bash-tool prefix
    (``Bash(<script> wrapper --repo-root <repo_root> *)``) — provider processes no longer launch
    with the repo checkout as their own cwd (see ``pantheon.providers``' own docstring for the
    config/MCP/hooks auto-discovery vector that closes), so :func:`os.getcwd` alone is no longer
    a reliable way for THIS process to learn where the repo actually is when a Bash-tool child of
    that provider invokes it. When ``--repo-root`` is given, it wins outright; when absent
    (direct CLI/test use — ``tests/test-git-readonly-wrapper.sh``'s own invocation shape, which
    predates and is unaffected by this fix), this falls back to :func:`os.getcwd`, unchanged."""
    cwd = os.getcwd()
    if len(argv) >= 2 and argv[0] == "--repo-root":
        cwd = argv[1]
        argv = argv[2:]
    try:
        result = run_readonly_wrapper(argv, cwd=cwd)
    except WrapperRefused as exc:
        print(f"pantheon-git-readonly: {exc}", file=sys.stderr)
        return 1
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "wrapper":
        return _wrapper_cli(argv[1:])
    print(
        "usage: python -m pantheon.execution wrapper [--repo-root <path>] <diff|show|log|status> [args...]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
