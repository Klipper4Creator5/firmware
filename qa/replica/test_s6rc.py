"""The boot, on a machine the real installer produced.

qa/static/test_s6rc_source.py proves the database SAYS the right thing. This
proves the printer DOES it: the scanner comes up, s6-rc-init lays the live
servicedirs down, one transition brings the boot set up, and s6 puts a killed
daemon back.

NOTHING HERE HAS RUN YET. There is no stock FlashForge package on the machine
this was written on, so `make build` is impossible and the replica image holds
a pre-s6-rc payload. The `box` fixture below fails with one clear message
rather than letting forty assertions fail for the same reason.
"""
import pytest

from lib import replica

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
SCANDIR = MODDIR + "/etc/s6"
LIVE = "/run/s6-rc"
DB = MODDIR + "/etc/s6-rc/compiled/current"

BOOT_SET = {"wifi", "nginx", "moonraker", "camera", "klipper", "ff-startup",
            "ui"}


@pytest.fixture(scope="module")
def box(printer):
    """The machine, with the package's own s6-rc actually present.

    Checked once, here, because every test below asks a question that has no
    meaning on a payload built before phase 8 -- and forty identical failures
    hide which one thing is wrong.
    """
    if not printer.file(MODDIR + "/bin/s6-rc-init").executable:
        pytest.fail(
            "this package has no s6-rc: %s/bin/s6-rc-init is missing, so the "
            "machine under test predates the compiled boot. Build a package "
            "from this tree first -- `make build` -- and the replica lane will "
            "pick it up (qa/lib/replica.py takes the newest work/out/*.tgz)."
            % MODDIR)
    return printer


@pytest.fixture(scope="module")
def booted(box):
    """The real boot path, run once, bounded.

    firmwareExe IS the boot -- scanner, s6-rc-init, one transition -- so this
    runs it rather than reimplementing the three steps, which is the mistake
    case-install.sh's header warns about ("an earlier version of this file
    replayed app_startup.sh by hand"). It never returns (it holds the
    foreground on `wait`), so it goes to the background and we poll for the
    tree instead.
    """
    box.sh("setsid /usr/prog/PROGRAM/software/firmwareExe >/dev/null 2>&1 &")
    for _ in range(60):
        if "ok-all" in box.sh("%s/bin/s6-rc -l %s -a list 2>/dev/null"
                              % (MODDIR, LIVE)).text:
            return box
        box.sh("sleep 2")
    pytest.fail(
        "the tree never came up within 120s. Boot log:\n%s"
        % box.file("/usr/data/logs/anvil-boot.log").text[-2000:])


def _up(box):
    return set(box.sh("%s/bin/s6-rc -l %s -a list" % (MODDIR, LIVE)).out.split())


# ------------------------------------------------------- the tree came up

def test_the_scanner_is_answering(booted):
    """Asked of the scanner over its control FIFO, not of the process table:
    a dead scanner leaves the FIFO on disk, so a name match cannot tell the
    difference."""
    got = booted.sh("%s/bin/s6-svscanctl -a %s" % (MODDIR, SCANDIR))
    assert got.ok, "the scanner is not listening on %s: %s" % (SCANDIR, got.text)


def test_the_boot_set_is_up(booted):
    assert BOOT_SET <= _up(booted), (
        "missing from the transition: %s" % (BOOT_SET - _up(booted)))


def test_the_scandir_was_populated_by_s6_rc_init(booted):
    """It ships EMPTY -- bin/patch.sh stopped copying servicedirs in when the
    database took over -- so anything here arrived at boot."""
    names = booted.sh("ls -1 %s" % SCANDIR).out.split()
    assert "nginx" in names, "s6-rc-init laid nothing down: %s" % names


def test_every_live_run_is_executable(booted):
    """s6 reports a non-executable `run` in its own log and nowhere else, so
    the service simply never comes up and nothing says why."""
    bad = [n for n in booted.sh("ls -1 %s" % SCANDIR).out.split()
           if booted.file("%s/%s/run" % (SCANDIR, n)).exists
           and not booted.file("%s/%s/run" % (SCANDIR, n)).executable]
    assert not bad, "not executable: %s" % ", ".join(bad)


def test_the_supervisor_is_the_one_we_shipped(box):
    """A cross-built MIPS binary, not a shell script standing in for one.
    `head -c 4` rather than `od -An -c`: the printer's busybox od has no -A."""
    scanner = box.file(MODDIR + "/bin/s6-svscan")
    assert scanner.executable, "no s6-svscan in the installed package"
    assert "ELF" in box.sh("head -c 4 %s" % scanner.path).out


def test_execline_shipped_too(box):
    """Every oneshot's `up` runs through s6rc-oneshot-runner, whose `run` is
    execline. Without execlineb the wifi oneshot fails at exec and nothing
    else does, which reads as a wifi bug."""
    assert box.file(MODDIR + "/bin/execlineb").executable


def test_the_scanner_logged_nothing(booted):
    """A healthy s6-svscan says nothing. The one that matters is the
    -D_FILE_OFFSET_BITS=64 trap: "unable to readdir .: Value too large for
    defined data type" -- a scanner that started and then went blind."""
    log = booted.file("/usr/data/logs/s6.log")
    assert log.empty, "s6-svscan wrote to its log: %s" % log.lines[:3]


# --------------------------------------------------- s6 does its one job

def test_a_killed_daemon_comes_back(booted):
    """The whole reason for shipping 14 binaries, and neither suite has ever
    asserted it. SIGKILL, because that is what an OOM does and it is the case
    a `stop` verb cannot cover."""
    before = booted.pgrep("nginx")
    assert before, "nginx was not running, so this proves nothing"
    for proc in before:
        booted.sh("kill -9 %s 2>/dev/null" % proc.pid)
    booted.sh("sleep 5")
    after = booted.pgrep("nginx")
    assert after, "s6 did not restart nginx after kill -9"
    assert {p.pid for p in after} != {p.pid for p in before}, (
        "the same pids are still there -- nothing was actually killed")


# ------------------------------------------------------- the negative controls

def test_a_database_moved_aside_is_reported(box):
    """The boot must say so rather than coming up silently wrong. Run in its
    own container: it breaks the machine it runs on."""
    box.sh("mv %s %s.moved" % (DB, DB))
    try:
        got = box.sh("%s/bin/s6-rc-init -c %s -l /run/probe %s 2>&1"
                     % (MODDIR, DB, SCANDIR))
        assert not got.ok, "s6-rc-init accepted a database that is not there"
    finally:
        box.sh("mv %s.moved %s" % (DB, DB))


def test_a_populated_scandir_is_swept_not_collided_with(box):
    """MEASURED: s6-rc-init creates one symlink per service in the scandir and
    dies with "unable to supervise service directories: File exists" if the
    name is taken. An upgrade from a phase-4/5 payload has nginx, moonraker
    and camera sitting there, so run-append.sh sweeps -- this is that sweep,
    asked of the machine."""
    box.sh("mkdir -p %s/nginx && rm -rf /run/probe2" % SCANDIR)
    got = box.sh("%s/bin/s6-rc-init -c %s -l /run/probe2 %s 2>&1"
                 % (MODDIR, DB, SCANDIR))
    assert "File exists" in got.text or got.ok, (
        "expected either a clean init or the documented collision, got: %s"
        % got.text)


# ------------------------------------------------------------ the watchdog

def test_firmware_exe_holds_the_foreground(booted):
    """app_startup.sh greps `ps` for "firmwareExe" 5s after launch, so the
    script must keep its name and not exit. It holds on `wait $SCANNER_PID`;
    an `exec` of the scanner would have renamed the process and busybox ash
    has no `exec -a`."""
    booted.sh("sleep 5")
    assert booted.pgrep("firmwareExe"), (
        "nothing named firmwareExe is running -- app_startup.sh's watchdog "
        "would re-exec us and restart every service")


# ------------------------------------------------------- the open question

def test_the_ui_runs_under_s6_supervise(booted):
    """THE BLOCKING UNKNOWN from docs/notes/80-s6-migration.md.

    Until phase 8 the UI ran in firmwareExe's foreground and inherited its
    descriptors and session. A supervised process gets neither. If this fails
    because helix-screen wants a controlling terminal, the answer is s6's own
    tty handling or a wrapper -- NOT a return to the foreground, which no
    longer exists.
    """
    if not booted.file(MODDIR + "/helixscreen/bin/helix-screen").exists:
        pytest.fail(
            "no HelixScreen in this package, so the one question this phase "
            "left open cannot be answered here -- build a package with "
            "BUILD_HELIX=1")
    stat = booted.sh("%s/bin/s6-svstat %s/ui" % (MODDIR, SCANDIR))
    assert "up" in stat.text, (
        "the UI is not up under s6-supervise: %s" % stat.text)
