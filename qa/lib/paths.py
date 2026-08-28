"""Where things are, found by looking rather than by counting.

Same rule as test/ffsim/__init__.py, and for the same reason recorded there:
the shell suite computed the root by counting `..` from $0, so moving a
launcher one directory deeper made ROOT point at test/ instead of the repo --
which happened, to five scripts at once, and shipped. A search does not care
where the file lives, so this module can move anywhere in the tree.
"""
from pathlib import Path

# A file that exists in this repo and nowhere above it.
_MARKER = ("bin", "common.sh")


def repo_root(start=None):
    here = Path(start or __file__).resolve()
    for d in (here,) + tuple(here.parents):
        if d.joinpath(*_MARKER).is_file():
            return d
    raise RuntimeError("not inside the repo: no %s above %s"
                       % ("/".join(_MARKER), here))


ROOT = repo_root()
