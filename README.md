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

**Why this instead of CodeRabbit/Copilot code review:** two independent agents (Artemis, Apollo)
split "does the diff look right" from "did the PR actually do what it claims," instead of one
reviewer doing both jobs. `DESIGN.md` is a spec-as-contract — Apollo gates against what YOU wrote
down, not a generic checklist. The verdict is [fail-closed](#how-the-gate-stays-honest), not a
review-quality promise. And it's bring-your-own Claude subscription (`claude_code_oauth_token`),
not a per-seat SaaS.

**Stability.** Within v1, the action's input names, `gate.conf` keys, and CLI flags are a stable
contract — renames only ride a major version bump, with a deprecation note.

## Quick start

No GitHub App, no signup, no third-party access grant — this file plus your own token is the
entire footprint. Three steps, no app:

**1. Add the workflow file** — `.github/workflows/review-gate.yml`:

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

**2. Add the token secret** — mint one with `claude setup-token`, then add it as the
`CLAUDE_CODE_OAUTH_TOKEN` repo Actions secret.

**3. Arm it** — set the `REVIEW_GATE_ENABLED` repo variable to `true`. Until then, the workflow
file sits inert; adding it never silently starts gating PRs.

Full recipe with comments explaining every line: [examples/review-gate.yml](https://github.com/G-Schumacher44/review-pantheon/blob/dev/examples/review-gate.yml).

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

### The other half — counsel before you build

The gate above enforces after the fact. The same install (`pip install review-pantheon` or
`brew install g-schumacher44/tap/review-pantheon`) also ships `pantheon counsel` — three advisory
agents (Socrates on options and go/no-go, Diogenes on excess, Plato on coherence) run against a
branch diff *before* it's a PR:

```bash
pantheon counsel --branch
```

Prints each agent's verdict to stdout and posts nothing — no PR required, no comment left
anywhere. Same token, same env var (`CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`), no extra
setup. Every flag: [docs/CLI.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/docs/CLI.md).

### Trust capsule — what you're wiring in

Before you hand it a token, here's what you're wiring in:

- **What it sends to the reviewer:** your PR's diff (`git diff <base>...<head>`); plus two kinds of
  review input — the bundled personas and verdict decider ship *inside the action itself*
  (`github.action_path`), so their revision is fixed by the ref your workflow calls — `@v1` in the
  Quick start is a moving major tag; call a release tag or full commit SHA instead to freeze them;
  your repo's own `REVIEW_RULES.md`, `DESIGN.md`, and any custom personas (`personas_path`) are
  optional and, when present, read base-pinned from your PR's base commit. It does not read or need
  your other secrets.
- **What it could reach:** the reviewer's `Read`/`Grep`/`Glob` tools are not path-scoped — they can
  open any file the runner process can read ([SECURITY.md → Execution
  tiers](https://github.com/G-Schumacher44/review-pantheon/blob/dev/SECURITY.md#execution-tiers)).
  The list above is what a review *uses*; this line is the honest ceiling on what it *could* read.
- **What it can post:** exactly one PR comment — the combined verdict. No commits, no branches, no
  releases, no settings.
- **The permissions ceiling** is the `permissions:` block in the Quick start YAML above:
  `contents: read` and `pull-requests: write`, nothing more. GitHub enforces whatever the calling
  workflow grants, so keep that block as shown — widening it widens a compromised run's reach
  ([SECURITY.md → Blast radius](https://github.com/G-Schumacher44/review-pantheon/blob/dev/SECURITY.md#blast-radius)).
- **The inner reviewer is SHA-pinned.** Inside the action, `anthropics/claude-code-action` is
  pinned to a full commit SHA, not a floating tag (this pin covers the reviewer engine — the outer
  ref your workflow calls is governed by the bullet above). Verify the pin yourself before
  adopting — resolve the pinned version's tag to its commit and confirm it matches `action.yml`:

  ```bash
  gh api repos/anthropics/claude-code-action/commits/v1.0.195 --jq .sha
  # → d40ddef4c030e508327d6e35a9c45f3368482c50   (must equal the SHA action.yml pins)
  ```

Reviewing untrusted content runs read-only by default; the full model and its honest limits are in
[SECURITY.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/SECURITY.md).

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
| Install it | [docs/SETUP.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/docs/SETUP.md) — three ways, zero-token demo |
| Use the CLI | [docs/CLI.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/docs/CLI.md) — every flag, `gate.conf`, worked examples |
| Review security | [SECURITY.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/SECURITY.md) — scope, reporting, honest limits |
| Contribute | [CONTRIBUTING.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/CONTRIBUTING.md) — ground rules, dev setup |

Also here: the binding spec ([DESIGN.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/DESIGN.md)),
the Claude Code skills ([skills/](https://github.com/G-Schumacher44/review-pantheon/tree/dev/skills),
`/gate` + `/counsel`), the release ceremony ([RELEASING.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/RELEASING.md)),
and the full doc index ([docs/README.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/docs/README.md)).

## How the gate stays honest

A missing, empty, or unparseable verdict can never render green — it degrades to `UNVERIFIED`,
mechanically, so the one failure mode worse than an honest red can't happen quietly. Cross-review by
a second agent is the real backstop against a compromised agent's deceptive-but-schema-valid
verdict, not a guarantee. Full model, honestly scoped:
[SECURITY.md](https://github.com/G-Schumacher44/review-pantheon/blob/dev/SECURITY.md) and DESIGN.md's
["Security posture"](https://github.com/G-Schumacher44/review-pantheon/blob/dev/DESIGN.md#security-posture).

## Works with Conductor

[aug-conductor-wrkflw](https://github.com/G-Schumacher44/aug-conductor-wrkflw) pairs with this
repo — it plans the work (slices, handoffs), review-pantheon verifies the delivery and
pressure-tests the plan before it's built.

---

<a name="on-generative-ai-use"></a>
**On generative AI use.** Claude agents built this repo — a from-scratch public rebuild of a private
review system the author runs, no code copied over, `DESIGN.md` as the binding contract, a human
coordinator directing. It has gated its own PRs since branch protection landed 2026-07-31 (one
disclosed pre-gate exception used the admin hatch and was re-landed through the gate after —
CONTRIBUTING.md's "Ground rules" covers it). The git history shows what landed before the gate and
what after; that's the point of keeping it. See DESIGN.md for the design story.

## License

MIT — © 2026 Garrett Schumacher. See [LICENSE](https://github.com/G-Schumacher44/review-pantheon/blob/dev/LICENSE).
