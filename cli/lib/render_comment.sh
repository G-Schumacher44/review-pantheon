#!/usr/bin/env bash
# cli/lib/render_comment.sh — the ONE combined-PR-comment renderer, shared by both runtimes.
#
# Before this file existed, review-pantheon rendered its combined comment twice: once in
# action/lib/combine_verdicts.sh (the published composite action, action.yml) and once inline
# in cli/review-gate (the CLI lane). Both built the same headline/table/folded-findings shape,
# but as two hand-synced copies. This file collapses that to one implementation — sourced
# directly by cli/review-gate (same directory) and by action/lib/combine_verdicts.sh via a
# relative path into the action checkout (`../../cli/lib/render_comment.sh` from action/lib/ —
# safe because the published action ships this whole repo at `github.action_path`, unlike
# bootstrap.sh's CLI-only install footprint). action/review.yml (the vendored, install.sh-Way-A
# workflow) is the one render path that still can't source this file — a target repo installs
# only the workflow YAML, decide_verdict.py, and personas, never cli/lib/ (see DESIGN.md's
# "Published action" section) — so its inline comment-building step stays a hand-synced third
# copy by necessity, same as before this change; keep it in wording sync by hand if the format
# here changes.
#
# Requires: bash (3.2+, no associative arrays / bash4-only features — macOS stock bash must
# work), jq (present on every environment this runs in: cli/review-gate already hard-requires
# it, and GitHub-hosted ubuntu-latest runners ship it standard).
#
# Contract: per agent NAME (upper-cased for the env var lookup), reads:
#   <NAME>_COLOR      - green|yellow|red|unverified (caller must normalize; never left empty)
#   <NAME>_VERDICT    - the reported verdict word (SHIP, FIX_FIRST, SKIPPED, UNVERIFIED, ...)
#   <NAME>_TOP        - fallback human text for the table's "top finding" cell and the
#                       per-agent narrative when no findings/summary are available (e.g. "agent
#                       did not run", "docs-only diff: apollo skipped by design")
#   <NAME>_FINDINGS   - the full verdict JSON object (has .summary, .findings[], etc), or "{}"
#   <NAME>_INVARIANT  - "true"/"false" — did the blocker invariant force this color to red?
#                       (defaults to "false" if unset)
#   <NAME>_REASON     - why, if invariant fired (the exact reason string decide_verdict /
#                       decide_verdict.py already computed — reused verbatim, not reworded)
#
# Two public entry points:
#   pantheon_overall_color <agent...>            -> prints green|yellow|red|unverified
#   pantheon_render_comment <head_sha> <agent...> -> prints the full comment markdown to stdout
set -u 2>/dev/null || true

# ---------------------------------------------------------------------------
# Small helpers (all prefixed _pantheon_ — internal, not part of the public contract)
# ---------------------------------------------------------------------------

# Markdown-table-safe + single-line: escape pipes, collapse newlines to spaces.
_pantheon_sanitize_inline() {
  local s="$1"
  s="${s//$'\n'/ }"
  s="${s//|/\\|}"
  printf '%s' "$s"
}

_pantheon_truncate() {
  local text="$1" max="${2:-90}"
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
  else
    printf '%s…' "${text:0:$((max - 1))}"
  fi
}

_pantheon_emoji_for_color() {
  case "$1" in
    green) printf '🟢' ;;
    yellow) printf '🟡' ;;
    red) printf '🔴' ;;
    *) printf '🟠' ;;
  esac
}

_pantheon_severity_badge() {
  case "$1" in
    blocker) printf '**blocker**' ;;
    should_fix) printf 'should_fix' ;;
    note) printf 'note' ;;
    *) printf '%s' "$1" ;;
  esac
}

# One compact JSON object per line, findings sorted blocker -> should_fix -> note -> other.
# Zero findings prints zero lines (a `while read` loop over this correctly no-ops).
_pantheon_sorted_findings() {
  jq -c '
    (.findings // [])
    | map(. + {_rank: (if .severity == "blocker" then 0
                        elif .severity == "should_fix" then 1
                        elif .severity == "note" then 2
                        else 3 end)})
    | sort_by(._rank)
    | .[]
  ' <<<"$1" 2>/dev/null
}

# Always prints exactly one line (possibly empty) — the highest-severity finding's issue text,
# or "" if there are none. Deliberately a single jq call (not sorted-findings | head -1) so an
# empty findings array can't turn into a zero-line command substitution edge case.
_pantheon_top_finding_text() {
  jq -r '
    (.findings // [])
    | map(. + {_rank: (if .severity == "blocker" then 0
                        elif .severity == "should_fix" then 1
                        elif .severity == "note" then 2
                        else 3 end)})
    | sort_by(._rank)
    | if length > 0 then (.[0].issue // "") else "" end
  ' <<<"$1" 2>/dev/null
}

# table_top_cell <verdict> <top-text> <findings-json>
_pantheon_table_top_cell() {
  local verdict="$1" top_text="$2" findings_json="$3" best
  if [ "$verdict" = "SKIPPED" ]; then
    printf 'skipped — %s' "$top_text"
    return 0
  fi
  best="$(_pantheon_top_finding_text "$findings_json")"
  if [ -n "$best" ]; then
    _pantheon_truncate "$best" 90
    return 0
  fi
  if [ -n "$top_text" ] && [ "$top_text" != "no findings" ]; then
    printf '%s' "$top_text"
    return 0
  fi
  printf '—'
}

# headline_lines <overall-color> — prints two lines: the bold signal line, then a one-sentence
# plain-language explanation of what that signal means for the merge decision.
_pantheon_headline_lines() {
  local overall="$1" emoji phrase explain
  emoji="$(_pantheon_emoji_for_color "$overall")"
  case "$overall" in
    green)
      phrase="Clean pass"
      explain="No blocker or review-note findings from any agent — this reads as safe to merge on the gate's own signal."
      ;;
    yellow)
      phrase="Review notes"
      explain="Non-blocking findings below are worth a look, but nothing here is stopping the merge."
      ;;
    red)
      phrase="Blocked"
      explain="A blocker finding was reported — this should not merge until it is resolved."
      ;;
    *)
      phrase="NOT GATED (fail-closed)"
      explain="At least one agent did not return a trustworthy verdict, so the gate is refusing to vouch for this PR instead of guessing — treat this as unreviewed, not as a pass."
      ;;
  esac
  printf '### %s **%s**\n' "$emoji" "$phrase"
  printf '%s\n' "$explain"
}

# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

# pantheon_overall_color <agent...> — worst-wins aggregate across the panel. Reads <NAME>_COLOR
# per agent; a missing/empty color is treated as unverified (fail-closed), same as everywhere
# else in this repo. Uses if-statements rather than `&&`/`||` chains on purpose — this file is
# sourced by callers running under `set -euo pipefail` (cli/review-gate), and a trailing failed
# test in an `&&`/`||` chain would abort the caller's shell.
pantheon_overall_color() {
  local overall="green" agent upper color_var color
  for agent in "$@"; do
    upper="$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]')"
    color_var="${upper}_COLOR"
    color="${!color_var:-unverified}"
    case "$color" in
      red) overall="red" ;;
      unverified)
        if [ "$overall" != "red" ]; then overall="unverified"; fi
        ;;
      yellow)
        if [ "$overall" = "green" ]; then overall="yellow"; fi
        ;;
    esac
  done
  printf '%s' "$overall"
}

# pantheon_render_comment <head_sha> <agent...> — prints the full comment markdown to stdout.
# See this file's header comment for the per-agent env var contract.
pantheon_render_comment() {
  local head_sha="$1"
  shift
  local short_sha="${head_sha:0:7}"
  [ -n "$short_sha" ] || short_sha="unknown"

  local overall
  overall="$(pantheon_overall_color "$@")"

  _pantheon_headline_lines "$overall"
  echo
  echo "| Agent | Verdict | Top finding |"
  echo "|---|---|---|"

  local agent upper color_var verdict_var top_var findings_var
  local color verdict top findings_json vcell topcell
  local total_findings=0 fcount

  for agent in "$@"; do
    upper="$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]')"
    color_var="${upper}_COLOR"
    verdict_var="${upper}_VERDICT"
    top_var="${upper}_TOP"
    findings_var="${upper}_FINDINGS"

    color="${!color_var:-unverified}"
    verdict="${!verdict_var:-UNVERIFIED}"
    top="${!top_var:-}"
    findings_json="${!findings_var:-\{\}}"
    [ -n "$findings_json" ] || findings_json='{}'

    fcount="$(jq -r '(.findings // []) | length' <<<"$findings_json" 2>/dev/null)"
    [ -n "$fcount" ] || fcount=0
    total_findings=$((total_findings + fcount))

    vcell="$(_pantheon_sanitize_inline "\`${verdict}\` — ${color}")"
    topcell="$(_pantheon_sanitize_inline "$(_pantheon_table_top_cell "$verdict" "$top" "$findings_json")")"
    printf '| %s | %s | %s |\n' "$agent" "$vcell" "$topcell"
  done

  echo
  local fold_open=""
  case "$overall" in
    red | unverified) fold_open=" open" ;;
  esac
  printf '<details%s>\n' "$fold_open"
  printf '<summary>Full findings (%s)</summary>\n' "$total_findings"
  echo

  local invariant_var reason_var invariant reason summary emoji
  local sev f ln issue scenario badge finding_obj any_finding

  for agent in "$@"; do
    upper="$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]')"
    color_var="${upper}_COLOR"
    verdict_var="${upper}_VERDICT"
    top_var="${upper}_TOP"
    findings_var="${upper}_FINDINGS"
    invariant_var="${upper}_INVARIANT"
    reason_var="${upper}_REASON"

    color="${!color_var:-unverified}"
    verdict="${!verdict_var:-UNVERIFIED}"
    top="${!top_var:-}"
    findings_json="${!findings_var:-\{\}}"
    [ -n "$findings_json" ] || findings_json='{}'
    invariant="${!invariant_var:-false}"
    reason="${!reason_var:-}"
    emoji="$(_pantheon_emoji_for_color "$color")"

    printf "**%s** @ \`%s\` — %s %s\n\n" "$agent" "$short_sha" "$emoji" "$verdict"

    summary="$(jq -r '.summary // empty' <<<"$findings_json" 2>/dev/null)"
    [ -n "$summary" ] || summary="$top"
    [ -n "$summary" ] || summary="no summary reported."
    printf '%s\n\n' "$(_pantheon_sanitize_inline "$summary")"

    if [ "$invariant" = "true" ] && [ -n "$reason" ]; then
      printf '**Overridden verdict:** %s\n\n' "$(_pantheon_sanitize_inline "$reason")"
    fi

    any_finding=false
    while IFS= read -r finding_obj; do
      [ -z "$finding_obj" ] && continue
      any_finding=true
      sev="$(jq -r '.severity // "note"' <<<"$finding_obj")"
      f="$(jq -r '.file // "?"' <<<"$finding_obj")"
      ln="$(jq -r '.line // "?"' <<<"$finding_obj")"
      issue="$(jq -r '.issue // ""' <<<"$finding_obj")"
      scenario="$(jq -r '.scenario // ""' <<<"$finding_obj")"
      badge="$(_pantheon_severity_badge "$sev")"
      printf -- "- %s \`%s:%s\` — %s\n" "$badge" "$f" "$ln" "$(_pantheon_sanitize_inline "$issue")"
      if [ -n "$scenario" ]; then
        printf '  scenario: %s\n' "$(_pantheon_sanitize_inline "$scenario")"
      fi
    done < <(_pantheon_sorted_findings "$findings_json")
    if [ "$any_finding" = "true" ]; then
      echo
    fi
  done

  echo "<details>"
  echo "<summary>Raw verdict JSON</summary>"
  echo
  for agent in "$@"; do
    upper="$(printf '%s' "$agent" | tr '[:lower:]' '[:upper:]')"
    findings_var="${upper}_FINDINGS"
    findings_json="${!findings_var:-\{\}}"
    [ -n "$findings_json" ] || findings_json='{}'
    printf '**%s**\n\n' "$agent"
    echo '```json'
    jq '.' <<<"$findings_json" 2>/dev/null || printf '%s\n' "$findings_json"
    echo '```'
    echo
  done
  echo "</details>"
  echo "</details>"
  echo
  echo "_review-pantheon — fails closed: a missing or unparseable verdict reads as NOT GATED, never as a pass._"
}
