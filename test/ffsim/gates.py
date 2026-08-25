"""The gates themselves.

Each one is a plain function that returns normally, raises Skip when its
precondition is genuinely absent, or raises Fail when it ran and the answer
was no. run-tests.py calls them directly -- no subprocess between the gate and
the thing counting results, so there is no output format to agree on and
nothing to misread. Three scripts in test/integration/ -- sim-install.py,
sim-roundtrip.py and extract-rootfs.py -- are thin wrappers around these same
functions, for running one gate on its own. (printer-exec.py wraps Replica
directly, and build-printer-image.sh / make-stock-fixture.sh are not wrappers
at all.)
"""
import os
import subprocess
import tarfile

from . import Fail, Skip
from .replica import Replica

PRINTER = ("test", "integration", "printer")


def _case(config, name):
    return str(config.root.joinpath(*PRINTER, name))


# ---------------------------------------------------------------- the rootfs

def extract_rootfs(config, on_output=None):
    """Pull the printer's real root filesystem out of the stock package.

    The kernel-*.tar.xz component carries ota_kernel_emmc/ota_v1/
    rootfs.squashfs -- the genuine buildroot rootfs: busybox 1.31.1,
    /etc/inittab, /etc/init.d including the stock S50dropbear, the real ash.
    Never committed: it is FlashForge's proprietary firmware.
    """
    root = config.root
    if not shutil_which("unsquashfs"):
        raise Fail("need squashfs-tools (the build image has it)")

    outer = root / "work" / "outer"
    if not outer.is_dir():
        raise Fail("run bin/unpack.sh first (no %s)" % outer)

    kernels = sorted(outer.glob("kernel-*.tar.xz"))
    if not kernels:
        raise Fail("no kernel-*.tar.xz in the package (a --slim build has none)")
    kern = kernels[0]

    kerndir = root / "work" / "kern"
    rootfs = root / "work" / "rootfs"
    for d in (kerndir, rootfs):
        if d.exists():
            _rmtree(d)
    kerndir.mkdir(parents=True)

    with tarfile.open(str(kern)) as tf:
        _extract_all(tf, kerndir)

    squash = None
    for path in kerndir.rglob("rootfs.squashfs*"):
        squash = path
        break
    if squash is None:
        raise Fail("no rootfs.squashfs inside %s" % kern.name)

    if on_output:
        on_output(">> %s" % squash.name)
    proc = subprocess.run(
        ["unsquashfs", "-q", "-d", str(rootfs), str(squash)],
        capture_output=True, text=True)
    if proc.returncode != 0:
        raise Fail("unsquashfs failed:\n%s" % proc.stderr.strip())
    _rmtree(kerndir)

    if not (rootfs / "bin").is_dir():
        raise Fail("unsquashfs produced no %s/bin" % rootfs)

    if on_output:
        initd = rootfs / "etc" / "init.d"
        dropbear = rootfs / "usr" / "sbin" / "dropbear"
        on_output("printer rootfs: work/rootfs\n"
                  "   init.d : %s\n"
                  "   dropbear: %s"
                  % (" ".join(sorted(p.name for p in initd.iterdir()))
                     if initd.is_dir() else "MISSING",
                     "present" if dropbear.exists() else "MISSING"))


# ------------------------------------------------------------- replica gates

def mcu_bringup(config, on_output=None):
    """Does start.sh's ff_mcu_bringup.py actually run on the printer's Python?"""
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-mcu-bringup.sh"), on_output=on_output)


def boot_screen(config, on_output=None):
    """Does the first-boot screen draw, on the printer's Python and its fb0?

    Hand-packed pixels and an interpreter FlashForge built themselves: the two
    things that cannot be established by reading the code or by running it on
    a developer's machine.
    """
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-boot-screen.sh"), on_output=on_output)


def install(config, package, on_output=None):
    """The end-to-end update: USB stick -> the printer's own installer -> boot.

    The package sits on a genuine FAT filesystem at /dev/sda1 and the
    printer's own app_startup.sh finds it, mounts it, decrypts it and runs the
    installer -- three boots, the last with the stick pulled. The baseline is
    the stock package for the SAME model: it is what makes /usr/prog authentic
    rather than hand-written, and the two models ship different firmwareExe
    binaries that each refuse to install on the other.
    """
    package = os.path.abspath(package)
    if not os.path.isfile(package):
        raise Fail("no package at %s" % package)
    name = os.path.basename(package)

    base = config.stock_for(name)
    if not base:
        raise Skip("no stock package configured for %s -- set STOCK_TGZ_* "
                   "in config.env" % name)

    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-install.sh"),
                     packages={name: package}, base_pkg=base,
                     usb_stick=True, on_output=on_output)


def roundtrip(config, mod, stock, on_output=None):
    """Recovery: install the mod, flash stock, and be back to stock."""
    mod, stock = os.path.abspath(mod), os.path.abspath(stock)
    for path, what in ((mod, "mod"), (stock, "stock")):
        if not os.path.isfile(path):
            raise Fail("no %s package at %s" % (what, path))

    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-recovery.sh"),
                     packages={"mod.tgz": mod, "stock.tgz": stock},
                     base_pkg=stock, on_output=on_output)


# ----------------------------------------------------------------- utilities

def shutil_which(name):
    import shutil
    return shutil.which(name)


def _rmtree(path):
    import shutil
    shutil.rmtree(str(path), ignore_errors=True)


def _extract_all(tf, dest):
    """tar extraction that cannot write outside dest.

    Python 3.12 warns about this and 3.14 changes the default; being explicit
    means the same behaviour on every interpreter the build image might carry.
    """
    dest = os.path.abspath(str(dest))
    for member in tf.getmembers():
        target = os.path.abspath(os.path.join(dest, member.name))
        if not (target == dest or target.startswith(dest + os.sep)):
            raise Fail("refusing to extract %s outside %s"
                       % (member.name, dest))
    try:
        tf.extractall(str(dest), filter="data")
    except TypeError:      # filter= arrived in 3.12
        tf.extractall(str(dest))
