# Docs index

| Doc | Description |
|---|---|
| [DESIGN.md](../DESIGN.md) | The contract. Hard rules, the verdict schema, security posture, configuration keys, and the lane-differences table every agent and provider lane is required to follow. |
| [SETUP.md](SETUP.md) | Install (three ways), the zero-token `--dry-run` demo, first live run, and troubleshooting (draft skips, UNVERIFIED causes, timeouts, force-push fallback). |
| [REVIEW_RULES.example.md](../REVIEW_RULES.example.md) | The shipped starting point for a house-spec: blocker-class rules Artemis and Apollo check on every PR. Copy to `REVIEW_RULES.md` at your repo root and edit it to match your team's actual rules. |
| [agents/artemis.md](../agents/artemis.md) | Gate agent — the hunter. Reviews the diff itself for correctness risks, untested failure paths, shortcuts, and house-rule violations. |
| [agents/apollo.md](../agents/apollo.md) | Gate agent — the verifier. Audits the claim of completed work against git reality. |
| [agents/socrates.md](../agents/socrates.md) | Counsel agent — options analyst. Maps distinct approaches and a go/no-go call before anything is built. |
| [agents/diogenes.md](../agents/diogenes.md) | Counsel agent — simplicity auditor. Assumes it works; asks only whether it's more than it needs to be. |
| [agents/plato.md](../agents/plato.md) | Counsel agent — coherence auditor. Assumes it works; asks whether it has one consistent shape or drifting sprawl. |
| [docs/README.md](README.md) | This index. |

See the root [README.md](../README.md) for the quickstart, the panel, and how the gate stays honest.
