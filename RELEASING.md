# Releasing — the operator's ceremony

This is a human checklist, not automation — `.github/workflows/release.yml` only reacts to a tag
push (build + test + publish); it never creates or moves a tag itself. `main` is protected and
the `v*` tag pattern has its own ruleset, so most of this can only be done by whoever has that
access. Doc index: [docs/README.md](docs/README.md). Binding contract: [DESIGN.md](DESIGN.md).

## Checklist

- [ ] **`dev` is green.** `origin/dev`'s latest commit has a passing `ci` run (all three jobs:
      `lint-and-test`, `setup-smoke`, `composite-action-self-check`).
- [ ] **Bump `pyproject.toml`'s `version` to match the tag you're about to cut** — PEP 440 form,
      no `v` prefix (tag `vX.Y.Z` → `version = "X.Y.Z"`). Do this as part of the
      `dev` → `main` promotion PR below (or a follow-up commit on `main` before tagging) — it must
      land on the commit you're about to tag. `.github/workflows/release.yml`'s `test` job gates
      on this: a tag that doesn't match `pyproject.toml`'s version fails loud, before the build
      step ever runs, so a forgotten bump blocks the release rather than shipping a
      mismatched-version tarball/wheel.
- [ ] **Promote `dev` → `main` via PR.** `main` is protected — no direct push. Open a PR from
      `dev` into `main`, get it reviewed, merge it. The merge commit on `main` is what gets
      tagged, never a commit that only exists on `dev`.
- [ ] **Tag the `main` commit:**
      ```bash
      git fetch origin
      git tag -a vX.Y.Z origin/main -m "vX.Y.Z"
      git push origin vX.Y.Z
      ```
      The push fires `.github/workflows/release.yml`, which runs six steps in order:
      1. **Reject a non-strict tag.** The workflow's own `v*.*.*` trigger is a glob and would
         otherwise also fire on `v1.2.3-rc1` or similar, but `bootstrap.sh --version` only ever
         accepts strict `vX.Y.Z` (digits only, no `-rc1`/build-suffix) — a release built from
         anything looser would be unfetchable by that surface. This step refuses the tag before
         anything else runs.
      2. **Enforce the promotion order.** Refuses unless the tagged commit is reachable from
         `origin/main` — a well-formed `vX.Y.Z` tag cut straight from `dev` (skipping the
         promotion step above) fails here, not silently.
      3. **Verify the tag matches `pyproject.toml`'s version** (the bump step above) — fails
         loud on mismatch, before any build or test step runs.
      4. **Re-run the lint/fixture/quality-gate suite.** The same suite `ci.yml`'s `lint-and-test`
         job runs — every fixture suite, plus the `pantheon` package's own `pip install -e .` +
         `ruff`/`mypy`/`pytest` gates — pinned at the tag (not a branch head).
      5. **Build and publish.** Only if step 4 passes: builds `review-pantheon-vX.Y.Z.tar.gz`
         (`agents/`, `skills/`, `pantheon/`, `pyproject.toml`, `bootstrap.sh`, `install.sh`,
         `REVIEW_RULES.example.md`, `gate.conf.example`, `LICENSE`, `README.md`) — no `action/`
         entry: `install.sh`'s Way A generates its thin-caller workflow at install time instead
         of vendoring one (issue #36) — generates `SHA256SUMS`, and publishes both as a GitHub
         Release with auto-generated notes.
      6. **Publish to PyPI.** Only if step 5 succeeds: builds the sdist + wheel
         (`python -m build`) and publishes them via PyPI's trusted publisher — OIDC only, no API
         token or secret involved. The trusted publisher is configured on PyPI's side for owner
         `G-Schumacher44`, repo `review-pantheon`, workflow `release.yml`, environment `pypi`;
         this job runs under a GitHub Environment named `pypi`, which is also where any
         deployment protection rules (required reviewers, wait timers) can be added later — see
         Settings → Environments on the repo.
- [ ] **Verify the release workflow went green and every asset landed** before announcing
      anything: `gh run list --workflow=release.yml --limit 1`,
      `gh release view vX.Y.Z` (confirm `review-pantheon-vX.Y.Z.tar.gz` AND `SHA256SUMS` are
      both listed as assets, not just one), and `pip index versions review-pantheon` (or the
      package's PyPI project page) to confirm `X.Y.Z` published.
- [ ] **Tick the GitHub Marketplace box — every release, not just the first.** The workflow's
      `gh release create` step above publishes the Release non-interactively, so this is a
      follow-up edit: open the Release in the GitHub UI (Releases → the tag → Edit release) and
      check "Publish this Action to the GitHub Marketplace" before saving. Marketplace does NOT
      automatically adopt a repo's newer releases or a moved `v1` tag — a release that skips this
      checkbox leaves the Marketplace listing pointing at the previous published release even
      though PyPI, the GitHub Release, and `v1` have all advanced. `action.yml`'s branding block
      (`branding:`) already satisfies Marketplace's listing requirements, so this is a checkbox,
      not a follow-up implementation task.

## Moving the `v1` major tag

> [!WARNING]
> Moving `v1` re-points **every consumer's `uses: G-Schumacher44/review-pantheon@v1`** — the
> published-action surface (`examples/review-gate.yml`, `docs/SETUP.md`'s Way C, any external repo
> that copied that reference) starts running whatever `v1` now points at on their very next PR,
> no opt-in, no notice. Only ever move it to a tag that just passed the release gate above —
> never straight from a local branch, never before `SHA256SUMS`/the tarball are confirmed
> attached.

```bash
git tag -f v1 vX.Y.Z
git push -f origin v1
```

The `v*` tag ruleset restricts who can force-push tags matching this pattern — if this fails
with a permissions error, that's the ruleset doing its job, not a bug.

## After releasing

- [ ] Spot-check `examples/review-gate.yml`'s `uses: G-Schumacher44/review-pantheon@v1` still
      resolves to the tag you just moved `v1` to (`gh api repos/G-Schumacher44/review-pantheon/git/ref/tags/v1`).
- [ ] If this was the first-ever release (no `v1` existed before), this is also the point where
      `examples/review-gate.yml`'s `@v1` reference and `bootstrap.sh`'s `curl | bash` remote-fetch
      path stop being aspirational — see `examples/review-gate.yml`'s header comment.
- [ ] `install.sh`'s Way A pins a full commit SHA (`WAY_A_PIN_SHA`/`WAY_A_PIN_RELEASE` near its
      top), deliberately NOT the `v1` tag — moving `v1` above does not re-pin it. Decide whether
      this release warrants re-pinning Way A too (resolve the new tag's commit the same way,
      update both constants, run `tests/test-install.sh` to confirm the generated stub picks it
      up) — a routine patch release may not need every adopter's generated workflow bumped
      immediately, but don't let it silently drift indefinitely either.
