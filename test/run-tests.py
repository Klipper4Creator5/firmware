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

def check_shell_syntax(r):
    """One line per check, not one per file: 25 green lines saying "syntax ok"
    hide the two that matter."""
    targets = []
    for pattern in ("bin/*.sh", "payload/*.sh", "payload/init.d/S*",
                    "payload/firmwareExe", "test/integration/printer/*.sh"):
        targets += sorted(ROOT.glob(pattern))
    bad = []
    for f in targets:
        if not f.is_file():
            continue
        proc = subprocess.run(["bash", "-n", str(f)],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            bad.append(f.relative_to(ROOT))
            r._say("       %s\n" % proc.stderr.strip())
    if bad:
        raise Fail("syntax errors in: %s" % " ".join(str(b) for b in bad))
    if not targets:
        raise Fail("no scripts found to parse -- the globs are wrong")


def check_no_bashisms(r):
    """The payload runs on the printer's busybox ash, which is not bash.

    shellcheck's dash dialect knows every "not supported in POSIX sh"
    construct (the SC3xxx family). dash, not sh: busybox ash, like dash,
    supports `local`, which the payload uses.
    """
    if not shutil.which("shellcheck"):
        raise Fail("shellcheck not installed (the build image has it -- run "
                   "through 'make test')")
    targets = (sorted(ROOT.glob("payload/*.sh"))
               + sorted(ROOT.glob("payload/init.d/S*"))
               + [ROOT / "payload" / "firmwareExe"])
    targets = [str(t) for t in targets if t.is_file()]
    # With no targets shellcheck writes usage to stderr and exits 1, leaving
    # `hits` empty -- a green gate that examined nothing. check_shell_syntax
    # guards this; this one did not, so moving payload/ would have retired the
    # ash-compatibility check silently.
    if not targets:
        raise Fail("no payload scripts found to check -- has payload/ moved?")
    proc = subprocess.run(["shellcheck", "-s", "dash", "-f", "gcc"] + targets,
                          capture_output=True, text=True)
    hits = [ln for ln in (proc.stdout or "").split("\n")
            if "SC3" in ln or "SC2039" in ln]
    # shellcheck exits 1 for findings (which `hits` covers) but also for a
    # usage or file error, which would otherwise pass unnoticed.
    if not hits and proc.returncode not in (0, 1):
        raise Fail("shellcheck failed to run (exit %d): %s"
                   % (proc.returncode, (proc.stderr or "").strip()[:200]))
    if hits:
        for ln in hits[:10]:
            r._say("       %s\n" % ln)
        raise Fail("bashisms in the payload")


# ------------------------------------------------------------------- pytest

def run_pytest(r):
    """Counts come from the JUnit XML, not from reading the summary line.

    The shell version grepped stdout for "N skipped". That is the same
    stringly-typed protocol that made a broken launcher look skipped, and it
    is just as wrong here even though pytest is well behaved about it.
    """
    with tempfile.TemporaryDirectory() as tmp:
        xml = os.path.join(tmp, "results.xml")
        proc = subprocess.run(
            [sys.executable, "-m", "pytest", "./test/integration", "-q",
             "--junitxml=" + xml],
            capture_output=True, text=True, cwd=str(ROOT))
        if not os.path.exists(xml):
            raise Fail("pytest produced no results:\n%s"
                       % (proc.stdout or proc.stderr)[-2000:])
        suite = ET.parse(xml).getroot()
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
    # tests="0", which used to give passed=0/failures=0/skipped=0 and a green
    # gate -- so renaming test/integration/, breaking a conftest import or
    # adding a collect_ignore would silently stop the whole Python lane while
    # make test and CI stayed green. That is the exact failure this harness
    # was written to end (see test-abi.sh in docs/testing.md).
    if not total:
        raise Fail("pytest collected no tests (exit %d) -- collection is "
                   "broken, or the suite has moved" % proc.returncode)
    if failures:
        r._say((proc.stdout or "")[-4000:])
        raise Fail("pytest: %d failed, %d passed, %d skipped"
                   % (failures, passed, skipped))
    if skipped:
        # Consistent with the rest of the suite: a gate that did not fully run
        # must not read as success. Unlike the shell version, the numbers that
        # led to the verdict are in the verdict -- and so are the names, so
        # "pytest skipped" can be checked against what SHOULD be unrunnable
        # here rather than taken on trust.
        for line in names:
            r._say("       %s\n" % line)
        raise Skip("%d passed, %d skipped: %s"
                   % (passed, skipped, "; ".join(n.split(" -- ")[0]
                                                 for n in names)))
    r._say("  %d passed\n" % passed)


# ------------------------------------------- packaging, on a synthetic stock

def make_fixture(r, tmp):
    """Build the synthetic stock package and the throwaway config for it.

    Returns the environment the build steps should run under. Each of those
    steps stays its own gate: they are slow, and on a real build the line that
    says `pack` is where you are looking when you want to know how far it got.
    """
    fxdir = ROOT / "work" / ".fixture"
    # Inside the repo: the replica starts sibling containers through the
    # docker socket, and those mounts are resolved by the host daemon, where
    # a path under this container's /tmp does not exist.
    r.run(["./test/integration/make-stock-fixture.sh", str(fxdir)], cwd=ROOT)

    fixture = fxdir / "Creator5Pro-stock-fixture.tgz"
    if not fixture.is_file():
        raise Fail("make-stock-fixture.sh produced no %s" % fixture.name)

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
    mr = assets / "mr" / "moonraker-fixture" / "moonraker"
    (mr / "components").mkdir(parents=True, exist_ok=True)
    (mr / "moonraker.py").write_text("# moonraker fixture\n")
    (mr / "components" / "webcam.py").write_text('# "enabled"\n')
    subprocess.run(["tar", "-czf", str(assets / "moonraker.tar.gz"),
                    "-C", str(assets / "mr"), "moonraker-fixture"], check=True)

    # A throwaway config, passed through CONFIG_ENV. It used to overwrite
    # ./config.env and copy it back afterwards, which put the config you
    # edited one crashed run away from being replaced by a fixture one.
    cfg = Path(tmp) / "config.env"
    # BUILD_KLIPPER=stock, BY NAME: this job must not need the network, and
    # the fork path needs the pinned tarball plus the ~203MB toolchain from
    # vendor/. patch.sh no longer falls back silently -- KLIPPER_FORK="" here
    # used to mean "quietly keep the stock tree", which is exactly how
    # v20260824 shipped without its Klipper. The fork path is exercised where
    # vendor/ exists: the printer-sim job and the release workflow.
    cfg.write_text(
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
        % (fixture, assets / "helixscreen.tar.gz", assets / "mainsail.zip",
           assets / "moonraker.tar.gz"))

    return dict(os.environ, CONFIG_ENV=str(cfg), TARGET_MACHINE="Creator5Pro")


# --------------------------------------------------------------------- main

def main():
    r = Reporter()
    emit = indented(r)
    config = Config.load(ROOT)

    r.hdr("shell syntax")
    with r.gate("every script parses"):
        check_shell_syntax(r)

    r.hdr("no bashisms in the on-printer payload")
    with r.gate("no bash-only constructs in the payload"):
        check_no_bashisms(r)

    stock = config.stock_for()

    # Extract before pytest: test_paths.py reads the rootfs directly and needs
    # no docker, so doing this first is what lets a single pytest run cover
    # both the config gate and the rootfs checks. This is also the unpack the
    # replica gates need later.
    if stock:
        r.hdr("extracting the printer rootfs")
        if (ROOT / "work" / "rootfs" / "bin").is_dir():
            r.ok("rootfs already extracted")
        else:
            with r.gate("extract the printer rootfs"):
                r.run(["./bin/unpack.sh"], cwd=ROOT)
                gates.extract_rootfs(config, on_output=emit)

    r.hdr("python checks")
    with r.gate("pytest"):
        run_pytest(r)

    with tempfile.TemporaryDirectory() as tmp:
        r.hdr("packaging, on a synthetic stock package")
        env = None
        with r.gate("synthetic stock package"):
            env = make_fixture(r, tmp)

        r.hdr("build on the fixture")
        if env is None:
            # The fixture is the input to every step below. Without it they
            # would each fail for the same reason, which reads as four
            # separate problems instead of one.
            with r.gate("build on the fixture"):
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
            failures_before = r.failed
            broken = False
            for step in ("unpack", "patch", "pack"):
                with r.gate(step):
                    r.run(["./bin/%s.sh" % step], cwd=ROOT, env=env)
                if r.failed > failures_before:
                    broken = True
                    break
            if not broken:
                with r.gate("verify"):
                    pkgs = sorted((ROOT / "work" / "out").glob("Creator5Pro-*.tgz"))
                    if not pkgs:
                        raise Fail("no package produced")
                    r.run(["./bin/verify.sh", str(pkgs[0])], cwd=ROOT, env=env)

    # Throw away everything the fixture half built. bin/ hardcodes work/, so
    # those packages land in the same work/out a real build uses -- and a
    # 380KB Creator5Pro-anvil-ci.tgz sitting there is one `make test-install`
    # away from being mistaken for something shippable.
    for d in ("out", "stage", "software", "outer", "modpayload"):
        shutil.rmtree(str(ROOT / "work" / d), ignore_errors=True)

    if not stock:
        r.hdr("printer replica")
        with r.gate("the printer replica"):
            raise Skip("no stock package in config.env -- these are the gates "
                       "that decide whether a package bricks a printer")
    else:
        r.hdr("MCU bring-up runs on the printer's own Python")
        with r.gate("mcu bring-up"):
            gates.mcu_bringup(config, on_output=emit)

        with r.gate("boot screen"):
            gates.boot_screen(config, on_output=emit)

        r.hdr("end-to-end update on the printer replica")
        with r.gate("boot -> install -> re-install -> boot"):
            for step in ("unpack", "patch", "pack"):
                r.run(["./bin/%s.sh" % step], cwd=ROOT)
            pkgs = sorted((ROOT / "work" / "out").glob("*-*.tgz"))
            if not pkgs:
                raise Fail("no package produced")
            gates.install(config, str(pkgs[0]), on_output=emit)

        r.hdr("recovery: a stock package reverts the mod")
        with r.gate("install mod -> flash stock -> back to stock"):
            pkgs = sorted((ROOT / "work" / "out").glob("*-*.tgz"))
            if not pkgs:
                raise Fail("no package produced")
            gates.roundtrip(config, str(pkgs[0]), stock, on_output=emit)

    return r.summary()


if __name__ == "__main__":
    sys.exit(main())
