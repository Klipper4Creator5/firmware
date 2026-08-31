"""An s6 `run` script must not launch its daemon through start-stop-daemon.

THE BUG THIS EXISTS FOR. `klipper/run` launched klippy with

    exec start-stop-daemon -S --exec "$FF_PYTHON" -- "$KLIPPY" ...

`-S` starts the program *unless a matching process is found*, and `--exec`
matches on the interpreter rather than on the script. moonraker runs
$FF_PYTHON too, so start-stop-daemon found moonraker, reported the service
already up, and returned without ever exec'ing klippy. s6 saw a longrun exit
and respawned it, for as long as the printer was on: moonraker up, klipper
`disconnected`, ff-startup giving up with KLIPPER DID NOT FINISH STARTING, and
HelixScreen in front of a machine with no motion and no heaters.

WHY THIS IS STATIC AND NOT A REPLICA TEST, which is the exception this file has
to earn. The replica CANNOT reproduce it. Printer binaries run there under
qemu-mipsel-static, so a moonraker process has

    cmdline[0] = /usr/bin/qemu-mipsel-static
    /proc/PID/exe -> /usr/bin/qemu-mipsel-static

and start-stop-daemon, matching on $FF_PYTHON, therefore matches nothing and
starts klippy exactly as it should. MEASURED: a replica built from a package
carrying the broken line passes a behaviour test that asserts klippy starts
with moonraker up. Emulation rewrites the process identity the bug depends on,
so the one lane that runs the real tools is blind to it by construction, and a
behaviour test there would be worse than none -- it would report this very
failure as green.

THE RULE, therefore, rather than the symptom: an s6 run script execs its daemon
and nothing else. s6-supervise is the parent -- it knows the pid, runs one copy
of a servicedir at a time, and restarts what dies -- so a "is one already
running?" check in a run script has no true positive left to find and can only
return false ones. moonraker/run states the same rule in prose at its head.
"""
import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

RUN_SCRIPTS = sorted(ROOT.glob("pkgs/*/payload/etc/s6-rc/source/*/run"))


def test_there_are_run_scripts_to_check():
    """A glob that matches nothing would make every test below vacuous."""
    assert RUN_SCRIPTS, "no s6-rc run scripts found under pkgs/*/payload"


@pytest.mark.parametrize(
    "run", RUN_SCRIPTS, ids=lambda p: p.parent.name)
def test_no_start_stop_daemon(run):
    """Code, not comments: moonraker/run and klipper/run both DISCUSS
    start-stop-daemon at length, and saying why it is absent must stay
    allowed."""
    offending = [
        line for line in run.read_text().splitlines()
        if "start-stop-daemon" in line and not line.lstrip().startswith("#")
    ]
    assert not offending, (
        "%s launches through start-stop-daemon: %s\n"
        "s6-supervise is the parent -- exec the daemon directly."
        % (run.parent.name, offending))
