<div align="center">

<img src="docs/assets/banner.png" alt="review-pantheon — Spec Driven AI Coding toolkit" width="100%"/>

<!-- Badges render only for authenticated viewers while this repo is private; they'll render
     for everyone once visibility flips to public — this is expected, not broken, and nothing
     here needs to change when that happens. -->
[![CI](https://github.com/G-Schumacher44/review-pantheon/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/G-Schumacher44/review-pantheon/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
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

## Quick start

Zero footprint — drop this into a workflow file (plus a PR trigger and `pull-requests: write`):

```yaml
- uses: G-Schumacher44/review-pantheon@v1
  with: { claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }} }
```

*(The `@v1` tag lands with this repo's first release — see [RELEASING.md](RELEASING.md). Until
then, pin a commit SHA or point `uses:` at a local checkout instead; a bare `@v1` 404s on a
brand-new checkout, not a typo.)*

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
the CLI only? Full walkthrough for every path: [docs/SETUP.md](docs/SETUP.md).

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

Full persona definitions, verdict vocabulary, and the gate-flow diagram: [DESIGN.md](DESIGN.md).

## Where to go

| I want to... | Go to |
|---|---|
| Decide whether to adopt this | This page, plus the security TL;DR below |
| Install it | [docs/SETUP.md](docs/SETUP.md) — three ways, zero-token demo |
| Use the CLI | [docs/CLI.md](docs/CLI.md) — every flag, `gate.conf`, worked examples |
| Use it inside Claude Code | [skills/](skills) — `/gate` and `/counsel` commands plus the `gate`/`counsel`/`spec-driven`/`design-contract` skills, installed via `install.sh --claude` |
| Understand the design contract | [DESIGN.md](DESIGN.md) — the binding spec |
| Review security | [SECURITY.md](SECURITY.md) — scope, reporting, honest limits |
| Contribute | [CONTRIBUTING.md](CONTRIBUTING.md) — ground rules, dev setup |
| Cut a release (operator) | [RELEASING.md](RELEASING.md) |
| See the full doc index | [docs/README.md](docs/README.md) |

## How the gate stays honest

- Reviewing untrusted PR content runs read-only by default (`execution=readonly`).
- That tool-scoping covers both surfaces — the CLI and the published action — which invoke
  Claude; non-Claude provider lanes aren't covered.
- Nothing here eliminates a fully-compromised agent handing back a deceptive-but-schema-valid
  verdict — cross-review by a second agent is the real backstop, not a guarantee.

Full technical detail, honestly scoped: [SECURITY.md](SECURITY.md) and DESIGN.md's ["Security
posture"](DESIGN.md#security-posture).

## Works with Conductor

[aug-conductor-wrkflw](https://github.com/G-Schumacher44/aug-conductor-wrkflw) pairs with this
repo — it plans the work (slices, handoffs), review-pantheon verifies the delivery and
pressure-tests the plan before it's built.

---

<a name="on-generative-ai-use"></a>
**On generative AI use.** review-pantheon is a public rebuild of a private review system the
author already runs — ported and re-implemented from scratch for open distribution (no code
copied over), with `DESIGN.md` as the rebuild's binding contract. Claude-based agents did the
rebuild work, with the author directing as coordinator — where a commit message says "the
coordinator", that's the human in the loop. The gate could not review this repo until it existed: of the first 44 commits, 23
went straight to `dev` with no pull request, and 14 of those touch code — including the original
CLI, the Action, the installer, and `bootstrap.sh`. Since branch protection landed (2026-07-31),
every change has gone through the gate: Artemis and Apollo on a pull request, fail-closed, no
direct pushes. The history shows which is which.

`88e0b01`, one of those 14, is the commit that introduced a shell-injection defect in the
vendored workflow — found and fixed later by this repo's own twin gate, once there was a gate to
find it. Human-directed, spec-driven, self-gated, and late to gate itself.

## License

MIT — © 2026 Garrett Schumacher. See [LICENSE](LICENSE).
