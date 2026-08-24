"""The chamber macros must follow the model's own config.

The Creator 5 Pro has a chamber heating element; the plain Creator 5 does not.
printer.chamber.cfg declares [heater_generic chamber_heater] on the Pro and
only a temperature_sensor on the non-Pro, and ff-chamber.cfg's macros ask
Klipper whether that object exists rather than being told by a flag.

Syntax alone does not prove the macros branch correctly, so this renders their
bodies through Klipper's own Jinja environment once per model, with a printer
context built from that model's real config file.

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

    This is load-bearing, not decoration. See test_default_delimiters_are_blind.
    """
    return jinja2.Environment("{%", "%}", "{", "}")


def chamber_cfg(cfgdir, machine):
    return os.path.join(cfgdir, "printer.chamber.cfg.%s" % MODELS[machine])


@pytest.fixture(scope="session")
def macros(cfgdir):
    return dict(sections(os.path.join(cfgdir, "ff-chamber.cfg")))


@pytest.fixture(scope="session")
def has_heater(cfgdir):
    return {m: HEATER in dict(sections(chamber_cfg(cfgdir, m))) for m in MODELS}


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


# --------------------------------------------------------------- parsing ----

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


def test_configs_exist(cfgdir):
    assert list(gcode_bodies(cfgdir)), "no ff-*.cfg gcode bodies found to parse"


def test_every_macro_parses(cfgdir):
    """Absorbed from test-macros.py, with the delimiters corrected."""
    broken = []
    for path, name, body in gcode_bodies(cfgdir):
        try:
            klipper_env().parse(body)
        except jinja2.TemplateSyntaxError as e:
            broken.append("%s [%s] line %s: %s" % (path, name, e.lineno, e.message))
    assert not broken, "macros do not parse as Klipper Jinja:\n  " + "\n  ".join(broken)


def test_default_delimiters_are_blind():
    """Why test-macros.py was theatre, pinned so it cannot come back.

    It used jinja2.Environment() -- default '{{' expressions. Our configs
    contain no '{{' at all, only single-brace expressions, so it validated
    '{% %}' block structure and never looked inside an expression.
    """
    broken = "M104 S{params.S|default(0)|floatm(( }"
    jinja2.Environment().parse(broken)          # the old test saw nothing wrong
    with pytest.raises(jinja2.TemplateSyntaxError):
        klipper_env().parse(broken)


def test_no_double_brace_expressions(cfgdir):
    """If this ever fails, Klipper's dialect assumption above needs revisiting."""
    for path, name, body in gcode_bodies(cfgdir):
        assert "{{" not in body, "%s [%s] uses '{{', which Klipper does not" % (path, name)


# ------------------------------------------------------- per-model layout ----

def test_no_variant_matches_the_plain_glob(cfgdir):
    leaked = [os.path.basename(f) for f in glob.glob(os.path.join(cfgdir, "ff-*.cfg"))
              if any(f.endswith("." + s) for s in MODELS.values())]
    assert not leaked, "per-model variants leaking into the plain glob: %r" % leaked


def test_every_per_model_file_exists_for_every_model(cfgdir):
    bases = {os.path.basename(f).rsplit(".", 1)[0]
             for s in MODELS.values()
             for f in glob.glob(os.path.join(cfgdir, "*." + s))}
    assert bases, "no per-model config variants found at all"
    missing = ["%s.%s" % (b, s) for b in sorted(bases) for s in MODELS.values()
               if not os.path.exists(os.path.join(cfgdir, "%s.%s" % (b, s)))]
    assert not missing, "per-model files missing: %s" % ", ".join(missing)


def test_pro_declares_the_heater(has_heater):
    assert has_heater["Creator5Pro"]


def test_non_pro_declares_no_heater(has_heater):
    assert not has_heater["Creator5"]


# ------------------------------------------- the non-Pro keeps the reading ----
# Absorbed from test-base-cfg.py, whose stock-drift comparison moved into
# bin/unpack.sh -- the only place a pristine stock tree exists, since
# bin/patch.sh overwrites the copy in work/software that the test read, so it
# had been comparing our file against itself.

def test_non_pro_declares_no_heater_section_at_all(cfgdir):
    np_ = dict(sections(chamber_cfg(cfgdir, "Creator5")))
    heaters = [n for n in np_
               if n.startswith("heater_generic") or n.startswith("verify_heater")]
    assert not heaters, "Creator 5 must declare no heater section: %r" % heaters


def test_non_pro_keeps_the_chamber_sensor(cfgdir):
    np_ = dict(sections(chamber_cfg(cfgdir, "Creator5")))
    assert "temperature_sensor chamber" in np_, sorted(np_)


def test_non_pro_sensor_matches_the_pro(cfgdir):
    """Same pin, type and bounds as the heater section it replaces."""
    sensor = dict(sections(chamber_cfg(cfgdir, "Creator5")))["temperature_sensor chamber"]
    ref = dict(sections(chamber_cfg(cfgdir, "Creator5Pro")))[HEATER]
    for k in ("sensor_type", "sensor_pin", "min_temp", "max_temp"):
        assert sensor.get(k) == ref.get(k), \
            "%s: %r != %r" % (k, sensor.get(k), ref.get(k))


# ------------------------------------------------------- the actual point ----

def test_non_pro_refuses_a_chamber_target(macros, has_heater):
    """A chamber target on a machine with no element for it.

    Left unguarded this reaches FlashForge's patched verify_heater, which
    hardcodes chamber_heater params, and klippy shuts down mid-print ~15
    minutes later with "not heating at expected rate".
    """
    out, said = render(macros, has_heater["Creator5"], "SET_HEATER_TEMPERATURE",
                       {"HEATER": "chamber_heater", "TARGET": "50"},
                       "HEATER=chamber_heater TARGET=50")
    assert BASE not in out, out.strip()
    assert said, "refused silently -- the user gets no explanation"


def test_pro_allows_a_chamber_target(macros, has_heater):
    out, _ = render(macros, has_heater["Creator5Pro"], "SET_HEATER_TEMPERATURE",
                    {"HEATER": "chamber_heater", "TARGET": "50"},
                    "HEATER=chamber_heater TARGET=50")
    assert BASE in out and "TARGET=50" in out, out.strip()


@pytest.mark.parametrize("machine", sorted(MODELS))
def test_chamber_off_always_passes_through(macros, has_heater, machine):
    """Our own macros and the stock app send TARGET=0 unconditionally."""
    out, _ = render(macros, has_heater[machine], "SET_HEATER_TEMPERATURE",
                    {"HEATER": "chamber_heater", "TARGET": "0"},
                    "HEATER=chamber_heater TARGET=0")
    assert BASE in out, out.strip()


@pytest.mark.parametrize("machine", sorted(MODELS))
def test_hotends_are_untouched(macros, has_heater, machine):
    out, _ = render(macros, has_heater[machine], "SET_HEATER_TEMPERATURE",
                    {"HEATER": "extruder", "TARGET": "220"},
                    "HEATER=extruder TARGET=220")
    assert BASE in out and "extruder" in out, out.strip()


def test_non_pro_m191_does_not_wait_forever(macros, has_heater):
    """TEMPERATURE_WAIT on a sensor that never reaches target hangs the print."""
    out, _ = render(macros, has_heater["Creator5"], "M191", {"S": "60"})
    assert "TEMPERATURE_WAIT" not in out, out.strip()


def test_pro_m191_waits_within_wait_band(macros, has_heater):
    out, _ = render(macros, has_heater["Creator5Pro"], "M191", {"S": "60"})
    assert "TEMPERATURE_WAIT" in out and "MINIMUM=58" in out, out.strip()
