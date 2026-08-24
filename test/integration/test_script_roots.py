"""A script that walks up to the repo root must walk up the right number of times.

This exists because moving the launchers from test/ down into test/integration/
broke every one of them at once. They all open with

    ROOT="$(cd "$(dirname "$0")/.." && pwd)"

and one `..` was right at test/ and wrong a directory deeper, so $ROOT became
test/ and the first thing each of them did -- source $ROOT/test/integration/
sim-image.sh -- looked for test/test/integration/.

Running them does not catch this, which is the whole reason the check is here.
sim-image.sh is the file that sources config.env, so when the broken path stops
it from loading, STOCK_TGZ_* is never set, the launcher concludes it has
nothing to work on, prints "SKIP:" and exits 0 -- on a machine that has docker
and the firmware and could have run the gate perfectly well. run-tests.sh greps
for exactly that string and counts it as a skip. Verified by putting the bug
back:

    line 22: .../test/test/integration/sim-image.sh: No such file or directory
      SKIP: no stock package configured for fake.tgz -- set STOCK_TGZ_* ...
    EXIT CODE: 0

The suite still goes red, because a skip is not forgiven, but it blames
config.env rather than line 12 of the script. This check names the file and
says how far off it is.

Static on purpose: no docker, no firmware, no shell, so it runs everywhere.
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
    checked = 0
    for path in shell_scripts(root):
        # How deep is this script? test/run-tests.sh is 1, test/integration/
        # sim-install.sh is 2, so that is how many `..` it needs.
        depth = os.path.relpath(path, root).count(os.sep)
        src = open(path, encoding="utf-8", errors="replace").read()
        for ups in UPWALK.findall(src):
            checked += 1
            climbed = ups.count("..")
            if climbed != depth:
                wrong.append("%s: climbs %d, is %d deep"
                             % (os.path.relpath(path, root), climbed, depth))
    assert not wrong, ("scripts that do not reach the repo root:\n  "
                       + "\n  ".join(wrong))
    # A regex that matched nothing would pass silently, and this repo has done
    # that before -- test-abi.sh sat in the suite printing green while checking
    # nothing at all, because the wiring left it with no targets on any run.
    assert checked, "no upward walks found -- regex or file walk broken?"
