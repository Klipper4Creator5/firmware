"""Two jobs, both about keeping one source of truth.

`on_pre_build` publishes README.md as the site's front page. The README is the
project's front door on GitHub and has to stay that; a hand-copied
docs/index.md would be a second front page, free to drift from the first, so
the build generates index.md on every run and .gitignore keeps it out of the
tree.

`on_page_markdown` rewrites the links that point out of docs/ -- at
`../payload/klipper/extras/ff_tool.py` and friends -- into GitHub URLs. Those
links are written relative because that is what works when the page is read in
the repo, which is where a contributor reads it; on the site they would 404.
Rewriting them here means nobody has to remember two link styles, and a link
whose target does not exist at all is still left alone, so mkdocs --strict can
fail the build over it.
"""

import pathlib
import re

REPO = "https://github.com/Klipper4FlashForge/firmware"
BRANCH = "master"
ROOT = pathlib.Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

# A markdown link target that is not absolute, an anchor, or a mail address.
LINK = re.compile(r"\]\((?!https?:|#|mailto:)([^)\s]+)\)")


def on_pre_build(config, **kwargs):
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    # The README's paths are relative to the repo root, the site's to docs/:
    # resolve from the root first, so `gcode/` and `docs/notes/` become GitHub
    # URLs, then strip the prefix from what is left, which is the site itself.
    text = _rewrite_links(text, ROOT)
    text = re.sub(r"\]\(docs/", "](", text)
    text = re.sub(r'(src|href)="docs/', r"\1=\"", text)
    index = DOCS / "index.md"
    # Only write on a real change: `mkdocs serve` watches docs/, and touching
    # index.md every build would rebuild forever.
    if not index.exists() or index.read_text(encoding="utf-8") != text:
        index.write_text(text, encoding="utf-8")


def on_page_markdown(markdown, page, **kwargs):
    return _rewrite_links(markdown, (DOCS / page.file.src_path).parent)


def _rewrite_links(markdown, here):
    def rewrite(match):
        target = match.group(1)
        path, _, fragment = target.partition("#")
        if not path:
            return match.group(0)
        resolved = (here / path).resolve()
        try:
            relative = resolved.relative_to(ROOT)
        except ValueError:
            return match.group(0)          # outside the repo; not ours to fix
        if not resolved.exists():
            return match.group(0)          # broken: let --strict say so
        if resolved.is_file() and DOCS in resolved.parents:
            return match.group(0)          # a page or an image; mkdocs has it
        kind = "tree" if resolved.is_dir() else "blob"
        suffix = f"#{fragment}" if fragment else ""
        return f"]({REPO}/{kind}/{BRANCH}/{relative}{suffix})"

    return LINK.sub(rewrite, markdown)
