---
name: design-contract
description: How to AUTHOR a binding contract doc (DESIGN.md-style) before building — hard rules, data contracts with explicit validation surfaces, honestly-scoped security posture, a deliberately-absent list, and a layout map, with what to leave OUT (incident history, forked inventories). Use when starting a new feature/system, writing a spec for an agent or team to build from, or adopting review-pantheon's spec_file check. Worked example throughout: this repo's own DESIGN.md.
---

# Authoring a binding contract doc

This is the authoring guide — for the methodology once a contract exists (sliced changes,
fail-closed gates, findings discipline), see the `spec-driven` skill. Worked example throughout:
this repo's own [`DESIGN.md`](../../DESIGN.md).

## When to write one

Before any non-trivial build — the contract precedes code, not the other way around. If the
approach itself is still open (more than one genuinely distinct way to build it), run
`socrates` (see the `counsel` skill) first and let that go/no-go land before drafting the
contract; don't draft a contract around an approach that hasn't been chosen yet.

## What a contract contains

- **Hard rules — numbered, non-negotiable, each individually enforceable.** Not principles to
  keep in mind; things a reviewer (human or agent) can check a diff against one at a time. This
  repo's `DESIGN.md` has five: read-only, fail-closed, evidence-not-vibes, one canonical persona
  per agent, docs-match-code. Each is short enough to cite by number.
- **Data contracts / schemas, with the validation surface stated explicitly.** Don't just show
  the shape — say what's actually checked (types, enums, required keys) versus what's
  deliberately left unchecked, and why. `DESIGN.md`'s "Validation surface" section is the worked
  example: it splits the verdict object into a type-strict, fail-closed surface (what the
  blocker invariant reasons over) and a deliberately-unvalidated display surface (what only ever
  gets rendered, sanitized at the render layer instead) — naming that split explicitly is what
  keeps a reviewer from assuming everything got the same scrutiny.
- **Security posture, scoped to what's actually implemented.** State honest limits inline, next
  to the claim they qualify — not as a disclaimer paragraph at the end nobody reads against the
  specific mechanism it limits. `DESIGN.md`'s security section pairs every mitigation with what
  it does *not* close (e.g. "raises the bar... rather than making [compromise] impossible").
- **A deliberately-absent list.** What you are explicitly NOT building, and why — this heads off
  both "why doesn't it do X" questions and scope creep from a well-meaning contributor filling
  the gap unasked. See `DESIGN.md`'s "Deliberately absent."
- **A layout/ownership map.** One file → one line saying what it is and who/what reads it. Not a
  narrative of how it was built — a lookup table for "where does X live."

## What a contract excludes (the hard-won part)

- **Incident history / changelogs.** Extract them to a separate doc (this repo's
  `docs/HARDENING-HISTORY.md`). Density kills a contract — if every rule carries its own origin
  story, the doc stops being scannable as a checklist and a reviewer stops reading it as one.
- **Duplicated inventories that fork.** One canonical home per enumerable list, everything else
  points at it. `DESIGN.md`'s "Layout" section explicitly declines to re-list the test suite
  (`CONTRIBUTING.md`'s table is canonical) — two lists of the same thing is how they drift.
- **Restatements of things another doc owns.** If `CONTRIBUTING.md` owns the dev-setup ritual,
  the contract doc points at it rather than repeating it stale.

## The binding rules

- **Docs-match-code.** A divergence between the contract and the implementation is a bug in one
  of them — fixed in the same PR that caused it, not deferred.
- **The contract is what delivery gets verified against**, not just aspirational prose: when a
  governing spec file is configured (this gate's `apollo`, via `spec_file`), the verifier reads it
  mechanically and flags contradictions between the delivered change and the sections relevant to
  what changed — that's the enforcement loop a contract doc plugs into, not merely a doc a human
  might read.
- **Update the contract in the same PR as the behavior change it governs**, never as a follow-up.

## Practical shape

Contract-not-encyclopedia: size it to be read start-to-finish in one sitting. Prefer a table for
anything enumerable (verdict vocabulary, provenance matrix, file layout) over prose paragraphs —
tables are what a reviewer actually scans against a diff. State each concept once, canonically,
and point to that one place from everywhere else it's relevant.
