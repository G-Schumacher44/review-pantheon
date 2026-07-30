#!/usr/bin/env bash
# Provider lane: Claude Code CLI.
#
# Default lane — the only provider lane integration-tested in v1. Runs the persona prompt
# through `claude -p` in non-interactive mode with a restricted, read-only tool set.
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

  local -a args=(-p "$(cat "$prompt_file")" --allowedTools "Read,Grep,Glob,Bash" --permission-mode default)
  if [[ -n "$model" ]]; then
    args+=(--model "$model")
  fi

  claude "${args[@]}"
}
