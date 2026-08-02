---
name: spec-driven
description: The transferable methodology review-pantheon itself runs on — a binding contract doc, sliced bounded changes, a fail-closed gate on every PR, and fixed-or-tracked findings discipline. Use in ANY repo (not just review-pantheon) when setting up spec-driven development, asked "how should specs work here," "what makes a doc binding," or when scoping a slice for an agent to build against a contract doc.
---

# Spec-driven development, transferable

This is the methodology, not review-pantheon's own gate mechanics — it applies to any repo that
adopts the shape, whether or not it runs this tool. For authoring the contract doc itself, see the
`design-contract` skill; for operating this repo's own gate against it, see the `gate` skill.

## The core move

Pick **one** doc as the binding contract for a surface — this repo's is `DESIGN.md`. "Binding"
means one specific, enforced thing: **docs-match-code is a bug bar, not an aspiration.** If the
doc and the implementation disagree, that's a bug in one of them, fixed in the same PR that
caused the divergence — never left for a later cleanup pass. Adopting this in a new repo starts
with naming which doc is that contract *before* writing code against it, not writing docs
afterward as historical color on already-decided behavior.

## Sliced, bounded changes

A change lands as a slice sized to be reviewed and gated as a whole — not an open-ended branch
that accretes scope while a reviewer loses track of what's actually being claimed done. When a
slice touches behavior the contract doc governs, the doc and the code move together in the same
PR; a PR that changes one without the other is incomplete, not "docs follow-up."

## Every PR gated, fail-closed

A gate — automated review, or a human checklist standing in for one — runs on every PR without
exception. Fail-closed is the load-bearing property: a missing, empty, or unparseable review
result degrades toward the *safer* failure, never toward a silent pass. This is the shape this
repo's own verdict contract encodes (`DESIGN.md` rule 2) — the underlying principle transfers even
to a repo with no formal verdict schema at all: a check that didn't run is a loud gap in the PR,
not a quiet green.

## Findings: fixed or tracked, never dropped

Every finding a gate or reviewer raises gets fixed in the same PR, or gets an issue plus a reply
on the review thread pointing at that issue number, followed by resolving the thread. A thread
left open with nothing linked is the one state not allowed (`CONTRIBUTING.md`'s ground rules).
A reply alone doesn't close the loop — the thread still needs resolving or explicitly tying to a
tracked issue.

## Class-close over instance patches

When a finding reveals a bug *class* — the same defect shape reachable more than one way, not a
one-off — fix the underlying shape once rather than patching only the reported instance and
leaving siblings live. This repo's own security posture is a worked example: a base-pinning gap
was found, fixed as a class across every call site it applied to, and the sweep documented as
such (`DESIGN.md`'s "the class this is one instance of") — not patched once and left for the next
reviewer to rediscover the second and third instance.

## Provenance rules for gate-read files

Any file a reviewer reads that shapes what the review *does* — not just what it judges — must
come from a source the party under review can't rewrite: a base commit predating their change, or
the reviewer's own trusted checkout. A file the change itself can edit and have read back by its
own reviewer is an injection surface, not a review. Full worked matrix for this repo's own gate:
`DESIGN.md`'s "Security posture" → "Read → provenance matrix."

## Transfer checklist for a new repo

1. Name the contract doc.
2. Write the fail-closed rule down explicitly — what a missing or malformed review result means.
3. Wire a gate (this repo's Action/CLI, or your own) to run on every PR.
4. Adopt the fixed-or-tracked findings discipline in that repo's own `CONTRIBUTING.md`.
5. Identify anything your gate reads that shapes its own behavior (personas, decision logic,
   config that changes tool scope) and pin its provenance the same way.
