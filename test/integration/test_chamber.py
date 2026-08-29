"""The chamber macros must follow the model's own config.

The Creator 5 Pro has a chamber heating element; the plain Creator 5 does not.
printer.chamber.cfg declares [heater_generic chamber_heater] on the Pro and
only a temperature_sensor on the non-Pro, and ff-chamber.cfg's macros ask
Klipper whether that object exists rather than being told by a flag.

Syntax alone does not prove the macros branch correctly, so the two that matter
are rendered through Klipper's own Jinja environment, with a printer context
built from that model's real config file.

WHAT IS LEFT. This was twenty tests and is four. The ones that went described
the layout -- a per-model file exists for every model, the non-Pro's sensor
copies the Pro's pins, the plain glob does not catch a variant -- true
statements whose failure is a config that does not load, which the printer
says loudly the first time. What is kept is the three ways a chamber mistake
is SILENT until it has cost a print, plus the parse gate they all rest on.

Needs nothing proprietary: python3, jinja2 and the configs in the repo.
"""
import glob
import os

import pytest

jinja2 = pytest.importorskip("jinja2")

from conftest import HEATER, MODELS
from ffcfg import sections

BASE = "SET_HEATER_TEMPERATURE_BASE"


def klipper_env():
    """Klipper's Jinja dialect: '{%','%}','{','}' -- NOT jinja2's defaults.

    Load-bearing, not decoration. jinja2's default '{{' expressions do not
    appear in our configs at all, so an Environment() with the defaults
    validates block structure and never looks inside an expression -- which is
    what an earlier version of this file did, and why it passed on a macro
    with `|floatm(( }` in it.
    """
    return jinja2.Environment("{%", "%}", "{", "}")


def gcode_bodies(cfgdir):
    """(file, section, body) for every gcode block we ship.

    The per-model variants are installed under their real name by
    bin/patch.sh, so they are Klipper config too and are swept as well.
    """
    files = sorted(glob.glob(os.path.join(cfgdir, "ff-*.cfg"))
                   + glob.glob(os.path.join(cfgdir, "ff-*.cfg.*")))
    for path in files:
        for name, opts in sections(path):
            if opts.get("gcode") is not None:
                yield os.path.basename(path), name, opts["gcode"]


def chamber_cfg(cfgdir, machine):
    return os.path.join(cfgdir, "printer.chamber.cfg.%s" % MODELS[machine])


@pytest.fixture(scope="session")
def macros(cfgdir):
    return dict(sections(os.path.join(cfgdir, "ff-chamber.cfg")))


@pytest.fixture(scope="session")
def has_heater(cfgdir):
    out = {m: HEATER in dict(sections(chamber_cfg(cfgdir, m))) for m in MODELS}
    # Vacuity guard: every rendering test below is about the difference between
    # these two, so a config change that made them agree would leave the tests
    # passing while asserting nothing.
    assert out == {"Creator5Pro": True, "Creator5": False}, out
    return out


def render(macros, has_heater, section, params, rawparams=""):
    said = []

    def action_respond_info(msg):
        said.append(msg)
        return ""

    # Klipper's GetStatusWrapper supports `in`; a dict is close enough.
    printer = {"gcode_macro _FF_CHAMBER": {"wait_band": 2.0}}
    if has_heater:
        printer[HEATER] = {"temperature": 25.0, "target": 0.0}
    out = klipper_env().from_string(
        macros["gcode_macro " + section]["gcode"]).render(
            printer=printer, params=params, rawparams=rawparams,
            action_respond_info=action_respond_info)
    return out, said


def test_every_macro_parses(cfgdir):
    """The gate everything else rests on, in Klipper's dialect."""
    bodies = list(gcode_bodies(cfgdir))
    assert bodies, "no ff-*.cfg gcode bodies found to parse"
    broken = []
    for path, name, body in bodies:
        try:
            klipper_env().parse(body)
        except jinja2.TemplateSyntaxError as e:
            broken.append("%s [%s] line %s: %s" % (path, name, e.lineno, e.message))
    assert not broken, "macros do not parse as Klipper Jinja:\n  " + "\n  ".join(broken)


# The chamber heater exists only on the Pro. Klipper renders a gcode_macro's
# WHOLE template before executing a line of it, so a bare
# printer["heater_generic chamber_heater"] anywhere in a macro raises on the
# plain Creator 5 -- taking the whole macro with it, and every macro that calls
# it. That is how LOAD_FILAMENT, PURGE and _FF_NOZZLE_CLEAN once broke
# START_PRINT, and with it every print on a non-Pro machine.
#
# The guard is `'heater_generic chamber_heater' in printer` in the same macro.
# Static on purpose: rendering every macro would need a fully populated printer
# object, and the failure guarded against is a template that cannot render.
MODEL_ONLY_OBJECT = "heater_generic chamber_heater"


def test_model_specific_objects_are_guarded_before_use(cfgdir):
    subscript = ('printer["%s"]' % MODEL_ONLY_OBJECT,
                 "printer['%s']" % MODEL_ONLY_OBJECT)
    guard = ('"%s" in printer' % MODEL_ONLY_OBJECT,
             "'%s' in printer" % MODEL_ONLY_OBJECT)
    unguarded = []
    checked = 0
    for fname, section, body in gcode_bodies(cfgdir):
        if not any(s in body for s in subscript):
            continue
        checked += 1
        if not any(g in body for g in guard):
            unguarded.append("%s: [%s]" % (fname, section))
    assert not unguarded, (
        "%s is used without an `in printer` guard, so these macros raise on a "
        "plain Creator 5:\n  " % MODEL_ONLY_OBJECT + "\n  ".join(unguarded))
    # Vacuity guard: if the subscript is ever spelled differently this test
    # would silently stop looking.
    assert checked >= 2, (
        "no macro subscripts %s -- has the spelling changed?"
        % MODEL_ONLY_OBJECT)


def test_non_pro_refuses_a_chamber_target(macros, has_heater):
    """A chamber target on a machine with no element for it.

    Left unguarded this reaches FlashForge's patched verify_heater, which
    hardcodes chamber_heater params, and klippy shuts down mid-print ~15
    minutes later with "not heating at expected rate". The Pro case is the
    control: the same render must pass the target through.
    """
    out, said = render(macros, has_heater["Creator5"], "SET_HEATER_TEMPERATURE",
                       {"HEATER": "chamber_heater", "TARGET": "50"},
                       "HEATER=chamber_heater TARGET=50")
    assert BASE not in out, out.strip()
    assert said, "refused silently -- the user gets no explanation"

    out, _ = render(macros, has_heater["Creator5Pro"], "SET_HEATER_TEMPERATURE",
                    {"HEATER": "chamber_heater", "TARGET": "50"},
                    "HEATER=chamber_heater TARGET=50")
    assert BASE in out and "TARGET=50" in out, out.strip()


def test_non_pro_m191_does_not_wait_forever(macros, has_heater):
    """TEMPERATURE_WAIT on a sensor that never reaches target hangs the print.

    The Pro must still wait, and within the band -- a M191 that returns
    immediately on the machine that HAS the heater is the same bug mirrored.
    """
    out, _ = render(macros, has_heater["Creator5"], "M191", {"S": "60"})
    assert "TEMPERATURE_WAIT" not in out, out.strip()

    out, _ = render(macros, has_heater["Creator5Pro"], "M191", {"S": "60"})
    assert "TEMPERATURE_WAIT" in out and "MINIMUM=58" in out, out.strip()
