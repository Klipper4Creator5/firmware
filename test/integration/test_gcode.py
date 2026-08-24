"""The feature-verification print must name commands this firmware has.

bin/gen-test-gcode.py writes a print whose whole job is to exercise the macros
the mod adds. That makes it the one artifact in the repo that goes stale
silently: rename START_PRINT or drop TOOL_OFFSET_STATUS and the generator still
produces a perfectly well-formed file, which then dies on the printer four
minutes into a heat-up with a tool already grabbed.

So the checks here are the two the file cannot check for itself -- that every
command in it is one the shipped configs and extras actually define, and that
every coordinate is one the machine can reach. Both read the real payload;
neither needs the proprietary package.
"""
import os
import re
import subprocess
import sys

import pytest

from ffcfg import sections

# Klipper's own commands. Everything else in the file has to come from the
# payload, which is what test_every_command_is_defined proves.
KLIPPER_BUILTINS = {"SET_PRESSURE_ADVANCE"}

MACRO = re.compile(r"^gcode_macro (\S+)$")
REGISTERED = re.compile(r"register_command\(\s*['\"]([A-Z0-9_]+)['\"]")
# A G-code word: G1, M106, T2. Anything else is a named command.
GCODE_WORD = re.compile(r"^[GMT]\d+$")
COORD = re.compile(r"\b([XYZ])(-?\d+(?:\.\d+)?)")


@pytest.fixture(scope="session")
def generated(tmp_path_factory, root):
    """The default file, straight from the generator."""
    out = tmp_path_factory.mktemp("gcode") / "feature-test.gcode"
    subprocess.run(
        [sys.executable, os.path.join(root, "bin", "gen-test-gcode.py"),
         "--out", str(out)],
        check=True, capture_output=True)
    return out.read_text(encoding="utf-8").splitlines()


@pytest.fixture(scope="session")
def defined(root, cfgdir):
    """Every command name the payload defines, config and Python alike."""
    names = set(KLIPPER_BUILTINS)
    for cfg in sorted(os.listdir(cfgdir)):
        if not cfg.endswith(".cfg"):
            continue
        for section, _ in sections(os.path.join(cfgdir, cfg)):
            m = MACRO.match(section)
            if m:
                names.add(m.group(1).upper())
    extras = os.path.join(root, "payload", "klipper", "extras")
    for py in sorted(os.listdir(extras)):
        if py.endswith(".py"):
            src = open(os.path.join(extras, py), encoding="utf-8").read()
            names.update(REGISTERED.findall(src))
    return names


@pytest.fixture(scope="session")
def limits(cfgdir):
    """position_min/position_max per axis, from the printer's own config."""
    out = {}
    path = os.path.join(cfgdir, "printer.base.cfg")
    for section, opts in sections(path):
        if section.startswith("stepper_"):
            axis = section.split("_", 1)[1].upper()
            lo = opts.get("position_min")
            hi = opts.get("position_max")
            if lo is not None and hi is not None:
                out[axis] = (float(lo.split(";")[0]), float(hi.split(";")[0]))
    assert set(out) == {"X", "Y", "Z"}, out
    return out


def commands(lines):
    """(lineno, word, rest) for each executable line."""
    for n, raw in enumerate(lines, 1):
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        word, _, rest = line.partition(" ")
        yield n, word.upper(), rest


def test_every_command_is_defined(generated, defined):
    """A macro rename must break this file here, not on the printer."""
    unknown = sorted({word for _, word, _ in commands(generated)
                      if not GCODE_WORD.match(word) and word not in defined})
    assert not unknown, (
        "the test print calls commands nothing in payload/ defines: %s"
        % ", ".join(unknown))


def test_toolchange_macros_are_the_real_ones(generated, defined):
    """The point of the file is the macros the mod adds -- prove it calls them.

    Without this the first test passes on a file that calls nothing but
    builtins, which is a well-formed print and a worthless verification.
    """
    called = {word for _, word, _ in commands(generated)}
    for required in ("START_PRINT", "END_PRINT", "TOOLCHANGE_STATUS",
                     "TOOL_OFFSET_STATUS", "M141"):
        assert required in called, "%s is not exercised by the test print" % required


def test_tools_param_matches_the_tools_used(generated):
    """START_PRINT TOOLS= is the preflight gate: it has to list every tool.

    A tool missing from TOOLS= is not purged, not wiped and not checked for
    presence -- it fails at its grab, mid-print, with filament down.
    """
    used = {int(word[1:]) for _, word, _ in commands(generated)
            if re.match(r"^T\d$", word)}
    start = [rest for _, word, rest in commands(generated) if word == "START_PRINT"]
    assert len(start) == 1, start
    m = re.search(r"TOOLS=(\S+)", start[0])
    assert m, start[0]
    declared = {int(part.split(":")[0]) for part in m.group(1).split(",")}
    assert declared == used, (
        "START_PRINT TOOLS=%s but the file uses %s"
        % (sorted(declared), sorted(used)))


def test_moves_stay_inside_the_machine(generated, limits):
    """Every coordinate within the axis limits Klipper is configured with.

    The generator keeps the printed shapes well inside the bed, but the prime
    lines deliberately reach out to X256 where the machine's own start block
    primes, so 'inside the bed' is the wrong bound to assert. The stepper
    limits are the real one: past them Klipper aborts the print.
    """
    bad = []
    for n, word, rest in commands(generated):
        if word not in ("G0", "G1"):
            continue
        for axis, value in COORD.findall(rest):
            lo, hi = limits[axis]
            if not lo <= float(value) <= hi:
                bad.append("line %d: %s%s outside %s %.1f..%.1f"
                           % (n, axis, value, axis, lo, hi))
    assert not bad, "\n".join(bad)


def test_relative_extrusion_is_never_left_absolute(generated):
    """The start block sets M83 and every E in the body is an increment.

    An M82 anywhere after it would turn the first E of the next move into an
    absolute target -- a single retraction becomes a 100 mm unspooling.
    """
    for n, word, _ in commands(generated):
        assert word != "M82", "line %d switches to absolute E mid-file" % n
