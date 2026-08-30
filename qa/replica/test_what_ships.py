"""What the package puts on the printer, and what it must not.

THE FILE THIS REPLACES

bin/verify.sh, which described itself as "simulate every check the printer
performs, against a built package". Forty checks, run on the host, against a
.tgz decrypted into a temp directory. The word doing the work in that sentence
is SIMULATE, and it is why nearly all forty are gone rather than moved.

qa/replica does not simulate the install. qa/replica/actions/install-package.sh
puts the real package on a genuine FAT filesystem exposed as /dev/sda1 and runs
the machine's OWN /usr/prog/app_startup.sh over it, verbatim, under qemu. So
every one of these, which verify.sh spent lines re-implementing on the host, is
now a PRECONDITION of this lane rather than an assertion in it:

  * the package decrypts with the firmware key (the printer's unTar does it)
  * runFirmwareExe.sh is present and the components are plain tar, not xz
    (the stock installer runs a bare `tar -xvf`)
  * md5sum.list verifies (the installer aborts and deletes the payload if not)
  * the MACHINE= gate matches (runFirmwareExe.sh refuses a foreign package)
  * the filename matches the glob (app_startup.sh globs /mnt/<Model>-*.tgz to
    find the file at all)

None of those can be quietly true here. If any of them broke, the install
would fail, `installed_image()` would raise with the install log attached, and
every test in the replica lane would go red at once. A host-side re-reading of
the same rules is a second implementation that can agree with itself while
disagreeing with the printer -- the same defect qa/replica/conftest.py records
this repo learning twice already about hand-placed payloads.

A further block of verify.sh was asking questions this suite already answers,
and answers of an installed filesystem rather than of a tar listing:

  * the klippy tree and c_helper.so     -> test_install.py, test_abi.py
  * the compiled s6-rc database, the
    oneshot runner's execline, s6 and
    s6-ftrigrd                          -> test_s6rc.py, test_supervisor.py
  * the klipper service, printer.base
    and the chamber configs             -> test_install.py, static/test_ipk.py
  * the .install-manifest               -> test_upgrade.py
  * libsodium's bare .so symlink        -> static/test_ipk.py
  * every shipped script's syntax       -> static/test_shell_syntax.py

WHAT IS LEFT, AND WHY IT IS THESE FOUR

Each one below is a question nothing else in the repo asks, and each is asked
here in a stronger form than verify.sh could manage. verify.sh read a `tar -t`
listing and grepped it for path fragments; a listing cannot tell you that a
shared object actually loads, or what a name resolves to on a PATH. This lane
has a booted machine, so it can simply ask.

The two negatives are both of the shape where PRESENCE IS THE BUG, which is
the shape that rots quietest: nothing fails, the payload is merely wrong.
"""
import hashlib
import os

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"

# Ours, not FlashForge's 3.8.2. anvil-env.sh exports this as FF_PYTHON and the
# klipper service, Moonraker and the ff-startup scripts all exec it.
PY = MODDIR + "/bin/python3.13"

ENV = MODDIR + "/anvil-env.sh"

# The host-side trees that must not reach a printer. verify.sh compared these
# same two directories, and by CONTENT rather than by name -- a blacklist would
# trip over any file Mainsail happens to call common.sh.
HOST_TREES = ("bin", "docker")

# Where the leak sweep looks. Everything the package writes lands under one of
# these two: $MODDIR is the payload, /usr/prog is the software component.
# Not the whole filesystem -- that is ~24000 files through qemu, and a build
# script of ours appearing in FlashForge's stock tree is not a thing a package
# can cause.
SHIP_ROOTS = (MODDIR, "/usr/prog")

LEAK_SCAN = "/tmp/qa-leak-scan.py"
LEAK_SIZES = "/tmp/qa-leak-sizes.txt"

# Reads the candidate sizes, walks the two roots, and md5s only the files whose
# size is one the host set contains. The size filter is what keeps this cheap:
# hashing every file under /usr/prog through qemu is minutes, and a leaked file
# is byte-identical to its host original by definition, so it cannot escape a
# filter on exact size.
LEAK_PROGRAM = r'''
import hashlib, os, sys

sizes = set()
for line in open("/tmp/qa-leak-sizes.txt"):
    line = line.strip()
    if line:
        sizes.add(int(line))

roots = sys.argv[1:]
out = sys.stdout
seen = 0
for root in roots:
    for dirpath, dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            seen += 1
            if size not in sizes:
                continue
            try:
                with open(path, "rb") as fh:
                    digest = hashlib.md5(fh.read()).hexdigest()
            except (OSError, IOError):
                continue
            out.write(digest + "\t" + path + "\n")
out.write("WALKED\t" + str(seen) + "\n")
'''


@pytest.fixture(scope="module")
def box(printer):
    """The installed machine, checked once.

    Every test below is meaningless on a machine where the payload did not
    land, and one clear failure here beats four obscure ones underneath.
    """
    if not printer.file(MODDIR).is_dir:
        pytest.fail(
            "there is no %s, so the install did not land and there is no "
            "package to ask about -- `make build` first." % MODDIR)
    return printer


def _host_files():
    """Every file under bin/ and docker/ in the checkout, by md5.

    Returns {md5: [relative paths]}. Several of these files are identical to
    each other often enough that the value has to be a list -- an empty
    __init__.py in two places would otherwise lose one of its names in the
    report.
    """
    by_digest = {}
    for tree in HOST_TREES:
        base = ROOT / tree
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(str(base)):
            for name in filenames:
                path = os.path.join(dirpath, name)
                if os.path.islink(path):
                    continue
                try:
                    with open(path, "rb") as fh:
                        digest = hashlib.md5(fh.read()).hexdigest()
                except (OSError, IOError):
                    continue
                rel = os.path.relpath(path, str(ROOT))
                by_digest.setdefault(digest, []).append(rel)
    return by_digest


# ------------------------------------------------------ the interpreter works

# The three extension modules this interpreter exists for. verify.sh grepped a
# tar listing for each one's .so, which proves a file was staged and nothing
# about whether it loads.
#
#   sqlite3        the module FlashForge's 3.8.2 has not got, and the reason
#                  there is a second CPython on this printer at all. It is
#                  also the one that fails INVISIBLY: a dropped -lm makes
#                  configure's link probe fail, and CPython then records the
#                  module as missing and builds a perfectly working
#                  interpreter without it.
#   lmdb           Moonraker's database at the pinned commit.
#   _cffi_backend  klippy's route to c_helper.so, and the reason this
#                  interpreter had to be glibc rather than musl.
#
# lmdb and _cffi_backend are also the two a cross build gets WRONG rather than
# missing, by resolving to an x86_64 manylinux wheel. Importing them is what
# tells the two apart: a wheel for the wrong architecture is present on disk
# and raises on import.
WANTED_MODULES = ("sqlite3", "lmdb", "_cffi_backend")


def test_the_interpreter_imports_what_it_was_rebuilt_for(box):
    """Asked by importing, on the printer, through anvil-env.sh.

    Sourcing the environment first is not a detail: the interpreter is linked
    against libraries in FlashForge's /usr/prog/<package>/ directories that are
    on no default loader path, so a bare exec dies at
    "libpython3.8.so.1.0: cannot open shared object file" long before it has
    an opinion about sqlite3. That is anvil-env.sh's whole reason for
    existing, and running without it would test the wrong thing.

    One module per line rather than one import statement, so the report names
    which of the three is missing instead of stopping at the first.
    """
    assert box.file(PY).executable, (
        "this package ships no interpreter at %s. It is a build output "
        "(pkgs/3rdparty/python), not a file in the checkout -- `make build`."
        % PY)

    broken = []
    for module in WANTED_MODULES:
        got = box.sh(". %s; %s -c 'import %s'" % (ENV, PY, module))
        if not got.ok:
            # The last line of a traceback is the exception, which is the part
            # that distinguishes "no such module" from "wrong architecture".
            tail = got.text.strip().splitlines()
            broken.append("%s: %s" % (module, tail[-1] if tail else "no output"))

    assert not broken, (
        "%s cannot import the modules it was rebuilt to provide:\n  %s\n"
        "A missing sqlite3 means checking LIBS/LIBSQLITE3_LIBS in "
        "pkgs/3rdparty/python/build.sh; a missing lmdb or _cffi_backend is "
        "usually a cross build that resolved to an x86_64 manylinux wheel -- "
        "see work/.pkg-python-*/wheel-*.log."
        % (PY, "\n  ".join(broken)))


def test_nothing_we_ship_shadows_flashforges_python3(box):
    """PRESENCE IS THE BUG, and the bug would be ours.

    anvil-env.sh PREPENDS $MODDIR/bin to PATH, because s6-svscan execs
    s6-supervise by name and s6-svc -w does the same for s6-svlisten. That
    prepend is what makes a `python3` symlink in $MODDIR/bin dangerous: it
    would silently put our 3.13 ahead of FlashForge's 3.8.2 for every process
    that says `python3` after the environment is sourced -- which is every
    process the mod starts, and several of theirs. Nothing would fail at
    install time; things would fail later, in FlashForge's code, against an
    interpreter it was never written for.

    anvil-env.sh's own comment states the rule ("adding our bin/ to PATH
    cannot quietly change what `python3` means"), and this is that rule asked
    of the machine. Callers that want ours use $FF_PYTHON, which the same file
    exports as an absolute path.

    Asked with `command -v` AFTER sourcing, rather than by looking for the
    symlink: the property is what the name resolves to, and that is what a
    future payload could break by some other route than the one file
    verify.sh grepped for.
    """
    got = box.sh(". %s; command -v python3" % ENV)
    resolved = got.out.strip()

    # Not an assertion about FlashForge having one -- if the base rootfs ever
    # ships without python3 that is their change, not a regression in ours.
    if not resolved:
        pytest.skip(
            "nothing on PATH is called python3 even with the mod environment "
            "sourced, so there is nothing for us to be shadowing")

    assert not resolved.startswith(MODDIR), (
        "`python3` resolves to %s with anvil-env.sh sourced, so our 3.13 is "
        "ahead of FlashForge's 3.8.2 on PATH for every process that says "
        "python3. Callers that want ours use $FF_PYTHON; nothing in "
        "%s/bin may be called python3." % (resolved, MODDIR))


# --------------------------------------------------------- what must not ship

# The dev half of CPython: headers so the python-* recipes can compile against
# it on a BUILD machine, pkgconfig files, and the config-3.13-* directory
# holding the Makefile and the static library. anvil-python-dev owns all of it
# and bin/patch.sh prunes it via PKG_DEV_FILES.
DEV_MARKERS = (
    MODDIR + "/include/python3.13",
    MODDIR + "/lib/pkgconfig",
)
DEV_GLOB = MODDIR + "/lib/python3.13/config-3.13-*"


def test_no_cpython_dev_files_reached_the_printer(box):
    """Extra files in a payload ship silently, which is the whole problem.

    Nothing breaks when the headers are there. The package is simply bigger
    than it should be, on a printer whose data partition is the reason the
    payload was split off the firmware partition in the first place, and no
    other check in the repo would ever mention it.
    """
    found = [p for p in DEV_MARKERS if box.file(p).exists]
    globbed = box.sh("ls -d %s 2>/dev/null" % DEV_GLOB).out.split()
    found.extend(globbed)

    assert not found, (
        "the payload carries CPython's dev half:\n  %s\n"
        "Those belong to anvil-python-dev, which a printer does not install. "
        "Check PKG_DEV_FILES in pkgs/3rdparty/python." % "\n  ".join(found))


def test_no_host_side_build_file_reached_the_printer(box):
    """The ship boundary: only payload/ and assets/ may reach a printer.

    Compared by CONTENT and not by name, which is verify.sh's own reasoning
    and worth keeping: a blacklist of names would trip over any file Mainsail
    happens to call common.sh, and would miss a build script copied in under a
    new name -- which is the case that actually matters, because it is the one
    nobody did on purpose.

    Asked of the INSTALLED filesystem rather than of the .tgz, which is the
    one thing this move makes stronger. verify.sh untarred the package and
    compared that; the machine also shows anything a maintainer script wrote
    at install time, and postinst scripts are code that runs as root on a
    printer.
    """
    by_digest = _host_files()

    # verify.sh carried this guard because its own `find` was relative and
    # came back empty from the wrong cwd, at which point it reported "package
    # carries nothing" having compared nothing at all. A gate that cannot go
    # red is worse than no gate.
    #
    # 5 and not the 10 distinct digests measured here on 2026-08-30: the floor
    # is there to catch an empty or near-empty walk, and a floor set AT the
    # current count turns deleting one script in bin/ into a failure of this
    # test, which would teach exactly the wrong lesson about what it checks.
    assert len(by_digest) >= 5, (
        "the leak sweep hashed only %d files under %s, which is not this "
        "checkout -- so it compared nothing and proves nothing"
        % (len(by_digest), " and ".join(t + "/" for t in HOST_TREES)))

    sizes = set()
    for tree in HOST_TREES:
        base = ROOT / tree
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(str(base)):
            for name in filenames:
                path = os.path.join(dirpath, name)
                if not os.path.islink(path):
                    try:
                        sizes.add(os.path.getsize(path))
                    except OSError:
                        pass

    box.write(LEAK_SIZES, "\n".join(str(s) for s in sorted(sizes)) + "\n")
    box.write(LEAK_SCAN, LEAK_PROGRAM)

    got = box.sh("%s %s %s" % (PY, LEAK_SCAN, " ".join(SHIP_ROOTS)), timeout=900)
    assert got.ok, (
        "the leak sweep did not run on %s (exit %s):\n%s"
        % (PY, got.code, got.text))

    lines = got.out.splitlines()
    # The sweep's completion marker, for the same reason test_abi.py has one:
    # a walk killed halfway reports a short list that this assertion passes
    # happily, which is a green gate over an unswept filesystem.
    assert lines and lines[-1].startswith("WALKED\t"), (
        "the leak sweep did not run to completion, so what it reported is a "
        "partial filesystem:\n%s" % got.text[-2000:])
    # 21132 files under the two roots, measured on the replica 2026-08-30. The
    # floor is two orders below that: it is here to catch a walk that found
    # nothing, not to pin a number that legitimately moves with the payload.
    walked = int(lines[-1].split("\t")[1])
    assert walked >= 100, (
        "the sweep looked at only %d files under %s -- the roots are wrong or "
        "the install did not land, and nothing was really compared"
        % (walked, " and ".join(SHIP_ROOTS)))

    leaked = []
    for line in lines[:-1]:
        fields = line.split("\t", 1)
        if len(fields) != 2:
            continue
        digest, path = fields
        if digest in by_digest:
            leaked.append("%s  (identical to %s)"
                          % (path, ", ".join(by_digest[digest])))

    assert not leaked, (
        "host-side build files reached the printer:\n  %s\n"
        "Only payload/ and assets/ may ship. Something under %s is being "
        "copied into the package."
        % ("\n  ".join(leaked),
           " or ".join(t + "/" for t in HOST_TREES)))
