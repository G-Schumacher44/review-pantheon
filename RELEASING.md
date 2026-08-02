# Releasing — the operator's ceremony

This is a human checklist, not automation — `.github/workflows/release.yml` only reacts to a tag
push (build + test + publish); it never creates or moves a tag itself. `main` is protected and
the `v*` tag pattern has its own ruleset, so most of this can only be done by whoever has that
access. Doc index: [docs/README.md](docs/README.md). Binding contract: [DESIGN.md](DESIGN.md).

## Checklist

- [ ] **`dev` is green.** `origin/dev`'s latest commit has a passing `ci` run (all three jobs:
      `lint-and-test`, `setup-smoke`, `composite-action-self-check`).
- [ ] **Promote `dev` → `main` via PR.** `main` is protected — no direct push. Open a PR from
      `dev` into `main`, get it reviewed, merge it. The merge commit on `main` is what gets
      tagged, never a commit that only exists on `dev`.
- [ ] **Tag the `main` commit:**
      ```bash
      git fetch origin
      git tag -a vX.Y.Z origin/main -m "vX.Y.Z"
      git push origin vX.Y.Z
      ```
      The push fires `.github/workflows/release.yml`, which runs four steps in order:
      1. **Reject a non-strict tag.** The workflow's own `v*.*.*` trigger is a glob and would
         otherwise also fire on `v1.2.3-rc1` or similar, but `bootstrap.sh --version` only ever
         accepts strict `vX.Y.Z` (digits only, no `-rc1`/build-suffix) — a release built from
         anything looser would be unfetchable by that surface. This step refuses the tag before
         anything else runs.
      2. **Enforce the promotion order.** Refuses unless the tagged commit is reachable from
         `origin/main` — a well-formed `vX.Y.Z` tag cut straight from `dev` (skipping the
         promotion step above) fails here, not silently.
      3. **Re-run the lint/fixture suite.** The same suite `ci.yml`'s `lint-and-test` job runs,
         pinned at the tag (not a branch head).
      4. **Build and publish.** Only if step 3 passes: builds `review-pantheon-vX.Y.Z.tar.gz` (the
         CLI surface: `cli/`, `agents/`, `bootstrap.sh`, `install.sh`, `action/decide_verdict.py`,
         `action/review.yml` — the two `action/` files `install.sh`'s default mode requires —
         `REVIEW_RULES.example.md`, `gate.conf.example`, `LICENSE`, `README.md`), generates
         `SHA256SUMS`, and publishes both as a GitHub Release with auto-generated notes.
- [ ] **Verify the release workflow went green and both files attached** before announcing
      anything: `gh run list --workflow=release.yml --limit 1` and
      `gh release view vX.Y.Z` (confirm `review-pantheon-vX.Y.Z.tar.gz` AND `SHA256SUMS` are
      both listed as assets, not just one).

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
