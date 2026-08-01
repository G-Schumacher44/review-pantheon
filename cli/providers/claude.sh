#!/usr/bin/env bash
# Provider lane: Claude Code CLI.
#
# Default lane — the only provider lane integration-tested in v1. Runs the persona prompt
# through `claude -p` in non-interactive mode with a tiered, execution-scoped tool set.
#
# provider_run <model> <prompt_file>
#   Prints the agent's raw stdout. Returns nonzero on failure. The caller (cli/review-gate)
#   is responsible for extracting and validating the trailing JSON verdict — this function
#   makes no assumption about output shape beyond "whatever the CLI printed."
provider_run() {
  local model="$1"
  local prompt_file="$2"

  if ! command -v claude >/dev/null 2>&1; then
    echo "claude.sh: 'claude' CLI not found on PATH" >&2
    return 1
  fi

  # PANTHEON_ALLOWED_TOOLS is computed and exported by cli/review-gate from gate.conf's
  # execution= / --execution (readonly default, trusted opt-in — see cli/lib/execution.sh and
  # DESIGN.md's "Security posture"). Falls back to the readonly tool set here too, so this
  # provider lane still fails safe (not open) when invoked directly, outside review-gate — routed
  # through the same argv-validating wrapper (cli/lib/pantheon-git-readonly.sh, resolved relative
  # to THIS file's own location, not review-gate's) rather than a bare `Bash(git diff *)`-style
  # prefix pattern, which can't tell a read-only git subcommand from the same subcommand carrying
  # a writing/execution-capable flag (`--output=`, `--ext-diff`) — see that script's own header
  # comment and cli/lib/execution.sh's for the finding this closes.
  local allowed_tools="${PANTHEON_ALLOWED_TOOLS:-}"
  if [[ -z "$allowed_tools" ]]; then
    local fallback_wrapper
    fallback_wrapper="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/pantheon-git-readonly.sh"
    allowed_tools="Read,Grep,Glob,Bash($fallback_wrapper *)"
  fi

  # --permission-mode dontAsk (not "default"): Claude Code's docs are explicit that `default`
  # mode only auto-approves reads without a prompt — everything else, including a tool call that
  # DOES match --allowedTools, still goes through a permission decision, and outside an
  # interactive terminal there is no one to answer it. `dontAsk` is documented as the mode "for
  # CI pipelines and scripts where you need the same result on every machine" / "locked-down CI
  # and scripts": it auto-denies anything not pre-approved and never waits for input. Empirically
  # confirmed the gap this closes: a live run using `default` mode (no explicit --permission-mode
  # at all, matching what action.yml had before this fix) let this wrapper's OWN invocation sit
  # unanswerable while Claude Code's separate, unconditional built-in "read-only forms of git"
  # allowance kept bare `git log`/`git diff` working regardless — see cli/lib/execution.sh's own
  # header comment for the fuller writeup (a real Apollo finding, from this PR's own self-review).
  local -a args=(-p "$(cat "$prompt_file")" --allowedTools "$allowed_tools" --permission-mode dontAsk)
  if [[ -n "$model" ]]; then
    args+=(--model "$model")
  fi

  claude "${args[@]}"
}
