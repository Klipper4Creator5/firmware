"""What is left of `case-supervisor.sh`: the binaries, and readiness.

A PORT OF THE RESIDUE, NOT OF THE FILE. `case-supervisor.sh` asked five
things, and three of them are already asked here by tests written since:

  * a service comes up under s6, and `s6-svstat` says so
        -> test_web.py::test_nginx_is_up, ::test_moonraker_is_up_and_ready
  * s6 puts a daemon back after `kill -9`
        -> test_s6rc.py::test_a_killed_daemon_comes_back,
           test_web.py::test_nginx_comes_back_after_a_kill
  * a blocking `s6-svc -d` returns with the service really down
        -> test_web.py::test_a_stopped_nginx_stays_stopped

What nothing else asks, and is therefore here:

  * THE WHOLE ROSTER LOADS. test_s6rc.py::test_the_supervisor_is_the_one_we
    _shipped reads four bytes of s6-svscan and stops there. A cross-build can
    emit one object this kernel refuses -- wrong endianness, wrong ABI -- and
    the ones nobody would notice are exactly the stop/wait-time tools, which
    no green boot ever executes. pkgs/3rdparty/s6/build.sh checks the same
    list exists and is non-empty, but existing is not running.
  * READINESS. `s6-svstat` reporting `ready` (test_web.py) proves moonraker's
    notification reached s6; it does not prove a WAITER can block on it, and
    the waiting verbs are the ones that break when s6's compiled-in
    libexecdir is wrong: `-U` execs s6-svlisten, which spawns s6-ftrigrd by
    absolute path out of the prefix baked in at compile time. That was the
    reason for choosing s6 over runit at all (tools/supervisor/README.md),
    and it is the one part of the case that measured rather than looked.

WHAT THE CASE ASKED THAT NOTHING CAN. Its section 3 printed supervisor RSS and
`du -sh bin libexec` under a `note` -- no verdict, then or now, and a footprint
number measured under qemu is not the printer's anyway. Dropped rather than
ported.

WHY ITS OWN MODULE. Same reason as test_web.py: the fixture starts a scanner,
so it must own its container. It never calls s6-rc, so it takes no s6-rc lock
and needs no `-t` -- s6-svc/s6-svwait carry their own explicit deadlines below,
which is a different thing from the EOVERFLOW trap in test_s6rc.py.

The subject is the s6 the INSTALLED PACKAGE carries. The case unpacked a
sup.tgz handed to it by the old harness; here the machine already has the real
one, put there by the printer's own installer.
"""
import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"

# A scandir of our own, not the boot's: this module supervises a service that
# exists to be timed, and putting it in the shipped etc/s6 would leave it
# behind for anything that later ran s6-rc-init there.
SCANDIR = MODDIR + "/qa-supervise"

# The thirteen the case named. The package ships eight more (the
# s6-ipcserver/s6-sudo family, see pkgs/3rdparty/s6/build.sh), which nothing in
# the boot path executes; these are the supervision core, every one of which
# some verb of ours reaches.
SUPERVISION_BINARIES = (
    "s6-svscan", "s6-svscanctl", "s6-supervise", "s6-svc", "s6-svstat",
    "s6-svwait", "s6-svok", "s6-svlisten", "s6-svlisten1", "s6-ftrig-listen1",
    "s6-mkfifodir", "s6-cleanfifodir", "s6-notifyoncheck",
)

# What the shell says when the kernel would not take the object. The case
# looked for exactly these, and they are the point of running the binaries at
# all -- a usage line, an error, any exit code is a pass; only "this is not a
# program on this machine" is not.
# "not found" is in the list because busybox says it for a binary that IS
# there but whose loader is not -- a dynamically linked s6 on a machine with
# no matching ld.so reads exactly like a missing file.
ENOEXEC = ("cannot execute", "not executable", "Exec format error",
           "not found")

# The readiness service sleeps this long before telling s6 it is up, standing
# in for a device that takes a while to appear -- the camera's own situation.
READY_DELAY = 5

RUN_SLOW = """#!/bin/sh
sleep %d
echo ready >&3
exec sleep 86400
""" % READY_DELAY


@pytest.fixture(scope="module")
def s6(printer):
    """The machine, with the package's own supervisor actually present."""
    if not printer.file(MODDIR + "/bin/s6-svscan").executable:
        pytest.fail("this package ships no supervisor: %s/bin/s6-svscan is "
                    "missing. Build a package from this tree -- `make build`."
                    % MODDIR)
    return printer


@pytest.fixture(scope="module")
def shipped(s6):
    """One listing of bin/ and libexec/, so membership is judged out here.

    One `ls` rather than thirteen `test -x`: each probe is a docker exec into
    a qemu chroot, and the question is about a set, not about a file.
    """
    return {
        "bin": set(s6.sh("ls -1 %s/bin" % MODDIR).out.split()),
        "libexec": set(s6.sh("ls -1 %s/libexec" % MODDIR).out.split()),
    }


@pytest.fixture(scope="module")
def loads(s6):
    """Every binary run once, in one action, with its first line kept.

    Each is given a servicedir path that does not exist, which every one of
    them treats as a fast fatal or a usage line. The case ran them with NO
    argument, which is safe for twelve of the thirteen and not for s6-svscan:
    with no argument it scans the current directory and does not return.
    """
    script = "\n".join(
        'echo "== %s"; %s/bin/%s /nonexistent-servicedir </dev/null 2>&1 '
        '| head -1' % (name, MODDIR, name) for name in SUPERVISION_BINARIES)
    got = s6.sh(script)
    first = {}
    name = None
    for line in got.text.splitlines():
        if line.startswith("== "):
            name = line[3:].strip()
            first[name] = ""
        elif name and not first[name]:
            first[name] = line.strip()
    return first


@pytest.fixture(scope="module")
def readiness(s6):
    """A service that declares itself ready after a deliberate delay, timed.

    The timing is taken INSIDE the replica: the wait is a docker exec into a
    qemu chroot, and a clock started out here would be measuring the
    transport as much as the notification.

    The servicedir is written before the scanner starts, so nothing has to
    rescan a live scandir; then the service is stopped and started again so
    its delay begins when the stopwatch does.
    """
    s6.sh("mkdir -p %s/slow" % SCANDIR)
    s6.write("%s/slow/run" % SCANDIR, RUN_SLOW, mode="0755")
    # s6 notifies on this descriptor and only reports `ready` if it is told
    # to expect one; without this file the run script's `echo >&3` writes to a
    # closed fd and the service is merely up.
    s6.write("%s/slow/notification-fd" % SCANDIR, "3\n")

    s6.sh("setsid %s/bin/s6-svscan %s >>%s/qa-svscan.log 2>&1 &"
          % (MODDIR, SCANDIR, MODDIR))
    for _ in range(20):
        if s6.sh("%s/bin/s6-svscanctl -a %s" % (MODDIR, SCANDIR)).ok:
            break
        s6.sh("sleep 1")
    else:
        pytest.fail("s6-svscan never answered on %s -- log: %s"
                    % (SCANDIR, s6.file(MODDIR + "/qa-svscan.log").text))

    timed = s6.sh("""
D=%(scandir)s/slow
%(bin)s/s6-svc -wD -T 20000 -d $D 2>&1
start=`date +%%s`
%(bin)s/s6-svc -u $D 2>&1
out=`%(bin)s/s6-svwait -U -t 30000 $D 2>&1`; rc=$?
end=`date +%%s`
echo "rc=$rc"
echo "start=$start"
echo "end=$end"
echo "out=$out"
""" % {"scandir": SCANDIR, "bin": MODDIR + "/bin"}, timeout=180)

    fields = {}
    for line in timed.text.splitlines():
        key, _, value = line.partition("=")
        fields[key.strip()] = value.strip()
    if "start" not in fields or "end" not in fields:
        pytest.fail("the readiness action did not report a clock:\n%s"
                    % timed.text)
    fields["elapsed"] = int(fields["end"]) - int(fields["start"])
    fields["state"] = s6.sh("%s/bin/s6-svstat %s/slow"
                            % (MODDIR, SCANDIR)).text.strip()
    return fields


# ------------------------------------------------- the kernel takes them all

@pytest.mark.parametrize("name", SUPERVISION_BINARIES)
def test_every_supervision_binary_is_installed(shipped, name):
    assert name in shipped["bin"], (
        "%s/bin/%s is not in the installed package. The recipe's own list is "
        "S6_BINS in pkgs/3rdparty/s6/build.sh -- if it is missing there, the "
        "verb that needs it fails only at stop or wait time." % (MODDIR, name))


@pytest.mark.parametrize("name", SUPERVISION_BINARIES)
def test_every_supervision_binary_runs_on_this_kernel(loads, name):
    """Only ENOEXEC is a failure. Every one of these exits non-zero on a
    servicedir that is not there, and that is a program that RAN."""
    said = loads.get(name)
    assert said is not None, (
        "%s produced no output at all, not even an error -- the batch that "
        "runs them may have died early." % name)
    bad = [marker for marker in ENOEXEC if marker.lower() in said.lower()]
    assert not bad, "the kernel would not run %s: %s" % (name, said)


def test_s6_ftrigrd_is_in_libexec(shipped):
    """Not on anyone's PATH and not spawned by name: the waiting verbs exec it
    by the absolute libexecdir compiled into them. Missing, s6 supervises
    perfectly and every waiting verb fails -- which is why it is asked here
    rather than left to the boot to discover."""
    assert "s6-ftrigrd" in shipped["libexec"], (
        "no %s/libexec/s6-ftrigrd -- s6-svwait and every `s6-svc -w` will "
        "fail. See S6_LIBEXEC in pkgs/3rdparty/s6/build.sh." % MODDIR)


# ------------------------------------------------------ readiness, measured

def test_a_waiter_sees_the_readiness_notification(readiness):
    """`s6-svwait -U` returning 0 is the whole waiting path working end to
    end, s6-ftrigrd out of the compiled-in prefix included. A wrongly
    prefixed s6 fails HERE and nowhere earlier."""
    assert readiness["rc"] == "0", (
        "s6-svwait -U did not see a readiness notification (rc=%s): %s"
        % (readiness["rc"], readiness.get("out")))


def test_the_waiter_did_not_return_on_the_fork(readiness):
    """The distinction between s6 and runit, and the reason for the choice:
    `sv start` returns when the process has been forked. If -U returned
    immediately it only checked that something was running, and the readiness
    contract every dependency in the boot graph rests on is not there."""
    assert readiness["elapsed"] >= READY_DELAY - 2, (
        "s6-svwait -U returned after %ss, before the service's %ss delay "
        "could have elapsed -- it did not wait for readiness"
        % (readiness["elapsed"], READY_DELAY))


def test_the_waiter_returned_when_ready_and_not_at_the_deadline(readiness):
    """The other half: -U must come back on the notification, not by timing
    out at 30000ms. Bounded at 25s so a `ready` that never arrives is a
    failure with a number in it rather than a slow pass."""
    assert readiness["elapsed"] <= 25, (
        "s6-svwait -U took %ss for a %ss readiness delay -- that is its "
        "timeout expiring, not a notification"
        % (readiness["elapsed"], READY_DELAY))


def test_s6_reports_the_service_as_ready_afterwards(readiness):
    """svstat's own word for it, read after the wait returned: `up ... ready`
    is s6 recording the notification it received, and it is what a dependent
    service's `up` transition is gated on."""
    assert readiness["state"].startswith("up"), readiness["state"]
    assert "ready" in readiness["state"], readiness["state"]
