#!/usr/bin/env python3
"""The chamber macros must follow the model's own config.

The Creator 5 Pro has a chamber heating element; the plain Creator 5 does not.
printer.chamber.cfg declares [heater_generic chamber_heater] on the Pro and
only a temperature_sensor on the non-Pro, and ff-chamber.cfg's macros ask
Klipper whether that object exists rather than being told by a flag.

Syntax alone does not prove the macros branch correctly, so this renders their
bodies through Klipper's own Jinja environment -- delimiters '{%','%}','{','}',
NOT jinja2's defaults -- once per model, with a printer context built from
that model's real config file.

    ./test/test-chamber.py
"""
import glob
import os
import sys

try:
    import jinja2
except ImportError:
    print("  SKIP: jinja2 not installed")
    sys.exit(0)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ffcfg import sections, ok, bad, finish

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFGDIR = os.path.join(ROOT, "payload", "klipper", "config")
CFG = os.path.join(CFGDIR, "ff-chamber.cfg")
HEATER = "heater_generic chamber_heater"
# TARGET_MACHINE -> the suffix bin/patch.sh derives from it. A model that is
# buildable but missing here would otherwise go untested.
MODELS = {"Creator5Pro": "creator5pro", "Creator5": "creator5"}

def load(machine):
    """ff-chamber.cfg's macros, plus whether this model declares the heater."""
    macros = dict(sections(CFG))
    chamber = os.path.join(CFGDIR, "printer.chamber.cfg.%s" % MODELS[machine])
    if not os.path.exists(chamber):
        bad("printer.chamber.cfg.%s exists" % MODELS[machine])
        return None, None
    return macros, HEATER in dict(sections(chamber))


def render(macros, has_heater, section, params, rawparams=""):
    env = jinja2.Environment("{%", "%}", "{", "}")
    said = []

    def action_respond_info(msg):
        said.append(msg)
        return ""

    # Klipper's GetStatusWrapper supports `in`; a dict is close enough.
    printer = {"gcode_macro _FF_CHAMBER": {"wait_band": 2.0}}
    if has_heater:
        printer[HEATER] = {"temperature": 25.0, "target": 0.0}
    out = env.from_string(macros["gcode_macro " + section]["gcode"]).render(
        printer=printer, params=params, rawparams=rawparams,
        action_respond_info=action_respond_info)
    return out, said


def main():
    # --- the build must install the variants, and completely ----------------
    patch_sh = open(os.path.join(ROOT, "bin", "patch.sh"), encoding="utf-8").read()
    if '*."$SUFFIX"' in patch_sh:
        ok("bin/patch.sh installs <file>.<model> under its real name")
    else:
        bad("bin/patch.sh installs <file>.<model> under its real name")

    leaked = [os.path.basename(f) for f in glob.glob(os.path.join(CFGDIR, "ff-*.cfg"))
              if any(f.endswith("." + s) for s in MODELS.values())]
    if not leaked:
        ok("no per-model variant matches the plain ff-*.cfg glob")
    else:
        bad("no per-model variant matches the plain ff-*.cfg glob", repr(leaked))

    bases = {os.path.basename(f).rsplit(".", 1)[0]
             for s in MODELS.values()
             for f in glob.glob(os.path.join(CFGDIR, "*." + s))}
    missing = ["%s.%s" % (b, s) for b in sorted(bases) for s in MODELS.values()
               if not os.path.exists(os.path.join(CFGDIR, "%s.%s" % (b, s)))]
    if not missing:
        ok("every per-model file exists for every model (%d file(s))" % len(bases))
    else:
        bad("every per-model file exists for every model", ", ".join(missing))

    pro_m, pro_h = load("Creator5Pro")
    np_m, np_h = load("Creator5")
    if pro_m is None or np_m is None:
        return finish()

    if pro_h:
        ok("Creator5Pro declares the chamber heater")
    else:
        bad("Creator5Pro declares the chamber heater")
    if not np_h:
        ok("Creator5 declares no chamber heater")
    else:
        bad("Creator5 declares no chamber heater")

    BASE = "SET_HEATER_TEMPERATURE_BASE"

    # --- the point: a chamber target on a machine with no heater ------------
    out, said = render(np_m, np_h, "SET_HEATER_TEMPERATURE",
                       {"HEATER": "chamber_heater", "TARGET": "50"},
                       "HEATER=chamber_heater TARGET=50")
    if BASE not in out and said:
        ok("non-Pro: chamber TARGET=50 is refused and explained")
    else:
        bad("non-Pro: chamber TARGET=50 is refused and explained",
            "rendered %r, said %r" % (out.strip(), said))

    out, _ = render(pro_m, pro_h, "SET_HEATER_TEMPERATURE",
                    {"HEATER": "chamber_heater", "TARGET": "50"},
                    "HEATER=chamber_heater TARGET=50")
    if BASE in out and "TARGET=50" in out:
        ok("Pro: chamber TARGET=50 reaches the real command")
    else:
        bad("Pro: chamber TARGET=50 reaches the real command", repr(out.strip()))

    # --- everything else passes through on BOTH models ----------------------
    for label, m, h in (("non-Pro", np_m, np_h), ("Pro", pro_m, pro_h)):
        # Turning the chamber off must always work: our own macros and the
        # stock app send TARGET=0 unconditionally.
        out, _ = render(m, h, "SET_HEATER_TEMPERATURE",
                        {"HEATER": "chamber_heater", "TARGET": "0"},
                        "HEATER=chamber_heater TARGET=0")
        if BASE in out:
            ok("%s: chamber TARGET=0 still passes through" % label)
        else:
            bad("%s: chamber TARGET=0 still passes through" % label, repr(out.strip()))

        out, _ = render(m, h, "SET_HEATER_TEMPERATURE",
                        {"HEATER": "extruder", "TARGET": "220"},
                        "HEATER=extruder TARGET=220")
        if BASE in out and "extruder" in out:
            ok("%s: hotends are untouched" % label)
        else:
            bad("%s: hotends are untouched" % label, repr(out.strip()))

    # --- M191 must not wait for a heater that cannot exist ------------------
    out, _ = render(np_m, np_h, "M191", {"S": "60"})
    if "TEMPERATURE_WAIT" not in out:
        ok("non-Pro: M191 does not wait forever")
    else:
        bad("non-Pro: M191 does not wait forever", repr(out.strip()))

    out, _ = render(pro_m, pro_h, "M191", {"S": "60"})
    if "TEMPERATURE_WAIT" in out and "MINIMUM=58" in out:
        ok("Pro: M191 waits to within wait_band")
    else:
        bad("Pro: M191 waits to within wait_band", repr(out.strip()))

    return finish()


if __name__ == "__main__":
    sys.exit(main())
