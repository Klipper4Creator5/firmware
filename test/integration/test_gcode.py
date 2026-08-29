"""The files in gcode/ must name commands this firmware has.

gcode/ holds the two files you send to a printer to prove the mod works:
creator5-safe-moves.gcode, which is cold and stays 50 mm above the plate, and
creator5-feature-test.gcode, which prints. They are hand-maintained G-code,
which makes them the one artifact in the repo that goes stale silently: rename
START_PRINT or drop TOOL_OFFSET_STATUS and both files still look perfectly
well-formed, and then die on the printer four minutes into a heat-up with a
tool already grabbed.

So the checks here are the ones the files cannot make for themselves: that
every command in them is one the shipped configs and extras define, and the
safe file's two promises -- cold, and never below Z50 -- which are its entire
reason to exist and exactly what an edit would quietly break.

WHAT IS LEFT. Coordinates-within-the-stepper-limits and no-M82 went: both are
real mistakes, and both are ones KLIPPER catches, at the first offending line,
before the toolhead has moved. The ones kept are the mistakes that run
perfectly and are wrong -- a renamed macro, a heater in the file that promises
it is cold.

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
    extras = os.path.join(root, "pkgs", "klipper", "payload", "klipper", "klippy", "extras")
    for py in sorted(os.listdir(extras)):
        if py.endswith(".py"):
            src = open(os.path.join(extras, py), encoding="utf-8").read()
            names.update(REGISTERED.findall(src))
    return names


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
