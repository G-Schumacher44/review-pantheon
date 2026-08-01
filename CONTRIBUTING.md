# Contributing

## Ground rules

- **PRs only.** `dev` is the base branch and is ruleset-protected; `main` is the release branch.
  Nobody — including the maintainer — pushes to either directly.
- **Every PR is gated twice: the repo's own review method, then a human.** This repo reviews its
  own PRs with the same panel it ships (see [README's "The panel"](README.md#the-panel)) — Artemis
  hunts the diff, Apollo verifies the claim against git reality. The gate is fail-closed: a
  missing or unparseable verdict from either twin is a failed check, not a pass. A human still
  reads and decides; the gate informs that decision, it doesn't replace it.
- **Findings get fixed or tracked — never silently dropped.** Address a finding in the same PR, or
  open an issue for it and resolve the review thread pointing at that issue number. A review
  thread left unresolved with nothing linked is the one state this repo doesn't allow.

## Dev setup

```bash
git clone https://github.com/G-Schumacher44/review-pantheon.git
cd review-pantheon
```

Prerequisites (bash, git, jq, gh, python3 for the Action lane, one provider CLI): see
[docs/SETUP.md](docs/SETUP.md#prerequisites) for the full table and what each one gates.

Run the suites — each is a standalone fixture test, no runner needed:

| Script | Covers |
|---|---|
| `tests/test-verdict-decision.sh` | The verdict-decision rule, cross-checked against both runtimes (`cli/lib/verdict.sh`, `action/decide_verdict.py`). |
| `tests/test-base-pinned-read.sh` | `cli/lib/pantheon-base-pin.sh` — base-SHA-pinned reads, including the symlink-resolution edge case. |
| `tests/test-render-comment.sh` | `cli/lib/render_comment.sh`, the combined-PR-comment renderer. |
| `tests/test-install.sh` | `install.sh`'s editor/CLI projection lanes. |
| `tests/test-prompt-assembly.sh` | Prompt assembly, including the spec-aware Apollo path. |
| `tests/test-state-persistence.sh` | `cli/review-gate`'s follow-up-mode state file. |
| `tests/test-git-readonly-wrapper.sh` | `cli/lib/pantheon-git-readonly.sh`, the read-only execution tier's argv-validating wrapper. |
| `tests/test-execution-tier.sh` | The tiered-execution feature (`readonly` vs `trusted`) end to end. |
| `tests/test-action-refs.sh` | Every `github.action_path` reference in `action.yml` resolves, plus SHA-pin checks. |
| `tests/test-setup-smoke.sh` | Clean-machine setup story — runs inside `Dockerfile.smoke` in CI, see below. |

```bash
bash tests/test-verdict-decision.sh
# ...repeat per script, or run the ones relevant to your change
```

**Shellcheck.** CI runs `shellcheck` repo-wide against every `*.sh` file and `cli/review-gate`
itself — run it locally before pushing, same invocation `.github/workflows/ci.yml` uses:

```bash
find . -type f \( -name '*.sh' -o -name 'review-gate' \) -not -path './.git/*' -print0 \
  | xargs -0 -n1 shellcheck
```

**Container-verify for shell-heavy changes.** `Dockerfile.smoke` exists because this repo's
day-to-day development is macOS and the CLI targets Linux CI too — GNU coreutils behavior (e.g.
the real `timeout` binary vs. the manual TERM/KILL fallback `cli/review-gate` uses when `timeout`
isn't present) doesn't round-trip. "Passes on my Mac" is not a pass for anything touching
`cli/review-gate`, the provider lanes, or the wrapper. Build and run it before pushing:

```bash
docker build -f Dockerfile.smoke -t review-pantheon-smoke .
docker run --rm review-pantheon-smoke
```

## Design constraints

`DESIGN.md` is the contract, not a suggestion — read it before changing anything under `agents/`,
`cli/`, or `action/`. A few rules bite contributors most often:

- **Fail-closed everywhere.** A missing, empty, or unparseable verdict (or, more generally, any
  gate-behavior signal) must degrade toward the safer failure, never toward a silent pass.
- **One canonical persona per agent.** `agents/<name>.md` is the only hand-maintained copy; both
  runners load and template that file. A persona is never inlined or forked per-runtime.
- **Docs match code — rule 5.** If `DESIGN.md` and an implementation disagree, that's a bug in one
  of them. Fix the divergence in the same PR that introduced it; don't leave the doc stale.
- **Base-pinned provenance for anything the gate reads that shapes its own behavior** (personas,
  the verdict decider, the read-only git wrapper, house-rules/spec files) — read from the PR's
  base commit or this repo's own trusted checkout, per DESIGN.md's read-provenance matrix,
  including its disclosed exceptions (the vendored `action/review.yml` workflow reads
  house-rules/spec content from the checked-out working tree instead — a documented, narrower
  exception, not a precedent to extend). See DESIGN.md's ["Security
  posture"](DESIGN.md#security-posture-kept-from-the-private-ancestor-by-design) for the full
  matrix and why.
- **Every new fixture must be shown failing against the pre-fix code.** A test that was never red
  proves nothing about the fix it's supposed to cover — this repo's own fixture tests follow that
  pattern (see `tests/test-git-readonly-wrapper.sh`'s history for a worked example) and reviewers
  will ask for it.

## Scope

See the [issues list](https://github.com/G-Schumacher44/review-pantheon/issues) for open work and
known gaps. The CLI is bash by design for v1 — the read-only-git wrapper, the deciders, the
provider lanes all lean on that being a hard constraint, not an oversight. A Python CLI port is a
planned v2 track; discussion and contributions toward it are welcome, but it's a separate surface
from the current bash implementation, not a rewrite-in-place.

## License

MIT. Contributions are accepted under the same license as the rest of the repo — see
[LICENSE](LICENSE).
