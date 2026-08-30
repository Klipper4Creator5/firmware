"""What is left of the gates: the cross-built python tree, as a tarball.

THERE ARE NO GATES IN HERE. There were fifteen, driving thirteen case
scripts, and every one of them is a module under qa/ now. The name is kept
because the two survivors have no better home yet and a rename would be the
only thing in the diff that could break an import.

What survives, and why:

  _python_trees / _python_tarball   `make boot-screen-sim` renders its frames
                                    with the interpreter we cross-build, so
                                    something has to hand it that tree.

`extract_rootfs` was the other survivor -- it unsquashed the printer's real
userland out of the stock package for a locally built replica. There is no
such replica any more: PRINTER_IMAGE is the one source of a machine, and
tools/replica/build-printer-image.sh does its own extraction from the public
firmware without needing a stock package at all.
"""
import shutil
import tarfile


def _python_trees(config):
    """Every recipe output that makes up the printer's python prefix.

    NINETEEN TREES, NOT ONE. This used to be work/.py313, the single directory
    bin/payload.sh cross-built the interpreter and its site-packages into
    together. CPython is pkgs/3rdparty/python now and each of the eighteen
    third-party packages is a pkgs/3rdparty/python-* of its own, so what a
    printer sees is the union of their bin/ and lib/ -- which is exactly what
    the payload's python packages provide, in this order.

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
    Returns None when nothing has built it yet: whether that is a Skip or a
    fallback is the caller's question.

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
