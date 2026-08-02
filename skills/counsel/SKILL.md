---
name: counsel
description: Convene review-pantheon's counsel tier (Socrates, Diogenes, Plato) — advisory agents that inform a human's decision on a spec, design doc, proposal, existing code, or a diff, and never gate a merge. Use when asked to "get a second opinion on this design," "run counsel," "is this over-engineered," "does this have a coherent shape," "go/no-go on this approach," or before committing to an implementation plan.
---

# Convening the counsel tier

Counsel agents (Socrates, Diogenes, Plato) **inform** — a human weighs their verdict. That's
different from the gate agents (Artemis, Apollo), which **enforce** and can block a merge. Full
persona definitions and the verdict vocabulary table: [DESIGN.md](../../DESIGN.md#the-idea).

## Which lens, when

- **Socrates — open decisions.** Maps genuinely distinct approaches against what the codebase
  already has and ends with a go/no-go. Run this *first*, and only while the approach itself is
  still undecided — once a shape is already committed to, Socrates' framing doesn't fit the
  question anymore.
- **Diogenes — over-build check.** Assumes the plan or code works; asks only whether it's *more
  than the job needs*. Run once a shape (a design, or already-written code) exists to weigh.
- **Plato — coherence/drift check.** Also assumes it works; asks whether it has *one consistent
  shape* or is ad-hoc sprawl — a duplicated concept, a special case where a coherent abstraction
  belongs. Diogenes' foil: he cuts what's extra, Plato asks what's missing structurally.

All three read the same kinds of input identically — a spec, a design doc, a proposal, existing
code, or a diff — whichever one they're handed. Timing (Socrates early, Diogenes/Plato once a
shape exists) is the convention this tier is designed around, not an access restriction.

## Invoking it

- **In a Claude Code session** (after `install.sh --claude`): `/counsel <reference>` — the
  generated command wraps the three agents installed at `.claude/agents/{socrates,diogenes,plato}.md`,
  runs Socrates first when the decision is still open, then Diogenes + Plato on the resulting
  shape, and synthesizes the verdicts.
- **Through the CLI gate** — a documented exception, not the default workflow:
  `review-gate --pr <n> --agents "socrates diogenes plato"`. Mechanically this gates *exactly*
  like Artemis/Apollo would: a `NO_GO`/`GUT`/`FRACTURED` verdict produces the same 🔴 blocked
  comment and nonzero exit a `STOP` from Artemis would. "Counsel never gates" is a usage
  convention (only Artemis/Apollo run automatically in CI) — the CLI itself doesn't distinguish
  gate agents from counsel agents. Don't wire a counsel-only `--agents` list into an automatic CI
  step expecting advisory-only behavior; it will block.

## Anti-patterns

- **Don't run all three on everything.** Socrates against code whose approach is already decided
  wastes its go/no-go framing on a closed question — skip it and run Diogenes + Plato alone when
  the request makes clear the shape, not the approach, is under review.
- **A yellow counsel verdict (`GO_WITH_GUARDRAILS`, `TRIM`, `DRIFTING`) is not a blocker.** It's a
  data point for the human deciding, not a reason to reflexively rework something the actual gate
  (Artemis/Apollo) already accepted. Don't treat counsel output as a second, informal gate.
- **Don't skip Diogenes/Plato just because Socrates went `GO`.** A go/no-go on the approach says
  nothing about whether the resulting shape stayed lean and coherent once built.
