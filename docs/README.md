# Docs index

| Doc | Description |
|---|---|
| [DESIGN.md](../DESIGN.md) | The contract. Hard rules, the verdict schema, security posture, configuration keys, and the surface-differences table every agent and provider lane is required to follow. |
| [HARDENING-HISTORY.md](HARDENING-HISTORY.md) | The security wrapper's round-by-round hardening history (Round 1–8) — moved out of DESIGN.md's main flow to keep the contract itself readable. DESIGN.md's "Security posture" section is still canonical for current-state behavior; this is the changelog. |
| [PYTHON-PORT.md](PYTHON-PORT.md) | The binding spec for the Python CLI port (v2 track) — packaging, CLI surface, the migration exam against the existing fixture suites, security-core carryover, module layout, and the slice plan. To the port what DESIGN.md is to the gate. |
| [SETUP.md](SETUP.md) | Install (three ways), the zero-token `--dry-run` demo, first live run, and troubleshooting (draft skips, UNVERIFIED causes, timeouts, force-push fallback). |
| [CLI.md](CLI.md) | The full `review-gate` CLI reference: every flag, every `gate.conf` key, the execution tiers, the follow-up-mode state model, exit codes, reading a verdict comment, and worked examples. |
| [RELEASING.md](../RELEASING.md) | The operator's release ceremony — dev→main promotion, tagging, moving the `v1` major tag, and the release gate `.github/workflows/release.yml` runs before publishing. |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Ground rules (PRs only, the review-loop contract), dev setup, the test suites, shellcheck/container-verify expectations, and design constraints contributors must respect. |
| [SECURITY.md](../SECURITY.md) | Supported surface, how to report a vulnerability privately (GitHub security advisories), and the honest scope notes on the `readonly`/`trusted` execution tiers. |
| [REVIEW_RULES.example.md](../REVIEW_RULES.example.md) | The shipped starting point for a house-spec: blocker-class rules Artemis and Apollo check on every PR. Copy to `REVIEW_RULES.md` at your repo root and edit it to match your team's actual rules. |
| [agents/artemis.md](../agents/artemis.md) | Gate agent — the hunter. Reviews the diff itself for correctness risks, untested failure paths, shortcuts, and house-rule violations. |
| [agents/apollo.md](../agents/apollo.md) | Gate agent — the verifier. Audits the claim of completed work against git reality. |
| [agents/socrates.md](../agents/socrates.md) | Counsel agent — options analyst. Maps distinct approaches and a go/no-go call before anything is built. |
| [agents/diogenes.md](../agents/diogenes.md) | Counsel agent — simplicity auditor. Assumes it works; asks only whether it's more than it needs to be. |
| [agents/plato.md](../agents/plato.md) | Counsel agent — coherence auditor. Assumes it works; asks whether it has one consistent shape or drifting sprawl. |
| [skills/gate/SKILL.md](../skills/gate/SKILL.md) | Claude Code skill — operating the gate from a session: dry-run first, reading the combined verdict, follow-up mode, findings discipline. |
| [skills/counsel/SKILL.md](../skills/counsel/SKILL.md) | Claude Code skill — convening the counsel tier: which lens when, invocation, anti-patterns. |
| [skills/spec-driven/SKILL.md](../skills/spec-driven/SKILL.md) | Claude Code skill — the transferable spec-driven methodology, for any adopting repo. |
| [skills/design-contract/SKILL.md](../skills/design-contract/SKILL.md) | Claude Code skill — authoring a binding contract doc (DESIGN.md-style): what to include, what to leave out. |
| [docs/README.md](README.md) | This index. |

See the root [README.md](../README.md) for the quickstart, the panel, and how the gate stays honest.
