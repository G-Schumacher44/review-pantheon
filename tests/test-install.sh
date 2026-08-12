#!/usr/bin/env bash
# tests/test-install.sh — fixture test for install.sh's editor/CLI lanes
# (--claude / --cursor / --codex / --gemini).
#
# Runs install.sh against temp target dirs and asserts: the default (no-flags) install is
# unchanged, each flag's expected files land with a GENERATED header, Claude's personas AND the
# four canonical skills (gate, counsel, spec-driven, design-contract) are copied byte-for-byte
# from agents/*.md and skills/*/SKILL.md respectively, the generated /counsel and /gate commands
# land, a second identical run makes no changes (idempotent), and a hand-customized generated/
# verbatim file is left alone on rerun (same skip contract the gate install already has).
#
# No test framework — plain bash, `bash tests/test-install.sh` is the whole invocation (also
# wired into .github/workflows/ci.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"

PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

assert_file() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then pass "$desc"; else fail "$desc (missing: $path)"; fi
}

assert_contains() {
  local desc="$1" path="$2" needle="$3"
  if [[ -f "$path" ]] && grep -qF "$needle" "$path"; then
    pass "$desc"
  else
    fail "$desc (missing '$needle' in $path)"
  fi
}

tree_hash() {
  find "$1" -type f -print0 | sort -z | xargs -0 cksum | cksum
}

PERSONAS=(apollo artemis diogenes plato socrates)
SKILLS=(gate counsel spec-driven design-contract)

# ---------------------------------------------------------------------------
# 1. Default (no flags) install — personas + REVIEW_RULES.md land, review.yml is GENERATED as a
#    thin caller of the published action (issue #36 — no vendored pantheon/ package or
#    action/review.yml copy any more), no editor/CLI dirs appear.
# ---------------------------------------------------------------------------
T1="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$T1" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
"$INSTALL" "$T1" >/dev/null

assert_file "default install: personas copied to .github/review-agents" "$T1/.github/review-agents/artemis.md"
assert_file "default install: review.yml workflow generated" "$T1/.github/workflows/review.yml"
assert_file "default install: REVIEW_RULES.md installed" "$T1/REVIEW_RULES.md"

# The generated workflow is a THIN CALLER, not a vendored reimplementation — it must pin
# review-pantheon itself to a full 40-char commit SHA (install.sh's WAY_A_PIN_SHA), never a
# moving tag, matching the discipline action.yml applies to anthropics/claude-code-action.
WAY_A_SHA="$(grep -oE '^WAY_A_PIN_SHA="[0-9a-f]+"' "$INSTALL" | grep -oE '[0-9a-f]+' )"
if [[ -n "$WAY_A_SHA" ]]; then
  assert_contains "default install: generated review.yml pins review-pantheon to WAY_A_PIN_SHA" \
    "$T1/.github/workflows/review.yml" "G-Schumacher44/review-pantheon@$WAY_A_SHA"
else
  fail "could not read WAY_A_PIN_SHA out of install.sh to check against"
fi

if grep -qE 'G-Schumacher44/review-pantheon@[A-Za-z0-9._-]+' "$T1/.github/workflows/review.yml" \
  && ! grep -qE 'G-Schumacher44/review-pantheon@[0-9a-f]{40}' "$T1/.github/workflows/review.yml"; then
  fail "default install: generated review.yml pins review-pantheon to something OTHER than a full 40-char commit SHA"
else
  pass "default install: generated review.yml's review-pantheon pin is a full commit SHA (or absent)"
fi

if python3 -c 'import yaml' 2>/dev/null; then
  if python3 -c "import yaml; yaml.safe_load(open('$T1/.github/workflows/review.yml'))" 2>/dev/null; then
    pass "default install: generated review.yml parses as valid YAML"
  else
    fail "default install: generated review.yml failed to parse as YAML"
  fi
else
  echo "note: python3 yaml (PyYAML) unavailable — skipping generated review.yml YAML-parse check, non-fatal"
fi

# No vendored pantheon/ package any more — the generated thin caller delegates all gate logic to
# review-pantheon's own action.yml checkout at github.action_path, so install.sh has nothing left
# to vendor for base-pinning to find (issue #36 deleted the ~1,000-line reimplementation that
# needed it).
if [[ ! -e "$T1/.github/review-agents/pantheon" ]]; then
  pass "default install: no vendored pantheon/ package (nothing left to base-pin against)"
else
  fail "default install: a pantheon/ package was vendored — should be dead weight since action/review.yml was deleted"
fi

if [[ ! -e "$T1/.claude" && ! -e "$T1/.cursor" && ! -e "$T1/.agents" && ! -e "$T1/.gemini" ]]; then
  pass "default install: no editor/CLI dirs created without flags"
else
  fail "default install: an editor/CLI dir was created without any flag"
fi
rm -rf "$T1"

# ---------------------------------------------------------------------------
# 2. All four flags together against a fresh target — expected files land.
# ---------------------------------------------------------------------------
T2="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$T2" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
"$INSTALL" "$T2" --claude --cursor --codex --gemini >/dev/null

for p in "${PERSONAS[@]}"; do
  assert_file "claude: $p.md installed" "$T2/.claude/agents/$p.md"
  if cmp -s "$ROOT/agents/$p.md" "$T2/.claude/agents/$p.md"; then
    pass "claude: $p.md matches agents/$p.md verbatim"
  else
    fail "claude: $p.md differs from agents/$p.md"
  fi

  assert_file "cursor: $p.md generated" "$T2/.cursor/agents/$p.md"
  assert_contains "cursor: $p.md has GENERATED header" "$T2/.cursor/agents/$p.md" "GENERATED by install.sh"
  assert_contains "cursor: $p.md marked readonly" "$T2/.cursor/agents/$p.md" "readonly: true"

  assert_file "codex: $p SKILL.md generated" "$T2/.agents/skills/$p/SKILL.md"
  assert_contains "codex: $p SKILL.md has GENERATED header" "$T2/.agents/skills/$p/SKILL.md" "GENERATED by install.sh"

  assert_file "gemini: $p.toml generated" "$T2/.gemini/commands/$p.toml"
  assert_contains "gemini: $p.toml has GENERATED header" "$T2/.gemini/commands/$p.toml" "GENERATED by install.sh"
done

if python3 -c 'import tomllib' 2>/dev/null; then
  for p in "${PERSONAS[@]}"; do
    if python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$T2/.gemini/commands/$p.toml" 2>/dev/null; then
      pass "gemini: $p.toml parses as valid TOML"
    else
      fail "gemini: $p.toml is not valid TOML"
    fi
  done
else
  echo "note: python3 tomllib unavailable (needs 3.11+) — skipping TOML parse check, non-fatal"
fi

assert_file "claude: /counsel command generated" "$T2/.claude/commands/counsel.md"
assert_contains "claude: /counsel references \$ARGUMENTS" "$T2/.claude/commands/counsel.md" "\$ARGUMENTS"
assert_contains "claude: /counsel has GENERATED header" "$T2/.claude/commands/counsel.md" "GENERATED by install.sh"

for s in "${SKILLS[@]}"; do
  assert_file "claude: $s skill installed" "$T2/.claude/skills/$s/SKILL.md"
  if cmp -s "$ROOT/skills/$s/SKILL.md" "$T2/.claude/skills/$s/SKILL.md"; then
    pass "claude: $s/SKILL.md matches skills/$s/SKILL.md verbatim"
  else
    fail "claude: $s/SKILL.md differs from skills/$s/SKILL.md"
  fi
  assert_contains "claude: $s skill has a description field" "$T2/.claude/skills/$s/SKILL.md" "description:"
done

assert_file "claude: /gate command generated" "$T2/.claude/commands/gate.md"
assert_contains "claude: /gate references \$ARGUMENTS" "$T2/.claude/commands/gate.md" "\$ARGUMENTS"
assert_contains "claude: /gate has GENERATED header" "$T2/.claude/commands/gate.md" "GENERATED by install.sh"
assert_contains "claude: /gate points at the installed gate skill" "$T2/.claude/commands/gate.md" ".claude/skills/gate/SKILL.md"
assert_contains "claude: /gate tells the user to pipx install if pantheon is missing" \
  "$T2/.claude/commands/gate.md" "pipx install review-pantheon"
assert_contains "claude: /gate tells the user to brew install if pantheon is missing" \
  "$T2/.claude/commands/gate.md" "brew install g-schumacher44/tap/review-pantheon"

assert_contains "claude: gate skill's locator leads with pipx install" \
  "$T2/.claude/skills/gate/SKILL.md" "pipx install review-pantheon"
assert_contains "claude: gate skill's locator leads with brew install" \
  "$T2/.claude/skills/gate/SKILL.md" "brew install g-schumacher44/tap/review-pantheon"
assert_contains "claude: gate skill's locator still covers a checkout dev install" \
  "$T2/.claude/skills/gate/SKILL.md" "pip install -e ."
assert_contains "claude: gate skill's locator still covers bootstrap.sh --prefix" \
  "$T2/.claude/skills/gate/SKILL.md" "bootstrap.sh --prefix"

# Frontmatter must parse under a STRICT YAML parser — not just "install.sh didn't crash." A Codex
# finding on this PR proved a hand-written value can look fine and still break YAML: an unquoted
# argument-hint with nested brackets/commas (flow-sequence syntax), or a plain scalar description
# containing an embedded ": " (colon-space, which YAML reserves for starting a mapping key even
# mid-scalar). Both are silent at install time — cmp/grep-based assertions above don't catch them —
# so this checks every installed command/skill's frontmatter block actually loads.
if python3 -c 'import yaml' 2>/dev/null; then
  if T2_TARGET="$T2" python3 - <<'PYEOF'
import glob
import os
import sys

import yaml

target = os.environ["T2_TARGET"]
files = [
    f"{target}/.claude/commands/gate.md",
    f"{target}/.claude/commands/counsel.md",
] + glob.glob(f"{target}/.claude/skills/*/SKILL.md")

failed = []
for f in files:
    text = open(f).read()
    if not text.startswith("---\n"):
        failed.append((f, "no frontmatter fence"))
        continue
    end = text.index("\n---\n", 4)
    fm = text[4:end]
    try:
        yaml.safe_load(fm)
    except Exception as exc:  # noqa: BLE001
        failed.append((f, str(exc)))

if failed:
    for f, err in failed:
        print(f"FRONTMATTER_YAML_FAIL {f}: {err}", file=sys.stderr)
    sys.exit(1)
print(f"parsed {len(files)} frontmatter blocks cleanly", file=sys.stderr)
PYEOF
  then
    pass "claude: every installed command/skill frontmatter block parses under strict YAML"
  else
    fail "claude: a command/skill frontmatter block failed strict YAML parsing"
  fi
else
  echo "note: python3 yaml (PyYAML) unavailable — skipping strict frontmatter YAML check, non-fatal"
fi

# ---------------------------------------------------------------------------
# 3. Idempotency — an identical second run changes nothing and installs nothing new.
# ---------------------------------------------------------------------------
BEFORE_HASH="$(tree_hash "$T2")"
SECOND_RUN_OUT="$("$INSTALL" "$T2" --claude --cursor --codex --gemini 2>&1)"
AFTER_HASH="$(tree_hash "$T2")"

if [[ "$BEFORE_HASH" == "$AFTER_HASH" ]]; then
  pass "idempotent: second run makes no file changes"
else
  fail "idempotent: second run changed file contents"
fi

if ! grep -q "^install.sh: installed " <<<"$SECOND_RUN_OUT"; then
  pass "idempotent: second run reports no new installs"
else
  fail "idempotent: second run reported a new install"
fi

# ---------------------------------------------------------------------------
# 3b. Workflow ownership contract — the ONE file with a refresh path instead of cmp-and-skip.
#     Marker line present -> installer-owned: a rerun REGENERATES it (the documented re-pin
#     flow, and the pre-collapse-vendored-file migration would strand without it — Codex
#     finding on the collapse PR). Marker line removed -> owned by the repo: never touched,
#     skip report says how to migrate deliberately.
# ---------------------------------------------------------------------------
WF="$T2/.github/workflows/review.yml"
WF_PRISTINE="$(cat "$WF")"

echo "# local tweak that keeps the GENERATED marker" >> "$WF"
WF_REFRESH_OUT="$("$INSTALL" "$T2" 2>&1)"
if [[ "$(cat "$WF")" == "$WF_PRISTINE" ]]; then
  pass "workflow ownership: marker-present edit is refreshed back to the generated content"
else
  fail "workflow ownership: marker-present edit survived a rerun (refresh path did not fire)"
fi
if grep -q "refreshed .*review.yml" <<<"$WF_REFRESH_OUT"; then
  pass "workflow ownership: refresh is reported in install.sh output"
else
  fail "workflow ownership: refresh not reported in install.sh output"
fi

grep -v "GENERATED by install.sh" "$WF" > "$WF.owned" && mv "$WF.owned" "$WF"
WF_OWNED="$(cat "$WF")"
WF_SKIP_OUT="$("$INSTALL" "$T2" 2>&1)"
if [[ "$(cat "$WF")" == "$WF_OWNED" ]]; then
  pass "workflow ownership: marker-removed file is never overwritten"
else
  fail "workflow ownership: marker-removed file was overwritten — ownership contract broken"
fi
if grep -q "not installer-generated" <<<"$WF_SKIP_OUT"; then
  pass "workflow ownership: migration hint reported for the non-generated file"
else
  fail "workflow ownership: skip/migration hint missing from install.sh output"
fi

# Restore the generated file so later sections (idempotency re-checks, snapshots) see the
# canonical state: delete and re-run installs it fresh.
rm -f "$WF"
"$INSTALL" "$T2" >/dev/null 2>&1
if [[ "$(cat "$WF")" == "$WF_PRISTINE" ]]; then
  pass "workflow ownership: delete-and-rerun reinstalls the canonical generated workflow"
else
  fail "workflow ownership: reinstall after delete produced different content"
fi

# personas_path must be an ACTIVE input in the generated workflow, not a commented-out example.
# Way A vendors personas into .github/review-agents precisely so the repo owns them; a stub that
# doesn't point the gate at them makes them decorative — and silently disables customized
# personas carried over from a pre-collapse install (Codex P2 on the collapse PR). Guard the
# exact regression: a future heredoc edit re-commenting or dropping the line must fail here.
if grep -qE '^\s+personas_path:\s+\.github/review-agents\s*$' "$WF"; then
  pass "generated workflow: personas_path is active (uncommented) and points at .github/review-agents"
else
  fail "generated workflow: personas_path missing or commented out — vendored/customized personas would be silently unused"
fi
if grep -qE '^\s*#.*personas_path:' "$WF"; then
  fail "generated workflow: a commented-out personas_path line coexists with (or shadows) the active one"
else
  pass "generated workflow: no commented-out personas_path shadowing the active input"
fi

# ---------------------------------------------------------------------------
# 4. Customization refusal — a hand-edited generated file is left alone and reported skipped.
# ---------------------------------------------------------------------------
echo "-- hand customized --" >> "$T2/.cursor/agents/artemis.md"
CUSTOM_BEFORE="$(cat "$T2/.cursor/agents/artemis.md")"
CUSTOM_RUN_OUT="$("$INSTALL" "$T2" --cursor 2>&1)"
CUSTOM_AFTER="$(cat "$T2/.cursor/agents/artemis.md")"

if [[ "$CUSTOM_BEFORE" == "$CUSTOM_AFTER" ]]; then
  pass "customization refusal: hand-edited .cursor/agents/artemis.md left unchanged"
else
  fail "customization refusal: hand-edited .cursor/agents/artemis.md was overwritten"
fi

echo "-- hand customized --" >> "$T2/.claude/skills/gate/SKILL.md"
SKILL_CUSTOM_BEFORE="$(cat "$T2/.claude/skills/gate/SKILL.md")"
SKILL_CUSTOM_RUN_OUT="$("$INSTALL" "$T2" --claude 2>&1)"
SKILL_CUSTOM_AFTER="$(cat "$T2/.claude/skills/gate/SKILL.md")"

if [[ "$SKILL_CUSTOM_BEFORE" == "$SKILL_CUSTOM_AFTER" ]]; then
  pass "customization refusal: hand-edited .claude/skills/gate/SKILL.md left unchanged"
else
  fail "customization refusal: hand-edited .claude/skills/gate/SKILL.md was overwritten"
fi

if grep -q "claude/skills/gate/SKILL.md" <<<"$SKILL_CUSTOM_RUN_OUT"; then
  pass "customization refusal: skill skip reported in install.sh output"
else
  fail "customization refusal: skill skip not reported in install.sh output"
fi

if grep -q "cursor/agents/artemis.md" <<<"$CUSTOM_RUN_OUT"; then
  pass "customization refusal: skip reported in install.sh output"
else
  fail "customization refusal: skip not reported in install.sh output"
fi

rm -rf "$T2"

# ---------------------------------------------------------------------------
# 5. Individual flags don't require each other — --gemini alone doesn't touch .claude/.cursor.
# ---------------------------------------------------------------------------
T3="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$T3" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
"$INSTALL" "$T3" --gemini >/dev/null
assert_file "gemini alone: socrates.toml generated" "$T3/.gemini/commands/socrates.toml"
if [[ ! -e "$T3/.claude" && ! -e "$T3/.cursor" && ! -e "$T3/.agents" ]]; then
  pass "gemini alone: no other tool's dirs created"
else
  fail "gemini alone: another tool's dir was created"
fi
rm -rf "$T3"

# ---------------------------------------------------------------------------
# 6. Adversarial escaping fixture — a persona whose description AND body
#    contain a backslash, an embedded double quote, and a literal triple-
#    quote ("""). This is the exact input class an audit proved broke the
#    --gemini generator: persona_body was written into a TOML basic
#    multi-line """ string unescaped, so a backslash (e.g. a Windows path
#    like C:\Users\name) or an embedded """ produced invalid TOML that
#    install.sh still reported as installed, exit 0. The --cursor/--codex
#    YAML frontmatter `description:` had the same gap. Both lanes must now
#    emit content that parses AND round-trips the source value byte-for-byte.
#
#    install.sh always globs $SCRIPT_DIR/agents/*.md, so to exercise the
#    generators against a synthetic persona (not one of the shipped five)
#    without touching this repo's real agents/ dir, this builds a throwaway
#    sibling "repo" — a copy of install.sh next to an agents/ dir holding the
#    five real personas plus the fixture — and runs that copy.
# ---------------------------------------------------------------------------
FIXTURE_ROOT="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$FIXTURE_ROOT" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
mkdir -p "$FIXTURE_ROOT/agents"
cp "$INSTALL" "$FIXTURE_ROOT/install.sh"
ln -s "$ROOT/skills" "$FIXTURE_ROOT/skills"
cp "$ROOT/REVIEW_RULES.example.md" "$FIXTURE_ROOT/REVIEW_RULES.example.md"
cp "$ROOT"/agents/*.md "$FIXTURE_ROOT/agents/"

FIXTURE_PERSONA="$FIXTURE_ROOT/agents/fixture-escape.md"
FIXTURE_DESC='fixture desc: has a colon, a backslash \ and "quotes" and a triple """ end'
cat > "$FIXTURE_PERSONA" <<EOF
---
name: fixture-escape
description: $FIXTURE_DESC
model: sonnet
---

Windows path example: C:\Users\name
A line with a quote: she said "hi" to him.
A raw triple-quote marker: """ should not break the wrapping string.
EOF

T6="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$T6" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
"$FIXTURE_ROOT/install.sh" "$T6" --gemini --cursor --codex >/dev/null 2>&1

assert_file "fixture: gemini toml generated" "$T6/.gemini/commands/fixture-escape.toml"
assert_file "fixture: cursor md generated" "$T6/.cursor/agents/fixture-escape.md"
assert_file "fixture: codex SKILL.md generated" "$T6/.agents/skills/fixture-escape/SKILL.md"

if python3 -c 'import tomllib' 2>/dev/null; then
  if FIXTURE_TARGET="$T6" FIXTURE_DESC="$FIXTURE_DESC" python3 - <<'PYEOF'
import os
import sys
import tomllib

target = os.environ["FIXTURE_TARGET"]
expected_desc = os.environ["FIXTURE_DESC"]
expected_body = (
    "\n"
    "Windows path example: C:\\Users\\name\n"
    "A line with a quote: she said \"hi\" to him.\n"
    "A raw triple-quote marker: \"\"\" should not break the wrapping string.\n"
)
expected_prompt = expected_body + "\nReference under review: {{args}}\n"

try:
    with open(f"{target}/.gemini/commands/fixture-escape.toml", "rb") as f:
        data = tomllib.load(f)
    assert data["description"] == expected_desc
    assert data["prompt"] == expected_prompt
except Exception as exc:  # noqa: BLE001
    print(f"FIXTURE_TOML_FAIL {exc}", file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    pass "fixture: gemini toml parses AND description+prompt round-trip byte-identical"
  else
    fail "fixture: gemini toml failed to parse or round-trip"
  fi
else
  echo "note: python3 tomllib unavailable (needs 3.11+) — skipping fixture TOML check, non-fatal"
fi

if python3 -c 'import yaml' 2>/dev/null; then
  if FIXTURE_TARGET="$T6" FIXTURE_DESC="$FIXTURE_DESC" python3 - <<'PYEOF'
import os
import sys
import yaml

target = os.environ["FIXTURE_TARGET"]
expected_desc = os.environ["FIXTURE_DESC"]

paths = [
    f"{target}/.cursor/agents/fixture-escape.md",
    f"{target}/.agents/skills/fixture-escape/SKILL.md",
]
try:
    for path in paths:
        text = open(path).read()
        frontmatter = text.split("---\n", 2)[1]
        data = yaml.safe_load(frontmatter)
        assert data["description"] == expected_desc, (path, data["description"])
except Exception as exc:  # noqa: BLE001
    print(f"FIXTURE_YAML_FAIL {exc}", file=sys.stderr)
    sys.exit(1)
PYEOF
  then
    pass "fixture: cursor+codex YAML frontmatter parses AND description round-trips byte-identical"
  else
    fail "fixture: cursor+codex YAML frontmatter failed to parse or round-trip"
  fi
else
  echo "note: python3 yaml (PyYAML) unavailable — skipping fixture YAML check, non-fatal"
fi

rm -rf "$FIXTURE_ROOT" "$T6"

# ---------------------------------------------------------------------------
# 7. --user — installs the per-tool projections at USER level ($HOME) instead
#    of into a target repo: no gate files, no target-repo argument, requires
#    at least one tool flag. HOME is overridden per-invocation
#    (`HOME=$SCRATCH "$INSTALL" --user ...`) so none of this ever touches the
#    real $HOME — verified below by snapshotting the real paths a regression
#    could leak into (including $HOME/.claude/agents, which on some machines
#    is a symlink into a real tracked repo) before and after every
#    invocation in this section, and asserting they're byte-for-byte
#    unchanged.
# ---------------------------------------------------------------------------
snapshot_paths() {
  # find+cksum every path in $@ that exists; silently skips ones that don't
  # (so a machine without e.g. ~/.gemini yet doesn't false-positive).
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    find "$p" -type f -print0 2>/dev/null | sort -z | xargs -0 cksum 2>/dev/null
  done
}

REAL_HOME_WATCH=("$HOME/.claude/agents" "$HOME/.claude/skills" "$HOME/.claude/commands" "$HOME/.cursor" "$HOME/.agents" "$HOME/.gemini")
REAL_HOME_BEFORE="$(snapshot_paths "${REAL_HOME_WATCH[@]}")"

# 7a. No tool flag with --user — error, lists all four flags, exits nonzero.
NO_TOOL_OUT="$("$INSTALL" --user 2>&1)"; NO_TOOL_STATUS=$?
if [[ "$NO_TOOL_STATUS" -ne 0 ]] \
  && grep -q -- "--claude" <<<"$NO_TOOL_OUT" && grep -q -- "--cursor" <<<"$NO_TOOL_OUT" \
  && grep -q -- "--codex" <<<"$NO_TOOL_OUT" && grep -q -- "--gemini" <<<"$NO_TOOL_OUT"; then
  pass "--user with no tool flag: exits nonzero and lists all four flags"
else
  fail "--user with no tool flag: expected nonzero exit + all four flags listed (got status=$NO_TOOL_STATUS: $NO_TOOL_OUT)"
fi

# 7b. A target-repo argument alongside --user — error, exits nonzero.
T7="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$T7" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
TARGET_ARG_OUT="$("$INSTALL" "$T7" --user --claude 2>&1)"; TARGET_ARG_STATUS=$?
if [[ "$TARGET_ARG_STATUS" -ne 0 ]] && grep -qi "not a target repo\|unexpected argument" <<<"$TARGET_ARG_OUT"; then
  pass "--user with a target-repo argument: exits nonzero with a clear message"
else
  fail "--user with a target-repo argument: expected nonzero exit + clear message (got status=$TARGET_ARG_STATUS: $TARGET_ARG_OUT)"
fi
rm -rf "$T7"

# 7c. Real install, HOME overridden to a scratch dir — expected files land per tool,
#     matching the SAME per-tool destinations as the repo-level install (Section 2),
#     just rooted at $HOME instead of a target repo.
T8="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
[ -n "$T8" ] || { echo "FATAL: empty scratch dir" >&2; exit 1; }
HOME="$T8" "$INSTALL" --user --claude --cursor --codex --gemini >/dev/null

for p in "${PERSONAS[@]}"; do
  assert_file "user/claude: $p.md installed" "$T8/.claude/agents/$p.md"
  if cmp -s "$ROOT/agents/$p.md" "$T8/.claude/agents/$p.md"; then
    pass "user/claude: $p.md matches agents/$p.md verbatim"
  else
    fail "user/claude: $p.md differs from agents/$p.md"
  fi
  assert_file "user/cursor: $p.md generated" "$T8/.cursor/agents/$p.md"
  assert_file "user/codex: $p SKILL.md generated" "$T8/.agents/skills/$p/SKILL.md"
  assert_file "user/gemini: $p.toml generated" "$T8/.gemini/commands/$p.toml"
done
for s in "${SKILLS[@]}"; do
  assert_file "user/claude: $s skill installed" "$T8/.claude/skills/$s/SKILL.md"
  if cmp -s "$ROOT/skills/$s/SKILL.md" "$T8/.claude/skills/$s/SKILL.md"; then
    pass "user/claude: $s/SKILL.md matches skills/$s/SKILL.md verbatim"
  else
    fail "user/claude: $s/SKILL.md differs from skills/$s/SKILL.md"
  fi
done
assert_file "user/claude: /counsel command generated" "$T8/.claude/commands/counsel.md"
assert_contains "user/claude: /counsel has GENERATED header" "$T8/.claude/commands/counsel.md" "GENERATED by install.sh"
assert_file "user/claude: /gate command generated" "$T8/.claude/commands/gate.md"
assert_contains "user/claude: /gate has GENERATED header" "$T8/.claude/commands/gate.md" "GENERATED by install.sh"

if [[ ! -e "$T8/.github" && ! -e "$T8/REVIEW_RULES.md" && ! -e "$T8/.gitignore" ]]; then
  pass "--user: no gate files installed (repo concepts, correctly skipped)"
else
  fail "--user: a gate file was installed under \$HOME"
fi

# 7d. Idempotency at user level — second run makes no file changes, no new installs.
USER_BEFORE_HASH="$(tree_hash "$T8")"
USER_SECOND_OUT="$(HOME="$T8" "$INSTALL" --user --claude --cursor --codex --gemini 2>&1)"
USER_AFTER_HASH="$(tree_hash "$T8")"
if [[ "$USER_BEFORE_HASH" == "$USER_AFTER_HASH" ]]; then
  pass "--user idempotent: second run makes no file changes"
else
  fail "--user idempotent: second run changed file contents"
fi
if ! grep -q "^install.sh: installed " <<<"$USER_SECOND_OUT"; then
  pass "--user idempotent: second run reports no new installs"
else
  fail "--user idempotent: second run reported a new install"
fi
rm -rf "$T8"

# 7e. Nothing was ever written outside the scratch $HOME across this whole section —
#     the real $HOME's watched paths (including the symlinked .claude/agents) are
#     byte-for-byte unchanged.
REAL_HOME_AFTER="$(snapshot_paths "${REAL_HOME_WATCH[@]}")"
if [[ "$REAL_HOME_BEFORE" == "$REAL_HOME_AFTER" ]]; then
  pass "--user: real \$HOME untouched by any invocation in this section"
else
  fail "--user: real \$HOME changed — a --user invocation leaked outside the overridden HOME"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "install.sh fixtures: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
