#!/usr/bin/env bash
# Provider lane: Cursor CLI (cursor-agent).
#
# Best-effort lane — verify against your installed CLI version; the gate fail-closes on any
# malformed output, so a misbehaving lane can never produce a false green.
#
# provider_run <model> <prompt_file>
#   Prints the agent's raw stdout. Returns nonzero on failure.
provider_run() {
  local model="$1"
  local prompt_file="$2"

  if ! command -v cursor-agent >/dev/null 2>&1; then
    echo "cursor.sh: 'cursor-agent' CLI not found on PATH" >&2
    return 1
  fi

  local -a args=(-p "$(cat "$prompt_file")")
  if [[ -n "$model" ]]; then
    args+=(--model "$model")
  fi

  cursor-agent "${args[@]}"
}
