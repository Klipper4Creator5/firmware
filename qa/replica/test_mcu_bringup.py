"""Can the machine actually RUN the MCU bring-up? -- the port of
test/integration/printer/case-mcu-bringup.sh.

WHAT THIS ASKS, AND WHY IT IS WORTH A CONTAINER

Not the handshake. There are no /dev/ttyS4, /dev/ttyS5 or /dev/ttyS7 on a
replica -- the three ports ff_mcu_bringup.py owns -- so no board can be handed
over here and no ready phase can be exercised. That is hardware, and closing it
is the simulated-MCU lane, not a longer deadline in this file.

What is left is exactly what the case script existed for, and it says so in its
own header: the boring part that has already bitten us. moonrakerDaemon shipped
broken because /usr/prog/Python-3.8.2/bin/python3 does not start without
LD_LIBRARY_PATH and was only ever launched from a script that exported it. So
this runs the command lines the printer really runs, in the environment the
shipped anvil-env.sh really sets, on the interpreter FF_PYTHON really names,
and asserts that the interpreter starts, that the script's imports resolve on
it, that it reports EVERY port it could not open by name, and that each caller
gets an exit status it can act on.

The machine is the `printer` fixture's: the real package, installed by the
printer's own app_startup.sh. Nothing here copies a script out of
/tmp/payload or unpacks a py.tgz, which is most of what the case script's first
thirty lines were -- the interpreter and the script are BUILD OUTPUTS and they
are in the installed package already. If either is missing that is a failure
here, with the fix in the message, and not a Skip decided in gates.py.

WHAT MOVED SINCE THE CASE SCRIPT WAS WRITTEN. It tests "the command line
start.sh really uses". start.sh no longer runs the bring-up at all: the s6-rc
`mcu-bringup` oneshot does, and it runs it through bin/ff-startup.py
--only-bringup, which imports ff_mcu_bringup as a module. Both entry points are
covered below, because they have opposite contracts about the exit status.

DELIBERATELY NOT PORTED

  * §5, `grep checkEboard /tmp/payload/start.sh`. Its subject is gone twice
    over: start.sh does not invoke the bring-up any more, and grepping a
    shipped script is a static-lane question -- this lane runs the real tools
    in the machine rather than reading the scripts it installed.

  * §6, the negative control "the interpreter must FAIL without
    LD_LIBRARY_PATH". Its subject is FlashForge's dynamically linked 3.8.2.
    FF_PYTHON is our own CPython 3.13 now, built --disable-shared against seven
    static libraries with no .so of ours to find (pkgs/3rdparty/python/build.sh),
    so it does not need LD_LIBRARY_PATH and the case script's own `skip()`
    branch is the one that fires. The fact is asserted in the direction that is
    now true instead -- test_it_runs_with_no_environment_at_all.

  * The port tuple and the every-port-fails pass. These were asserted on the
    host by test/integration/test_ff_mcu_bringup.py, which imported the module
    directly and needed no replica. That file has been dropped -- it drove a
    module whose one interesting path, the handshake, it could not reach --
    so both are unasserted anywhere. See docs/qa-migration.md, Still owed.
"""
import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
SCRIPT = MODDIR + "/bin/ff_mcu_bringup.py"
STARTUP = MODDIR + "/bin/ff-startup.py"
PY = MODDIR + "/bin/python3.13"

# The three the bring-up owns. ttyS5 is in the list because NOTHING else covers
# it -- checkEboard is gone and start.sh never replaced it -- so a bring-up that
# quietly stopped covering ttyS5 would strand the eboard with nothing left to
# notice.
PORTS = ("/dev/ttyS4", "/dev/ttyS5", "/dev/ttyS7")

# The environment every real caller is in, taken from the SHIPPED file rather
# than retyped. A copy would agree with the printer right up until one of them
# changed, and proving the bring-up runs in an environment the printer never
# uses is worse than not proving it. MODDIR first, because that is what
# anvil-env.sh's own FF_PYTHON line reads -- and the s6-rc `mcu-bringup` up
# script sets it the same way.
ENV = "MODDIR=%s\n. $MODDIR/anvil-env.sh\n" % MODDIR

# Short deadline: every port fails to open on the first pass here, so the run
# is over immediately and this only bounds the damage if that ever stops being
# true.
RUN = '"$FF_PYTHON" %s -t 1 2>&1' % SCRIPT


@pytest.fixture(scope="module")
def box(printer):
    """The installed machine, with the two build outputs this asks about.

    Checked once, here, because every test below is meaningless without them
    and one clear failure beats six identical ones.
    """
    if not printer.file(SCRIPT).exists:
        pytest.fail(
            "this package ships no %s, so there is no bring-up to run. Build a "
            "package from this tree -- `make build` -- and the replica lane "
            "takes the newest work/out/*.tgz." % SCRIPT)
    if not printer.file(PY).executable:
        pytest.fail(
            "this package ships no interpreter at %s, so nothing FF_PYTHON "
            "names can run. It is a build output (pkgs/3rdparty/python), not a "
            "file in the checkout -- `make build`." % PY)
    return printer


def _run(box, script):
    return box.sh(ENV + script)


# ------------------------------------------------- the environment resolves

def test_the_shipped_environment_names_our_own_interpreter(box):
    """The whole reason FF_PYTHON exists, and the line the case script's §2
    caught with its MODDIR alias: a $MODDIR that is not set resolves this to
    the empty-prefix "/bin/python3.13" and every caller then runs nothing."""
    got = _run(box, 'echo "$FF_PYTHON"').first_line
    assert got == PY, "anvil-env.sh resolves FF_PYTHON to %r, not %s" % (got, PY)


def test_the_interpreter_it_names_actually_starts(box):
    """Separately from the bring-up, so a loader failure is not reported as a
    bring-up failure. This is the moonrakerDaemon shape: the interpreter dies
    before it has read a line of anybody's python."""
    got = _run(box, '"$FF_PYTHON" -c "print(1)" 2>&1')
    assert got.ok, "%s did not start: %s" % (PY, got.text)


def test_the_bringups_imports_resolve_on_it(box):
    """Imported as ff-startup.py imports it -- by name, out of the directory it
    sits in -- rather than as `import os, sys, termios`, so a module-level
    import added to the script is covered without this file being edited."""
    got = _run(box, 'cd %s/bin && "$FF_PYTHON" -c "import ff_mcu_bringup" 2>&1'
               % MODDIR)
    assert got.ok, "ff_mcu_bringup.py does not import on %s: %s" % (PY, got.text)


# ------------------------------------------------------- it runs, and reports

def test_it_runs_without_raising_or_failing_to_load(box):
    """The two failures that look identical from the boot log and need opposite
    fixes: a traceback is ours, a loader error is the environment's."""
    out = _run(box, RUN).text
    assert "Traceback" not in out, "the bring-up raised: %s" % out
    assert "error while loading shared libraries" not in out, (
        "the interpreter could not load its libraries: %s" % out)


def test_it_names_every_port_it_could_not_open(box):
    """A port that cannot be opened must be REPORTED, by name, not silently
    dropped -- otherwise a board that was never handed over reaches klippy as
    an unexplained 'MCU error during connect' ninety seconds later.

    All three in one test on purpose: what matters is that the set is complete,
    and a failure that says which one is missing says it better than three
    tests that each know about one port.
    """
    out = _run(box, RUN).text
    missing = [dev for dev in PORTS if ("mcu-bringup: " + dev) not in out]
    assert not missing, (
        "never mentioned %s -- the whole output was: %s"
        % (", ".join(missing), out))


def test_a_port_it_could_not_open_is_a_non_zero_exit(box):
    """Run DIRECTLY, which is the contract a person at an ssh prompt gets: no
    device here, so every port fails and the exit status has to say so. 1, not
    2 and not 127 -- those are python failing to start the script at all, which
    is the case this whole module exists to tell apart from a bad board."""
    got = _run(box, RUN)
    assert got.code == 1, (
        "expected exit 1 with no serial ports present, got %d: %s"
        % (got.code, got.text))


# --------------------------------------------------------------- the oneshot

def test_the_s6_oneshot_command_line_never_fails(box):
    """The opposite contract, and the more important one. etc/s6-rc/source/
    mcu-bringup/up runs ff-startup.py --only-bringup, and klipper DEPENDS on
    that service: s6-rc does not start what depends on a failed service, so a
    bring-up that exited non-zero over a board that did not answer would leave
    the printer with no klipper at all -- worse than the board it is reporting
    on. Every port fails here, which is the strongest available version of that
    test."""
    got = _run(box, '"$FF_PYTHON" %s --only-bringup 2>&1' % STARTUP)
    assert got.code == 0, (
        "the mcu-bringup oneshot exited %d, so s6-rc would not start klipper: "
        "%s" % (got.code, got.text))
    assert "mcu-bringup: /dev/ttyS4" in got.text, (
        "the oneshot did not reach the bring-up at all: %s" % got.text)


# ------------------------------------------------------ the environment's turn

def test_it_runs_with_no_environment_at_all(box):
    """What §6 of the case script was reaching for, in the direction that is
    true today.

    FF_PYTHON is our 3.13, linked --disable-shared against static libraries, so
    unlike FlashForge's 3.8.2 it needs nothing exported to start. That is worth
    holding: it means a bring-up run from a bare ssh session, from cron, or from
    an s6 `up` that forgot to source anvil-env.sh still reports on the boards
    instead of dying with a loader error. If a future build makes the
    interpreter need a library path again, this is where it goes red, and the
    fix is a dependency to stop shipping dynamically -- not an export.
    """
    got = box.sh("env -i %s %s -t 1 2>&1" % (PY, SCRIPT))
    assert "error while loading shared libraries" not in got.text, (
        "the interpreter needs an exported library path: %s" % got.text)
    assert "mcu-bringup: /dev/ttyS4" in got.text, (
        "it did not get as far as reporting, on an empty environment: %s"
        % got.text)
