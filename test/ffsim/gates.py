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
import shutil
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

def mcu_bringup(config, on_output=None):
    """Does start.sh's ff_mcu_bringup.py actually run on FF_PYTHON?

    FF_PYTHON is our own cross-built CPython 3.13 now (payload/anvil-env.sh),
    not FlashForge's 3.8.2, so the interpreter under test is a build output --
    work/pkg/python* -- handed over as py.tgz exactly as case-python.sh receives
    one. Skips rather than degrading: there is no fallback interpreter worth
    testing this against, since nothing on the printer still launches
    ff_mcu_bringup.py on FlashForge's 3.8.2.
    """
    tree = _python_tarball(config)
    if not tree:
        raise Skip("nothing in work/pkg/python -- run ./bin/patch.sh first")
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-mcu-bringup.sh"),
                     packages={"py.tgz": tree}, on_output=on_output)


def boot_screen(config, on_output=None):
    """Does the first-boot screen draw, on FF_PYTHON and its fb0?

    Hand-packed pixels and an interpreter FF_PYTHON resolves to -- since the
    switch, our own cross-built CPython 3.13 (work/pkg/python*), handed over as
    py.tgz. Skips rather than degrading, for the same reason as mcu_bringup
    above: FlashForge's 3.8.2 is not what draws this screen any more.
    """
    tree = _python_tarball(config)
    if not tree:
        raise Skip("nothing in work/pkg/python -- run ./bin/patch.sh first")
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-boot-screen.sh"),
                     packages={"py.tgz": tree}, on_output=on_output)


def moonraker(config, on_output=None):
    """Does the web stack actually start on the printer?

    Installs the payload as an update does, then drives the shipped tools:
    anvil-env.sh must produce a working interpreter, every component the
    config asks for must import, and init.d/S62moonraker must bring moonraker
    up on the printer's own python -- from /usr/data/anvil/moonraker, not
    FlashForge's tree on /usr/prog -- answer on :7125, and stop and restart
    cleanly. Since nginx and moonraker are separate scripts now, it also
    checks the thing that split was for: stopping moonraker leaves nginx up.
    With the pre-flight gone from the firmware, this is also the only place a
    Moonraker pin that cannot load gets caught -- before it ships.

    Since phase 5 moonraker is supervised, so the case also proves what that
    bought: s6 respawns a killed moonraker, `S62moonraker stop` is a stop the
    supervisor does not undo, MOD_WEB=0 leaves the service down, and readiness
    means the API is LISTENING rather than the process was forked.

    HANDED THE REAL s6 WHENEVER ONE EXISTS, and it DEGRADES rather than
    skipping when one does not -- which is the opposite of nginx and camera,
    on purpose. Those two cases are about supervision and have nothing to say
    without a supervisor. This one is also the only gate that runs the shipped
    Moonraker at all, so skipping it in a checkout that has not built s6 yet
    would take the component-import checks with it and let a broken pin
    through. Without a tarball the case runs sections 1-11 against
    S62moonraker's no-supervisor fallback -- which is real shipped code, the
    path a printer with MOD_S6=0 takes -- and says so in its output.

    THE INTERPRETER TARBALL IS NOT OPTIONAL THE SAME WAY. FF_PYTHON names our
    own $MODDIR/bin/python3.13 now, and there is no fallback interpreter the
    way there is a no-supervisor fallback for s6 -- without it nothing from
    section 1 on has anything to run, so this is a Skip rather than a
    degrade, exactly like moonraker313_s6 below.

    The negative controls carry as much weight as the rest: take the library
    path away and the interpreter must fail, take libsodium away (when it is
    on the path at all -- see case-libpath.sh for why it usually is not any
    more) and the authorization component must fail, supervise a daemonising
    service and it must churn, or the list is cargo and the supervision is
    decoration.
    """
    prefix = _prefix_tarball(config)
    if not prefix:
        raise Skip("nothing in work/pkg/python or work/.sodium -- run ./bin/patch.sh first")
    packages = {"pref.tgz": prefix}
    s6 = _s6_tarball(config)
    if s6:
        packages["sup.tgz"] = s6
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-moonraker.sh"),
                     packages=packages, on_output=on_output)


def _s6_tarball(config):
    """The cross-built s6 tree, packed the way a printer would see it.

    THREE TREES, NOT ONE. This used to read work/.s6, the single directory
    bin/patch.sh cross-built s6 into. s6 is four packages now -- skalibs, which
    ships nothing to a printer, plus execline, s6 and s6-rc -- so the bin/ and
    libexec/ a case unpacks into $MODDIR are merged from three recipe outputs
    under work/pkg. The shape a case sees is unchanged, which is the point.

    Returns None when nothing has built them yet -- the caller decides whether
    that is a Skip or a reason to fall back, because those are different
    questions: case-supervisor is ABOUT s6 and has nothing to say without it,
    while case-services is about our own scripts and can still check most of
    its contract against a stand-in.
    """
    trees = [config.root / "work" / "pkg" / n
             for n in ("execline", "s6", "s6-rc")]
    if not (config.root / "work" / "pkg" / "s6" / "bin" / "s6-svscan").is_file():
        return None
    staged = config.root / "work" / ".s6-gate"
    if staged.is_dir():
        shutil.rmtree(str(staged))
    for tree in trees:
        for sub in ("bin", "libexec"):
            src = tree / sub
            if src.is_dir():
                shutil.copytree(str(src), str(staged / sub), dirs_exist_ok=True,
                                symlinks=True)
    out = config.root / "work" / ".s6-gate.tgz"
    with tarfile.open(str(out), "w:gz") as tar:
        for sub in ("bin", "libexec"):
            if (staged / sub).is_dir():
                tar.add(str(staged / sub), arcname=sub)
    return str(out)


def moonraker313_s6(config, on_output=None):
    """The real Moonraker, on OUR 3.13, brought up by S62moonraker under s6.

    THE GATE THE FF_PYTHON SWITCH IS WAITING ON, and the only one that runs all
    four real things at once. Its two neighbours each leave the same hole on
    purpose and say so in their own headers: case-moonraker stands the ENTRY
    POINT in for its supervision sections, because the real Moonraker's
    fork-to-listen gap is the better part of a minute on qemu and measuring s6
    through it is slow and imprecise; case-moonraker313 drives the entry point
    DIRECTLY, with no init script anywhere near it, so that a failure there is
    the interpreter and not a shell script. Between them nothing had ever taken
    the boot path -- S40s6, the scandir, `down`, S62moonraker, svc_s6_up, the
    notification-fd -- on the interpreter the mod is going to switch to.

    What it measures that nothing else does: that s6-svwait -U returns when
    :7125 is LISTENING and not when the process forked, against the REAL
    startup rather than a controllable delay; that the process s6 ends up
    holding is our interpreter and our entry point, read from /proc/PID/cmdline
    rather than inferred; that a respawn after kill -9 comes back on the same
    interpreter, because the run script re-sources anvil-env.sh from the
    scanner's environment every time; and that the supervised process maps zero
    libraries under /usr/prog.

    IT RUNS ON BOTH SIDES OF THE SWITCH, which is what makes it a gate rather
    than a thing that has to be written twice. What is under test is the
    POST-switch configuration, so while payload/anvil-env.sh still names
    FlashForge's 3.8.2 -- which it does, deliberately, until there is hardware
    evidence behind the change -- the case applies the same two edits to the
    INSTALLED copy and says out loud that it did; afterwards it will assert the
    shipped file already says so and change nothing. Either way the thing
    measured is identical, so this neither blocks the switch nor rots the day
    after it.

    Skips rather than degrading when a build output is missing. There is no
    fallback worth having: a stand-in supervisor, a stand-in interpreter or a
    stand-in Moonraker each removes one of the exactly four things the case is
    the intersection of.
    """
    s6 = _s6_tarball(config)
    if not s6:
        raise Skip("nothing in work/pkg/s6 -- run ./bin/patch.sh first")
    prefix = _prefix_tarball(config)
    if not prefix:
        raise Skip("nothing in work/pkg/python or work/.sodium -- run ./bin/patch.sh first")
    tree = _moonraker_tarball(config)
    if not tree:
        raise Skip("no Moonraker tarball in vendor/ -- run ./bin/fetch-assets.sh first")
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-moonraker313-s6.sh"),
                     packages={"sup.tgz": s6, "pref.tgz": prefix,
                               "mr.tgz": tree},
                     on_output=on_output)


def _prefix_tarball(config):
    """The mod's own /usr/data/anvil prefix: interpreter, stdlib, packages and
    libsodium, in one tarball because it is one prefix.

    bin/patch.sh puts every one of these under the same $MODDIR: section 5c
    writes bin/python3.13 and lib/python3.13 (stdlib AND site-packages) out of
    pkgs/3rdparty/python and the eighteen pkgs/3rdparty/python-* recipes, and section 5d writes
    lib/libsodium.so* out of pkgs/3rdparty/libsodium. Many recipe outputs, one
    destination, so one tarball -- which also means the case unpacks it exactly
    once and every file lands where it was compiled to expect itself.

    Returns None when either half is missing, which for this gate is a Skip:
    see the docstring above for why there is no useful fallback.
    """
    trees = _python_trees(config)
    sodium = config.root / "work" / ".sodium"
    if not (trees[0] / "bin" / "python3.13").is_file():
        return None
    if not list(sodium.glob("lib/libsodium.so*")):
        return None
    out = config.root / "work" / ".pref-gate.tgz"
    with tarfile.open(str(out), "w:gz") as tar:
        for tree in trees:
            for sub in ("bin", "lib"):
                if (tree / sub).is_dir():
                    tar.add(str(tree / sub), arcname=sub)
        for so in sorted(sodium.glob("lib/libsodium.so*")):
            tar.add(str(so), arcname="lib/" + so.name)
    return str(out)


def _moonraker_tarball(config):
    """Moonraker's own tree plus the mod's configs, in the payload's shape.

    The other two tarballs come out of work/; this one is made from the two
    places bin/patch.sh makes the payload's moonraker/ and config/ from -- the
    pinned sdist in vendor/ and assets/*.conf -- because that is where they
    exist in a checkout that has not built anything. Repacked here rather than
    handed over whole for one reason: busybox tar's --strip-components is not
    something to bet a gate on, and the vendor tarball has a commit-named top
    directory that has to come off.

    tests/ is dropped, exactly as patch.sh drops it, so that what the case
    installs is what a printer installs.
    """
    version = ""
    versions = config.root / "versions.env"
    if versions.is_file():
        for line in versions.read_text().splitlines():
            if line.startswith("MOONRAKER_VERSION="):
                version = line.partition("=")[2].strip().strip('"\'')
                break
    src = config.root / "vendor" / ("moonraker-%s.tar.gz" % version)
    if not src.is_file():
        found = sorted((config.root / "vendor").glob("moonraker-*.tar.gz"))
        if not found:
            return None
        src = found[-1]

    out = config.root / "work" / ".mrtree-gate.tgz"
    with tarfile.open(str(src)) as inp, tarfile.open(str(out), "w:gz") as tar:
        top = None
        for member in inp.getmembers():
            parts = member.name.split("/")
            if top is None:
                top = parts[0]
            if len(parts) < 2 or parts[0] != top or parts[1] != "moonraker":
                continue
            if len(parts) > 2 and parts[2] == "tests":
                continue
            member.name = "/".join(parts[1:])
            if member.isfile():
                tar.addfile(member, inp.extractfile(member))
            else:
                tar.addfile(member)
        for name in ("moonraker.conf", "moonraker-custom.conf"):
            conf = config.root / "assets" / name
            if conf.is_file():
                tar.add(str(conf), arcname="config/" + name)
    return str(out)


def supervisor(config, on_output=None):
    """Does the s6 we cross-compiled actually work on the printer?

    Not "did it build" -- it execs, it supervises, it respawns a killed
    process, its stop waits for the process to be gone, and s6-svwait -U
    blocks until a service says it is ready. That last one is the whole reason
    s6 was chosen over runit, and it is also the check that proves the prefix
    baked into the binaries at compile time is the one the printer sees: get
    it wrong and status still works while every waiting verb fails.
    """
    s6 = _s6_tarball(config)
    if not s6:
        raise Skip("nothing in work/pkg/s6 -- run ./bin/patch.sh first")
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-supervisor.sh"),
                     packages={"sup.tgz": s6}, on_output=on_output)


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


def python(config, on_output=None):
    """Does the CPython 3.13 we cross-compiled run on the printer, with sqlite?

    Not "did it build" -- the kernel loads it, a database is created, written,
    closed and reopened from disk by a second process, ssl/ctypes/zlib/lzma/
    bz2/hashlib/asyncio all import, and /proc/self/maps shows nothing under
    /usr/prog, which is what "independent of FlashForge's libraries" means
    when it is measured rather than asserted.

    The negative control is what gives the rest its meaning: FlashForge's own
    3.8.2, handed the library path it needs to start, cannot import sqlite3 --
    the single fact that pins MOONRAKER_VERSION to a 2023 commit.

    Skips rather than degrading when nothing has been built. Unlike
    case-moonraker there is no fallback worth having here: the whole case is
    about one artefact, and a stand-in interpreter would be testing python.
    """
    tree = _python_tarball(config)
    if not tree:
        raise Skip("nothing in work/pkg/python -- run ./bin/patch.sh first")
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-python.sh"),
                     packages={"py.tgz": tree}, on_output=on_output)


def nginx(config, on_output=None):
    """Is nginx really supervised, and does a stop really stop it?

    The migration bug this exists to catch is the one that looks fine: a
    service that starts, and a `stop` the supervisor quietly undoes a second
    later. It also pins down what killing nginx hard actually does here --
    SIGKILL orphans the worker, the worker keeps :80, and the respawned master
    cannot bind, so s6 loops for ever while svstat cheerfully says up.
    """
    s6 = _s6_tarball(config)
    if not s6:
        raise Skip("nothing in work/pkg/s6 -- run ./bin/patch.sh first")
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-nginx.sh"),
                     packages={"sup.tgz": s6}, on_output=on_output)


def camera(config, on_output=None):
    """Does readiness actually gate, or does it just mean "forked"?

    The camera is why s6 was chosen over runit. Its old script hand-rolled a
    respawn loop and a 30-second poll of /dev/video0; both are gone, and the
    replacement is only worth anything if s6-svwait -U blocks until the
    streamer is genuinely serving rather than merely running. The case asserts
    up-and-not-ready together, so it cannot pass vacuously against a service
    that never started at all.
    """
    s6 = _s6_tarball(config)
    if not s6:
        raise Skip("nothing in work/pkg/s6 -- run ./bin/patch.sh first")
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-camera.sh"),
                     packages={"sup.tgz": s6}, on_output=on_output)


def libpath(config, on_output=None):
    """Is every directory anvil-env.sh exports actually needed, and every one
    it dropped actually dead?

    ANVIL_LIBS was ten /usr/prog directories defended by an argument -- give
    every caller the union and no config change can break it -- and it is four
    now because the argument did not survive being measured. This is the
    measurement, kept: each of the four is removed from LD_LIBRARY_PATH on its
    own and made to fail (the interpreter will not start without Python or
    openssl, `import ctypes` needs libffi, `import libnacl` needs libsodium),
    and a python running with the whole old ten-entry path is caught by
    /proc/PID/maps loading none of the six that went. Without those negative
    controls a gate here would pass just as happily on a list of forty.
    """
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-libpath.sh"), on_output=on_output)


def services(config, on_output=None):
    """Do all five init.d services behave like the same kind of thing?

    They used to be five one-off scripts with four different ways of asking
    "is it running" and four different `case "$1"` blocks. anvil-service.sh
    made those one decision each; this is what stops them drifting apart
    again. It runs every service on the printer's own busybox and checks the
    contract they share -- the library loads, `status` answers, the output
    names the service, an unknown verb gets a usage line and exit 1 -- rather
    than grepping the scripts for how they are spelled.

    Handed the real cross-built s6 whenever one exists, because S40s6 is one
    of those services now and a gate that only ever ran against a stand-in
    scanner would pass happily on a printer that cannot exec the supervisor it
    ships. The case falls back to its stand-in on its own when no tarball
    arrives -- which keeps this useful in a checkout that has not built yet --
    and says out loud which of the two it used.

    case-priority.sh rides along here because it is the same subject from the
    other side: not "do they all answer the same verbs" but "do they start at
    the priority anvil.conf asks for". Both run the real scripts on the
    printer's own busybox, and both would pass a grep that means nothing --
    whether `start-stop-daemon -N` is honoured is a property of THIS busybox
    (1.31.1, and it has no ionice applet at all), so it has to be measured.
    """
    packages = {}
    s6 = _s6_tarball(config)
    if s6:
        packages["sup.tgz"] = s6
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-services.sh"),
                     packages=packages, on_output=on_output)
    replica.run_case(_case(config, "case-priority.sh"), on_output=on_output)


def upgrade(config, on_output=None):
    """Does an update delete what it installed, and only what it installed?

    The installer used to start an update by wiping seven whole directories,
    which is right only while every file under them is ours -- and $MODDIR/bin
    is where a supervisor and later a Python are going to live. It ships a
    manifest now and deletes what the previous one named. This runs the real
    run-append.sh over two hand-built payloads on the printer's own busybox
    and asks the filesystem afterwards: the init script the last payload
    shipped and this one does not is gone, the file nobody shipped is still
    there, anvil.conf keeps the user's edit, config-installed survives, and a
    printer with no manifest at all still gets cleaned up the old way.
    """
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-upgrade.sh"), on_output=on_output)


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
