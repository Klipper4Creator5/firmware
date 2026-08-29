"""The gates themselves.

Each one is a plain function that returns normally, raises Skip when its
precondition is genuinely absent, or raises Fail when it ran and the answer
was no.

WHAT IS LEFT. This was fifteen gates driving thirteen case scripts; every one
of them is a module under qa/ now. `extract_rootfs` survives because it is not
a gate at all -- it unpacks the printer's real userland, which `make rootfs`
does and which a locally built replica needs. The python
tarball helpers survive because `make boot-screen-sim` renders its frames with
the cross-built interpreter.
"""
import os
import shutil
import subprocess
import tarfile

from . import Fail

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
    kernel_tarball = kernels[0]

    kerndir = root / "work" / "kern"
    rootfs = root / "work" / "rootfs"
    for d in (kerndir, rootfs):
        if d.exists():
            _rmtree(d)
    kerndir.mkdir(parents=True)

    with tarfile.open(str(kernel_tarball)) as tf:
        _extract_all(tf, kerndir)

    squash = None
    for path in kerndir.rglob("rootfs.squashfs*"):
        squash = path
        break
    if squash is None:
        raise Fail("no rootfs.squashfs inside %s" % kernel_tarball.name)

    if on_output:
        on_output(">> %s" % squash.name)
    completed = subprocess.run(
        ["unsquashfs", "-q", "-d", str(rootfs), str(squash)],
        capture_output=True, text=True)
    if completed.returncode != 0:
        raise Fail("unsquashfs failed:\n%s" % completed.stderr.strip())
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
def _python_trees(config):
    """Every recipe output that makes up the printer's python prefix.

    NINETEEN TREES, NOT ONE, for the same reason _s6_tarball reads three. This
    used to be work/.py313, the single directory bin/patch.sh cross-built the
    interpreter and its site-packages into together. CPython is pkgs/3rdparty/python now
    and each of the eighteen third-party packages is a pkgs/3rdparty/python-* of its own,
    so what a printer sees is the union of their bin/ and lib/ -- which is
    exactly what the payload's python packages provide, in this order.

    The interpreter comes first so that a half-built checkout fails on the
    thing the caller actually needs rather than on a package that depends on it.
    """
    pkg = config.root / "work" / "pkg"
    return [pkg / "python"] + sorted(d for d in pkg.glob("python-*") if d.is_dir())


def _python_tarball(config):
    """The cross-built CPython 3.13 tree, packed the way a printer sees it.

    The interpreter is configured --prefix=/usr/data/anvil and its stdlib lives
    in lib/python3.13/, so a tarball of the merged bin/ + lib/ unpacks straight
    into $MODDIR and every file lands where it was compiled to expect itself.
    Returns None when nothing has built it yet; the same shape as _s6_tarball
    above, and for the same reason: whether that is a Skip or a fallback is the
    caller's question.

    THE DEV HALF RIDES ALONG and is deliberately not filtered out. work/pkg/python
    holds the whole build -- headers, lib/pkgconfig and config-3.13-* included --
    because the split into anvil-python and anvil-python-dev happens where the
    .ipk files are made. Which paths those are is pkgs/3rdparty/python/pkg.conf's business,
    and repeating the list here would be a second spelling that goes stale
    silently. This is a test fixture unpacked into a simulator, not something a
    printer installs: 3MB of headers it will never open costs nothing, and the
    package boundary is gated where it is made.
    """
    trees = _python_trees(config)
    if not (trees[0] / "bin" / "python3.13").is_file():
        return None
    staged = config.root / "work" / ".py-gate"
    if staged.is_dir():
        shutil.rmtree(str(staged))
    for tree in trees:
        for sub in ("bin", "lib"):
            src = tree / sub
            if src.is_dir():
                shutil.copytree(str(src), str(staged / sub), dirs_exist_ok=True,
                                symlinks=True)
    out = config.root / "work" / ".py-gate.tgz"
    with tarfile.open(str(out), "w:gz") as tar:
        for sub in ("bin", "lib"):
            if (staged / sub).is_dir():
                tar.add(str(staged / sub), arcname=sub)
    return str(out)
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
