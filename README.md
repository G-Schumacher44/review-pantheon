<div align="center">

<img src="https://raw.githubusercontent.com/G-Schumacher44/review-pantheon/dev/docs/assets/banner.png" alt="review-pantheon — Spec Driven AI Coding toolkit" width="100%"/>

[![CI](https://github.com/G-Schumacher44/review-pantheon/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/G-Schumacher44/review-pantheon/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/G-Schumacher44/review-pantheon/blob/dev/LICENSE)
[![fail-closed by design](https://img.shields.io/badge/fail--closed-by%20design-brightgreen)](#how-the-gate-stays-honest)

</div>

# review-pantheon — Spec Driven AI Coding toolkit

- AI-assisted development produces work faster than a human can independently verify it — the
  bottleneck moves from writing the change to trusting the report of it.
- A pass with no fail-closed rule turns a missing or malformed verdict into a quiet green — the
  one failure mode worse than an honest red.

A portable review gate — a GitHub Action plus a provider-agnostic CLI — that splits "does the
diff look right" from "did the PR actually do what it claims" into two independent agents
(Artemis, Apollo), backed by three advisory philosopher agents for the planning stage before
anything is built. Built for teams where a written spec is the contract, not a suggestion read
once and forgotten: `DESIGN.md` in this repo is itself that contract.

**Who it's for:** teams or solo builders shipping AI-assisted changes fast enough that human
review has become the bottleneck, who want a second opinion that can't be talked out of a red
verdict by a confident-sounding PR description.

**Why this instead of CodeRabbit/Copilot code review:** a missing or malformed verdict can never
render green — the fail-closed rule below is mechanical, not a review-quality promise. Two
independent agents (Artemis, Apollo) split "does the diff look right" from "did the PR actually
do what it claims," instead of one reviewer doing both jobs. `DESIGN.md` is a spec-as-contract —
Apollo gates against what YOU wrote down, not a generic checklist. And it's bring-your-own Claude
subscription (`claude_code_oauth_token`), not a per-seat SaaS.

**Stability.** Within v1, the action's input names, `gate.conf` keys, and CLI flags are a stable
contract — renames only ride a major version bump, with a deprecation note.

## Quick start

Zero footprint — drop this into `.github/workflows/review-gate.yml` (this is the whole install;
gated on a repo variable so adding the file never silently starts gating PRs):

```yaml
name: review-pantheon
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
permissions:
  contents: read
  pull-requests: write
jobs:
  review:
    if: ${{ vars.REVIEW_GATE_ENABLED == 'true' && github.event.pull_request.draft == false }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
          fetch-depth: 0
      - uses: G-Schumacher44/review-pantheon@v1
        with:
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Set the `REVIEW_GATE_ENABLED` repo variable to `true` once the token secret is in place. Full
recipe with comments explaining every line: [examples/review-gate.yml](https://github.com/G-Schumacher44/review-pantheon/blob/dev/examples/review-gate.yml).

*(`@v1` tracks the latest release — it moves when a new one is cut (see
[RELEASING.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/RELEASING.md)). Prefer updates on your own schedule? Pin a full commit SHA
instead — that's exactly what `install.sh`'s generated workflow does.)*

Nothing else lands in your repo. The CLI installs from PyPI or Homebrew:

```bash
pipx install review-pantheon            # or: pip install review-pantheon
brew install g-schumacher44/tap/review-pantheon
```

Want to try it first with zero tokens spent? From any install (or a local
checkout in a venv, `pip install -e .`):

```bash
pantheon gate --pr <number> --dry-run
```

runs the real thing — real diff, real prompts — right up to calling a provider, then prints
exactly what it *would* post. `pantheon` is the CLI (docs/CLI.md). Prefer a vendored install, or
the CLI only? Full walkthrough for every path: [docs/SETUP.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/docs/SETUP.md).

## The panel

**Gate agents** (Artemis, Apollo) enforce — they run on every PR and can block a merge.
**Counsel agents** (Socrates, Diogenes, Plato) inform — a human weighs their verdict; they never
gate, whatever they're pointed at (spec, design doc, proposal, code, or a diff).

| Agent | Tier | Role |
|---|---|---|
| **Artemis** | Gate | Hunts bugs in the diff — assumes nothing works until shown. |
| **Apollo** | Gate | Verifies the claim against git reality, and against the spec when one's configured. |
| **Socrates** | Counsel | Maps distinct approaches, go/no-go — usually runs earliest. |
| **Diogenes** | Counsel | Simplicity — is this more than it needs to be? |
| **Plato** | Counsel | Coherence — one consistent shape, or drifting sprawl? |

Full persona definitions, verdict vocabulary, and the gate-flow diagram: [DESIGN.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/DESIGN.md).

## Where to go

| I want to... | Go to |
|---|---|
| Decide whether to adopt this | This page, plus the security TL;DR below |
| Install it | [docs/SETUP.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/docs/SETUP.md) — three ways, zero-token demo |
| Use the CLI | [docs/CLI.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/docs/CLI.md) — every flag, `gate.conf`, worked examples |
| Use it inside Claude Code | [skills/](https://github.com/G-Schumacher44/review-pantheon/tree/dev/skills) — `/gate` and `/counsel` commands plus the `gate`/`counsel`/`spec-driven`/`design-contract` skills, installed via `install.sh --claude` |
| Understand the design contract | [DESIGN.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/DESIGN.md) — the binding spec |
| Review security | [SECURITY.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/SECURITY.md) — scope, reporting, honest limits |
| Contribute | [CONTRIBUTING.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/CONTRIBUTING.md) — ground rules, dev setup |
| Cut a release (operator) | [RELEASING.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/RELEASING.md) |
| See the full doc index | [docs/README.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/docs/README.md) |

## How the gate stays honest

- Reviewing untrusted PR content runs read-only by default (`execution=readonly`).
- That tool-scoping covers both surfaces — the CLI and the published action — which invoke
  Claude; non-Claude provider lanes aren't covered.
- Nothing here eliminates a fully-compromised agent handing back a deceptive-but-schema-valid
  verdict — cross-review by a second agent is the real backstop, not a guarantee.

Full technical detail, honestly scoped: [SECURITY.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/SECURITY.md) and DESIGN.md's ["Security
posture"](https://github.com/G-Schumacher44/review-pantheon/blob/dev/DESIGN.md#security-posture).

## Works with Conductor

[aug-conductor-wrkflw](https://github.com/G-Schumacher44/aug-conductor-wrkflw) pairs with this
repo — it plans the work (slices, handoffs), review-pantheon verifies the delivery and
pressure-tests the plan before it's built.

---

<a name="on-generative-ai-use"></a>
**On generative AI use.** Claude agents built this repo — a from-scratch public rebuild of a
private review system the author runs, no code copied over, with `DESIGN.md` as the binding
contract and a human coordinator directing the work.

It couldn't gate itself into existence: of the first 44 commits, half went straight to `dev`,
because there was no gate yet to stop them — the original CLI, the Action, and the installers
among them. Branch protection landed 2026-07-31; since then everything goes through the gate
on a pull request, fail-closed — Artemis on every diff, Apollo wherever there's a claim of
work to verify (docs-only changes skip him, loudly) — with one disclosed exception that used
the admin hatch and was re-landed through the gate after (CONTRIBUTING.md's "Ground rules"
covers the hatch).
The history shows which is which — that's the point of keeping it.

Fittingly, one of the gate's first real catches was in this repo's own pre-gate code: PR text
could reach a shell string in a vendored CI workflow — the classic Actions injection. It was
caught and closed while the repo was still private, days before the first public release, and
the published action itself never carried it. Built by AI, directed by a human, gated by
itself — and honest about the order those happened in.

## License

MIT — © 2026 Garrett Schumacher. See [LICENSE](https://github.com/G-Schumacher44/review-pantheon/blob/dev/LICENSE).
