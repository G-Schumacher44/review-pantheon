# Contributing

## Ground rules

- **PRs only.** `dev` is the base branch and is ruleset-protected; `main` is the release branch.
  Nobody pushes to `main` directly — its ruleset admits no bypass at all. `dev` is PR-only too, with
  an admin bypass retained as the maintainer's emergency hatch.
- **This repo reviews its own PRs with the same panel it ships, then a human decides.** CI's
  `composite-action-self-check` job runs a live self-test of `action.yml` against this repo's own
  PRs (Artemis + Apollo, `execution: trusted` — the own-repo/trusted-author case that tier is for) —
  **when it runs.** That step is fail-soft by design, not a required check: it only fires on a
  `pull_request` event with the token secret present, and is a no-op skip notice otherwise. So the
  honest claim is two-layered: any verdict the twins DO post is fail-closed (a missing or unparseable
  one reads `UNVERIFIED`, never green — DESIGN.md rule 2), but CI passing does not by itself guarantee
  a twin review ran. A human reads and decides either way; the gate informs that decision, never
  replaces it.
- **Gate your branch before you open the PR.** `pantheon gate --branch` runs the same twins against
  your local diff, so the PR opens hardened instead of becoming the debugger. Commit first (the gate
  reads commits, not the dirty tree), then:

  ```bash
  pantheon gate --branch          # base: origin/HEAD, else main; or: --branch main
  ```

  Bound yourself to 2–3 runs. If a finding survives and you judge it invalid, refute it in the PR
  body under a "Pre-gate: unresolved findings" heading — never drop it silently. CI's twins remain
  the enforcement floor; this makes their pass cheap.
- **Findings get fixed or tracked — never silently dropped.** Address a finding in the same PR, or
  open an issue for it and resolve the review thread pointing at that issue number. A review thread
  left unresolved with nothing linked is the one state this repo doesn't allow.

## Dev setup

```bash
git clone https://github.com/G-Schumacher44/review-pantheon.git
cd review-pantheon
```

Prerequisites (bash, git, gh, python3, one provider CLI): see
[docs/SETUP.md](docs/SETUP.md#prerequisites) for the full table and what each one gates.

**The test map is [tests/README.md](tests/README.md)** — the canonical per-file list of both the
bash fixture suites and the pytest unit layer, with what each covers. Run one suite, or the ones
relevant to your change:

```bash
bash tests/test-verdict-decision-python.sh   # any one bash suite
pytest -q                                     # the whole pytest layer
```

**Shellcheck.** CI runs `shellcheck` repo-wide against every `*.sh` file — run it locally before
pushing, same invocation `.github/workflows/ci.yml` uses:

```bash
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 shellcheck
```

**Container-verify for shell-heavy changes.** `Dockerfile.smoke` exists because this repo's
day-to-day development is macOS and the setup story targets Linux CI too — GNU coreutils behavior
doesn't always round-trip. "Passes on my Mac" is not a pass for anything touching `install.sh`,
`bootstrap.sh`, or the provider lanes. Build and run it before pushing:

```bash
docker build -f Dockerfile.smoke -t review-pantheon-smoke .
docker run --rm review-pantheon-smoke
```

## Design constraints

`DESIGN.md` is the contract, not a suggestion — read it before changing anything under `agents/`,
`pantheon/`, or `action/`. A few rules bite contributors most often:

- **Fail-closed everywhere.** A missing, empty, or unparseable verdict (or any gate-behavior signal)
  must degrade toward the safer failure, never toward a silent pass.
- **One canonical persona per agent.** `agents/<name>.md` is the only hand-maintained copy; both
  runners load and template that file. A persona is never inlined or forked per-runtime.
- **Docs match code — rule 5.** If `DESIGN.md` and an implementation disagree, that's a bug in one
  of them. Fix the divergence in the same PR that introduced it; don't leave the doc stale.
- **Current-state only, no fix-round narrative.** `DESIGN.md`, `SECURITY.md`, and this file describe
  what's true now — not how it got that way. No round-numbered retries, no earlier-attempt or
  old-fix recaps, no past-tense "we used to…" asides. A PR's own diff and commit history are the
  changelog; a doc that accumulates its own fix history becomes unreadable. CI's doc-lint step
  (`.github/workflows/ci.yml`) fails the build if those markers appear in any of the three — see that
  step's comment for the exact pattern.
- **Base-pinned provenance for anything the gate reads that shapes its own behavior** (personas, the
  verdict decider, the read-only git wrapper, house-rules/spec files) — read from the PR's base
  commit or this repo's own trusted checkout, per DESIGN.md's read-provenance matrix. See DESIGN.md's
  ["Security posture"](DESIGN.md#security-posture) for the full matrix and why.
- **Every new fixture must be shown failing against the pre-fix code.** A test that was never red
  proves nothing about the fix it covers — this repo's own fixtures follow that pattern (see
  `tests/test-git-readonly-wrapper.sh`'s negative-control fixtures) and reviewers will ask for it.

## Scope

See the [issues list](https://github.com/G-Schumacher44/review-pantheon/issues) for open work and
known gaps. `pantheon` (the Python package, stdlib-only) is the CLI, full stop — there is no other
runtime and no deprecation window. New work targets `pantheon/`.

## License

MIT. Contributions are accepted under the same license as the rest of the repo — see
[LICENSE](LICENSE).
