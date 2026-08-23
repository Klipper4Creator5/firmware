#!/usr/bin/env python3
"""The chamber-heater gate in ff-chamber.cfg must actually gate.

The Creator 5 Pro has a chamber heater and the plain Creator 5 does not, but
both ship the same printer.base.cfg, so [heater_generic chamber_heater] is
declared either way. FlashForge hardcoded verify_heater's parameters, so the
ONLY thing keeping a non-Pro safe is that nothing ever sets a target -- set
one and klippy shuts the printer down ~15 min later, mid-print.

ff-chamber.cfg is byte-identical in every package; the answer comes from
ff-model.cfg, which exists once per model as ff-model.cfg.creator5 /
ff-model.cfg.creator5pro and is installed under its real name. Syntax alone does
not prove the selection has any effect, so this renders the macro bodies
through Klipper's own Jinja environment (delimiters '{%','%}','{','}' -- NOT
jinja2's defaults) and asserts what comes out, for each model in turn.

    ./test/test-chamber.py
"""
import ast
import glob
import importlib.util
import os
import sys

try:
    import jinja2
except ImportError:
    print("  SKIP: jinja2 not installed")
    sys.exit(0)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFGDIR = os.path.join(ROOT, "payload", "klipper", "config")
CFG = os.path.join(CFGDIR, "ff-chamber.cfg")
# TARGET_MACHINE -> the suffix bin/patch.sh derives from it, and the answer
# that model is expected to give. A model that is buildable but missing from
# here would otherwise go untested.
MODELS = {"Creator5Pro": ("creator5pro", 1), "Creator5": ("creator5", 0)}

# Reuse the config reader from its sibling; the '-' in the name rules out a
# plain import.
_spec = importlib.util.spec_from_file_location(
    "test_macros", os.path.join(ROOT, "test", "test-macros.py"))
_tm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_tm)

PASS, FAIL = [], []


def ok(name):
    PASS.append(name)
    print("  \033[32mPASS\033[0m  %s" % name)


def bad(name, detail=""):
    FAIL.append(name)
    print("  \033[31mFAIL\033[0m  %s" % name)
    if detail:
        print("        %s" % detail)


def variables_of(secs):
    """The chamber_heater answer this config combination gives."""
    raw = secs.get("gcode_macro _FF_MODEL", {}).get("variable_chamber_heater")
    try:
        return int(raw)
    except (TypeError, ValueError):
        return raw


def load(machine):
    """The shared logic file plus the ff-model.cfg that patch.sh would pick."""
    secs = dict(_tm.sections(CFG))
    model = os.path.join(CFGDIR, "ff-model.cfg.%s" % MODELS[machine][0])
    if not os.path.exists(model):
        bad("ff-model.cfg.%s exists" % MODELS[machine][0],
            "bin/patch.sh would fail the build for TARGET_MACHINE=%s" % machine)
        return None
    secs.update(dict(_tm.sections(model)))
    return secs


def render(secs, section, params, rawparams=""):
    """Render one macro body the way Klipper's gcode_macro does."""
    env = jinja2.Environment("{%", "%}", "{", "}")
    said = []

    def action_respond_info(msg):
        said.append(msg)
        return ""

    # Klipper exposes a macro's variables as attributes of its status object
    # after ast.literal_eval; a plain dict is close enough for these lookups.
    def variables(section):
        out = {}
        for k, v in secs.get(section, {}).items():
            if not k.startswith("variable_"):
                continue
            try:
                out[k[len("variable_"):]] = ast.literal_eval(v)
            except (ValueError, SyntaxError):
                out[k[len("variable_"):]] = v
        return out

    printer = {"gcode_macro _FF_CHAMBER": variables("gcode_macro _FF_CHAMBER"),
               "gcode_macro _FF_MODEL": variables("gcode_macro _FF_MODEL")}
    out = env.from_string(secs["gcode_macro " + section]["gcode"]).render(
        printer=printer, params=params, rawparams=rawparams,
        action_respond_info=action_respond_info)
    return out, said


def main():
    if not os.path.exists(CFG):
        print("  SKIP: no ff-chamber.cfg")
        return 0

    # bin/patch.sh must actually do the selecting.
    patch_sh = open(os.path.join(ROOT, "bin", "patch.sh"), encoding="utf-8").read()
    if '*."$SUFFIX"' in patch_sh and 'tr \'A-Z\' \'a-z\'' in patch_sh:
        ok("bin/patch.sh installs <file>.<model> under its real name")
    else:
        bad("bin/patch.sh installs <file>.<model> under its real name",
            "nothing selects the per-model variants")

    # A variant must never match the plain ff-*.cfg glob, or it would ship to
    # every model under its suffixed name as well.
    leaked = [os.path.basename(f)
              for f in glob.glob(os.path.join(CFGDIR, "ff-*.cfg"))
              if any(os.path.basename(f).endswith("." + sfx)
                     for sfx, _ in MODELS.values())]
    if not leaked:
        ok("no per-model variant matches the plain ff-*.cfg glob")
    else:
        bad("no per-model variant matches the plain ff-*.cfg glob", repr(leaked))

    # Every file that has one variant must have all of them, or some model
    # silently ships without it.
    bases = {os.path.basename(f).rsplit(".", 1)[0]
             for sfx, _ in MODELS.values()
             for f in glob.glob(os.path.join(CFGDIR, "*." + sfx))}
    missing = [(b, sfx) for b in sorted(bases) for sfx, _ in MODELS.values()
               if not os.path.exists(os.path.join(CFGDIR, "%s.%s" % (b, sfx)))]
    if not missing:
        ok("every per-model file exists for every model (%d file(s))" % len(bases))
    else:
        bad("every per-model file exists for every model",
            ", ".join("%s.%s" % m for m in missing))

    for machine, (_sfx, want) in sorted(MODELS.items()):
        secs = load(machine)
        if secs is None:
            continue
        got = variables_of(secs)
        if got == want:
            ok("%s declares chamber_heater=%d" % (machine, want))
        else:
            bad("%s declares chamber_heater=%d" % (machine, want), "got %r" % got)

    pro, nonpro = load("Creator5Pro"), load("Creator5")
    if FAIL:
        # The config no longer has the shape patch.sh edits; rendering it would
        # only bury that under a Jinja traceback.
        print("\n  %d passed, %d failed" % (len(PASS), len(FAIL)))
        return 1

    BLOCKED = "SET_HEATER_TEMPERATURE_BASE"

    # --- the whole point: a chamber target on a machine with no heater ------
    out, said = render(nonpro, "SET_HEATER_TEMPERATURE",
                       {"HEATER": "chamber_heater", "TARGET": "50"},
                       "HEATER=chamber_heater TARGET=50")
    if BLOCKED not in out and said:
        ok("non-Pro: chamber TARGET=50 is blocked and explained")
    else:
        bad("non-Pro: chamber TARGET=50 is blocked and explained",
            "rendered %r, said %r" % (out.strip(), said))

    out, _ = render(pro, "SET_HEATER_TEMPERATURE",
                    {"HEATER": "chamber_heater", "TARGET": "50"},
                    "HEATER=chamber_heater TARGET=50")
    if BLOCKED in out and "TARGET=50" in out:
        ok("Pro: chamber TARGET=50 reaches the real command")
    else:
        bad("Pro: chamber TARGET=50 reaches the real command", repr(out.strip()))

    # --- everything else must pass through on BOTH models -------------------
    # Turning the chamber off has to work even where there is no heater: the
    # stock app and our own macros send TARGET=0 unconditionally.
    for label, secs in (("non-Pro", nonpro), ("Pro", pro)):
        out, _ = render(secs, "SET_HEATER_TEMPERATURE",
                        {"HEATER": "chamber_heater", "TARGET": "0"},
                        "HEATER=chamber_heater TARGET=0")
        if BLOCKED in out:
            ok("%s: chamber TARGET=0 still passes through" % label)
        else:
            bad("%s: chamber TARGET=0 still passes through" % label, repr(out.strip()))

        out, _ = render(secs, "SET_HEATER_TEMPERATURE",
                        {"HEATER": "extruder", "TARGET": "220"},
                        "HEATER=extruder TARGET=220")
        if BLOCKED in out and "extruder" in out:
            ok("%s: hotends are untouched" % label)
        else:
            bad("%s: hotends are untouched" % label, repr(out.strip()))

    # --- M191 must not wait for a heater that cannot heat -------------------
    out, _ = render(nonpro, "M191", {"S": "60"})
    if "TEMPERATURE_WAIT" not in out:
        ok("non-Pro: M191 does not wait forever")
    else:
        bad("non-Pro: M191 does not wait forever", repr(out.strip()))

    out, _ = render(pro, "M191", {"S": "60"})
    if "TEMPERATURE_WAIT" in out and "MINIMUM=58" in out:
        ok("Pro: M191 waits to within wait_band")
    else:
        bad("Pro: M191 waits to within wait_band", repr(out.strip()))

    print("\n  %d passed, %d failed" % (len(PASS), len(FAIL)))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
