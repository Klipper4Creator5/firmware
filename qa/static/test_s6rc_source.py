"""The boot order, asserted by compiling it.

payload/etc/s6-rc/source/ is the boot: which services exist, which waits for
which, and how long each is allowed to take. Everything here asks the COMPILED
database rather than reading the source tree, because the database is what the
printer runs and the compiler is free to reject, rewrite or silently drop what
it was given -- `down` being the one that bit us (s6-rc-compile accepts a
`down` file and discards it, producing a byte-identical servicedir).

Static rather than replica: it needs no printer, no qemu and no docker, and it
catches the whole class of "the graph says something other than we think" in
about a second.
"""
import subprocess

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

SOURCE = ROOT / "payload" / "etc" / "s6-rc" / "source"

# bin/patch.sh section 5b-2 builds a NATIVE skarnet stack here to compile the
# database at build time. Same path, so a developer who has run a build already
# has what this needs and nothing has to be installed.
NATIVE = ROOT / "work" / ".s6-native" / "bin"

# What the boot brings up. mcu-bringup is deliberately absent -- it arrives as
# klipper's dependency, which is how "down by default" has to be expressed:
# a `down` file in a definition directory is accepted and silently dropped.
BOOT_SET = {"wifi", "nginx", "moonraker", "camera", "klipper", "ff-startup",
            "ui"}

# Seconds a transition will wait, per service. The camera's matters most: on a
# printer with no camera this is time the UI does not exist for.
TIMEOUTS = {"moonraker": 120000, "camera": 40000, "mcu-bringup": 60000,
            "ff-startup": 300000}


def _tool(name):
    path = NATIVE / name
    if not path.exists():
        # A failure, not a skip. See qa/conftest.py: a machine that cannot
        # answer this is not a machine where the question does not apply.
        pytest.fail(
            "no %s -- the s6-rc database was never compiled here, so nothing "
            "checked the boot graph. `make build` builds it (bin/patch.sh, "
            "section 5b-2); it lands in %s." % (name, NATIVE))
    return str(path)


@pytest.fixture(scope="session")
def db(tmp_path_factory):
    """The compiled database, built from the shipped source tree."""
    out = tmp_path_factory.mktemp("s6rc") / "db"
    built = subprocess.run([_tool("s6-rc-compile"), str(out), str(SOURCE)],
                           capture_output=True, text=True)
    assert built.returncode == 0, (
        "s6-rc-compile refused the source tree:\n%s" % built.stderr.strip())
    return str(out)


def _db(db, *args):
    got = subprocess.run([_tool("s6-rc-db"), "-c", db] + list(args),
                         capture_output=True, text=True)
    assert got.returncode == 0, (
        "s6-rc-db %s failed: %s" % (" ".join(args), got.stderr.strip()))
    return got.stdout.split()


def test_the_database_is_internally_consistent(db):
    checked = subprocess.run([_tool("s6-rc-db"), "-c", db, "check"],
                             capture_output=True, text=True)
    assert checked.returncode == 0, checked.stderr.strip()


def test_the_bundle_is_the_boot_set(db):
    assert set(_db(db, "contents", "ok-all")) == BOOT_SET


def test_mcu_bringup_is_reachable_but_not_in_the_bundle(db):
    """The only way s6-rc expresses "start it, but not because the boot asked
    for it": be somebody's dependency and nothing else."""
    assert "mcu-bringup" not in _db(db, "contents", "ok-all")
    assert "mcu-bringup" in _db(db, "list", "all")


@pytest.mark.parametrize("service,wants", [
    ("klipper", {"mcu-bringup"}),
    ("ff-startup", {"moonraker", "klipper"}),
    ("ui", {"ff-startup"}),
])
def test_the_edges(db, service, wants):
    """s6rc-oneshot-runner is filtered out: s6-rc adds it to every oneshot's
    dependencies itself, and it is machinery rather than boot order."""
    got = {d for d in _db(db, "dependencies", service)
           if not d.startswith("s6rc-")}
    assert got == wants


def test_nginx_does_not_gate_moonraker(db):
    """S60nginx's header wants nginx first because it proxies moonraker, and
    that is a preference, not a dependency. As an edge it would mean
    `s6-rc -d change nginx` also stops moonraker -- taking the API down with
    the UI, which is what splitting S60web into two scripts prevented."""
    assert "nginx" not in _db(db, "dependencies", "moonraker")


@pytest.mark.parametrize("service,want", sorted(TIMEOUTS.items()))
def test_timeouts_reach_the_database(db, service, want):
    """Without one, a service that never comes up holds the boot transition
    open for ever and nothing after it starts."""
    assert _db(db, "-u", "timeout", service) == [str(want)]


def test_the_oneshot_runner_runs_our_execline(db):
    """MEASURED, and the reason the native stack is configured with the target
    --prefix: execline bakes --shebangdir into the #! line s6-rc-compile
    writes here. Built with the wrong prefix, every oneshot dies with ENOENT
    on the printer while every longrun keeps working."""
    run = open("%s/servicedirs/s6rc-oneshot-runner/run" % db).read()
    assert run.startswith("#!/usr/data/anvil/bin/execlineb"), (
        "the database asks for %r" % run.splitlines()[:1])


def _oneshot_scripts(db):
    found = []
    for name in _db(db, "list", "oneshots"):
        if name.startswith("s6rc-"):
            continue
        for verb in ("-u", "-d"):
            got = subprocess.run(
                [_tool("s6-rc-db"), "-c", db, verb, "script", name],
                capture_output=True, text=True)
            if got.returncode == 0 and got.stdout.strip():
                found.append(("%s %s" % (name, verb.strip("-")), got.stdout))
    return found


def test_oneshots_have_scripts(db):
    assert _oneshot_scripts(db), "no oneshot up/down scripts -- did they move?"


def test_oneshot_shell_parses(db):
    """The `up` and `down` files are EXECLINE command lines carrying shell
    inside a `/bin/sh -c "..."` argument, so the shell checks in
    test_shell_syntax.py cannot see this code at all -- they would parse the
    wrapper and pass. This is the only thing that reads the body, and it reads
    the body the COMPILER stored, not the one on disk.
    """
    broken = []
    for name, argv in _oneshot_scripts(db):
        # s6-rc-db writes the stored argv NUL-separated, which is also the
        # proof that the shell arrived as ONE argument -- execline lexing the
        # body into several would be a script that runs its own first line.
        parts = argv.split("\0")
        assert parts[:2] == ["/bin/sh", "-c"], (
            "%s is not a /bin/sh -c script: %r" % (name, parts[:3]))
        body = parts[2]
        parsed = subprocess.run(["sh", "-n"], input=body,
                                capture_output=True, text=True)
        if parsed.returncode != 0:
            broken.append("%s: %s" % (name, parsed.stderr.strip()))
    assert not broken, "oneshot scripts do not parse:\n  " + "\n  ".join(broken)
