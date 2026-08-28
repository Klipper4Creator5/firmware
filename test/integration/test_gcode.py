"""The files in gcode/ must name commands this firmware has.

gcode/ holds the two files you send to a printer to prove the mod works:
creator5-safe-moves.gcode, which is cold and stays 50 mm above the plate, and
creator5-feature-test.gcode, which prints. They are hand-maintained G-code,
which makes them the one artifact in the repo that goes stale silently: rename
START_PRINT or drop TOOL_OFFSET_STATUS and both files still look perfectly
well-formed, and then die on the printer four minutes into a heat-up with a
tool already grabbed.

So the checks here are the ones the files cannot make for themselves -- that
every command in them is one the shipped configs and extras define, and that
every coordinate is one the machine can reach. The safe file gets two more,
because "cold, and never below Z50" is its entire reason to exist and is
exactly the property an edit would quietly break.

All of it reads the real payload; none of it needs the proprietary package.
"""
import os
import re

import pytest

from ffcfg import sections

# Klipper's own commands. Everything else in the files has to come from the
# payload, which is what test_every_command_is_defined proves.
KLIPPER_BUILTINS = {"SET_PRESSURE_ADVANCE"}

FEATURE = "creator5-feature-test.gcode"
SAFE = "creator5-safe-moves.gcode"

# The floor the safe file promises in its own header.
SAFE_Z = 50.0

MACRO = re.compile(r"^gcode_macro (\S+)$")
REGISTERED = re.compile(r"register_command\(\s*['\"]([A-Z0-9_]+)['\"]")
# A G-code word: G1, M106, T2. Anything else is a named command.
GCODE_WORD = re.compile(r"^[GMT]\d+$")
COORD = re.compile(r"\b([XYZE])(-?\d+(?:\.\d+)?)")


@pytest.fixture(scope="session")
def gcodedir(root):
    return os.path.join(root, "gcode")


@pytest.fixture(scope="session")
def files(gcodedir):
    """Every shipped file, by name."""
    out = {}
    for name in sorted(os.listdir(gcodedir)):
        if name.endswith(".gcode"):
            path = os.path.join(gcodedir, name)
            out[name] = open(path, encoding="utf-8").read().splitlines()
    assert set(out) == {FEATURE, SAFE}, sorted(out)
    return out


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
    extras = os.path.join(root, "pkg", "klipper", "prog", "klippy", "extras")
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


@pytest.mark.parametrize("name", [FEATURE, SAFE])
def test_every_command_is_defined(files, defined, name):
    """A macro rename must break this file here, not on the printer."""
    unknown = sorted({word for _, word, _ in commands(files[name])
                      if not GCODE_WORD.match(word) and word not in defined})
    assert not unknown, (
        "%s calls commands nothing the mod ships defines: %s"
        % (name, ", ".join(unknown)))


@pytest.mark.parametrize("name", [FEATURE, SAFE])
def test_moves_stay_inside_the_machine(files, limits, name):
    """Every coordinate within the axis limits Klipper is configured with.

    Both files keep the printed and traversed shapes well inside the bed, but
    the feature print's prime lines deliberately reach out to X256 where the
    machine's own start block primes, so "inside the bed" is the wrong bound to
    assert. The stepper limits are the real one: past them Klipper aborts.
    """
    bad = []
    for n, word, rest in commands(files[name]):
        if word not in ("G0", "G1"):
            continue
        for axis, value in COORD.findall(rest):
            if axis == "E":
                continue
            lo, hi = limits[axis]
            if not lo <= float(value) <= hi:
                bad.append("line %d: %s%s outside %s %.1f..%.1f"
                           % (n, axis, value, axis, lo, hi))
    assert not bad, "%s:\n%s" % (name, "\n".join(bad))


@pytest.mark.parametrize("name", [FEATURE, SAFE])
def test_extrusion_is_never_left_absolute(files, name):
    """M83 is set once and must stay set.

    An M82 after it turns the first E of the next move into an absolute
    target -- a single retraction becomes a 100 mm unspooling.
    """
    for n, word, _ in commands(files[name]):
        assert word != "M82", "%s line %d switches to absolute E" % (name, n)


def test_feature_print_calls_the_macros_it_exists_to_test(files, defined):
    """Without this the file could call nothing but builtins.

    That is still a well-formed print, and a worthless verification.
    """
    called = {word for _, word, _ in commands(files[FEATURE])}
    for required in ("START_PRINT", "END_PRINT", "TOOLCHANGE_STATUS",
                     "TOOL_OFFSET_STATUS", "M141"):
        assert required in called, "%s does not exercise %s" % (FEATURE, required)


def test_feature_print_declares_every_tool_it_uses(files):
    """START_PRINT TOOLS= is the preflight gate: it has to list every tool.

    A tool missing from TOOLS= is not purged, not wiped and not checked for
    presence -- it fails at its grab, mid-print, with filament down.
    """
    lines = files[FEATURE]
    used = {int(word[1:]) for _, word, _ in commands(lines)
            if re.match(r"^T\d$", word)}
    start = [rest for _, word, rest in commands(lines) if word == "START_PRINT"]
    assert len(start) == 1, start
    m = re.search(r"TOOLS=(\S+)", start[0])
    assert m, start[0]
    declared = {int(part.split(":")[0]) for part in m.group(1).split(",")}
    assert declared == used, (
        "START_PRINT TOOLS=%s but the file uses %s"
        % (sorted(declared), sorted(used)))


def test_safe_file_never_descends_below_its_floor(files):
    """The whole promise of the safe file, in one assertion.

    G28 itself has to touch the eddy sensor, and carries no Z word; every
    commanded Z after it is bounded here.
    """
    bad = []
    for n, word, rest in commands(files[SAFE]):
        if word not in ("G0", "G1"):
            continue
        for axis, value in COORD.findall(rest):
            if axis == "Z" and float(value) < SAFE_Z:
                bad.append("line %d: Z%s is below the Z%.0f floor"
                           % (n, value, SAFE_Z))
    assert not bad, "\n".join(bad)


def test_safe_file_is_cold_and_extrudes_nothing(files):
    """No E word, and no heater ever given a target.

    "No filament needed" is a promise made to someone standing at a machine
    they have just flashed, and an M104 slipped in later would break it
    silently -- the file would still run, and still look safe.
    """
    for n, word, rest in commands(files[SAFE]):
        assert word not in ("M104", "M109", "M140", "M190", "M191",
                            "SET_HEATER_TEMPERATURE"), (
            "line %d gives a heater a target: %s %s" % (n, word, rest))
        if word in ("G0", "G1"):
            assert "E" not in {a for a, _ in COORD.findall(rest)}, (
                "line %d extrudes: %s %s" % (n, word, rest))
    # M141 is the exception and is deliberate: the chamber gate is the thing
    # being tested, and the file sets it straight back to 0.
    chamber = [rest for _, word, rest in commands(files[SAFE]) if word == "M141"]
    assert chamber and chamber[-1].strip() == "S0", (
        "the safe file must leave the chamber off, got %s" % chamber)
