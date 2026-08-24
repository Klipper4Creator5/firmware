"""A script that walks up to the repo root must walk up the right number of times.

This exists because moving the launchers from test/ down into test/integration/
broke every one of them at once. They all open with

    ROOT="$(cd "$(dirname "$0")/.." && pwd)"

and one `..` was right at test/ and wrong a directory deeper, so $ROOT became
test/ and the first thing each of them did -- source $ROOT/test/integration/
sim-image.sh -- looked for test/test/integration/. Nothing caught it: the
integration half cannot run without docker and the stock package, so on any
machine missing either, five broken scripts still reported a clean skip.

The check is static on purpose. It needs no docker, no firmware and no shell,
so it runs everywhere -- which is the whole point, because the bug it pins
only shows itself in the gates that often do not run at all.
"""
import os
import re

# `cd "$(dirname "$0")/../.." && pwd`, `. "$(dirname "$0")/../../bin/common.sh"`
UPWALK = re.compile(r'dirname "\$0"\)((?:/\.\.)+)')


def shell_scripts(root):
    out = []
    for dirpath, dirnames, names in os.walk(os.path.join(root, "test")):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        out.extend(os.path.join(dirpath, n) for n in names if n.endswith(".sh"))
    return sorted(out)


def test_upward_walks_land_on_the_repo_root(root):
    wrong = []
    for path in shell_scripts(root):
        # How deep is this script? test/run-tests.sh is 1, test/integration/
        # sim-install.sh is 2, so that is how many `..` it needs.
        depth = os.path.relpath(path, root).count(os.sep)
        src = open(path, encoding="utf-8", errors="replace").read()
        for ups in UPWALK.findall(src):
            climbed = ups.count("..")
            if climbed != depth:
                wrong.append("%s: climbs %d, is %d deep"
                             % (os.path.relpath(path, root), climbed, depth))
    assert not wrong, "scripts that do not reach the repo root:\n  " + "\n  ".join(wrong)


def test_some_scripts_were_actually_checked(root):
    """Guard against the walk or the regex silently matching nothing."""
    hits = [p for p in shell_scripts(root)
            if UPWALK.search(open(p, encoding="utf-8", errors="replace").read())]
    assert hits, "no upward walks found -- regex or file walk broken?"
