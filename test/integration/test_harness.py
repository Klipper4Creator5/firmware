"""Checks on the test harness itself.

The harness has a specific hazard: most of it only runs on a machine with
docker and the proprietary firmware, so a launcher can be broken for a long
time and report nothing worse than a skip. Everything here is static and needs
neither, which is the point -- these run on every machine, including the ones
where the gates they cover cannot.

This file used to be called test_script_roots.py and had one job, pinning the
`..` count in `ROOT="$(cd "$(dirname "$0")/.." && pwd)"`. Those launchers are
Python now and locate the repo by searching upward for a marker file, so that
bug is gone by construction rather than by being tested for -- see
test_repo_root_does_not_care_how_deep_it_is below, which pins the property
that replaced it.
"""
import compileall
import io
import os
import re
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from ffsim import Fail, repo_root                                # noqa: E402

UPWALK = re.compile(r'dirname "\$0"\)((?:/\.\.)+)')


def shell_scripts(root):
    out = []
    for dirpath, dirnames, names in os.walk(os.path.join(root, "test")):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        out.extend(os.path.join(dirpath, n) for n in names if n.endswith(".sh"))
    return sorted(out)


def python_files(root):
    out = []
    for sub in ("test",):
        for dirpath, dirnames, names in os.walk(os.path.join(root, sub)):
            dirnames[:] = [d for d in dirnames if d != "__pycache__"]
            out.extend(os.path.join(dirpath, n)
                       for n in names if n.endswith(".py"))
    return sorted(out)


def test_upward_walks_land_on_the_repo_root(root):
    """Two host-side shell scripts are left; they still count `..` by hand.

    build-printer-image.sh bakes the published replica image and is run by
    hand, so it is exactly the kind of script that can be broken for months
    without anyone noticing.
    """
    wrong = []
    checked = 0
    for path in shell_scripts(root):
        depth = os.path.relpath(path, root).count(os.sep)
        with open(path, encoding="utf-8", errors="replace") as fh:
            src = fh.read()
        for ups in UPWALK.findall(src):
            checked += 1
            climbed = ups.count("..")
            if climbed != depth:
                wrong.append("%s: climbs %d, is %d deep"
                             % (os.path.relpath(path, root), climbed, depth))
    assert not wrong, ("scripts that do not reach the repo root:\n  "
                       + "\n  ".join(wrong))
    # A regex matching nothing would pass silently, and this repo has done
    # that before: test-abi.sh sat in the suite printing green while checking
    # nothing, because the wiring left it with no targets on any run.
    assert checked, "no upward walks found -- regex or file walk broken?"


def test_every_harness_file_compiles(root):
    """Byte-compile the whole harness, including the parts nothing else runs.

    run-tests.py imports ffsim, so a syntax error there shows up immediately.
    The single-gate wrappers -- sim-install.py, sim-roundtrip.py,
    printer-exec.py, extract-rootfs.py -- are only executed by `make
    test-install` and friends, which need docker and the firmware. Without
    this, a typo in one of them would wait quietly until release day.
    """
    files = python_files(root)
    assert files, "no python files found -- the walk is broken"

    err = io.StringIO()
    stderr, sys.stderr = sys.stderr, err
    try:
        good = True
        for path in files:
            if not compileall.compile_file(path, quiet=2, force=True):
                good = False
    finally:
        sys.stderr = stderr
    assert good, "python that does not compile:\n" + err.getvalue()


def test_repo_root_does_not_care_how_deep_it_is(root, tmp_path):
    """The property that replaced counting `..`.

    Moving a launcher into a deeper directory silently broke five scripts at
    once and shipped, because each one computed the repo root by climbing a
    fixed number of levels from $0. repo_root() searches instead, so the
    answer is the same from anywhere inside the checkout -- and outside it,
    the answer is a loud error rather than a wrong path.
    """
    deep = os.path.join(root, "test", "integration", "printer")
    for start in (root, os.path.join(root, "test"), deep,
                  os.path.join(deep, "Dockerfile")):
        assert str(repo_root(start)) == str(root), "wrong root from %s" % start

    with pytest.raises(Fail):
        repo_root(str(tmp_path))
