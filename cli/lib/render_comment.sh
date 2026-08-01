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
#
# Sanitize-at-render (the two-layer contract): every value this file reads out of an agent's
# JSON, or derives from one, is untrusted model output — verdict, summary, and each finding's
# severity/file/line/issue/scenario — and gets routed through _pantheon_sanitize_inline (or a
# stricter variant, e.g. .line's numeric-or-"?" coercion) before it reaches the human-readable
# section of the comment. That's the DISPLAY half of the contract: this file's job is to make
# sure no byte of model-controlled input can fracture the comment's markdown/HTML structure,
# regardless of what the decision layer upstream (cli/lib/verdict.sh, decide_verdict.py) did or
# didn't validate about that same data on the invariant-read surface (verdict/has_blocker/
# findings/severity — the fields the blocker invariant and vocabulary lookup actually reason
# over). The two layers check different things for different reasons and neither substitutes
# for the other. The ONE deliberate exception is the machine tail (the nested "Raw verdict
# JSON" block near the end of pantheon_render_comment) — it prints the untouched JSON on
# purpose, because that's the whole point of keeping a machine-readable copy.
set -u 2>/dev/null || true

# ---------------------------------------------------------------------------
# Small helpers (all prefixed _pantheon_ — internal, not part of the public contract)
# ---------------------------------------------------------------------------

# Markdown/HTML-hostile-content-safe + single-line, for ANY model-controlled string this
# renderer interpolates — table cells, prose, AND values placed inside a backtick code span
# (e.g. the per-finding `` `file:line` `` in the itemized list). Every text field this file
# reads from an agent's JSON is untrusted the same way PR metadata is (DESIGN.md's "Security
# posture") — the agent's own output, not something this renderer can assume is well-formed.
#   - Pipes: escaped (\|), so a stray `|` can't fracture a markdown table row.
#   - Newlines: collapsed to spaces, so a multi-line value can't fracture a table row or list
#     item into extra rows/lines.
#   - Backticks: replaced with a straight quote. There is no backslash-escape for a backtick
#     INSIDE a single-backtick-fenced code span in CommonMark (the only safe way to include a
#     literal backtick there is a wider double-backtick fence, which this renderer doesn't
#     use) — a raw backtick would prematurely close the span and let everything after it
#     render as uncontrolled markdown. Applied everywhere (not only inside code spans) for one
#     rule, one function, rather than a second bespoke sanitizer just for code-span contexts.
#   - Angle brackets: HTML-escaped (&lt;/&gt;), so a value can't be mistaken for (or rendered
#     as) an HTML tag in GitHub's comment renderer.
#   - @: replaced with the fullwidth lookalike ＠ (U+FF20). A raw `@name` in a posted GitHub
#     comment is a real notification ping, not just a markdown-structure risk — this is about
#     not letting a model's text page an arbitrary user/team, not about rendering.
_pantheon_sanitize_inline() {
  local s="$1"
  s="${s//$'\n'/ }"
  s="${s//|/\\|}"
  s="${s//\`/\'}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//@/＠}"
  printf '%s' "$s"
}

# Character-safe, not byte-safe: bash's own `${#text}`/`${text:a:b}` only count/slice by
# character when the CALLER's locale happens to be UTF-8-aware (LC_CTYPE) — under a `C`/POSIX
# locale (a bare-bones container with no locale configured, for instance), both become
# byte-oriented, and slicing at a byte offset that lands mid-way through a multi-byte UTF-8
# character garbles it (the truncated string ends in a broken byte sequence, and terminals/
# GitHub's renderer show the replacement-character mess). jq's string functions are UTF-8-aware
# by construction, independent of the C library locale (jq strings are always Unicode codepoint
# sequences, per the jq manual) — jq is already a hard requirement for this whole file, so this
# reuses it instead of hand-rolling locale-independent UTF-8 byte counting in bash.
_pantheon_truncate() {
  local text="$1" max="${2:-90}"
  jq -rn --arg t "$text" --argjson m "$max" '
    if ($t | length) <= $m then $t
    else ($t[0:($m - 1)] + "…")
    end
  '
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
    # An out-of-enum severity is still model output, interpolated raw here until this fix —
    # sanitize it like every other model-controlled field, AND wrap it in a literal label so
    # it reads as "the gate doesn't recognize this," not as a fourth kind of legitimate badge
    # sitting next to blocker/should_fix/note. Visible, not pretty, on purpose.
    *) printf 'unrecognized-severity(%s)' "$(_pantheon_sanitize_inline "$1")" ;;
  esac
}

# `.findings` is only checked for PRESENCE upstream (cli/lib/verdict.sh's decide_verdict,
# decide_verdict.py's REQUIRED_KEYS), never for being an array of objects — a malformed
# verdict (e.g. an agent emitting `"findings": "none"` instead of `[]`, or an array with a
# stray non-object element mixed in among real findings) would otherwise still pass that
# validation and reach this renderer. `_pantheon_safe_findings_filter` degrades both cases —
# a non-array `.findings` becomes `[]`; a non-object element inside an otherwise-valid array
# is dropped, not left to blow up every downstream `.severity`/`.file`/`.issue` access with a
# jq type error — rather than letting jq error out (silently swallowed by every call site's
# command-substitution subshell, which would render an agent's real findings as an empty list
# even on a red/blocked verdict) or, worse, `length` on a bare string silently returning a
# wrong count. Fail-closed for the render layer specifically: a malformed findings shape (or a
# malformed element within it) reads as "no findings" / fewer findings, never a crash or a
# bogus count. Reused as a jq `def` (not a bash string constant) so every call site stays a
# single source, not three hand-copied filter expressions that could drift.
_pantheon_safe_findings_filter='
  def safe_findings:
    (.findings // [])
    | if type == "array" then . else [] end
    | map(select(type == "object"));
'

# One compact JSON object per line, findings sorted blocker -> should_fix -> note -> other.
# Zero findings prints zero lines (a `while read` loop over this correctly no-ops).
_pantheon_sorted_findings() {
  jq -c "$_pantheon_safe_findings_filter"'
    safe_findings
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
  jq -r "$_pantheon_safe_findings_filter"'
    safe_findings
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

    fcount="$(jq -r "$_pantheon_safe_findings_filter"'safe_findings | length' <<<"$findings_json" 2>/dev/null)"
    [ -n "$fcount" ] || fcount=0
    total_findings=$((total_findings + fcount))

    # Sanitize the raw verdict value FIRST, then wrap it in our own backticks — not the other
    # way around: sanitizing an already-backtick-wrapped string would treat those backticks as
    # hostile content too (the sanitizer can't tell "markdown we constructed" from "a backtick
    # smuggled in by the model"), corrupting our own formatting. Same rule applies everywhere
    # else this file adds its own backticks/bold around a value — sanitize the value, then wrap.
    vcell="\`$(_pantheon_sanitize_inline "$verdict")\` — ${color}"
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

    printf "**%s** @ \`%s\` — %s %s\n\n" "$agent" "$short_sha" "$emoji" "$(_pantheon_sanitize_inline "$verdict")"

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
      # .line is schema'd as a number, but it's still model output — coerce anything that
      # isn't a plain non-negative integer to the same "?" placeholder already used when the
      # key is missing entirely, rather than interpolating arbitrary text where a line number
      # is expected. .file goes through the same sanitize pass as every other model-controlled
      # field (see _pantheon_sanitize_inline) — both sit inside a backtick code span below, so
      # this is the call site the sanitizer's backtick handling exists for.
      [[ "$ln" =~ ^[0-9]+$ ]] || ln="?"
      f="$(_pantheon_sanitize_inline "$f")"
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
