"""Every script parses, and none of them is secretly bash.

Ported from test/run-tests.py's check_shell_syntax and check_no_bashisms. The
logic is theirs; what changes is the granularity. There, one gate covered ~25
files and reported one bit, so a syntax error in S62moonraker and a syntax
error in patch.sh were the same red line. Here each file is its own test, named
after itself, and `pytest -k S62moonraker` runs exactly one.

The original's docstring made a deliberate choice worth preserving:

    One line per check, not one per file: 25 green lines saying "syntax ok"
    hide the two that matter.

That reasoning was about output noise, and it was right. pytest solves it a
different way -- passes collapse to dots, and only failures print -- so the
granularity and the quiet are no longer in tension.

WHY THE PAYLOAD IS CHECKED TWICE, WITH DIFFERENT DIALECTS

`bash -n` proves a file parses at all. shellcheck's dash dialect proves it uses
nothing bash-only, which is what matters for anything a recipe ships: the
printer runs busybox ash, not bash, and a bash-only construct parses perfectly
here and fails there. dash rather than sh as the dialect because busybox ash,
like dash, supports `local`, which the payload uses.
"""
import importlib.util
import os
import shutil
import subprocess
import sys

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static


# ------------------------------------------------------------------ the sets

# Everything that must at least parse. bin/ and test/ run under bash on the
# build image; the printer's scripts run under its ash but bash parses them
# too, and a file that does not parse under either is broken beyond dialect.
#
# THE PRINTER'S SCRIPTS ARE ADDRESSED BY THE SHAPE OF A RECIPE, not by a
# top-level directory: pkgs/<recipe>/payload/ is what that recipe installs
# under $MODDIR and pkgs/<recipe>/prog/ is what bin/patch.sh places on
# /usr/prog. Both run on the printer; neither is named recipe by recipe here,
# so a new recipe with scripts in it is covered the day it lands.
SYNTAX_GLOBS = ("bin/*.sh", "pkgs/*/payload/*.sh", "pkgs/*/payload/init.d/S*",
                "pkgs/*/prog/*.sh", "pkgs/*/prog/firmwareExe", "installer/*.sh",
                "test/integration/printer/*.sh",
                "qa/replica/actions/*.sh",
                # BOTH RECIPE LEVELS. pkgs/*/build.sh alone silently
                # stopped covering thirty-four of the thirty-eight the day
                # they moved under 3rdparty/ -- a glob that matches fewer
                # files does not fail, it just checks less. _files() now
                # refuses a pattern that matches nothing, so the next one
                # fails instead of quietly shrinking.
                "pkgs/*.sh", "pkgs/*/build.sh", "pkgs/3rdparty/*/build.sh",
                "pkgs/ipk-install")

# The subset executed by the printer's busybox ash. bin/ and test/ are
# deliberately absent: they run on the build image, where bash is the shell and
# a bashism is not a defect.
#
# qa/replica/actions/ IS here, and that is not a formality. Those scripts are
# handed to entrypoint.sh and run inside the chroot exactly as a case script
# is, so they are as exposed to ash as anything under payload/. A bashism in
# hold.sh would fail at container start and read as "the replica is broken on
# this machine" -- a harness failure wearing a machine failure's clothes, which
# is the hardest kind to diagnose.
# pkgs/ipk-install is here and pkgs/*/build.sh is deliberately not. The recipes
# are build-host bash, like everything in bin/; the installer is the one file
# under pkgs/ that the PRINTER runs, so it is as exposed to busybox ash as
# anything a recipe ships -- and it is not under a recipe's payload/ only
# because the PoC does not ship it yet (docs/notes/85-packaging.md, phase 2).
# A bashism in it would be found by the printer rather than by this lane.
#
# installer/ is here too: run-pre.sh and run-append.sh are spliced into
# FlashForge's own run.sh and execute inside the stock installer's shell,
# which is the same busybox.
#
# NOT here, and it is a real gap rather than a decision:
# pkgs/*/payload/bin/*.sh. wifi-action.sh runs on the printer and no lane
# checks its dialect. It was not covered before the recipe layout either --
# the old glob was payload/*.sh, one level up from it -- so adding it belongs
# with the fix, not with a move.
ASH_GLOBS = ("pkgs/*/payload/*.sh", "pkgs/*/payload/init.d/S*",
             "pkgs/*/prog/*.sh", "pkgs/*/prog/firmwareExe", "installer/*.sh",
             "qa/replica/actions/*.sh", "pkgs/ipk-install")

PY_GLOBS = ("bin/*.py", "pkgs/*/payload/bin/*.py",
            "pkgs/*/payload/klipper/klippy/extras/*.py", "test/*.py", "test/ffsim/*.py",
            "test/integration/*.py", "qa/*.py", "qa/lib/*.py",
            "qa/static/*.py", "qa/replica/*.py")


def _files(globs):
    """Expand the globs, and refuse one that matches nothing.

    A glob that stops matching does not fail -- it checks less, and the lane
    stays green while doing it. That is not hypothetical: moving thirty-four
    recipes under pkgs/3rdparty/ left "pkgs/*/build.sh" matching the four that
    had not moved, and the only visible sign was a test count dropping by
    thirty-four in a run nobody was counting.

    So an empty pattern is a collection error, which is as loud as this file
    can be, and the message says the two things that cause it: a file that
    moved, or a pattern that was never right.
    """
    found = []
    for pattern in globs:
        hits = sorted(p for p in ROOT.glob(pattern) if p.is_file())
        if not hits:
            raise AssertionError(
                "%r matches no files -- either something moved and this "
                "pattern did not follow it, or the pattern is wrong. Either "
                "way this lane was checking less than it claimed." % pattern)
        found += hits
    return found


def _ids(paths):
    return [str(p.relative_to(ROOT)) for p in paths]


SHELL_FILES = _files(SYNTAX_GLOBS)
ASH_FILES = _files(ASH_GLOBS)
PY_FILES = _files(PY_GLOBS)


# --------------------------------------------------------- the globs are live
#
# Each lane below asserts its own inputs exist. This is not defensive noise: it
# is the exact bug the original guarded against, quoted from check_no_bashisms:
#
#     With no targets shellcheck writes usage to stderr and exits 1, leaving
#     `hits` empty -- a green gate that examined nothing. check_shell_syntax
#     guards this; this one did not, so moving payload/ would have retired the
#     ash-compatibility check silently.
#
# Parametrized tests fail the same way, and worse: zero parameters is zero
# tests, which is not even a red line. It is an empty run that reads as clean.

def test_shell_globs_match_something():
    assert SHELL_FILES, "no scripts to parse -- the globs in SYNTAX_GLOBS rotted"


def test_ash_globs_match_something():
    assert ASH_FILES, "no on-printer scripts -- has the recipe layout moved?"


def test_python_globs_match_something():
    assert PY_FILES, "no python files -- have the globs in PY_GLOBS rotted?"


ACTIONS = sorted((ROOT / "qa" / "replica" / "actions").glob("*.sh"))


@pytest.mark.parametrize("script", ACTIONS, ids=_ids(ACTIONS))
def test_action_scripts_are_executable(script):
    """qa/replica/actions/*.sh are handed to docker, not sourced.

    bake.sh is a `--entrypoint` and the others are mounted in and run, so a
    missing executable bit is not a style problem -- the container dies at
    init with `exec: permission denied` before a single test runs, and the
    43 errors that follow all say "could not install the package", which
    points at the installer rather than at a file mode.

    Caught here because it happened: bake.sh was written without the bit and
    the whole lane failed in 1.6 seconds with an error about the mod. It is
    the same failure the payload's own s6 `run` scripts have a check for --
    "s6 reports a non-executable run in its own log and nowhere else" -- and
    it deserved the same treatment here.
    """
    assert os.access(str(script), os.X_OK), (
        "%s is not executable, so docker cannot run it. `chmod +x` it and "
        "commit the mode." % script.name)


# ------------------------------------------------------------------- it parses

@pytest.mark.parametrize("script", SHELL_FILES, ids=_ids(SHELL_FILES))
def test_parses(script):
    parsed = subprocess.run(["bash", "-n", str(script)],
                            capture_output=True, text=True)
    assert parsed.returncode == 0, parsed.stderr.strip()


# ------------------------------------------------------ it is not secretly bash

@pytest.fixture(scope="session")
def bashisms():
    """shellcheck over every payload script at once, indexed by file.

    One process, not one per file. shellcheck spends most of a run starting
    up, so per-file invocation cost more than everything else in this lane
    combined -- but per-file REPORTING is the whole point of the port. The
    gcc output format is `path:line:col: level: message [SCxxxx]`, so the
    findings can be split back apart by path afterwards and each test can ask
    only about itself.
    """
    # A failure, not a skip. There is no configuration in which running this
    # suite without shellcheck is a complete run, so calling it "skipped" would
    # describe a machine that is not set up as though it were a decision
    # somebody made. See qa/conftest.py.
    #
    # pytest.fail rather than a bare assert on which(): `assert None` is what
    # an assert would lead with, and the sentence explaining how to fix it
    # would be the part that got truncated in the summary.
    if not shutil.which("shellcheck"):
        pytest.fail(
            "shellcheck is not installed, so nothing checked that the payload "
            "is free of bash-only constructs -- the printer runs busybox ash. "
            "The build image has it: run `make qa`, or install it locally "
            "(dnf install ShellCheck / apt install shellcheck).")

    checked = subprocess.run(
        ["shellcheck", "-s", "dash", "-f", "gcc"]
        + [str(p) for p in ASH_FILES],
        capture_output=True, text=True, cwd=str(ROOT))

    # SC3xxx is shellcheck's "not supported in POSIX sh" family; SC2039 is its
    # older spelling of the same thing. Everything else it says here is style,
    # and a gate that goes red for style gets switched off.
    found = {}
    for line in (checked.stdout or "").splitlines():
        if "SC3" not in line and "SC2039" not in line:
            continue
        path = line.split(":", 1)[0]
        found.setdefault(path, []).append(line)

    # shellcheck exits 1 for findings, which `found` covers, but also for a
    # usage or file error -- which would otherwise pass unnoticed as "no
    # findings". Raised here rather than returned so it fails every test in
    # the lane instead of hiding behind whichever file happens to be clean.
    if not found and checked.returncode not in (0, 1):
        raise AssertionError(
            "shellcheck failed to run (exit %d): %s"
            % (checked.returncode, (checked.stderr or "").strip()[:200]))
    return found


@pytest.mark.parametrize("script", ASH_FILES, ids=_ids(ASH_FILES))
def test_no_bash_only_constructs(script, bashisms):
    # shellcheck echoes back the path it was given. It was given absolute
    # paths, but match on both spellings so a future cwd-relative call site
    # does not silently stop matching and report every file clean.
    rel = str(script.relative_to(ROOT))
    hits = bashisms.get(str(script), []) + bashisms.get(rel, [])
    assert not hits, "bash-only constructs:\n  " + "\n  ".join(hits)


# ------------------------------------------------------- every name is bound

# One test, not one per file: pyflakes resolves names within a module, so the
# per-file split buys nothing here and costs an interpreter start each. The
# failure message names the files itself.
def test_no_undefined_names():
    """A name that does not exist anywhere it is read.

    py_compile catches typos in syntax; nothing caught typos in names, so a
    rename that renamed an assignment and missed one of its uses stayed green
    through both lanes and waited for the line to execute on the printer. That
    is how `_plate_check` came to reach for `z_trigger` when what it had bound
    was `station_z` -- on the one path that runs BEFORE a nozzle is allowed to
    descend.
    """
    # The debian package ships the module without putting a pyflakes
    # executable on PATH, so shutil.which() -- the shape the shellcheck test
    # above uses -- reports it missing on the very image that has it.
    #
    # A failure, not a skip, for the same reason as shellcheck above.
    if importlib.util.find_spec("pyflakes") is None:
        pytest.fail(
            "pyflakes is not installed, so nothing checked that every name is "
            "bound -- which is the gate that catches a rename missing one of "
            "its uses. The build image has it: run `make qa`, or install it "
            "locally (apt install python3-pyflakes / pip install pyflakes).")

    checked = subprocess.run(
        [sys.executable, "-m", "pyflakes"] + [str(p) for p in PY_FILES],
        capture_output=True, text=True, cwd=str(ROOT))

    # Only the fatal findings count. pyflakes also reports unused imports and
    # the like, which are untidy but cannot fail at runtime.
    fatal = ("undefined name", "referenced before assignment",
             "syntax error", "invalid syntax")
    hits = [line for line in (checked.stdout or "").splitlines()
            if any(marker in line.lower() for marker in fatal)]

    assert hits or checked.returncode in (0, 1), (
        "pyflakes failed to run (exit %d): %s"
        % (checked.returncode, (checked.stderr or "").strip()[:200]))

    assert not hits, "names used but never bound:\n  " + "\n  ".join(hits)
