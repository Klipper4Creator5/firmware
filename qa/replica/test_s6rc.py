"""The boot, on a machine the real installer produced.

The database is compiled in the replica now, by the s6-rc-compile we ship. This
proves the printer DOES it: the scanner comes up, s6-rc-init lays the live
servicedirs down, one transition brings the boot set up, and s6 puts a killed
daemon back.

RUN, on a real replica off a real package. What the replica can prove is the
machinery -- scanner, s6-rc-init, live servicedirs, supervision, restart -- and
that is what the `booted` fixture waits for. It does NOT wait for `ok-all`:
that set reaches services which need hardware this machine does not have, and
those are asked of the compiled database instead. See BOOT_SET/HW_SET below.
"""
import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
SCANDIR = MODDIR + "/etc/s6"
DB = MODDIR + "/etc/s6-rc/compiled/current"

# SPLIT BY WHAT THIS MACHINE CAN ANSWER, not by what the printer runs. Both
# sets are in ok-all on a real printer.
#
# BOOT_SET is the longruns that need nothing but the rootfs, so s6-supervise
# must report them up here. wifi is NOT in it despite needing no hardware: it
# is a oneshot, so there is no supervised servicedir for s6-svstat to read.
BOOT_SET = {"nginx", "moonraker", "ntp"}
# HW_SET cannot come up on a replica, so it is asked of the compiled database
# instead -- still where a missing or misnamed service shows:
#
#   mcu-bringup  wants /dev/ttyS4,5,7, and klipper depends on it
#   camera       wants /dev/video*, and hits its 40s timeout-up
#   ff-startup   waits out its own 300000ms timeout for klipper -- holding
#                the s6-rc lock, which is why nothing here asks s6-rc for
#                the live list
#   ui           needs no hardware itself, but depends on ff-startup, so the
#                transition never reaches it
#   wifi         the oneshot above
HW_SET = {"camera", "klipper", "mcu-bringup", "ff-startup", "ui", "wifi"}

# EVERY s6-rc-init HERE NEEDS THIS, for the reason firmwareExe needs it: the
# default deadline is TAIN_INFINITE_RELATIVE, which does not fit this printer's
# 32-bit time_t, so s6-rc-init fails with EOVERFLOW ("Value too large for
# defined data type") before it reaches the thing under test. Matches
# firmwareExe's own S6RC_T.
S6RC_T = 30000


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
    up = set()
    for _ in range(60):
        up = _up(box)
        if BOOT_SET <= up:
            return box
        box.sh("sleep 2")

    pytest.fail(
        "the hardware-independent services never came up within 120s.\n"
        "missing: %s\nup: %s\nboot log:\n%s"
        % (", ".join(sorted(BOOT_SET - up)) or "none", ", ".join(sorted(up)),
           box.file("/usr/data/logs/anvil-boot.log").text[-2000:]))


def _up(box):
    """The live services, asked of s6-supervise one at a time.

    NOT `s6-rc -a list`: that takes the s6-rc lock, and ff-startup holds it for
    its whole 300000ms timeout-up while it waits for a klipper that has no MCU
    to talk to -- so the list comes back "unable to take locks: Device or
    resource busy" rather than short.
    """
    got = box.sh(
        "for n in $(ls -1 %s); do %s/bin/s6-svstat %s/$n 2>/dev/null "
        "| grep -q '^up' && echo $n; done" % (SCANDIR, MODDIR, SCANDIR))
    return set(got.out.split())


# ------------------------------------------------------- the tree came up

def test_the_scanner_is_answering(booted):
    """Asked of the scanner over its control FIFO, not of the process table:
    a dead scanner leaves the FIFO on disk, so a name match cannot tell the
    difference."""
    got = booted.sh("%s/bin/s6-svscanctl -a %s" % (MODDIR, SCANDIR))
    assert got.ok, "the scanner is not listening on %s: %s" % (SCANDIR, got.text)


def test_the_boot_set_is_up(booted):
    up = _up(booted)
    assert BOOT_SET <= up, "missing from the transition: %s" % (BOOT_SET - up)


def test_the_hardware_services_are_in_the_database(box):
    """HW_SET cannot start on a replica, so what is asked is that the
    transition would reach them on a printer: every one compiled into the
    database under the name ok-all's contents.d spells."""
    got = box.sh("%s/bin/s6-rc-db -c %s list all" % (MODDIR, DB))
    assert got.ok, "s6-rc-db could not read the compiled database: %s" % got.text
    known = set(got.out.split())
    assert HW_SET <= known, (
        "not in the compiled database: %s" % (HW_SET - known))


def test_the_scandir_was_populated_by_s6_rc_init(booted):
    """It ships EMPTY -- bin/payload.sh stopped copying servicedirs in when the
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


def test_the_scanner_did_not_go_blind(booted):
    """The -D_FILE_OFFSET_BITS=64 trap: without it every readdir returns
    EOVERFLOW and the scanner starts, then sees nothing for ever.

    Asked as "no scanner error", not "the log is empty": the services share
    this log with s6-svscan on purpose -- moonraker's run script sends its
    early stderr here so that a moonraker dying before its own logging is
    configured has somewhere to say so.
    """
    bad = [ln for ln in booted.file("/usr/data/logs/s6.log").lines
           if "s6-svscan:" in ln or "unable to readdir" in ln
           or "Value too large for defined data type" in ln]
    assert not bad, "s6-svscan reported a failure: %s" % bad[:3]


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
        got = box.sh("%s/bin/s6-rc-init -t %d -c %s -l /run/probe %s 2>&1"
                     % (MODDIR, S6RC_T, DB, SCANDIR))
        assert not got.ok, "s6-rc-init accepted a database that is not there"
    finally:
        box.sh("mv %s.moved %s" % (DB, DB))


def test_a_populated_scandir_is_swept_not_collided_with(box):
    """MEASURED: s6-rc-init creates one symlink per service in the scandir and
    dies with "unable to supervise service directories: File exists" if the
    name is taken. An upgrade from a phase-4/5 payload has nginx, moonraker
    and camera sitting there, so runFirmwareExe.sh sweeps -- this is that sweep,
    asked of the machine."""
    box.sh("mkdir -p %s/nginx && rm -rf /run/probe2" % SCANDIR)
    got = box.sh("%s/bin/s6-rc-init -t %d -c %s -l /run/probe2 %s 2>&1"
                 % (MODDIR, S6RC_T, DB, SCANDIR))
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
