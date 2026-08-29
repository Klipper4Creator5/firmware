#!/usr/bin/env python3
"""The suite.

    ./test/run-tests.py                        runs the replica gates when a
                                               stock package is configured
    REQUIRE_PRINTER_SIM=1 ./test/run-tests.py  fails instead of skipping them
    ALLOW_SKIP=1 ./test/run-tests.py           accepts any gate that cannot
                                               run; ALLOW_SKIP="a,b" accepts
                                               exactly the gates named

Ordering matters. The rootfs is extracted BEFORE pytest, so one invocation
sees the best world available: with a stock package configured that is every
test, and without one the handful that read the rootfs skip and are reported
as gates that did not run.

This was run-tests.sh. It is Python now for one reason: in the shell version
"this gate did not run" travelled between processes as the string "SKIP:" on
stdout, and the runner decided by grepping for it. A launcher that had already
failed -- because the path to the file that loads config.env was wrong --
concluded it had nothing to work on, printed those characters, exited 0, and
was recorded as a clean skip on a machine that could have run it. The gates
are function calls now. Their verdict is an exception or the absence of one,
and output cannot imitate either.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

for _p in Path(__file__).resolve().parents:
    if (_p / "bin" / "common.sh").is_file():
        sys.path.insert(0, str(_p / "test"))
        break

from ffsim import Fail, Skip, repo_root          # noqa: E402
from ffsim.config import Config                  # noqa: E402
from ffsim.report import Reporter                # noqa: E402
from ffsim import gates                          # noqa: E402

ROOT = repo_root()
os.chdir(ROOT)


def indented(reporter):
    def emit(text):
        for line in str(text).rstrip("\n").split("\n"):
            reporter._say("  " + line + "\n")
    return emit


# ------------------------------------------------------------ static checks

def check_shell_syntax(reporter):
    """One line per check, not one per file: 25 green lines saying "syntax ok"
    hide the two that matter."""
    targets = []
    for pattern in ("bin/*.sh", "pkgs/*/payload/*.sh",
                    "pkgs/*/payload/init.d/S*", "pkgs/*/prog/*.sh",
                    "pkgs/*/prog/firmwareExe", "installer/*.sh",
                    "test/integration/printer/*.sh"):
        targets += sorted(ROOT.glob(pattern))
    broken = []
    for script in targets:
        if not script.is_file():
            continue
        parsed = subprocess.run(["bash", "-n", str(script)],
                                capture_output=True, text=True)
        if parsed.returncode != 0:
            broken.append(script.relative_to(ROOT))
            reporter._say("       %s\n" % parsed.stderr.strip())
    if broken:
        raise Fail("syntax errors in: %s"
                   % " ".join(str(path) for path in broken))
    if not targets:
        raise Fail("no scripts found to parse -- the globs are wrong")


def check_no_bashisms(reporter):
    """The payload runs on the printer's busybox ash, which is not bash.

    shellcheck's dash dialect knows every "not supported in POSIX sh"
    construct (the SC3xxx family). dash, not sh: busybox ash, like dash,
    supports `local`, which the payload uses.
    """
    if not shutil.which("shellcheck"):
        raise Fail("shellcheck not installed (the build image has it -- run "
                   "through 'make test')")
    targets = (sorted(ROOT.glob("pkgs/*/payload/*.sh"))
               + sorted(ROOT.glob("pkgs/*/payload/init.d/S*"))
               + sorted(ROOT.glob("pkgs/*/prog/*.sh"))
               + sorted(ROOT.glob("pkgs/*/prog/firmwareExe"))
               + sorted(ROOT.glob("installer/*.sh")))
    targets = [str(t) for t in targets if t.is_file()]
    # With no targets shellcheck writes usage to stderr and exits 1, leaving
    # `hits` empty -- a green gate that examined nothing. check_shell_syntax
    # guards this; this one did not, so moving these files would have retired
    # the ash-compatibility check silently.
    if not targets:
        raise Fail("no on-printer scripts found to check -- has the recipe "
                   "layout moved?")
    checked = subprocess.run(
        ["shellcheck", "-s", "dash", "-f", "gcc"] + targets,
        capture_output=True, text=True)
    hits = [line for line in (checked.stdout or "").split("\n")
            if "SC3" in line or "SC2039" in line]
    # shellcheck exits 1 for findings (which `hits` covers) but also for a
    # usage or file error, which would otherwise pass unnoticed.
    if not hits and checked.returncode not in (0, 1):
        raise Fail("shellcheck failed to run (exit %d): %s"
                   % (checked.returncode,
                      (checked.stderr or "").strip()[:200]))
    if hits:
        for ln in hits[:10]:
            reporter._say("       %s\n" % ln)
        raise Fail("bashisms in the payload")


def check_undefined_names(reporter):
    """The Python counterpart of check_shell_syntax: a name that does not
    exist anywhere it is read.

    py_compile catches typos in syntax; nothing caught typos in names, so a
    rename that renamed an assignment and missed one of its uses stayed
    green through both lanes and waited for the line to execute on the
    printer. That is how `_plate_check` came to reach for `z_trigger` when
    what it had bound was `station_z` -- on the one path that runs BEFORE a
    nozzle is allowed to descend.

    Only the fatal findings count. pyflakes also reports unused imports and
    the like, which are untidy but cannot fail at runtime, and a gate that
    goes red for those gets switched off.
    """
    # The debian package ships the module without putting a pyflakes
    # executable on PATH, so shutil.which() -- the shape the shellcheck gate
    # uses -- reports it missing on the very image that has it.
    if importlib.util.find_spec("pyflakes") is None:
        raise Fail("pyflakes not installed (the build image has it -- run "
                   "through 'make test')")
    targets = []
    for pattern in ("bin/*.py", "pkgs/*/payload/bin/*.py",
                    "pkgs/*/prog/klippy/extras/*.py", "test/*.py",
                    "test/ffsim/*.py", "test/integration/*.py"):
        targets += sorted(ROOT.glob(pattern))
    targets = [str(t) for t in targets if t.is_file()]
    # As in check_no_bashisms: with no targets the tool reports nothing and
    # the gate would pass having examined nothing at all.
    if not targets:
        raise Fail("no python files found to check -- have the globs rotted?")
    checked = subprocess.run([sys.executable, "-m", "pyflakes"] + targets,
                             capture_output=True, text=True)
    fatal = ("undefined name", "referenced before assignment",
             "syntax error", "invalid syntax")
    hits = [line for line in (checked.stdout or "").split("\n")
            if any(marker in line.lower() for marker in fatal)]
    if not hits and checked.returncode not in (0, 1):
        raise Fail("pyflakes failed to run (exit %d): %s"
                   % (checked.returncode,
                      (checked.stderr or "").strip()[:200]))
    if hits:
        for line in hits[:10]:
            reporter._say("       %s\n" % line)
        raise Fail("names used but never bound")


# ------------------------------------------------------------------- pytest

def run_pytest(reporter):
    """Counts come from the JUnit XML, not from reading the summary line.

    The shell version grepped stdout for "N skipped". That is the same
    stringly-typed protocol that made a broken launcher look skipped, and it
    is just as wrong here even though pytest is well behaved about it.
    """
    with tempfile.TemporaryDirectory() as tmp:
        results_xml = os.path.join(tmp, "results.xml")
        completed = subprocess.run(
            [sys.executable, "-m", "pytest", "./test/integration", "-q",
             "--junitxml=" + results_xml],
            capture_output=True, text=True, cwd=str(ROOT))
        if not os.path.exists(results_xml):
            raise Fail("pytest produced no results:\n%s"
                       % (completed.stdout or completed.stderr)[-2000:])
        suite = ET.parse(results_xml).getroot()
        if suite.tag == "testsuites":
            suite = suite.find("testsuite")
        total = int(suite.get("tests", 0))
        failures = int(suite.get("failures", 0)) + int(suite.get("errors", 0))
        skipped = int(suite.get("skipped", 0))

        # Which ones, and why. "5 skipped" says something is not being
        # checked without saying what, which is most of the way back to the
        # bare count this harness was rewritten to get rid of.
        names = []
        for case in suite.iter("testcase"):
            mark = case.find("skipped")
            if mark is not None:
                names.append("%s -- %s" % (case.get("name", "?"),
                                           (mark.get("message") or "").strip()
                                           or "no reason given"))

    passed = total - failures - skipped
    # A run that collected nothing is not a pass. pytest exits 5 and writes
    # tests="0", which reads as passed=0/failures=0/skipped=0 and a green gate
    # -- so renaming test/integration/, breaking a conftest import or adding a
    # collect_ignore would silently stop the whole Python lane while make test
    # and CI stayed green.
    if not total:
        raise Fail("pytest collected no tests (exit %d) -- collection is "
                   "broken, or the suite has moved" % completed.returncode)
    if failures:
        reporter._say((completed.stdout or "")[-4000:])
        raise Fail("pytest: %d failed, %d passed, %d skipped"
                   % (failures, passed, skipped))
    if skipped:
        # Consistent with the rest of the suite: a gate that did not fully run
        # must not read as success. Unlike the shell version, the numbers that
        # led to the verdict are in the verdict -- and so are the names, so
        # "pytest skipped" can be checked against what SHOULD be unrunnable
        # here rather than taken on trust.
        for line in names:
            reporter._say("       %s\n" % line)
        raise Skip("%d passed, %d skipped: %s"
                   % (passed, skipped, "; ".join(n.split(" -- ")[0]
                                                 for n in names)))
    reporter._say("  %d passed\n" % passed)


# ------------------------------------------- packaging, on a synthetic stock

def make_fixture(reporter, tmp):
    """Build the synthetic stock package and the throwaway config for it.

    Returns the environment the build steps should run under. Each of those
    steps stays its own gate: they are slow, and on a real build the line that
    says `pack` is where you are looking when you want to know how far it got.
    """
    fxdir = ROOT / "work" / ".fixture"
    # Inside the repo: the replica starts sibling containers through the
    # docker socket, and those mounts are resolved by the host daemon, where
    # a path under this container's /tmp does not exist.
    reporter.run(["./test/integration/make-stock-fixture.sh", str(fxdir)],
                 cwd=ROOT)

    stock_package = fxdir / "Creator5Pro-stock-fixture.tgz"
    if not stock_package.is_file():
        raise Fail("make-stock-fixture.sh produced no %s" % stock_package.name)

    # Stand-ins for Mainsail and HelixScreen. The real ones are a 3MB zip and
    # a 60MB tarball; the tests must not need the network, but they DO need
    # the unpack paths in patch.sh to run, so point the build at two tiny
    # archives with the same shape.
    assets = fxdir / "assets"
    (assets / "ms").mkdir(parents=True, exist_ok=True)
    (assets / "hs" / "helixscreen" / "bin").mkdir(parents=True, exist_ok=True)
    (assets / "ms" / "index.html").write_text("<html>mainsail fixture</html>\n")
    with zipfile.ZipFile(str(assets / "mainsail.zip"), "w") as z:
        z.write(str(assets / "ms" / "index.html"), "index.html")
    helix = assets / "hs" / "helixscreen" / "bin" / "helix-screen"
    helix.write_text("#!/bin/sh\n")
    helix.chmod(0o755)
    subprocess.run(["tar", "-czf", str(assets / "helixscreen.tar.gz"),
                    "-C", str(assets / "hs"), "helixscreen"], check=True)

    # And one for Moonraker. Same reason, and the same shape patch.sh expects:
    # a source tarball with one top directory, stripped, holding
    # moonraker/moonraker.py -- which patch.sh checks for by name before it
    # ships anything. Without this the fixture build dies on the missing
    # tarball, and it dies AFTER the payload is half-assembled, so what the
    # verify gate then reads is a stump: no init.d, no HelixScreen, no
    # Moonraker. That is exactly how it failed in CI while `make test` was
    # green locally against a populated vendor/.
    moonraker_fixture = assets / "mr" / "moonraker-fixture" / "moonraker"
    (moonraker_fixture / "components").mkdir(parents=True, exist_ok=True)
    (moonraker_fixture / "moonraker.py").write_text("# moonraker fixture\n")
    (moonraker_fixture / "components" / "webcam.py").write_text(
        '# "enabled"\n')
    subprocess.run(["tar", "-czf", str(assets / "moonraker.tar.gz"),
                    "-C", str(assets / "mr"), "moonraker-fixture"], check=True)

    # A throwaway config, passed through CONFIG_ENV rather than written over
    # ./config.env -- which would put the config you edited one crashed run
    # away from being replaced by a fixture one.
    config_file = Path(tmp) / "config.env"
    # BUILD_KLIPPER=stock, BY NAME: this job must not need the network, and
    # the fork path needs the pinned tarball plus the ~203MB toolchain from
    # vendor/. Named explicitly because patch.sh refuses to fall back silently
    # -- a fork build that quietly kept the stock tree is how v20260824 shipped
    # without its Klipper. The fork path is exercised where vendor/ exists: the
    # printer-sim job and the release workflow.
    config_file.write_text(
        "MOD_NAME=anvil\n"
        "MOD_VER=ci\n"
        'SW_VER=""\n'
        'STOCK_TGZ="%s"\n'
        "BUILD_KLIPPER=stock\n"
        'HELIX_TGZ="%s"\n'
        'MAINSAIL_ZIP="%s"\n'
        'MOONRAKER_TGZ="%s"\n'
        'BUSYBOX_BIN=""\n'
        "TARGET_MACHINE=Creator5Pro\n"
        "ROOT_PW_HASH='$6$ci$abcdefghijklmnopqrstuvwxyz'\n"
        "FF_KEY='FFP0331&*%%root'\n"
        # A FEED OF ITS OWN, for the same reason the config is a throwaway.
        # The payload is assembled by installing packages, so this lane builds
        # them -- and it builds them from a config that renames every package
        # carrying MOD_VER and points three recipes at fixture assets. Sharing
        # work/packages would leave anvil-core_ci-1 where the developer's
        # anvil-core_<date>-1 was, and bin/build-packages.sh's prune would
        # delete the rest of their feed on the way past. Measured, the first
        # time this lane ran: 44 packages became 43, all renamed.
        'PKG_FEED="%s"\n'
        % (stock_package, assets / "helixscreen.tar.gz",
           assets / "mainsail.zip",
           assets / "moonraker.tar.gz",
           fxdir / "packages"))

    return dict(os.environ, CONFIG_ENV=str(config_file),
                TARGET_MACHINE="Creator5Pro")


# --------------------------------------------------------------------- main

def main():
    reporter = Reporter()
    emit = indented(reporter)
    config = Config.load(ROOT)

    reporter.hdr("shell syntax")
    with reporter.gate("every script parses"):
        check_shell_syntax(reporter)

    reporter.hdr("no bashisms in the on-printer payload")
    with reporter.gate("no bash-only constructs in the payload"):
        check_no_bashisms(reporter)

    stock = config.stock_for()

    # Extract before pytest: test_paths.py reads the rootfs directly and needs
    # no docker, so doing this first is what lets a single pytest run cover
    # both the config gate and the rootfs checks. This is also the unpack the
    # replica gates need later.
    if stock:
        reporter.hdr("extracting the printer rootfs")
        if (ROOT / "work" / "rootfs" / "bin").is_dir():
            reporter.ok("rootfs already extracted")
        else:
            with reporter.gate("extract the printer rootfs"):
                reporter.run(["./bin/unpack.sh"], cwd=ROOT)
                gates.extract_rootfs(config, on_output=emit)

    reporter.hdr("python checks")
    with reporter.gate("every name resolves"):
        check_undefined_names(reporter)

    with reporter.gate("pytest"):
        run_pytest(reporter)

    with tempfile.TemporaryDirectory() as tmp:
        reporter.hdr("packaging, on a synthetic stock package")
        env = None
        with reporter.gate("synthetic stock package"):
            env = make_fixture(reporter, tmp)

        reporter.hdr("build on the fixture")
        if env is None:
            # The fixture is the input to every step below. Without it they
            # would each fail for the same reason, which reads as four
            # separate problems instead of one.
            with reporter.gate("build on the fixture"):
                raise Fail("no fixture -- the steps below cannot run")
        else:
            # Stop at the first step that fails. These are a chain, not four
            # independent checks: a patch.sh that died half way leaves a
            # half-assembled payload behind, and running verify.sh over it
            # reports the missing pieces as separate failures -- "no init.d",
            # "no HelixScreen" -- which describe the wreckage rather than the
            # cause. The steps after a break are not registered as skipped
            # gates: a skip here would ask to be accepted by name in
            # ALLOW_SKIP, and nothing about a failed build should need that.
            # Counted from here, not from zero: an earlier gate (pytest, say)
            # may already have failed, and that is not a reason to skip the
            # build.
            failures_before = reporter.failed
            broken = False
            # build-packages FIRST, and under the FIXTURE's config. The payload
            # is assembled by installing the feed, so patch.sh needs .ipk files
            # that match the config it is running under -- and this config is
            # not the developer's: MOD_VER=ci alone renames every package whose
            # version is the release date, so a feed built from config.env
            # resolves to filenames that do not exist here. It also points
            # MAINSAIL_ZIP and friends at the tiny stand-ins make_fixture
            # writes, which is what keeps this lane off the network.
            #
            # Cheap in practice: the pinned third-party recipes are keyed on
            # their own versions and stay cached, so what actually rebuilds is
            # the handful of packages carrying MOD_VER or a fixture asset.
            for step in ("build-packages", "unpack", "patch", "pack"):
                with reporter.gate(step):
                    reporter.run(["./bin/%s.sh" % step], cwd=ROOT, env=env)
                if reporter.failed > failures_before:
                    broken = True
                    break
            if not broken:
                with reporter.gate("verify"):
                    packages = sorted(
                        (ROOT / "work" / "out").glob("Creator5Pro-*.tgz"))
                    if not packages:
                        raise Fail("no package produced")
                    reporter.run(["./bin/verify.sh", str(packages[0])],
                                 cwd=ROOT, env=env)

    # Throw away everything the fixture half built. bin/ hardcodes work/, so
    # those packages land in the same work/out a real build uses -- and a
    # 380KB Creator5Pro-anvil-ci.tgz sitting there is one `make test-install`
    # away from being mistaken for something shippable.
    for d in ("out", "stage", "software", "outer", "modpayload-root"):
        shutil.rmtree(str(ROOT / "work" / d), ignore_errors=True)

    if not stock:
        reporter.hdr("printer replica")
        with reporter.gate("the printer replica"):
            raise Skip("no stock package in config.env -- these are the gates "
                       "that decide whether a package bricks a printer")
    else:
        reporter.hdr("MCU bring-up runs on the printer's own Python")
        with reporter.gate("mcu bring-up"):
            gates.mcu_bringup(config, on_output=emit)

        with reporter.gate("boot screen"):
            gates.boot_screen(config, on_output=emit)

        with reporter.gate("moonraker"):
            gates.moonraker(config, on_output=emit)

        with reporter.gate("s6 supervises, waits and reports"):
            gates.supervisor(config, on_output=emit)

        # Runs even though nothing on the printer uses this interpreter yet:
        # a shipped artefact that nothing exercises is a shipped artefact
        # nobody notices rotting. See the header of case-python.sh.
        with reporter.gate("cpython 3.13 runs, with a working sqlite3"):
            gates.python(config, on_output=emit)

        # And the one that puts all four real things together -- the real
        # Moonraker, on that interpreter, under the real s6, started by the
        # real init script. It is the slowest gate here and it is the one
        # whose failure means "do not switch FF_PYTHON", so it runs beside
        # the interpreter gate rather than at the end where a timeout would
        # take it out first.
        with reporter.gate("moonraker on 3.13, supervised"):
            gates.moonraker313_s6(config, on_output=emit)

        with reporter.gate("nginx under s6"):
            gates.nginx(config, on_output=emit)

        with reporter.gate("camera readiness under s6"):
            gates.camera(config, on_output=emit)

        with reporter.gate("init.d services"):
            gates.services(config, on_output=emit)

        with reporter.gate("the library path is what it claims"):
            gates.libpath(config, on_output=emit)

        with reporter.gate("upgrade keeps what it did not install"):
            gates.upgrade(config, on_output=emit)

        reporter.hdr("end-to-end update on the printer replica")
        with reporter.gate("boot -> install -> re-install -> boot"):
            for step in ("unpack", "patch", "pack"):
                reporter.run(["./bin/%s.sh" % step], cwd=ROOT)
            packages = sorted((ROOT / "work" / "out").glob("*-*.tgz"))
            if not packages:
                raise Fail("no package produced")
            gates.install(config, str(packages[0]), on_output=emit)

        reporter.hdr("recovery: a stock package reverts the mod")
        with reporter.gate("install mod -> flash stock -> back to stock"):
            packages = sorted((ROOT / "work" / "out").glob("*-*.tgz"))
            if not packages:
                raise Fail("no package produced")
            gates.roundtrip(config, str(packages[0]), stock, on_output=emit)

    return reporter.summary()


if __name__ == "__main__":
    sys.exit(main())
