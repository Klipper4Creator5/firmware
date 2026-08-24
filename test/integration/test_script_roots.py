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


# A repo-relative path naming something checked in: "$ROOT/test/integration/
# printer", "./bin/unpack.sh", "test/integration/printer/Dockerfile".
REPO_PATH = re.compile(r'(?:\$ROOT/|\./|(?<![\w./$-]))((?:test|bin)/[\w./-]+)')


def host_scripts(root):
    """The launchers, which run on the host and so name paths in this repo.

    test/integration/printer/ is excluded: those run inside the container, and
    inside a chroot of the printer's own filesystem after that, where `bin/`
    is the printer's /bin and has nothing to do with this checkout.
    """
    printer = os.path.join(root, "test", "integration", "printer") + os.sep
    return [p for p in shell_scripts(root) if not p.startswith(printer)]


def test_named_paths_under_test_and_bin_exist(root):
    """Every checked-in path a launcher names must actually be there.

    The check above pins the `..` count; this pins the other half of the same
    accident. Moving the replica into test/integration/ left two `docker build`
    lines with a corrected -f Dockerfile argument and a STALE build context on
    the very same line -- `-f test/integration/printer/Dockerfile test/printer`
    -- because the search-and-replace matched the first path on the line and
    not the second. docker fails outright on a context that is not there, but
    only when PRINTER_IMAGE is unset, so anyone on the published prebuilt
    image never reached it.

    Comments are skipped. They are prose, and they legitimately name paths
    that no longer exist -- run-tests.sh opens by explaining where test/unit
    went.
    """
    missing = []
    for path in host_scripts(root):
        rel = os.path.relpath(path, root)
        for n, line in enumerate(
                open(path, encoding="utf-8", errors="replace"), 1):
            if line.lstrip().startswith("#"):
                continue
            for hit in REPO_PATH.findall(line):
                # A glob or a shell variable is not a literal to resolve.
                if "*" in hit or "$" in hit:
                    continue
                if not os.path.exists(os.path.join(root, hit)):
                    missing.append("%s:%d: names %s, which is not there"
                                   % (rel, n, hit))
    assert not missing, ("scripts naming paths that do not exist:\n  "
                         + "\n  ".join(missing))


def test_some_paths_were_actually_checked(root):
    """As above: a regex that matches nothing would pass silently."""
    hits = [p for p in host_scripts(root)
            if REPO_PATH.search(open(p, encoding="utf-8", errors="replace").read())]
    assert hits, "no repo-relative paths found -- regex or file walk broken?"
