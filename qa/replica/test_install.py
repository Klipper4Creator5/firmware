"""What the machine's own installer produced, asked of the machine it produced.

The port of `case-install.sh` (579 lines, one bit) -- the gate that decides
whether a package bricks a printer.

WHY THIS MODULE LOOKS SO DIFFERENT FROM THE CASE SCRIPT. Most of that file was
DRIVING the install: attach the stick, run app_startup.sh, wait for it to
settle, do it twice more. None of that is here, because the `printer` fixture
already IS the result -- the package installed by `/usr/prog/app_startup.sh`,
verbatim, off a genuine FAT filesystem on `/dev/sda1`, exactly as a user
installs it from a USB stick (see qa/replica/conftest.py). What is left is the
part that was always the point: the assertions.

That is also why nothing here replays the install by hand. The case script's
own header records that lesson being learned once already:

    An earlier version of this file replayed app_startup.sh by hand -- which
    meant a bug in our reading of it could never be caught.

THREE OF THE CASE'S ASSERTIONS WERE STALE AND ARE NOT REPRODUCED. They are why
the gate was red, and each is replaced by the question that means the same
thing today:

  * `grep helix firmwareExe` -- the wrapper used to exec HelixScreen itself.
    It does not: it starts s6 and the UI is the `ui` service. Replaced by
    test_the_wrapper_starts_the_supervisor and
    test_the_ui_is_a_service_in_the_compiled_database.
  * `[ -d $MODDIR/init.d ]`, else "no service dir exists to start Klipper" --
    there is no init.d. Replaced by test_klipper_is_a_service_in_the_database.
  * grepping the boot log for `S60nginx S62moonraker S70klipper S80ui`.
    NOT replaced by grepping it for the new names. That log line reads
    `s6-rc: bringing up: camera klipper moonraker nginx ui ff-startup wifi`
    and names every service in the boot set INCLUDING THE ONES THAT THEN FAIL,
    so grepping it would pass on a machine where klipper never started -- a
    green assertion that cannot go red. The database is asked instead, which
    is a fact about what was installed rather than an intention.

WHAT A REPLICA CANNOT ANSWER, so it is not asked here:

  * boot 2, the re-install: the bake deletes `/stick.img` once the install has
    landed, so there is no stick to install from a second time. The property
    that matters -- an update keeps what the user edited and drops only what
    the last package shipped -- is asserted directly in test_upgrade.py, which
    drives runFirmwareExe.sh over two payloads.
  * boot 3's UI liveness: `ok-all` is unreachable on a replica (no
    /dev/ttyS4,5,7, no /dev/video*), so "the UI is running and the stock
    watchdog is satisfied" cannot be asked. The static half of it -- that the
    wrapper holds the foreground and keeps its name -- is in test_s6rc.py.
"""
import re

import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
FE = "/usr/prog/PROGRAM/software/firmwareExe"
# The other two stock paths anvil-link-prog.sh owns.
START = "/usr/prog/klipper/start.sh"
DAEMON = "/usr/prog/klipper/klipperDaemon"
APP = "/usr/prog/app_startup.sh"
SOURCE = MODDIR + "/etc/s6-rc/source"
DB = MODDIR + "/etc/s6-rc/compiled/current"
# The klipper s6-rc service execs $FF_PYTHON against $MODDIR/klipper/klippy.
# /usr/prog/klipper/klippy still holds FlashForge's stock tree; nothing reads it.
KLIPPY_DIR = MODDIR + "/klipper/klippy"
INSTALL_LOG = "/usr/data/anvil-install.log"


@pytest.fixture(scope="module")
def box(printer):
    """The installed machine, checked once for the one thing that would make
    every assertion below meaningless."""
    if not printer.file(MODDIR).is_dir:
        pytest.fail(
            "there is no %s, so the install did not land. The `printer` "
            "fixture bakes an image by running the machine's own "
            "app_startup.sh over a package from work/out -- `make build` "
            "first." % MODDIR)
    return printer


# ------------------------------------------------- the stock boot chain is stock

def test_app_startup_is_unmodified(box):
    """Replacing firmwareExe owns the whole userspace boot, which is what lets
    app_startup.sh, rcS and the init chain stay stock and never be patched. A
    mod marker in here means that claim has quietly stopped being true."""
    text = box.file(APP).text
    assert text, "no %s -- there is no stock baseline on this machine" % APP
    for marker in ("anvil", "MODDIR", "/usr/data/anvil"):
        assert marker not in text, (
            "%s carries the mod marker %r -- the boot scripts must stay stock"
            % (APP, marker))


def test_app_startup_still_parses(box):
    """Under the printer's own busybox ash, not the host's shell."""
    parsed = box.sh("sh -n %s 2>&1" % APP)
    assert parsed.ok, "BRICK: %s has a syntax error: %s" % (APP, parsed.text)


def test_app_startup_still_loads_the_kernel_modules(box):
    """The insmod lines are what bring up wifi and the touch panel. An
    installer that trimmed them would leave a printer with no screen."""
    assert "insmod" in box.file(APP).text, (
        "BRICK: no insmod lines left in %s" % APP)


# ------------------------------------------------------------- the wrapper

def test_the_wrapper_is_installed(box):
    """A shebang, not an ELF. The stock binary still sitting here means the
    install did not take -- and that must fail rather than be tolerated,
    because tolerating it turns "the install produced nothing" into a pass."""
    head = box.sh("head -c 2 %s" % FE).out
    assert head == "#!", (
        "BRICK: %s is not the mod wrapper (starts %r) -- the install did not "
        "replace it" % (FE, head))


def test_the_wrapper_is_executable(box):
    assert box.file(FE).executable, "BRICK: %s is not executable" % FE


def test_the_wrapper_parses(box):
    parsed = box.sh("sh -n %s 2>&1" % FE)
    assert parsed.ok, "BRICK: wrapper syntax error: %s" % parsed.text


def test_the_wrapper_starts_the_supervisor(box):
    """Replaces the case script's `grep helix`. The wrapper no longer execs a
    UI: it starts s6-svscan and brings the boot set up, and the UI is one
    service in that set. Asking for HelixScreen by name here would be asking
    about an architecture that has been gone since phase 8."""
    text = box.file(FE).text
    assert "s6-svscan" in text, (
        "BRICK: the wrapper starts no supervisor -- nothing would bring the "
        "printer up")
    assert "s6-rc" in text, (
        "BRICK: the wrapper never asks s6-rc for a transition, so no service "
        "would start")


def test_the_stock_paths_are_symlinks_into_the_payload(box):
    """The property the whole seam rests on since the software component
    stopped carrying firmwareExe and start.sh.

    anvil-core installs all three at $MODDIR/prog/ and anvil-link-prog.sh points
    the stock paths at them -- from runFirmwareExe.sh on a flash and from the
    postinst on `opkg upgrade anvil-core`. A REGULAR FILE at any of these means
    the link step did not run, and the printer would go on executing whatever
    the last install happened to leave there while an upgrade quietly rewrote
    $MODDIR.

    klipperDaemon is here for a second reason. It was hand-copied by the
    installer until the nice value it carried went away, and the guard on that
    copy named a path the file had stopped shipping at -- so for several
    releases the block was skipped in silence and every printer kept
    FlashForge's own, whose `start` forks a second unsupervised klippy beside
    the s6 one. A link cannot be skipped in silence.
    """
    for path in (FE, START, DAEMON):
        target = box.sh("readlink %s 2>/dev/null" % path).out.strip()
        assert target, (
            "%s is not a symlink -- anvil-link-prog.sh did not run, so an "
            "`opkg upgrade anvil-core` would not change what this printer "
            "executes" % path)
        assert target.startswith(MODDIR + "/prog/"), (
            "%s -> %r, which is not under %s/prog -- anvil-core is not what "
            "this printer runs" % (path, target, MODDIR))
        assert box.file(path).exists, (
            "%s -> %r dangles: the link is there but the payload is not"
            % (path, target))


def test_the_klipper_daemon_shim_refuses_to_start_a_second_klippy(box):
    """The whole point of shipping it. Stock's `start` runs start-stop-daemon
    -b, which would put an unsupervised klippy next to the supervised one,
    fighting for /dev/ttyS4 and /tmp/uds. Asked by RUNNING it, because the file
    being in place says nothing about what it does."""
    got = box.sh("%s start 2>&1; echo rc=$?" % DAEMON)
    assert "rc=0" in got.text, (
        "`klipperDaemon start` did not exit 0 -- a caller that treats failure "
        "as fatal would break on it: %s" % got.text)
    assert "supervised" in got.text, (
        "`klipperDaemon start` did not report that klipper is supervised, so "
        "this is probably FlashForge's own: %s" % got.text)
    running = box.pgrep("klippy.py")
    assert len(running) <= 1, (
        "`klipperDaemon start` left %d klippy processes running -- the shim "
        "forked one: %s" % (len(running), [p.cmdline for p in running]))


def test_every_installed_script_parses_under_the_printers_busybox(box):
    """Every shell script the mod put on the machine, with the shell that will
    actually run it. A bashism here is a service that dies at boot."""
    listed = box.sh(
        "find %s -name '*.sh' -type f 2>/dev/null; "
        "find %s -type f 2>/dev/null" % (MODDIR, SOURCE))
    scripts = [s for s in listed.out.split() if s]
    assert scripts, "found no installed scripts to parse -- the find is wrong"

    broken = box.sh(
        "for f in %s; do head -c 2 \"$f\" | grep -q '#!' || continue; "
        "sh -n \"$f\" 2>&1 >/dev/null || echo \"BAD $f\"; done"
        % " ".join(scripts))
    assert "BAD" not in broken.text, (
        "syntax errors under the printer's ash:\n%s" % broken.text)


# ------------------------------------------------ what actually starts klipper

def test_klipper_is_a_service_in_the_database(box):
    """Replaces `[ -d $MODDIR/init.d ]`. Asked of the COMPILED database rather
    than of the source tree, because s6-rc-compile is free to reject or drop
    what it was given -- a `down` file in a definition directory is accepted
    and discarded, which is how this bit us once."""
    listed = box.sh("%s/bin/s6-rc-db -c %s list services 2>&1" % (MODDIR, DB))
    assert listed.ok, "could not read the compiled database: %s" % listed.text
    assert "klipper" in listed.out.split(), (
        "nothing starts Klipper -- the UI would boot with no motion and no "
        "heaters. Services in the database: %s" % listed.out.split())


def test_the_ui_is_a_service_in_the_compiled_database(box):
    """The other half of the retired `grep helix`: the UI still gets started by
    something, it is just the `ui` service now rather than a line in the
    wrapper."""
    listed = box.sh("%s/bin/s6-rc-db -c %s list services 2>&1" % (MODDIR, DB))
    assert "ui" in listed.out.split(), (
        "BRICK: no `ui` service -- the printer would boot with no interface. "
        "Services: %s" % listed.out.split())


def test_klipper_depends_on_the_mcu_bringup(box):
    """The ordering the whole s6-rc graph exists for: the boards must be out of
    their bootloaders before klippy opens the ports, on EVERY start, which is
    what having it as a dependency buys over calling it once at boot."""
    deps = box.sh("%s/bin/s6-rc-db -c %s dependencies klipper 2>&1"
                  % (MODDIR, DB))
    assert deps.ok, "could not read klipper's dependencies: %s" % deps.text
    assert "mcu-bringup" in deps.out.split(), (
        "klipper does not depend on mcu-bringup, so klippy could open the "
        "ports before the boards are handed over. Dependencies: %s"
        % deps.out.split())


# --------------------------------------------------------------- klippy itself

def test_klippy_is_present(box):
    """In the payload, which is the only copy: anvil-klipper installs it and
    the s6 service execs it there. There is no component copy to fall back
    on any more, so this failing means the printer has no Klipper at all."""
    assert box.file(KLIPPY_DIR + "/klippy.py").exists, (
        "%s/klippy.py missing -- anvil-klipper did not install and there is "
        "nothing to start" % KLIPPY_DIR)


def test_the_klipper_service_runs_the_payload_tree_on_our_python(box):
    """The regression that would silently restore the old arrangement: a run
    script pointing back at /usr/prog gets its klippy from a stock flash, not
    from the package, and no other test here would notice."""
    # The compiled servicedir is what s6-supervise actually execs; the source
    # tree is the fallback so this still says something useful on a machine
    # where the database did not compile.
    body = box.file(DB + "/servicedirs/klipper/run").text \
        or box.file(SOURCE + "/klipper/run").text
    assert body, "no klipper run script in either the database or the source tree"
    assert "/usr/prog/klipper/klippy" not in body, (
        "the klipper service still execs klippy out of /usr/prog -- that tree "
        "is FlashForge's stock 0.12 and a stock flash owns it")
    # The run script spells it $MODDIR, unexpanded, so match the tail rather
    # than the absolute path this file computes.
    assert "klipper/klippy/klippy.py" in body, (
        "the klipper service does not exec %s/klippy.py" % KLIPPY_DIR)
    assert "$FF_PYTHON" in body, (
        "the klipper service does not run klippy under $FF_PYTHON")


def test_klippy_imports_resolve_on_our_python(box):
    """cffi, greenlet, pyserial and jinja2 are anvil-klipper's Depends. They
    used to arrive as anvil-moonraker's, or from a hardcoded list in
    bin/patch.sh -- so a BUILD_MOONRAKER=0 build shipped a klippy that dies
    the first time it opens an MCU."""
    for mod in ("cffi", "greenlet", "serial", "jinja2"):
        r = box.sh(". %s/anvil-env.sh; $FF_PYTHON -c 'import %s' 2>&1"
                   % (MODDIR, mod))
        assert r.ok, (
            "klippy's %s does not import on FF_PYTHON: %s" % (mod, r.text))


# THE CHELPER'S ABI IS NOT ASKED HERE ANY MORE. Two tests used to read its
# ELF header a byte at a time through `xxd` -- 32-bit, little-endian, MIPS,
# then e_flags for nan2008 -- for one file out of the several hundred ELF
# objects an install puts on this machine. qa/replica/test_abi.py sweeps all
# of them on the same fixture and names c_helper.so explicitly, so what was
# here is a strict subset of what runs there.


# ------------------------------------------------------- the mod's own config

def test_the_config_include_set_is_wired_up(box):
    """printer.base.cfg must include every ff-*.cfg the package shipped, and
    each one must be there. A shipped-but-unincluded file is a feature that
    silently does nothing."""
    base = box.file("/usr/data/config/printer.base.cfg")
    assert base.exists, "no printer.base.cfg -- the mod's config is not wired up"
    included = set(re.findall(r"\[include\s+(ff-[\w.-]+\.cfg)\]", base.text))
    assert included, "printer.base.cfg includes no ff-*.cfg at all"

    shipped = set(box.sh("ls %s/config/ff-*.cfg 2>/dev/null" % MODDIR).out.split())
    shipped = {p.rsplit("/", 1)[-1] for p in shipped}
    assert shipped, "the package shipped no ff-*.cfg"
    assert shipped <= included, (
        "shipped but never included: %s" % sorted(shipped - included))

    missing = [name for name in included
               if not box.file("/usr/data/config/" + name).exists]
    assert not missing, "included but not installed: %s" % missing


def test_the_user_printer_cfg_was_not_clobbered(box):
    """The one file on the machine that is the owner's, not ours."""
    cfg = box.file("/usr/data/config/printer.cfg")
    assert cfg.exists, "user printer.cfg was clobbered by the install"


# ---------------------------------------------------------- the rollback copy

def test_a_pristine_snapshot_was_kept(box):
    """runFirmwareExe.sh copies the first install's backup to backup/stock and never
    overwrites it, so there is always one snapshot taken before the mod ever
    touched the machine -- later backups are of an already-modded printer."""
    stock = box.file(MODDIR + "/backup/stock")
    assert stock.is_dir, (
        "no pristine snapshot at %s/backup/stock -- there is nothing taken "
        "before the mod to restore from" % MODDIR)
    assert box.sh("ls %s/backup/stock" % MODDIR).out.split(), (
        "%s/backup/stock is empty" % MODDIR)


# ------------------------------------------------------------ the install log

def test_the_installer_said_it_installed(box):
    """The anti-vacuity guard. Every assertion above describes a machine the
    installer built; if the installer never ran, they would be describing
    something else entirely and several would still pass."""
    log = box.file(INSTALL_LOG)
    assert log.exists, (
        "no %s -- runFirmwareExe.sh never ran, so nothing here is asserting "
        "against an install" % INSTALL_LOG)
    assert "mod payload installed" in log.text, (
        "the install log does not say the payload was installed:\n%s"
        % log.text[-1500:])


def test_the_installer_left_no_payload_in_the_scratch_directory(box):
    """/usr/data/update is where app_startup.sh unpacks the package, and where
    runFirmwareExe.sh finds anvil.tar.xz beside itself. MEASURED: the directory
    itself survives the
    install, empty, so its mere existence is not the question the case script
    thought it was asking. What must not survive is its CONTENTS: an ~80MB
    half-unpacked tree on the data partition that a later install could trip
    over."""
    left = box.sh("ls -A /usr/data/update 2>/dev/null").out.split()
    assert not left, (
        "the installer left its unpacked payload behind in /usr/data/update: %s"
        % left)


def test_the_root_password_was_dealt_with_exactly_once(box):
    """A random root password is generated on the FIRST install only. Doing it
    again on every update would mean a printer whose password changes under its
    owner each time they upgrade."""
    # `+`-prefixed lines are skipped because the software component's run.sh
    # still runs under FlashForge's `set -x` and its trace lands in the same
    # log. None of OUR echoes can appear that way any more -- the installer is
    # its own file and is not spliced into anything -- but a trace line that
    # merely quotes the string would still be counted, and this stays cheap.
    log = box.file(INSTALL_LOG).text
    generated = len([ln for ln in log.splitlines()
                     if "root password set (random" in ln
                     and not ln.lstrip().startswith("+")])
    assert generated <= 1, (
        "the installer generated a root password %d times -- an update must "
        "preserve it, not reroll it" % generated)


# ------------------------------------- no stick, no update (the case's boot 3)

def test_a_boot_with_no_stick_does_not_try_to_update(box):
    """case-install.sh's third boot. The bake removes /stick.img once the
    install has landed, so this machine IS the "stick pulled" case:
    app_startup.sh must go straight to a normal boot rather than hunting for a
    package that is no longer there.

    `find update file` is app_startup.sh's own marker for entering the update
    block -- the same string the case script keyed on, rather than a fuzzy
    search for the word "update", which appears in a healthy boot too.

    firmwareExe is neutered for the run, because the real one holds the
    foreground forever by design. What is under test is the update block's
    decision, not the boot that follows it.

    The stub goes in by MOVING THE SYMLINK ASIDE, not by writing to $FE: that
    path is a link into $MODDIR/prog now, so a redirection would write through
    it and leave the packaged wrapper stubbed for whatever runs next. `mv`
    moves the link itself, and moving it back restores it exactly.
    """
    box.sh("mv -f %s /tmp/fe.link && printf '#!/bin/sh\\nexit 0\\n' > %s "
           "&& chmod +x %s" % (FE, FE, FE))
    try:
        box.sh("sh %s > /tmp/boot-nostick.log 2>&1; echo rc=$?" % APP,
               timeout=300)
        log = box.file("/tmp/boot-nostick.log").text
    finally:
        box.sh("rm -f %s && mv -f /tmp/fe.link %s" % (FE, FE))

    assert log.strip(), "app_startup.sh produced no output at all"
    assert "find update file" not in log, (
        "app_startup.sh entered the update block with no stick present:\n%s"
        % log[-1500:])


def test_a_boot_with_no_stick_hits_no_missing_commands(box):
    """The boot log from the run above. A `not found` here is a command the
    payload assumed and the printer has not got -- which on a real machine is
    a step of the boot silently not happening."""
    log = box.file("/tmp/boot-nostick.log").text
    assert log.strip(), (
        "no boot log -- test_a_boot_with_no_stick_does_not_try_to_update must "
        "run first; it is the one that produces this")
    bad = [ln for ln in log.splitlines()
           if "not found" in ln or "Syntax error" in ln]
    assert not bad, "missing commands or syntax errors in the boot:\n%s" % (
        "\n".join(bad[:5]))
