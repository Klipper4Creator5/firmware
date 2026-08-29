"""Do our init.d services all behave like the same kind of thing?

Ported from test/integration/printer/case-services.sh. Same machine, same
assertions, same reasoning -- the header below is the original's, because the
reasons have not changed. What changes is that its ~30 checks were one exit
code and are now 43 named tests.

WHY THIS EXISTS -- the seven services used to be seven one-off scripts. Each
had grown its own way of asking "is it running" (a pidfile and kill -0, a
`ps | grep`, a `pgrep -f` with a ps fallback, a socket test), its own spelling
of the log lines, and its own `case "$1"` block with subtly different verbs and
exit codes. Two real bugs lived in that drift: a stop that returned before the
process was gone, so the restart that followed saw it still in the process
table and declined to start anything; and a status that read a socket klippy
does not unlink on exit, so a dead klippy reported itself running and `restart`
did nothing at all.

anvil-service.sh exists to make those one decision each instead of seven. This
file is what stops them drifting apart again. It is deliberately NOT a grep
over the scripts -- that would pass on a service that cannot start anything and
fail on a rename. It RUNS every service, on the printer's own busybox, and
asserts on what came back.

What it does NOT do is start real daemons: that is case-moonraker.sh's job for
the web stack, and wifi/camera/klipper need hardware the replica has none of.
What is checked here is the contract every service shares -- it loads its
library, it answers `status` without blowing up, it names itself in what it
prints, and it rejects a verb it does not know with a usage line and exit 1.

WHAT THE PORT CHANGED

Two things.

THE MACHINE. The original installs the payload itself, with a `cp -f` of
payload/*.sh and payload/init.d/S* into $MODDIR. Here the `printer` fixture is
a machine that had the real package installed by its own app_startup.sh, off a
real FAT stick. So the install is under test rather than re-implemented, and
the services being run are the ones the installer placed -- including the
cross-built s6, which is a build output that no amount of copying from
payload/ can produce. The stand-in scanner the original needs, and the
skip-or-not branching around it, are gone with the copying. See
qa/replica/conftest.py.

THE STOPWATCH. The original bounds the init sequence with a background
subshell, a marker file and a `while [ ! -f ... ]` counter, because a test that
hangs is a test that reports nothing. That is a real constraint and the
implementation was sound, but a timeout is something the host can simply have:
Printer.sh takes one, and a command that does not come back is a Result whose
`timed_out` is True. The negative control is kept -- see TestInitSequence --
because a stopwatch that cannot catch a hang would let the real check pass no
matter what S40s6 did, and that is as true of this one as of the original.
"""
import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
SERVICES = ["S40s6", "S50wifi", "S60nginx", "S62moonraker",
            "S65camera", "S70klipper", "S80ui"]

# What each service must call itself. Every line a service prints is
# "name: something": it is what makes a boot log readable when seven services
# are interleaving their output -- and the services background their slow work
# precisely so that they DO interleave.
PREFIX = {"S40s6": "s6", "S50wifi": "wifi", "S60nginx": "nginx",
          "S62moonraker": "moonraker", "S65camera": "camera",
          "S70klipper": "klipper", "S80ui": "ui"}


# --------------------------------------------------------------- the fixtures
#
# There is no payload-install fixture and no supervisor-staging fixture. The
# `printer` fixture (qa/replica/conftest.py) is already a machine that had the
# real package installed by its own app_startup.sh, so the payload is where the
# installer put it and s6 is the cross-built one the package ships. Nothing
# here stands in a scanner: hand-placing payload/ cannot deliver a binary that
# only exists as a build output.


@pytest.fixture(scope="module")
def box(printer):
    """The installed machine. Named for brevity; it is just `printer`."""
    return printer


# ------------------------------------------------------------- the foundation

def test_payload_ships_anvil_service_sh(box):
    """The library is sourced, never executed, so it is packaged with
    a plain cp and no chmod +x. It once did not stage it at all, which would
    have made every service abort at boot -- hence checking for it by itself,
    before anything tries to use it."""
    assert box.file("%s/anvil-service.sh" % MODDIR).exists, (
        "the payload ships no anvil-service.sh -- every service aborts")


# ----------------------------------------------------------- the shared contract

@pytest.mark.parametrize("name", SERVICES)
class TestServiceContract:
    """The four properties every service shares, asked of each of the seven.

    Parametrized over the class so a failure names both the service and the
    property: `test_status_answers[S62moonraker]` is a complete bug report in
    its own identifier, which is the thing 360 lines reporting one exit code
    could never do.
    """

    def test_is_installed_and_executable(self, box, name):
        assert box.svc(name, MODDIR + "/init.d").installed, (
            "%s is missing or not executable" % name)

    def test_status_answers(self, box, name):
        """A service must always answer. An empty status is the failure mode
        that matters: it means the dispatcher fell through, and a boot script
        that prints nothing is one nobody can debug from a log."""
        got = box.svc(name, MODDIR + "/init.d").status()
        assert "no /usr/data/anvil/anvil-service.sh" not in got.text, (
            "%s cannot find its library at runtime" % name)
        assert got.text.strip(), (
            "%s status printed nothing (rc=%d) -- a service must always answer"
            % (name, got.code))

    def test_names_itself(self, box, name):
        got = box.svc(name, MODDIR + "/init.d").status()
        assert got.first_line.startswith(PREFIX[name]), (
            "%s output is unprefixed: %r" % (name, got.first_line))

    def test_unknown_verb_is_usage_and_exit_1(self, box, name):
        """One dispatcher means one answer to a verb nobody implements.
        Getting this wrong is how a typo in a boot script becomes a silent
        no-op."""
        got = box.svc(name, MODDIR + "/init.d")("bogusverb")
        assert got.code == 1, (
            "%s: unknown verb gave rc=%d, output: %s"
            % (name, got.code, got.text))
        assert "usage:" in got.text, (
            "%s: unknown verb printed no usage line: %s" % (name, got.text))


def test_klipper_advertises_force_start(box):
    """S70klipper is the one service with a verb of its own.

    force-start exists because start() normally stands aside for
    bin/ff-startup.py, and the firmwareExe wrapper needs a way to say "no,
    actually start it" when that program returned and left no klippy behind.
    If the shared dispatcher ever swallows it, the printer loses its
    last-resort path to a running Klipper.
    """
    got = box.svc("S70klipper", MODDIR + "/init.d")("bogusverb")
    assert "force-start" in got.text, (
        "S70klipper lost force-start from its usage line: %s" % got.text)


# ------------------------------------------------- the boot it must not hang

def _run_init_sequence(box, directory, limit):
    """Run a directory of S* scripts the way firmwareExe runs them.

    One at a time, in the foreground, in filename order -- and bounded, because
    a test that hangs is a test that reports nothing.

    The bound lives on Printer.sh (a host-side timeout on the docker exec)
    rather than in a background subshell with a marker file. Same guarantee,
    and the verdict arrives as `result.timed_out` instead of as the absence of
    a file.
    """
    return box.sh(
        'for service in %s/S*; do\n'
        '    [ -x "$service" ] || continue\n'
        '    echo "--- `basename $service` ---"\n'
        '    "$service" start || echo "`basename $service`: returned $?"\n'
        'done\n' % directory,
        timeout=limit)


@pytest.fixture(scope="module")
def booted(box):
    """The init sequence, run once, with its result kept.

    A fixture rather than a step inside the first test, so that every
    assertion about the state afterwards DEPENDS on it having happened rather
    than on having been written below it in the file. Run a post-boot test on
    its own -- `pytest -k test_scandir_exists` -- and the sequence still runs
    first. Without this the test would pass on a machine where nothing had
    ever started, which is the vacuous green this suite exists to refuse.
    """
    return _run_init_sequence(box, MODDIR + "/init.d", 90)


class TestInitSequence:
    """S40s6 starts s6-svscan, and s6-svscan NEVER RETURNS -- that is its job.

    firmwareExe runs $MODDIR/init.d/S* one at a time IN THE FOREGROUND, so a
    start() that runs the scanner inline does not slow the boot down, it ends
    it: no wifi, no ssh, no Mainsail, no Klipper, no screen, for ever, on every
    boot, with no way in to find out why.
    """

    def test_negative_control_a_foreground_scanner_hangs(self, box):
        """THE NEGATIVE CONTROL, and it runs first on purpose.

        A stopwatch that cannot catch a hang would let the real check below
        pass no matter what S40s6 did. So here is the naive implementation
        somebody would write -- the scanner in the foreground, which is what
        you get by deleting the svc_detach from S40s6 -- run through the SAME
        harness. It has to time out.

        Its own scandir, because the real s6 takes a lock on the one it is
        scanning and a second instance EXITS rather than hangs, which would
        make this control pass for entirely the wrong reason.
        """
        box.sh("mkdir -p /tmp/naive-init.d %s/etc/s6-negctl" % MODDIR)
        box.write("/tmp/naive-init.d/S41hang",
                  "#!/bin/sh\nexec %s/bin/s6-svscan %s/etc/s6-negctl\n"
                  % (MODDIR, MODDIR), mode="+x")
        try:
            got = _run_init_sequence(box, "/tmp/naive-init.d", 15)
            assert got.timed_out, (
                "an init script that runs the scanner inline RETURNED -- "
                "the stopwatch proves nothing, so the real check below is "
                "meaningless")
        finally:
            # It is still sitting there holding the foreground; take it down
            # before the real sequence runs, or the process-table checks later
            # count it.
            box.sh("%s/bin/s6-svscanctl -t %s/etc/s6-negctl 2>/dev/null; "
                   "sleep 2" % (MODDIR, MODDIR))
            for proc in box.pgrep("s6-negctl"):
                box.sh("kill -9 %s 2>/dev/null" % proc.pid)
            box.sh("rm -rf /tmp/naive-init.d %s/etc/s6-negctl" % MODDIR)

    def test_the_real_sequence_returns(self, booted):
        """Every service the payload ships, run the way firmwareExe runs them.

        90 seconds is generous -- the whole point of svc_detach is that these
        return in well under a second each -- and generous is right for a
        bound whose only job is to turn a hang into a failure.
        """
        assert not booted.timed_out, (
            "the init sequence did NOT return -- the boot would never reach "
            "klipper or the UI\n%s" % booted.text)

    def test_scanner_is_running_afterwards(self, box, booted):
        """Asked of the scanner itself, not of `ps`.

        svc_s6_running pings the control FIFO, which a dead scanner leaves
        behind on disk, so this distinguishes "running" from "the socket is
        still lying there" the way a name match cannot.
        """
        got = box.svc("S40s6", MODDIR + "/init.d").status()
        assert "scanning %s/etc/s6" % MODDIR in got.text, (
            "the scanner is not running after the init sequence: %s"
            % got.text)

    def test_scandir_exists(self, box, booted):
        """It ships empty from bin/patch.sh and is mkdir -p'd again at
        runtime, so what is checked here is the runtime mkdir."""
        assert box.file("%s/etc/s6" % MODDIR).is_dir

    def test_scanner_survives(self, box, booted):
        """AN EMPTY SCANDIR IS NOT AN ERROR.

        The scanner is alive and supervising possibly nothing, and it has to
        be content with that -- if it exited, or complained, every boot would
        carry a scary log line and the first service to move in would be
        debugged against a scanner that was already unhappy.
        """
        box.sh("sleep 3")
        got = box.svc("S40s6", MODDIR + "/init.d").status()
        assert "scanning" in got.text, "the scanner exited"

    def test_the_supervisor_is_the_one_we_shipped(self, box):
        """The scanner under test is the package's own cross-built s6.

        Cheap, and it is what makes the next test mean anything. When this
        file hand-placed payload/ it could not deliver s6 at all -- s6 is a
        build output, not a repo file -- so it carried a stand-in scanner and
        gated the log check on whether the stand-in was in use. Installing the
        real package removed both. This assertion is what stops that quietly
        coming back: a machine whose s6-svscan is a shell script is one where
        everything below is testing a mock again.
        """
        scanner = box.file("%s/bin/s6-svscan" % MODDIR)
        assert scanner.executable, (
            "no s6-svscan in the installed package -- anvil-s6 ships it "
            "from work/.s6, so this package was built without it")
        # A cross-built MIPS binary, not a shell script. The first four bytes
        # of an ELF are \x7fELF; Printer.sh decodes with errors="replace", so
        # the \x7f arrives as a replacement character and "ELF" survives
        # intact. Deliberately NOT `od -An -c`: the printer's busybox od has
        # no -A ("invalid option -- 'A'"), which is exactly the class of
        # difference this whole replica exists to surface -- the host's
        # coreutils and the printer's busybox are not the same tools.
        magic = box.sh("head -c 4 %s" % scanner.path)
        assert "ELF" in magic.out, (
            "%s is not an ELF binary -- it looks like a script, which means "
            "something is standing in for the supervisor: %r"
            % (scanner.path, magic.out[:40]))

    def test_scanner_logged_nothing(self, box, booted):
        """A healthy s6-svscan says nothing at all.

        Anything in its log is a fault, and the one that matters is the
        -D_FILE_OFFSET_BITS=64 trap from tools/supervisor/README.md: "unable
        to readdir .: Value too large for defined data type", which is a
        scanner that started and then went blind.
        """
        log = box.file("/usr/data/logs/s6.log")
        assert log.empty, "s6-svscan wrote to its log: %s" % log.lines[:3]


# ------------------------------------------------ the service directories

def _service_dirs(box):
    got = box.sh("ls -1 %s/etc/s6 2>/dev/null" % MODDIR)
    return [n for n in got.out.split()
            if box.file("%s/etc/s6/%s" % (MODDIR, n)).is_dir]


class TestServiceDirs:
    """Every service directory the payload ships has to be startable BY s6
    and has to start DOWN."""

    def test_some_were_staged(self, box, booted):
        assert _service_dirs(box), (
            "no service directories in %s/etc/s6 -- nothing was staged"
            % MODDIR)

    def test_each_ships_an_executable_run(self, box, booted):
        """The executable bit is the one that goes wrong quietly: s6 reports a
        non-executable `run` in its own log and nowhere else, so the service
        simply never comes up and nothing says why."""
        missing = [n for n in _service_dirs(box)
                   if not box.file("%s/etc/s6/%s/run" % (MODDIR, n)).executable]
        assert not missing, (
            "no executable run (s6 would report that only in its own log): %s"
            % ", ".join(missing))

    def test_each_ships_down(self, box, booted):
        """`down` is what keeps the gate in anvil.conf meaningful -- without
        it the scanner starts the service the instant it appears, before any
        script has read MOD_WEB or MOD_CAM, so "disabled" would mean "runs for
        a moment on every boot"."""
        missing = [n for n in _service_dirs(box)
                   if not box.file("%s/etc/s6/%s/down" % (MODDIR, n)).exists]
        assert not missing, (
            "no 'down' file, so these would start regardless of their MOD_* "
            "gate: %s" % ", ".join(missing))


# ------------------------------------------------------- the supervisor's life

@pytest.fixture(scope="module")
def stopped(box, booted):
    """A scanner that WAS running and has been stopped.

    The precondition is asserted, not assumed, and that is the whole reason
    this is a fixture. "stop left no s6 processes behind" and "the pidfile is
    gone" are both trivially true of a machine where nothing ever started, so
    written as bare tests in definition order they would pass for the wrong
    reason the moment anyone ran one on its own with -k. Here the fixture
    fails loudly instead: there was nothing to stop, so the questions below
    have no meaning.
    """
    before = box.svc("S40s6", MODDIR + "/init.d").status()
    assert "scanning" in before.text, (
        "nothing was running to stop, so the assertions that depend on this "
        "would pass vacuously: %s" % before.text)
    box.svc("S40s6", MODDIR + "/init.d").stop()
    box.sh("sleep 2")
    return box


class TestSupervisorLifecycle:
    """Four questions about one lifecycle. `stopped` is what orders them --
    the second-start test runs against a live scanner, and the three after it
    depend on a stop that provably had something to stop."""

    def test_a_second_start_is_a_no_op(self, box, booted):
        """What a hand-run `S40s6 start` over ssh does, and what firmwareExe's
        last-resort re-check does if it misreads the status.

        It must be a no-op with exit 0, not a second scanner: the real
        s6-svscan takes a lock on the scandir and the second instance dies,
        leaving a pidfile pointing at a corpse and `status` answering for the
        wrong process.
        """
        got = box.svc("S40s6", MODDIR + "/init.d").start()
        assert got.ok and "already" in got.text, (
            "a second start did not say already-running (rc=%d): %s"
            % (got.code, got.text))

    def test_stop_leaves_no_processes_behind(self, stopped):
        """The scanner is the process that would otherwise put everything
        back, so a stop that kills the services and not the scanner is not a
        stop at all -- the same mistake as killing mjpg_streamer without
        S65camera's respawn loop. Asked of the process table, which is the
        only thing that can answer it.
        """
        left = [p for p in stopped.ps()
                if "s6-svscan" in p.cmdline or "s6-supervise" in p.cmdline]
        assert not left, (
            "s6 processes survived stop: %s"
            % "; ".join(p.cmdline for p in left))

    def test_status_reports_the_stopped_scanner(self, stopped):
        got = stopped.svc("S40s6", MODDIR + "/init.d").status()
        assert "not running" in got.text, (
            "status still claims a scanner after stop: %s" % got.first_line)

    def test_stop_removed_the_pidfile(self, stopped):
        """So the next status cannot be answered by a pid the kernel has since
        handed to something else -- the stale-pidfile bug this whole library
        has two comments about."""
        assert not stopped.file("%s/s6-svscan.pid" % MODDIR).exists, (
            "stop left %s/s6-svscan.pid behind" % MODDIR)
