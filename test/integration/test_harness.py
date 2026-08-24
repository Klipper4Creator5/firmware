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
import os
import py_compile
import re
import subprocess
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
    """One host-side shell script is left that still counts `..` by hand.

    build-printer-image.sh bakes the published replica image and is run by
    hand, so it is exactly the kind of script that can be broken for months
    without anyone noticing.

    The `assert checked` below passes on a single hit, so it does not notice
    if that one script stops walking upward and this test quietly covers
    nothing. If the count ever reaches zero the guard fires; between one and
    zero there is no alarm.
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


def test_every_harness_file_compiles(root, tmp_path):
    """Byte-compile the whole harness, including the parts nothing else runs.

    run-tests.py imports ffsim, so a syntax error there shows up immediately.
    The single-gate wrappers -- sim-install.py, sim-roundtrip.py,
    printer-exec.py, extract-rootfs.py -- are only executed by `make
    test-install` and friends, which need docker and the firmware. Without
    this, a typo in one of them would wait quietly until release day.
    """
    files = python_files(root)
    assert files, "no python files found -- the walk is broken"

    # py_compile with an explicit cfile, not compileall: compileall writes the
    # .pyc beside the source and returns False if it cannot, which is
    # indistinguishable from a syntax error and, under quiet=2, comes with an
    # empty message. A read-only checkout or a root-owned __pycache__ then
    # reads as "your code does not compile" and tells you nothing. This
    # touches nothing outside tmp_path and reports the real exception.
    broken = []
    for path in files:
        cfile = tmp_path / (os.path.relpath(path, str(root))
                            .replace(os.sep, "_") + "c")
        try:
            py_compile.compile(path, cfile=str(cfile), doraise=True)
        except py_compile.PyCompileError as exc:
            broken.append(str(exc))
    assert not broken, "python that does not compile:\n" + "\n".join(broken)


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


def test_every_script_with_a_shebang_is_executable_in_git(root):
    """A shebang and no exec bit is a script that only runs by accident.

    This one shipped. `core.filemode` is false on the maintainer's checkout --
    it has to be, because the repo lives on a Windows drive where every file
    reads back as 0777, so turning it on would mark the entire tree
    executable. The consequence is that a local `chmod +x` changes nothing git
    can see, and for the whole life of the CI workflow not one tracked file
    was 100755. Every run died on the first line it tried to execute:

        ./test/run-tests.sh: Permission denied      exit 126

    Locally it all worked, because `make` invokes the launchers through bash
    and because the working tree claims 0777 anyway. So the mode has to come
    from the index: asking the filesystem here answers a question about
    Windows, not about what was committed.
    """
    root = str(root)
    if not os.path.exists(os.path.join(root, ".git")):
        pytest.skip("not a git checkout")

    # -c safe.directory=*: git refuses to read a repository owned by
    # another uid, and every docker run here is root over a checkout that is
    # not, so without this the test skips inside the build image -- and
    # release.yml runs the suite there with no ALLOW_SKIP. Reading file modes
    # out of a repo whose code we are already executing is not the threat that
    # guard exists for.
    proc = subprocess.run(["git", "-c", "safe.directory=*", "ls-files", "-s"],
                          cwd=root, capture_output=True, text=True)
    if proc.returncode != 0:
        pytest.skip("git unavailable: %s" % proc.stderr.strip())

    wrong, checked = [], 0
    for line in proc.stdout.splitlines():
        meta, _, path = line.partition("\t")
        if not meta or not path:
            continue
        mode = meta.split()[0]
        try:
            with open(os.path.join(root, path), "rb") as fh:
                if fh.read(2) != b"#!":
                    continue
        except OSError:
            continue
        checked += 1
        if mode != "100755":
            wrong.append("%s is %s" % (path, mode))

    assert not wrong, (
        "scripts with a shebang that git records as non-executable:\n  "
        + "\n  ".join(sorted(wrong))
        + "\n\nFix with: git update-index --chmod=+x <path>")
    # Same vacuity guard as above: a walk that finds nothing must not pass.
    assert checked, "no shebang files found -- the walk is broken"
