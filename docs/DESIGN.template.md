# Design — <project name>

<!--
This is a SKELETON, not a fill-in-the-blanks form — the `design-contract` skill points here for
the shape a binding contract doc takes; see that skill (skills/design-contract/SKILL.md) for the
authoring rules this structure exists to serve. Delete this comment block and every bracketed
placeholder before treating the result as real. review-pantheon's own DESIGN.md is the worked
example this skeleton was extracted from — read it for what a filled-in section actually looks
like, not just this outline.

BINDING RULE, non-negotiable: this doc describes CURRENT-STATE BEHAVIOR ONLY. No "Round N", "the
first attempt was...", "the fix was...", "previously we...", or any other fix-round narrative —
that history belongs in git (commit messages, PR descriptions), never in the contract. A
contract that accumulates its own changelog stops being scannable as a checklist. If you're
tempted to explain HOW a rule came to be, put that in the commit that changed it and state only
WHAT is true now here.
-->

<One paragraph: what this system does, who it's for, and what document this is (the binding
contract — implementations conform to this, not the other way around).>

## Hard rules (non-negotiable)

<Numbered, each individually enforceable — a reviewer (human or agent) checks a diff against one
rule at a time, not a paragraph of principles to keep in mind. review-pantheon's DESIGN.md has
five: read-only, fail-closed, evidence-not-vibes, one-canonical-source-per-concept,
docs-match-code. Aim for that density — each rule short enough to cite by number.>

1. <rule>
2. <rule>

## Data / verdict contract

<The shape of whatever this system produces or consumes — a schema, a JSON contract, an API
response. Show the actual shape (a code block), not just a description.>

### Validation surface

<State explicitly what's actually checked (types, enums, required keys, invariants) versus what's
deliberately left unvalidated, and why. Two different surfaces checked for two different reasons
is the usual shape: a type-strict, fail-closed surface that decisions get made from, and a
display-only surface that's sanitized at render time instead of validated at decision time. Name
the split — don't let a reader assume everything got the same scrutiny.>

## Security posture

<Current-state only — see the binding rule at the top of this file. Every mitigation paired with
what it does NOT close, inline, next to the claim it qualifies — not a disclaimer paragraph at
the end nobody reads against the specific mechanism it limits. If there's a provenance/trust
matrix (which inputs are trusted, from where, and why), this is where it goes — a table, not
prose, so a reviewer can scan it against a diff.>

- <mitigation> — closes <vector>. Honest limit: <what it does not close>.

## Deliberately absent

<What you are explicitly NOT building, and why. Heads off both "why doesn't it do X" questions
and scope creep from a well-meaning contributor filling the gap unasked.>

- <thing not built> — <why>

## Layout

<One file/module → one line saying what it is and who/what reads it. A lookup table for "where
does X live," not a narrative of how it was built. Don't duplicate an enumerable list that has a
canonical home elsewhere (a test suite table in CONTRIBUTING.md, say) — point at it instead;
two lists of the same thing is how they drift.>

```
path/               what it is, what reads it
```
