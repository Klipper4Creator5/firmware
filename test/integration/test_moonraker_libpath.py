"""The library path moonraker is started with.

A printer reported moonraker never coming up: no Mainsail, no API, nothing but
the screen. The cause was S60web naming three /usr/prog/*/lib directories and
inheriting the other nine from app_startup.sh, which exports twelve before it
runs the wrapper. That inheritance holds on a normal boot and nowhere else --
re-run the script over ssh and the environment is bare.

The one that matters is libsodium: moonraker's `authorization` component is
linked against it, so without it moonraker exits during component load rather
than failing to import python, which is why it looks like "moonraker just did
not start". moonraker-preflight.py exists because that same library caught us
once already.

So the list is set explicitly in both places that start or check moonraker,
and this is what stops them drifting apart again.
"""
import os
import re

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

S60WEB = os.path.join(ROOT, "payload", "init.d", "S60web")
RUN_APPEND = os.path.join(ROOT, "payload", "run-append.sh")

# Everything moonraker's components are linked against. Named here so the test
# fails loudly if a directory is dropped from the shipped scripts rather than
# silently agreeing with whatever they happen to say.
REQUIRED = {
    "/usr/prog/Python-3.8.2/lib",
    "/usr/prog/openssl-1.0.2d/lib",
    "/usr/prog/libffi-3.4.4/lib",
    "/usr/prog/libsodium/lib",
}


def code(path):
    """The script with its comments stripped.

    Tests that grep a shell script have to read what it DOES; a rule about
    what it must not run is otherwise satisfied or broken by a comment
    explaining why it does not run it."""
    out = []
    for line in open(path):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        out.append(line.split(" #")[0])
    return "".join(out)


def lib_dirs(path):
    """The /usr/prog/*/lib directories a script puts on LD_LIBRARY_PATH."""
    return set(re.findall(r"/usr/prog/[A-Za-z0-9._-]+/lib\b", code(path)))


def test_s60web_sets_everything_moonraker_needs():
    have = lib_dirs(S60WEB)
    assert REQUIRED <= have, "S60web is missing %s" % (REQUIRED - have)


def test_libsodium_is_there_because_it_is_the_one_that_broke():
    # Called out on its own: it is the failure a user actually reported, and
    # the one whose absence looks like moonraker simply not starting.
    assert "/usr/prog/libsodium/lib" in lib_dirs(S60WEB)


def test_the_installer_checks_against_the_same_list():
    # run-append.sh's preflight decides whether the shipped moonraker is
    # usable. If it checked against a fuller path than the boot script sets,
    # it would pass a build that then failed to start -- which is precisely
    # the shape of the bug this is guarding.
    boot, install = lib_dirs(S60WEB), lib_dirs(RUN_APPEND)
    assert boot == install, (
        "S60web and run-append.sh disagree: only in boot=%s, only in install=%s"
        % (sorted(boot - install), sorted(install - boot)))


def test_the_directories_are_probed_before_use():
    # A directory that is not on this model gets skipped rather than pushed
    # onto the path as a dead entry.
    assert '[ -d "$d" ]' in code(S60WEB)


def test_moonraker_is_started_through_the_daemon():
    # Not python3.8 moonraker.py & -- the daemon owns the pidfile `stop` uses
    # and sets TMPDIR=/usr/data/tmp, without which moonraker writes to /tmp,
    # a ramdisk on this machine.
    text = code(S60WEB)
    assert "moonrakerDaemon start" in text
    assert not re.search(r"moonraker\.py\s", text)


def test_a_dead_moonraker_is_reported_in_the_boot_log():
    # Moonraker failing a component load exits quietly, minutes before anyone
    # opens a browser. The boot log is the only place that can say so.
    text = code(S60WEB)
    assert "moonraker_check" in text
    assert "moonraker.log" in text or "MR_LOG" in text
