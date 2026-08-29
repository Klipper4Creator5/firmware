"""Every object the kernel will load, asked of the filesystem it will load them from.

THE GATE THIS REPLACES

`mips_abi_gate` lived in bin/common.sh and ran `readelf -h` over a build tree
at the packaging boundary, plus twice more inside recipes that did not trust
it to. It was a good gate aimed at the wrong thing: a PKG_ROOT is what one
recipe staged, so the gate could only ever answer "did this recipe produce the
right ABI", once per recipe, and only for the trees that go through
build-packages.sh. It never saw:

  * anything bin/patch.sh writes into /usr/prog -- firmwareExe, prog/*.sh and
    whatever a future one adds. pkgs/helixscreen/pkg.conf carried a note
    saying exactly that, for a package with a 24MB binary in it.
  * what the INSTALL produced, as opposed to what the build staged. Those are
    different files whenever opkg, a maintainer script or app_startup.sh puts
    something somewhere the recipe did not.
  * the stock tree it lands beside.

The filesystem after the install is the only place all three are visible at
once, and it is also the thing the question is actually about: the printer's
kernel does not read a PKG_ROOT, it reads /. So the gate moved here, and this
is now the ONLY ABI check in the repo.

WHAT "CORRECT ABI" IS

ELF32, little-endian, EM_MIPS, and e_flags carrying nan2008 (0x400), o32
(0x1000) and mips32r2 (0x70000000 in the arch field). The low three bits are
NOREORDER/PIC/CPIC and vary between objects that are otherwise identical, so
they are masked out rather than compared -- both 0x70001405 and 0x70001407 are
on this filesystem and both run. Anything else gets ENOEXEC from the kernel's
binfmt_elf loader, which is a printer that boots to nothing.

Note that qemu does NOT enforce this. The replica runs the machine's binaries
under qemu-mipsel-static, which is far more forgiving than a real MIPS kernel,
and that is how a legacy-NaN object once shipped with every gate green. This
test reads the header rather than trying to run the file, so it answers the
kernel's question and not qemu's.

WHAT IS EXEMPT, AND WHY -- ALL OF IT MEASURED ON THE INSTALLED REPLICA

The sweep finds 603 ELF objects: 569 the loader handles (ET_EXEC and ET_DYN)
and 34 it does not (ET_REL). 568 of the 569 conform. The two exemptions are:

  * ET_REL objects are not asked about the FP ABI. 33 of the 34 are stock
    `.ko` kernel modules at e_flags 0x70001001 and the last is a stray
    python.o in FlashForge's CPython 3.8 tree. insmod and the linker read
    these, not the ELF loader, and kernel code has no FP ABI to agree about --
    so the absence of nan2008 is not a defect in them. The exemption is by
    e_type and NOT by a `.ko` suffix, which is why the python.o needs no
    special case of its own.
  * /usr/prog/PROGRAM/ffstartup-arm, an ARM (EM_ARM) executable FlashForge
    ships in the stock package. Nothing in the stock tree names it -- grepped
    -- and this printer is MIPS, so it is inert baggage rather than something
    that runs. It is exempted BY PATH, so an ARM binary appearing anywhere
    else still fails.

Both are narrow on purpose. A rule of "skip anything that is not ET_EXEC"
would have quietly skipped c_helper.so, which is ET_DYN and is the one file
whose ABI has broken a printer; and the ET_REL exemption covers the FP ABI
only -- 32-bit, little-endian and MIPS are still required of every object on
the machine, kernel modules included.

THE ARCHITECTURE IS SETTLED BEFORE ANYTHING IS CLASSIFIED, and that ordering
was found by planting a counterexample rather than reasoned out in advance. A
big-endian object decodes its own e_type big-endian, so ET_DYN reads back as
768, which is in neither bucket -- an early draft of this file looked straight
at such a file and passed. test_no_object_on_the_filesystem_is_a_foreign_
architecture therefore runs over every ELF regardless of e_type, and the
e_type split is only ever applied to files already known to be MIPS32 LE.
"""
import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
PY = MODDIR + "/bin/python3.13"

# The one this exists for. klippy dlopens it through cffi at connect time, so
# a wrong-ABI build is not noticed until the printer is already trying to
# print -- and it is ET_DYN, which is why the sweep cannot restrict itself to
# executables.
CHELPER = MODDIR + "/klipper/klippy/chelper/c_helper.so"

# FlashForge's, not ours: see the module docstring.
STOCK_ARM = "/usr/prog/PROGRAM/ffstartup-arm"

EM_MIPS = 8

# nan2008 | o32 | mips32r2, with NOREORDER/PIC/CPIC masked out.
ABI_MASK = 0x70001400
ABI_WANT = 0x70001400

# The kernel's ELF loader handles these two; ET_REL (1) is an object file or a
# kernel module and reaches the kernel by another road entirely.
LOADABLE = (2, 3)                                        # ET_EXEC, ET_DYN

# Kernel and container mounts. Everything else is the printer's own storage and
# is swept, including /tmp and /usr/data -- a binary is no safer for being in a
# directory nobody expected it in.
PRUNE = ("/proc", "/sys", "/dev")

SCAN = "/tmp/qa-abi-scan.py"

# Runs INSIDE the chroot, on the printer's own interpreter, as one process.
# One process and not a shell loop because the walk touches ~24000 files: a
# `find | while read; do xxd; done` is 24000 qemu-mipsel starts and takes
# longer than the whole rest of the lane. Reading 52 bytes per file is the
# whole ELF header for ELF32; e_type is at 16, e_machine at 18, e_flags at 36.
SCAN_PROGRAM = r'''
import os, struct, sys

PRUNE = set(%(prune)r)

out = sys.stdout
for dirpath, dirnames, filenames in os.walk("/"):
    dirnames[:] = [d for d in dirnames
                   if os.path.join(dirpath, d) not in PRUNE]
    for name in filenames:
        path = os.path.join(dirpath, name)
        # Symlinks are skipped, not followed: the target is walked on its own
        # and a lib*.so -> lib*.so.1.2.3 chain would otherwise be reported
        # three times under three names.
        if os.path.islink(path):
            continue
        try:
            with open(path, "rb") as fh:
                head = fh.read(52)
        except (OSError, IOError):
            continue
        if len(head) < 52 or head[:4] != b"\x7fELF":
            continue
        cls, data = head[4], head[5]
        # e_type/e_machine/e_flags can only be decoded once the endianness is
        # known, and a header that lies about its own endianness is exactly
        # the kind of file this is looking for -- so it is reported with the
        # fields left at -1 rather than guessed at.
        if data == 1:
            etype, machine = struct.unpack_from("<HH", head, 16)
            flags, = struct.unpack_from("<I", head, 36)
        elif data == 2:
            etype, machine = struct.unpack_from(">HH", head, 16)
            flags, = struct.unpack_from(">I", head, 36)
        else:
            etype = machine = flags = -1
        out.write("%%d\t%%d\t%%d\t%%d\t%%d\t%%s\n"
                  %% (cls, data, etype, machine, flags, path))
out.write("SWEPT\n")
''' % {"prune": PRUNE}


class Elf(object):
    """One ELF object on the printer's filesystem, as its header describes it."""

    def __init__(self, cls, data, etype, machine, flags, path):
        self.cls = cls                   # EI_CLASS: 1 = ELF32
        self.data = data                 # EI_DATA:  1 = little-endian
        self.etype = etype               # e_type
        self.machine = machine           # e_machine
        self.flags = flags               # e_flags
        self.path = path

    @property
    def loadable(self):
        return self.etype in LOADABLE

    @property
    def is_mips32le(self):
        return self.cls == 1 and self.data == 1 and self.machine == EM_MIPS

    @property
    def conforms(self):
        return self.is_mips32le and (self.flags & ABI_MASK) == ABI_WANT

    def __repr__(self):
        return ("%s (class %d, %s, machine %d, e_flags 0x%08x)"
                % (self.path, self.cls,
                   {1: "LE", 2: "BE"}.get(self.data, "endianness %d" % self.data),
                   self.machine, self.flags & 0xFFFFFFFF))


@pytest.fixture(scope="module")
def box(printer):
    """The installed machine, with the interpreter the sweep runs on."""
    if not printer.file(MODDIR).is_dir:
        pytest.fail(
            "there is no %s, so the install did not land and there is no "
            "package to gate -- `make build` first." % MODDIR)
    if not printer.file(PY).executable:
        pytest.fail(
            "this package ships no interpreter at %s, so the sweep cannot "
            "run. It is a build output (pkgs/3rdparty/python), not a file in "
            "the checkout -- `make build`." % PY)
    return printer


@pytest.fixture(scope="module")
def elves(box):
    """Every ELF object on the printer's filesystem, swept once.

    Module-scoped: the walk is the expensive part and every test below is a
    different question about the same answer.
    """
    box.write(SCAN, SCAN_PROGRAM)
    # The walk is ~24000 files through qemu, which is minutes on a cold cache
    # -- well past the 120s default, and a timeout here reads as "the sweep
    # found nothing" if it is not given room.
    got = box.sh("%s %s" % (PY, SCAN), timeout=900)
    assert got.ok, (
        "the ABI sweep did not run on %s (exit %s):\n%s"
        % (PY, got.code, got.text))

    lines = got.out.splitlines()
    # The sweep's own completion marker. Without it a walk killed halfway --
    # by a timeout, by the interpreter dying on one unreadable directory --
    # returns a short list that every assertion below passes happily, which is
    # a green gate over an unswept filesystem.
    assert lines and lines[-1] == "SWEPT", (
        "the sweep did not run to completion, so what it did report is a "
        "partial filesystem and proves nothing:\n%s" % got.text[-2000:])

    found = []
    for line in lines[:-1]:
        fields = line.split("\t")
        if len(fields) != 6:
            continue
        found.append(Elf(int(fields[0]), int(fields[1]), int(fields[2]),
                         int(fields[3]), int(fields[4]), fields[5]))
    return found


# ------------------------------------------------------------- the sweep ran

def test_the_sweep_found_a_filesystem_full_of_binaries(elves):
    """The guard on every assertion below.

    A sweep that returns nothing -- wrong root, a walk that raised on its
    first directory -- makes each check underneath it vacuously true, and a
    gate that cannot go red is worse than no gate. 603 objects were measured
    on the replica; 400 is a floor low enough to survive a package losing a
    component and high enough that an empty or half walk fails here.
    """
    assert len(elves) >= 400, (
        "the sweep found only %d ELF objects on the whole filesystem, which "
        "is not a printer -- the walk did not cover it, so nothing below is "
        "a real check" % len(elves))


def test_the_sweep_reads_what_is_under_moddir(box, elves):
    """The walk has to reach the package, not just the stock tree around it.

    Asked of the interpreter because the `box` fixture has already
    established that file is there, so a failure here is unambiguously the
    sweep's and not the package's. Without it, a walk that covered only
    /usr and stopped short of /usr/data would pass every gate below by
    having nothing of ours left to judge.
    """
    assert PY in set(e.path for e in elves), (
        "the sweep did not read %s, which the fixture just confirmed is an "
        "executable file -- so the walk does not reach %s and nothing this "
        "package ships is being gated." % (PY, MODDIR))


def test_the_sweep_covers_the_object_that_has_broken_a_printer(box, elves):
    """c_helper.so is the failure this gate was built for: klippy dlopens it
    through cffi at connect time, so a wrong-ABI build is not noticed until
    the printer is already trying to print.

    Whether the package ships one AT ALL is qa/replica/test_install.py's
    question (test_klippy_is_present), and asking it a second time here is
    exactly the duplication this module exists to remove. So this asks only
    the part that is this module's own: when the machine has a chelper, the
    sweep read it rather than walking past it.
    """
    if not box.file(CHELPER).exists:
        pytest.skip(
            "this package installed no %s -- test_install.py's "
            "test_klippy_is_present is where that is a failure. There is no "
            "object here for the sweep to have missed." % CHELPER)
    assert CHELPER in set(e.path for e in elves), (
        "%s is on the machine and the sweep did not read it, so the one "
        "object this gate exists for went ungated" % CHELPER)


# --------------------------------------------------------- the architecture

def test_no_object_on_the_filesystem_is_a_foreign_architecture(elves):
    """32-bit, little-endian, EM_MIPS -- asked of EVERY ELF, before anything
    is classified by what its header says it is.

    THE ORDER IS THE POINT, and it was found by planting one. A big-endian
    object decodes its own e_type big-endian too, so ET_DYN (3) reads back as
    768 -- which is not in LOADABLE, so the two gates below skipped it and it
    sailed through a sweep that had looked straight at it. A header cannot be
    trusted to classify itself until the encoding it is written in has been
    agreed, so the encoding is settled here first and nothing downstream has
    to reason about a file that lies.

    This is also the check that covers the `.ko` files. They are exempt from
    the FP-ABI question below -- see the module docstring -- and they are not
    exempt from this one: an x86-64 object staged among the kernel modules is
    exactly the failure the per-member half of mips_abi_gate used to catch,
    and this is now the only thing looking for it.
    """
    bad = [e for e in elves if not e.is_mips32le and e.path != STOCK_ARM]
    assert not bad, (
        "%d ELF object(s) on the printer's filesystem are not 32-bit "
        "little-endian MIPS:\n  %s"
        % (len(bad), "\n  ".join(repr(e) for e in bad)))


# ------------------------------------------------------------ what we shipped

def test_every_object_the_package_ships_is_the_printers_abi(elves):
    """The gate mips_abi_gate used to be, over the installed tree instead of
    over one recipe's staging directory -- so it covers every recipe at once,
    plus whatever the install itself put there."""
    ours = [e for e in elves if e.path.startswith(MODDIR + "/")]
    assert ours, (
        "nothing under %s is an ELF object at all. A package with no native "
        "code in it is not this package." % MODDIR)
    bad = [e for e in ours if e.loadable and not e.conforms]
    assert not bad, (
        "BRICK: %d object(s) under %s are not nan2008/o32/mips32r2 MIPS32 LE. "
        "The kernel returns ENOEXEC for each one:\n  %s"
        % (len(bad), MODDIR, "\n  ".join(repr(e) for e in bad)))


# --------------------------------------------------------- the whole machine

def test_every_loadable_object_on_the_filesystem_is_the_printers_abi(elves):
    """Not just ours: /usr/prog is written by bin/patch.sh, which no gate has
    ever read, and the stock tree is what the mod has to keep working."""
    bad = [e for e in elves
           if e.loadable and not e.conforms and e.path != STOCK_ARM]
    assert not bad, (
        "%d object(s) on the printer's filesystem are not "
        "nan2008/o32/mips32r2 MIPS32 LE, and the kernel returns ENOEXEC for "
        "each one:\n  %s" % (len(bad), "\n  ".join(repr(e) for e in bad)))


def test_the_only_foreign_binary_is_the_stock_one_we_know_about(elves):
    """The exemption above is a path, so it has to be kept honest from the
    other side: if FlashForge stops shipping ffstartup-arm, the exemption is
    dead code and should go rather than sit there widening the gate."""
    arm = [e for e in elves if e.path == STOCK_ARM]
    assert arm, (
        "%s is gone from the stock tree, so the exemption for it in this "
        "file no longer describes anything -- delete it" % STOCK_ARM)
