# Review rules (example)

This is the file `cli/review-gate` and `action/review.yml` pass to Artemis and Apollo as
blocker-class checks, in addition to whatever they find on their own. Copy this to
`REVIEW_RULES.md` at your repo root (or point `rules_file=` in `gate.conf` at wherever you keep
it) and edit it to match your team's actual rules. Each rule below is a blocker: a violation
should push the verdict to red, not just a note.

- **No secrets or credentials in diffs or logs.** No API keys, tokens, passwords, or private
  keys committed in code, config, fixtures, or log output added by this change.
- **No direct commits to the default branch.** All changes land through a pull request; nothing
  in the diff should represent a commit made straight to `main`/`master`.
- **Behavior changes ship with test updates.** If the diff changes observable behavior (not just
  refactors it), a test exists that would fail without the change.
- **No new `TODO`/`FIXME` without a linked issue.** A `TODO` or `FIXME` introduced by this diff
  must reference a tracked issue number; an untracked one is scope debt with no owner.
- **Dependencies are added only with a matching lockfile update.** A new or bumped dependency in
  a manifest file is accompanied by the corresponding lockfile change in the same diff.
