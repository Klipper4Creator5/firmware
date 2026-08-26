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

    The negative controls carry as much weight as the rest: take the library
    path away and the interpreter must fail, take libsodium away and the
    authorization component must fail, supervise a daemonising service and it
    must churn, or the list is cargo and the supervision is decoration.
    """
    packages = {}
    s6 = _s6_tarball(config)
    if s6:
        packages["sup.tgz"] = s6
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-moonraker.sh"),
                     packages=packages, on_output=on_output)


def _s6_tarball(config):
    """The cross-built s6 tree, packed the way a printer would see it.

    bin/patch.sh leaves it in work/.s6 as bin/ + libexec/, which is exactly
    the shape a case wants to unpack straight into $MODDIR. Returns None when
    nothing has built it yet -- the caller decides whether that is a Skip or a
    reason to fall back, because those are different questions: case-supervisor
    is ABOUT s6 and has nothing to say without it, while case-services is
    about our own scripts and can still check most of its contract against a
    stand-in.
    """
    built = config.root / "work" / ".s6"
    if not (built / "bin" / "s6-svscan").is_file():
        return None
    out = config.root / "work" / ".s6-gate.tgz"
    with tarfile.open(str(out), "w:gz") as tar:
        for sub in ("bin", "libexec"):
            tar.add(str(built / sub), arcname=sub)
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
        raise Skip("nothing in work/.s6 -- run ./bin/patch.sh first")
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-supervisor.sh"),
                     packages={"sup.tgz": s6}, on_output=on_output)


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
        raise Skip("nothing in work/.s6 -- run ./bin/patch.sh first")
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
        raise Skip("nothing in work/.s6 -- run ./bin/patch.sh first")
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-camera.sh"),
                     packages={"sup.tgz": s6}, on_output=on_output)


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
    """
    packages = {}
    s6 = _s6_tarball(config)
    if s6:
        packages["sup.tgz"] = s6
    replica = Replica.start(config, want_output=on_output)
    replica.run_case(_case(config, "case-services.sh"),
                     packages=packages, on_output=on_output)


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
