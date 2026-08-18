#!/usr/bin/env python3
"""sync-wiki.py — regenerate the GitHub wiki as a read-only projection of the gated docs.

The wiki is NEVER hand-edited: every page here is generated from the tracked, PR-gated doc
set (DESIGN.md rule 5's "docs match code" applies to the sources; this script makes the wiki
incapable of independent drift by owning every page it publishes). CI runs this on every push
to dev (the publish-wiki job in .github/workflows/ci.yml); hand edits to the wiki are
overwritten on the next sync, and the shared `_Footer.md` (which GitHub renders beneath every
wiki page) says so.

Usage:
    python3 sync-wiki.py /path/to/wiki-clone          # regenerate pages into the clone
    python3 sync-wiki.py /path/to/wiki-clone --check  # regenerate + exit 1 if anything changed

Stdlib-only, same constraint as the pantheon package. Commit/push is the caller's job (the CI
step or an operator) — this script only writes files, so it stays trivially testable.
"""

from __future__ import annotations

import posixpath
import re
import shutil
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent

# Source doc -> wiki page name (flat namespace; GitHub wikis have no directories).
PAGE_MAP: dict[str, str] = {
    "docs/README.md": "Home",
    "docs/SETUP.md": "Setup",
    "docs/CLI.md": "CLI",
    "DESIGN.md": "Design",
    "SECURITY.md": "Security",
    "CONTRIBUTING.md": "Contributing",
    "RELEASING.md": "Releasing",
}

# Canonical repo-relative path -> wiki page. Relative link targets are RESOLVED against the
# linking file's own directory before lookup, so "../DESIGN.md" from docs/ and "DESIGN.md" from
# the root both canonicalize to "DESIGN.md". Anchors survive: "docs/CLI.md#gateconf" ->
# "CLI#gateconf".
LINK_MAP: dict[str, str] = dict(PAGE_MAP)

BLOB_BASE = "https://github.com/G-Schumacher44/review-pantheon/blob/dev/"

SIDEBAR = """**[Home](Home)**

*Install & use*
- [Setup](Setup)
- [CLI reference](CLI)

*The contract*
- [Design](Design)
- [Security](Security)

*Maintaining*
- [Contributing](Contributing)
- [Releasing](Releasing)
"""

FOOTER = (
    "\n\n---\n*Generated from the repo's gated `docs/` by `sync-wiki.py` — do not edit this "
    "wiki directly; hand edits are overwritten on the next sync. Changes land via pull request "
    "to [the repository](https://github.com/G-Schumacher44/review-pantheon), where the review "
    "gate sees them.*\n"
)


def rewrite_links(text: str, src: str) -> str:
    """Point markdown links at wiki pages where a page exists, absolute blob URLs where not.

    Only relative links are touched; absolute URLs and pure #anchors pass through. This is a
    conservative textual rewrite (the docs are lint-clean CommonMark), not a markdown parser —
    the same trade every doc-lint check in this repo makes.
    """

    def repl(m: re.Match[str]) -> str:
        label, target = m.group(1), m.group(2)
        if target.startswith(("http://", "https://", "#", "mailto:")):
            return m.group(0)
        path, anchor = (target.split("#", 1) + [""])[:2]
        anchor = f"#{anchor}" if anchor else ""
        # Resolve against the LINKING FILE'S directory — a bare "DESIGN.template.md" inside
        # docs/README.md means docs/DESIGN.template.md, not a root file (the first draft of
        # this script produced exactly that 404, caught by the blob-link audit).
        src_dir = posixpath.dirname(src)
        path = posixpath.normpath(posixpath.join(src_dir, path)) if path else path
        if path in LINK_MAP:
            return f"[{label}]({LINK_MAP[path]}{anchor})"
        # A relative link to something we don't project (examples/, agents/, skills/, code):
        # send it to the real file on GitHub rather than a wiki 404. `path` is already
        # canonical repo-relative after the normpath above.
        return f"[{label}]({BLOB_BASE}{path}{anchor})"

    return re.sub(r"\[([^\]]*)\]\(([^)\s]+)\)", repl, text)


def _clear_destination(dest: Path) -> None:
    """Clear a hostile occupant of a generated page's path before write_text() touches it.

    write_text() follows symlinks, so a reserved page name (e.g. "Home.md") planted as a
    symlink would silently redirect the write to whatever it points at — possibly outside the
    wiki tree entirely, while staying tracked as an ordinary wiki file. And write_text() raises
    IsADirectoryError on a directory, wedging every publication. Checking is_symlink() first
    (mirrors the stray-sweep below) means a symlink is always removed as a link, never
    dereferenced into is_dir()/rmtree.
    """
    if dest.is_symlink():
        dest.unlink()
    elif dest.is_dir():
        shutil.rmtree(dest)


def generate(wiki_dir: Path) -> list[str]:
    """Write every page; return the list of page filenames written."""
    written: list[str] = []
    keep: set[str] = {"_Sidebar.md", "_Footer.md"}
    for src, page in PAGE_MAP.items():
        body = (REPO_ROOT / src).read_text(encoding="utf-8")
        out = rewrite_links(body, src)
        dest = wiki_dir / f"{page}.md"
        _clear_destination(dest)
        dest.write_text(out, encoding="utf-8")
        written.append(f"{page}.md")
        keep.add(f"{page}.md")
    sidebar_dest = wiki_dir / "_Sidebar.md"
    _clear_destination(sidebar_dest)
    sidebar_dest.write_text(SIDEBAR, encoding="utf-8")
    footer_dest = wiki_dir / "_Footer.md"
    _clear_destination(footer_dest)
    footer_dest.write_text(FOOTER.strip("\n") + "\n", encoding="utf-8")
    written += ["_Sidebar.md", "_Footer.md"]

    # This script owns the WHOLE wiki, not just the *.md namespace: GitHub wikis can serve
    # pages in other markups (.mediawiki, .creole, .textile, .rst, .asciidoc, ...) and can hold
    # subdirectories. Any entry outside the generated set (and .git) is a hand edit or a stale
    # projection — of any format, at any depth — and leaving it live would be exactly the
    # ungated-surface drift the projection design exists to prevent. `keep` is the generated
    # filename set only; `written`'s stray-removal markers must never be checked against
    # themselves.
    for entry in wiki_dir.iterdir():
        if entry.name == ".git" or entry.name in keep:
            continue
        # Check is_symlink() first: entry.is_dir() follows symlinks, so a tracked symlink to a
        # directory would otherwise hit shutil.rmtree() — which refuses to operate on a symlink
        # and raises, breaking every publication until the wiki is hand-repaired. A symlink is
        # always removed as a link (never dereferenced into rmtree), so following one out of the
        # wiki tree can never happen here.
        if entry.is_symlink():
            entry.unlink()
        elif entry.is_dir():
            shutil.rmtree(entry)
        else:
            entry.unlink()
        written.append(f"(removed stray {entry.name})")
    return written


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    wiki_dir = Path(sys.argv[1])
    if not (wiki_dir / ".git").exists():
        print(f"sync-wiki: {wiki_dir} is not a git clone of the wiki repo", file=sys.stderr)
        return 1
    for page in generate(wiki_dir):
        print(f"sync-wiki: wrote {page}")
    if "--check" in sys.argv[2:]:
        import subprocess

        dirty = subprocess.run(
            ["git", "-C", str(wiki_dir), "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if dirty:
            print("sync-wiki: wiki is out of date with the docs:\n" + dirty, file=sys.stderr)
            return 1
        print("sync-wiki: wiki matches the docs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
