"""The replica, as a fixture rather than as a test runner.

WHAT CHANGED, AND WHY IT IS THE WHOLE POINT

test/ffsim/replica.py runs one container per case script:

    docker run --rm --privileged ... <image> /case.sh

entrypoint.sh sets the machine up, chroots in, runs the case, and the
container exits. The case's exit code is the entire result. That is why
6,280 lines of case-*.sh report 13 bits between them, and why a failure in
case-moonraker.sh -- 1,059 lines -- tells you only that something in there
went wrong.

Here the container is started ONCE per test module and held open, and each
test reaches into it with `docker exec`. Nothing about the machine changes:
the same image, the same --privileged, the same entrypoint.sh, assemble.sh,
binfmt.sh and seed-prog.sh, the same read-only squashfs root and writable
prog/data partitions, the same chroot onto the printer's own busybox under
qemu. What changes is that one container now yields as many individually
named, individually selectable results as you care to write.

HOW IT IS HELD OPEN

entrypoint.sh is reused UNMODIFIED -- it is setup, and setup is exactly where
shell belongs. It ends by running the case script inside the chroot, so the
case script it is given here is qa/replica/actions/hold.sh, which touches a
marker and then sleeps forever. Setup runs to completion exactly as it always
has, and then the container simply does not exit.

That marker is also the readiness signal, and it has to be: setup takes from
under a second (a prebuilt PRINTER_IMAGE) to over a minute (unpacking the
factory image and installing the stock baseline under qemu). Polling for the
marker waits for however long this machine actually needs, rather than for a
constant somebody guessed.

ISOLATION

One container per module, which is the same boundary the case scripts have
today -- each of them starts from a fresh machine, and none of them shares
state with another. Tests within a module share, deliberately: they are the
assertions that used to live in one case script, and they were always
sequential steps against one machine.

For the rare test that needs to undo what it did, snapshot()/restore() tar
the writable partitions. It is not the default because it costs a second or
two per call and most tests do not need it.
"""
import hashlib
import os
import shutil
import subprocess
import time

from .config import Config
from .paths import ROOT

# Where the container is assembled. Matches entrypoint.sh's own layout.
CHROOT = "/printer"

# hold.sh writes this inside the chroot once setup has finished.
READY_MARKER = "/tmp/qa-replica-ready"


class ReplicaMissing(Exception):
    """The machine cannot supply a replica: no docker, no daemon, no image.

    A FAILURE, everywhere, and never a skip. These tests exist to decide
    whether a package bricks a printer; a run that could not build the printer
    did not answer that, and "skipped" is a word that makes not answering look
    like a choice. Every message raised here names what is missing AND what to
    do about it, because the honest report is "this machine is not set up",
    which is actionable, rather than "unavailable", which is not.
    """


class Result:
    """What a command did, as data.

    `ok` rather than a raised exception by default: most assertions here are
    about the output of a command that is EXPECTED to fail (a service
    rejecting an unknown verb with exit 1), and a façade that raises on
    non-zero would make the interesting cases the awkward ones.
    """

    def __init__(self, argv, code, out, err):
        self.argv = argv
        self.code = code
        self.out = out
        self.err = err

    @property
    def ok(self):
        return self.code == 0

    @property
    def text(self):
        """stdout and stderr together, which is what `cmd 2>&1` gave the case
        scripts and what nearly every assertion here wants."""
        return (self.out or "") + (self.err or "")

    @property
    def first_line(self):
        lines = [ln for ln in self.text.splitlines() if ln.strip()]
        return lines[0] if lines else ""

    def __repr__(self):
        return "Result(code=%d, text=%r)" % (self.code, self.text[:200])


class File:
    """A path inside the replica, asked about from here."""

    def __init__(self, printer, path):
        self._p = printer
        self.path = path

    @property
    def exists(self):
        return self._p.sh("[ -e %s ]" % self.path).ok

    @property
    def is_dir(self):
        return self._p.sh("[ -d %s ]" % self.path).ok

    @property
    def executable(self):
        return self._p.sh("[ -x %s ]" % self.path).ok

    @property
    def empty(self):
        """True for absent-or-zero-length. `[ -s ]` is the inverse, and the
        distinction matters for log files: 'the scanner wrote nothing' and
        'there is no log' are the same healthy answer."""
        return not self._p.sh("[ -s %s ]" % self.path).ok

    @property
    def text(self):
        return self._p.sh("cat %s 2>/dev/null" % self.path).out

    @property
    def lines(self):
        return [ln for ln in self.text.splitlines() if ln.strip()]

    def __repr__(self):
        return "File(%s)" % self.path


class Service:
    """One of anvil-core's init.d/S*, driven through its own dispatcher.

    Every method returns a Result. Nothing here decides anything by reading
    the script: it runs the service and reports what came back, which is the
    property case-services.sh's header insists on and is worth keeping.
    """

    def __init__(self, printer, name, initd):
        self._p = printer
        self.name = name
        self.path = "%s/%s" % (initd, name)

    def __call__(self, verb):
        return self._p.sh("%s %s 2>&1" % (self.path, verb))

    def status(self):
        return self("status")

    def start(self):
        return self("start")

    def stop(self):
        return self("stop")

    @property
    def installed(self):
        return self._p.file(self.path).executable

    def __repr__(self):
        return "Service(%s)" % self.name


class Process:
    """A row of the process table, read from /proc rather than from `ps`.

    busybox `ps` truncates its command column, and qemu prefixes every
    cmdline with the emulator and its arguments, so `ps | grep` both misses
    long command lines and matches on the wrong half of short ones.
    case-install.sh learned this and scans /proc/*/cmdline; putting it here
    means the rest of the suite inherits the lesson instead of relearning it.
    """

    def __init__(self, pid, argv):
        self.pid = pid
        self.argv = argv

    @property
    def cmdline(self):
        return " ".join(self.argv)

    def __repr__(self):
        return "Process(%s, %r)" % (self.pid, self.cmdline[:120])


class Printer:
    """A live replica. Actions run inside it; assertions run out here."""

    def __init__(self, container, docker, config):
        self.container = container
        self.docker = docker
        self.config = config

    # ------------------------------------------------------------- execution

    def sh(self, script, timeout=120):
        """Run a script inside the chroot, on the printer's own busybox ash.

        The script arrives on stdin rather than as an argv element, so it can
        contain any quoting it likes without a layer of escaping between here
        and there -- and the tests can therefore hold real shell snippets
        rather than shell snippets bent around the transport.
        """
        argv = [self.docker, "exec", "-i", self.container,
                "chroot", CHROOT, "/bin/sh"]
        try:
            done = subprocess.run(
                argv, input=script, capture_output=True, text=True,
                # errors="replace": a command that cats one of the printer's
                # MIPS binaries emits bytes that are not UTF-8, and a strict
                # decode raises out of communicate() -- so the harness fails
                # and reports nothing about the test.
                errors="replace", timeout=timeout)
        except subprocess.TimeoutExpired as expired:
            # A timeout is a Result, not an exception, because "it did not
            # come back" is a verdict some tests are specifically looking for
            # -- the init sequence must return, and an S40s6 that runs the
            # scanner inline is exactly the failure that hangs it.
            return Timeout(argv, expired, timeout)
        return Result(argv, done.returncode, done.stdout, done.stderr)

    def sh_host(self, argv, timeout=120):
        """Run a command in the container but OUTSIDE the chroot.

        For the container's own Debian tools -- tar, cp -- when staging
        something into the machine. Never for assertions.
        """
        done = subprocess.run(
            [self.docker, "exec", self.container] + argv,
            capture_output=True, text=True, errors="replace", timeout=timeout)
        return Result(argv, done.returncode, done.stdout, done.stderr)

    def write(self, path, content, mode=None):
        """Create a file inside the chroot with exactly these bytes.

        Via stdin and `cat`, not a heredoc built into a command string: a
        heredoc terminator that happens to appear in the content would end it
        early, and the content here is often itself shell.
        """
        script = "cat > %s" % path
        argv = [self.docker, "exec", "-i", self.container,
                "chroot", CHROOT, "/bin/sh", "-c", script]
        done = subprocess.run(argv, input=content, capture_output=True,
                              text=True, errors="replace")
        if done.returncode != 0:
            raise RuntimeError("could not write %s: %s" % (path, done.stderr))
        if mode:
            self.sh("chmod %s %s" % (mode, path))

    # -------------------------------------------------------------- observing

    def file(self, path):
        return File(self, path)

    def svc(self, name, initd="/usr/data/anvil/init.d"):
        return Service(self, name, initd)

    def ps(self):
        """The process table, from /proc/*/cmdline.

        NUL-separated argv per process, with a record separator between
        processes, parsed here. /proc is the container's own mount inside the
        chroot, so this sees every process in the container's namespace --
        which is what "stop left nothing behind" is a claim about.
        """
        # `printf` rather than `echo` for the separator: busybox echo would
        # interpret the escape itself on some builds and not others.
        script = r'''
for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    printf '%s\t' "${d#/proc/}"
    cat "$d/cmdline" 2>/dev/null | tr '\0' ' '
    printf '\n'
done
'''
        out = self.sh(script).out
        found = []
        for line in out.splitlines():
            if "\t" not in line:
                continue
            pid, _, rest = line.partition("\t")
            argv = [a for a in rest.split(" ") if a]
            if not argv:
                continue          # a kernel thread has an empty cmdline
            found.append(Process(pid, argv))
        return found

    def pgrep(self, needle):
        """Processes whose command line contains `needle`.

        Note what this deliberately does NOT need: the `grep -v grep` and
        `grep -v case.sh` dance every case script carries, because there is
        no pipeline here to match itself and no case script in the table.
        """
        return [p for p in self.ps() if needle in p.cmdline]

    def listening(self, port):
        """Is anything listening on this TCP port?

        /proc/net/tcp, because the printer has no `nc`, no `ss` and no
        `netstat -l` worth the name. The local address column is
        HEX_IP:HEX_PORT and state 0A is LISTEN -- the same parse the s6 run
        scripts do, which is the reason this readiness protocol exists at all.
        """
        want = "%04X" % int(port)
        script = "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"
        for line in self.sh(script).out.splitlines():
            cols = line.split()
            if len(cols) < 4 or ":" not in cols[1]:
                continue
            if cols[1].rsplit(":", 1)[-1].upper() == want and cols[3] == "0A":
                return True
        return False

    # --------------------------------------------------------------- staging

    def snapshot(self, name="default"):
        """Tar the writable partitions, for a test that needs to undo itself."""
        self.sh_host(["sh", "-c",
                      "tar -cf /qa-snap-%s.tar -C %s/usr/data ." % (name, CHROOT)])

    def restore(self, name="default"):
        self.sh_host(["sh", "-c",
                      "rm -rf %s/usr/data/* && tar -xf /qa-snap-%s.tar -C %s/usr/data"
                      % (CHROOT, name, CHROOT)])


class Timeout(Result):
    """A command that never came back.

    A Result subclass so callers need no special case, with a code that is
    not zero and a text that says what happened. `timed_out` is there for the
    tests whose whole question is whether something returns -- the bounded
    init sequence, which exists because a start() that runs s6-svscan inline
    does not slow the boot down, it ends it.
    """

    timed_out = True

    def __init__(self, argv, expired, limit):
        out = expired.stdout or ""
        err = expired.stderr or ""
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        if isinstance(err, bytes):
            err = err.decode("utf-8", "replace")
        Result.__init__(self, argv, 124, out,
                        err + "\n[did not return within %ss]" % limit)
        self.limit = limit


# Every non-timeout Result answers False, so `result.timed_out` is always safe.
Result.timed_out = False


# --------------------------------------------------------------- the lifecycle

def find_docker():
    """The docker CLI, or a reason. docker.exe is the WSL case: the daemon
    runs on the Windows side and the Linux binary may not be installed."""
    for name in ("docker", "docker.exe"):
        if shutil.which(name):
            return name
    raise ReplicaMissing(
        "no docker CLI on PATH, so no replica can be built and none of the "
        "gates that decide whether a package bricks a printer can run. "
        "Install docker, or run the suite through `make qa-replica`, which "
        "does all of this inside the build image.")


def resolve_image(config, docker):
    """The replica image, built locally if no prebuilt one is configured."""
    probe = subprocess.run([docker, "info"], capture_output=True, text=True)
    if probe.returncode != 0:
        # The two causes look identical from here and need opposite fixes, so
        # the message carries both rather than guessing. "permission denied"
        # is the common one and it is not a dead daemon at all -- the daemon
        # is fine and the user is not in the docker group, which an already
        # open shell will not notice even after usermod, because a process
        # keeps the groups it started with.
        said = (probe.stderr or "").strip().splitlines()
        raise ReplicaMissing(
            "the docker daemon did not answer, so no replica can be built:\n"
            "    %s\n"
            "Either it is not running (systemctl start docker), or this user "
            "cannot reach its socket (usermod -aG docker $USER, then start a "
            "new login shell)."
            % (said[-1] if said else "docker info exited %d" % probe.returncode))

    image = config.get("PRINTER_IMAGE")
    if image:
        # A prebuilt image carries the firmware already -- rootfs, /usr/prog,
        # /usr/data, baked by test/integration/build-printer-image.sh.
        return image, True

    if not (ROOT / "work" / "rootfs" / "bin").is_dir():
        raise ReplicaMissing(
            "no replica to test against: PRINTER_IMAGE is unset and there is "
            "no extracted rootfs in work/rootfs.\n"
            "    quickest:  PRINTER_IMAGE=monstrofil/creator5-printer:latest "
            "(or put it in test.env -- see test.env.example)\n"
            "    from the stock package:  make rootfs")

    image = "creator5-printer-sim"
    build_dir = ROOT / "test" / "integration" / "printer"
    # Always rebuild: a cache hit takes about a second, and a stale image
    # silently testing yesterday's harness is not a trade worth making.
    built = subprocess.run(
        [docker, "build", "-q", "-t", image, "-f",
         str(build_dir / "Dockerfile"), str(build_dir)],
        capture_output=True, text=True)
    if built.returncode != 0:
        raise ReplicaMissing("could not build %s:\n%s"
                                 % (image, built.stderr.strip()))
    return image, False


def mod_package(config):
    """The built package under test: work/out/<Model>-<mod>-<ver>.tgz.

    Never built on demand. `make build` unpacks, patches and repacks the stock
    firmware, cross-compiles s6 and CPython and takes minutes; a test fixture
    that silently kicked that off would turn "the suite is slow today" into a
    mystery. Missing means missing, and the message says which command makes
    one.
    """
    out = ROOT / "work" / "out"
    found = [p for p in out.glob("*-*.tgz") if p.is_file()]
    if not found:
        raise ReplicaMissing(
            "no package in work/out, so there is nothing to install and the "
            "replica lane has nothing to test.\n"
            "    build one:  make build\n"
            "This lane deliberately does NOT hand-place a recipe's files into the "
            "machine -- it installs the real package through the printer's "
            "own updater, so that the install is under test too.")
    # Newest by mtime: on a tree that has been built more than once, "the
    # package I just built" is what a developer means, not whichever name
    # happens to sort last.
    return max(found, key=lambda p: p.stat().st_mtime)


def _md5(path):
    digest = hashlib.md5()
    with open(str(path), "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def installed_image(config=None, on_output=None):
    """A replica image that IS a printer with our package installed.

    Baked once per package and cached under a tag derived from its md5, the
    same trick test/integration/build-printer-image.sh uses for the stock
    baseline and for the same reason: the install is the machine's own
    app_startup.sh running under qemu, it takes minutes, and it produces an
    identical result every time.

    Rebuild the package and the md5 changes, so the next run bakes again
    rather than testing yesterday's build -- which is the failure mode a
    hand-rolled "is it stale?" check always eventually gets wrong.
    """
    config = config or Config.load()
    docker = find_docker()
    base, _prebuilt = resolve_image(config, docker)
    pkg = mod_package(config)

    tag = "creator5-printer-anvil:%s" % _md5(pkg)[:12]
    have = subprocess.run([docker, "image", "inspect", tag],
                          capture_output=True)
    if have.returncode == 0:
        return tag

    if on_output:
        on_output("qa: baking %s from %s (%s) -- once per package, then cached"
                  % (tag, base, pkg.name))

    actions = ROOT / "qa" / "replica" / "actions"
    stage = ROOT / "work" / (".qa-bake-%d" % os.getpid())
    if stage.exists():
        shutil.rmtree(str(stage))
    (stage / "pkgs").mkdir(parents=True)
    shutil.copy(str(pkg), str(stage / "pkgs" / pkg.name))

    name = "qa-bake-%d" % os.getpid()
    subprocess.run([docker, "rm", "-f", name], capture_output=True)
    argv = [
        docker, "run", "--privileged", "--name", name,
        "-v", "%s/pkgs:/pkgs:ro" % stage,
        "-v", "%s/bake.sh:/qa-bake.sh:ro" % actions,
        "-v", "%s/install-package.sh:/case.sh:ro" % actions,
        "-e", "FF_KEY=%s" % config.ff_key,
        "-e", "BASE_PKG=",
        "-e", "USB_STICK=1",
        "-e", "PKGS= %s=/pkgs/%s" % (pkg.name, pkg.name),
        "-e", "PROG_DUMP=",
        "-e", "PROG_MB=%s" % config.get("PROG_MB"),
        "-e", "DATA_MB=%s" % config.get("DATA_MB"),
        "-e", "SIM_VERBOSE=%s" % os.environ.get("SIM_VERBOSE", "0"),
        "--entrypoint", "/qa-bake.sh", base,
    ]
    try:
        baked = subprocess.run(argv, capture_output=True, text=True,
                               errors="replace")
        if on_output and baked.stdout:
            on_output(baked.stdout)
        if baked.returncode != 0:
            raise ReplicaMissing(
                "could not install the package into a replica -- the mod "
                "cannot be tested because it cannot be installed:\n%s"
                % ((baked.stdout or "") + (baked.stderr or ""))[-4000:])
        committed = subprocess.run(
            [docker, "commit",
             "--change", 'ENTRYPOINT ["/opt/printer/entrypoint.sh"]',
             name, tag],
            capture_output=True, text=True)
        if committed.returncode != 0:
            raise ReplicaMissing("could not commit %s:\n%s"
                                 % (tag, committed.stderr.strip()))
    finally:
        subprocess.run([docker, "rm", "-f", name], capture_output=True)
        shutil.rmtree(str(stage), ignore_errors=True)
    return tag


def start(config=None, base_pkg=None, packages=None, setup_timeout=600,
          image=None):
    """Start a replica and hold it open. Returns a Printer.

    The argv is deliberately the same as test/ffsim/replica.py's, minus --rm
    and plus -d: this must be the SAME machine the old suite tests, or the
    two suites running side by side during the migration prove nothing about
    each other.
    """
    config = config or Config.load()
    packages = packages or {}
    docker = find_docker()
    if image:
        # A caller-supplied image is already a machine (installed_image()'s
        # bake, normally), so it needs no rootfs mount and no baseline: those
        # are baked in, exactly as they are in a prebuilt PRINTER_IMAGE.
        prebuilt = True
    else:
        image, prebuilt = resolve_image(config, docker)

    stage = ROOT / "work" / (".qa-%d" % os.getpid())
    if stage.exists():
        shutil.rmtree(str(stage))
    (stage / "pkgs").mkdir(parents=True)

    hold = ROOT / "qa" / "replica" / "actions" / "hold.sh"
    shutil.copy(str(hold), str(stage / "case.sh"))
    for name, path in packages.items():
        if not os.path.isfile(path):
            raise ReplicaMissing("no package at %s (for %s)" % (path, name))
        shutil.copy(path, str(stage / "pkgs" / name))
    if base_pkg:
        shutil.copy(base_pkg, str(stage / "pkgs" / "base.tgz"))

    argv = [docker, "run", "-d", "--privileged"]
    if not prebuilt:
        argv += ["-v", "%s/work/rootfs:/rootfs:ro" % ROOT]
    argv += [
        "-v", "%s/pkgs:/pkgs:ro" % stage,
        "-v", "%s/case.sh:/case.sh:ro" % stage,
        # THE PRINTER'S FILES, FROM THE RECIPES THAT OWN THEM. This used to
        # be one mount of a top-level payload/ directory. It is three now, and
        # entrypoint.sh reassembles /tmp/payload out of them, because the
        # files a case script reaches for are split across two recipes and two
        # roles: anvil-core's $MODDIR overlay, its anvil.conf template, and
        # Klipper's launcher, which goes to /usr/prog.
        #
        # Reassembled rather than re-pointed on purpose. Every case script
        # copies out of /tmp/payload with `2>/dev/null` -- a path that stops
        # resolving does not fail there, it copies nothing and the case runs
        # green against an empty $MODDIR. Keeping the assembled tree byte-for
        # -byte what it was means none of those copies had to be touched.
        "-v", "%s/pkg/anvil-core/payload:/payload:ro" % ROOT,
        "-v", "%s/pkg/anvil-core/seed:/payload-seed:ro" % ROOT,
        "-v", "%s/pkg/klipper/prog:/payload-klipper:ro" % ROOT,
        "-e", "FF_KEY=%s" % config.ff_key,
        "-e", "BASE_PKG=%s" % ("/pkgs/base.tgz" if base_pkg else ""),
        "-e", "PKGS=%s" % "".join(" %s=/pkgs/%s" % (n, n) for n in packages),
    ]

    # A real /usr/prog taken off a printer. Only for a locally built replica:
    # a prebuilt image already has one baked in, and mounting over it would
    # replace the genuine tree with an older copy.
    prog_dump = config.get("PROG_DUMP")
    if not prebuilt and prog_dump and os.path.exists(prog_dump):
        argv += ["-e", "PROG_DUMP=/progdump",
                 "-v", "%s:/progdump:ro" % os.path.abspath(prog_dump)]
    else:
        argv += ["-e", "PROG_DUMP="]

    argv += [
        "-e", "PROG_MB=%s" % config.get("PROG_MB"),
        "-e", "DATA_MB=%s" % config.get("DATA_MB"),
        "-e", "SIM_VERBOSE=%s" % os.environ.get("SIM_VERBOSE", "0"),
        "-e", "USB_STICK=0",
        image, "/case.sh",
    ]

    started = subprocess.run(argv, capture_output=True, text=True)
    if started.returncode != 0:
        shutil.rmtree(str(stage), ignore_errors=True)
        raise ReplicaMissing("docker run failed:\n%s"
                                 % started.stderr.strip())
    container = started.stdout.strip()

    printer = Printer(container, docker, config)
    printer._stage = stage
    try:
        _await_ready(printer, setup_timeout)
    except Exception:
        stop(printer)
        raise
    return printer


def _await_ready(printer, limit):
    """Wait for hold.sh's marker, which means entrypoint.sh finished.

    Polled rather than slept, because setup is anywhere from under a second
    (a prebuilt PRINTER_IMAGE) to over a minute (unpacking the factory image
    and installing the stock baseline under qemu). A constant would either
    waste the fast case or fail the slow one.
    """
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        alive = subprocess.run(
            [printer.docker, "inspect", "-f", "{{.State.Running}}",
             printer.container],
            capture_output=True, text=True)
        if alive.stdout.strip() != "true":
            raise ReplicaMissing(
                "the replica exited during setup:\n%s" % logs(printer)[-4000:])
        probe = subprocess.run(
            [printer.docker, "exec", printer.container,
             "test", "-f", CHROOT + READY_MARKER],
            capture_output=True)
        if probe.returncode == 0:
            return
        time.sleep(0.5)
    raise ReplicaMissing(
        "the replica did not finish setup within %ss:\n%s"
        % (limit, logs(printer)[-4000:]))


def logs(printer):
    got = subprocess.run([printer.docker, "logs", printer.container],
                         capture_output=True, text=True, errors="replace")
    return (got.stdout or "") + (got.stderr or "")


def stop(printer):
    subprocess.run([printer.docker, "rm", "-f", printer.container],
                   capture_output=True)
    stage = getattr(printer, "_stage", None)
    if stage:
        # The staged packages are ~80MB each.
        shutil.rmtree(str(stage), ignore_errors=True)
