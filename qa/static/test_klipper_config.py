"""The Klipper config we ship: one pin, one owner, and macros that compile.

THE BUG THIS EXISTS FOR. `chamber_heat_fan` had to change section type per
model -- `[heater_fan]` on the Pro so the element's fan follows the chamber
heater without any G-code running, `[fan_generic]` on the plain Creator 5,
which has no `chamber_heater` for `lookup_heater()` to resolve at
`klippy:ready`. Klipper can override an option but cannot un-declare a section,
so the section had to MOVE out of `printer.base.cfg` into the per-model
`chamber/<model>.cfg`.

That move is the dangerous kind. Leave the old section behind and PD12 is
claimed twice; `pins.py` raises "pin PD12 used multiple times in config" and
klippy refuses to start -- on a printer, after a flash, with no UI to say why.
Nothing else in the suite reads these files: `test_ipk.py` checks that the
chamber configs are PACKAGED, never that they PARSE.

WHY THIS LANE, AND WHAT IT THEREFORE CANNOT SEE. The static lane runs on a bare
checkout, so the only configs here are the ones this repo ships. FlashForge's
own includes -- printer.filament.cfg, printer.probe.cfg, printer.mesh.cfg,
printer.vibration.cfg -- exist only under work/ after `bin/unpack.sh`, and
conftest is explicit that a missing firmware image is a failure rather than a
skip, so depending on them here would make this lane fail on a clean clone.
They are skipped, and a pin they claim that one of ours also claims is NOT
caught here. That is a real hole; what closes it is that every pin-bearing
section on the main MCU lives in printer.base.cfg, which is ours.

WHY RawConfigParser(strict=False). Klipper's own parser. Same-named sections
MERGE and the last value wins, which is the mechanism ff-chamber.cfg uses to
override `initial_WHITE` on `[led chamber_led]`; a strict parser would call
that a duplicate-section error and this test would be wrong about the file the
printer actually reads.
"""
import ast
import configparser
import re
import shlex

import jinja2
import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

CONFIG = ROOT / "pkgs" / "klipper-config" / "payload" / "config"
MODELS = ("Creator5", "Creator5Pro")
# Only the Pro has a chamber heating element, which is the single functional
# difference between the two stock firmwareExe builds.
HAS_HEATER = {"Creator5": False, "Creator5Pro": True}

# Outputs and thermistors. `endstop_pin` is deliberately absent: Klipper shares
# endstops by design (share_type "endstop"), and FlashForge's hd_home and
# e_stop extras re-claim those same input pins on purpose. An output pin or an
# ADC pin cannot be claimed twice under any share_type, so those are the ones
# worth asserting on.
PIN_OPTS = ("pin", "heater_pin", "sensor_pin", "white_pin", "red_pin",
            "green_pin", "blue_pin", "step_pin", "dir_pin", "enable_pin")
SHARED_SECTION_TYPES = ("hd_home", "e_stop", "gcode_button")

INCLUDE = re.compile(r"^\[include (.+)\]\s*$")


def _resolve(name, model):
    # printer.chamber.cfg is not a file in the payload: the package ships a
    # chamber/ directory and anvil-link-prog.sh links the model's file into
    # place on the printer. Resolve it the same way.
    if name == "printer.chamber.cfg":
        return CONFIG / "chamber" / (model + ".cfg")
    path = CONFIG / name
    return path if path.is_file() else None


def _assemble(model):
    """The config text klippy would see, minus FlashForge's own includes."""
    seen, chunks, skipped = set(), [], []

    def load(name):
        path = _resolve(name, model)
        if path is None:
            skipped.append(name)
            return
        if path in seen:
            return
        seen.add(path)
        body = []
        for line in path.read_text(encoding="utf-8").splitlines():
            m = INCLUDE.match(line)
            if m:
                load(m.group(1).strip())
                body.append("")
            else:
                body.append(line)
        chunks.append("\n".join(body))

    load("printer.base.cfg")
    return "\n".join(chunks), skipped


def _parse(model):
    text, _ = _assemble(model)
    # klippy's own parser settings (configfile.py). inline_comment_prefixes
    # matters as much as strict=False: configparser strips ';' and '#' only
    # when whitespace precedes them, so a ';' inside a string literal -- as in
    # ff-filament's "paused with T%s mounted; filament operations ..." --
    # survives. Stripping comments by hand instead reports those as broken.
    cp = configparser.RawConfigParser(
        strict=False, inline_comment_prefixes=(";", "#"))
    cp.read_string(text)
    return cp


# --------------------------------------------------------------------------
# Running the macros, because parsing them is not the same as believing them.
#
# THE BUG THIS HALF EXISTS FOR. SET_HEATER_TEMPERATURE is a MUX command keyed
# on HEATER: klippy dispatches it through _cmd_mux, which raises "The value
# 'chamber_heater' is not valid for HEATER" for a heater that was never
# registered (gcode.py). That is a command error, and a command error aborts a
# running print. On the plain Creator 5 there is no chamber_heater, and the
# gate in ff-chamber.cfg only blocked TARGET > 0 -- so `M141 S0`, which is what
# slicers put in their END G-CODE, went straight to the base command and killed
# the print at the very end. The file's own header said "chamber off behaves
# exactly as before"; it did not.
#
# Reading the macro did not show that. Running it did.
# --------------------------------------------------------------------------

ARGS_R = re.compile("([A-Z_]+|[A-Z*])")


def _is_traditional(cmd):
    return len(cmd) >= 2 and cmd[0].isupper() and cmd[1].isdigit()


def _parse_params(line, cmd):
    """klippy's TWO parameter parsers, which disagree with each other.

    Traditional (M141): args_r.split(line.upper()) -- the whole line is
    uppercased, and "M141 S60" yields {'M': '141', 'S': '60'}.

    Extended (SET_HEATER_TEMPERATURE): shlex over the RAW text, keys uppercased
    and values left alone, which is why HEATER=chamber_heater stays lowercase
    and the macro's `|lower` is load-bearing rather than decorative.
    """
    rest = line[len(line.split()[0]):]
    if _is_traditional(cmd):
        parts = ARGS_R.split(line.upper())
        return {parts[i]: parts[i + 1].strip()
                for i in range(1, len(parts) - 1, 2)}
    lex = shlex.shlex(rest, posix=True)
    lex.whitespace_split = True
    lex.commenters = "#;"
    return {k.upper(): v for k, v in (a.split("=", 1) for a in lex)}


def _run(model, command, has_heater):
    """Expand `command` until only non-macro commands remain, as klippy would.

    Returns (emitted commands, action_respond_info messages).
    """
    cp = _parse(model)
    printer = {}
    for sec in cp.sections():
        if sec.startswith("gcode_macro "):
            variables = {}
            for opt in cp.options(sec):
                if opt.startswith("variable_"):
                    try:
                        variables[opt[9:]] = ast.literal_eval(cp.get(sec, opt))
                    except (ValueError, SyntaxError):
                        variables[opt[9:]] = cp.get(sec, opt)
            printer[sec] = variables
    if has_heater:
        printer["heater_generic chamber_heater"] = {
            "temperature": 25.0, "target": 0.0}

    env = jinja2.Environment("{%", "%}", "{", "}")
    out, info = [], []

    def step(line, depth=0):
        assert depth < 10, "macro recursion in %s" % command
        line = line.strip()
        if not line:
            return
        cmd = line.split()[0].upper()
        sec = next((s for s in cp.sections()
                    if s.lower() == ("gcode_macro " + cmd).lower()), None)
        if sec is None or not cp.has_option(sec, "gcode"):
            out.append(line)
            return
        rendered = env.from_string(cp.get(sec, "gcode")).render(
            params=_parse_params(line, cmd),
            rawparams=line[len(line.split()[0]):].strip(),
            printer=printer,
            action_respond_info=lambda m: info.append(m) or "",
            action_raise_error=_raise,
        )
        for sub in rendered.splitlines():
            step(sub, depth + 1)

    step(command)
    return out, info


def _raise(msg):
    raise AssertionError("macro raised: %s" % msg)


def test_setting_a_chamber_target_starts_the_loop_fan_first():
    out, _ = _run("Creator5Pro", "M141 S60", has_heater=True)
    assert out == [
        "SET_FAN_SPEED FAN=chamber_loop_fan SPEED=0.3",
        "SET_HEATER_TEMPERATURE_BASE HEATER=chamber_heater TARGET=60.0",
    ], out


def test_clearing_a_chamber_target_stops_the_loop_fan_last():
    out, _ = _run("Creator5Pro", "M141 S0", has_heater=True)
    assert out == [
        "SET_HEATER_TEMPERATURE_BASE HEATER=chamber_heater TARGET=0.0",
        "SET_FAN_SPEED FAN=chamber_loop_fan SPEED=0",
    ], out


def test_m191_waits_below_the_target_by_the_band():
    out, _ = _run("Creator5Pro", "M191 S60", has_heater=True)
    assert 'TEMPERATURE_WAIT SENSOR="heater_generic chamber_heater" ' \
           "MINIMUM=58.0" in out, out


@pytest.mark.parametrize("command", ["M141 S0", "M191 S0", "M141"])
def test_turning_the_chamber_off_is_silent_on_a_model_without_one(command):
    """The end-of-print case. Emitting anything here aborts the print."""
    out, info = _run("Creator5", command, has_heater=False)
    assert out == [], (
        "%s reaches klippy on a Creator 5 and SET_HEATER_TEMPERATURE is a mux "
        "command: it raises \"The value 'chamber_heater' is not valid for "
        "HEATER\" and aborts the print. Emitted: %s" % (command, out))
    assert info == [], "nothing to turn off is not worth a message: %s" % info


def test_asking_for_chamber_heat_on_a_model_without_one_warns_and_continues():
    out, info = _run("Creator5", "M141 S60", has_heater=False)
    assert out == [], out
    assert info and "ignoring TARGET=60.0" in info[0], info


@pytest.mark.parametrize("model", MODELS)
def test_other_heaters_are_untouched(model):
    """The gate must not cost the hotend or the bed anything."""
    out, info = _run(model, "SET_HEATER_TEMPERATURE HEATER=extruder TARGET=220",
                     HAS_HEATER[model])
    assert out == ["SET_HEATER_TEMPERATURE_BASE HEATER=extruder TARGET=220"], out
    assert info == []


@pytest.mark.parametrize("model", MODELS)
def test_the_shipped_config_parses(model):
    cp = _parse(model)
    assert cp.sections(), "%s assembled to nothing -- includes did not resolve" % model


@pytest.mark.parametrize("model", MODELS)
def test_no_output_pin_is_claimed_twice(model):
    cp = _parse(model)
    claims = {}
    for sec in cp.sections():
        if sec.split()[0] in SHARED_SECTION_TYPES:
            continue
        for opt in PIN_OPTS:
            if not cp.has_option(sec, opt):
                continue
            raw = cp.get(sec, opt).split(",")[0].strip()
            pin = raw.lstrip("!^~").strip()
            # A templated or empty value is not a literal claim.
            if not pin or "{" in pin:
                continue
            claims.setdefault(pin, []).append("[%s] %s" % (sec, opt))

    dupes = {p: v for p, v in sorted(claims.items()) if len(v) > 1}
    assert not dupes, "klippy would refuse to start on %s:\n%s" % (
        model,
        "\n".join("  pin %s claimed by %s" % (p, " AND ".join(v))
                  for p, v in dupes.items()),
    )


@pytest.mark.parametrize("model", MODELS)
def test_every_gcode_macro_body_compiles(model):
    # Klipper's own delimiters (gcode_macro.py: Environment('{%','%}','{','}')).
    # A default Environment would read `{rawparams}` as literal text and compile
    # anything, which is a test that cannot fail.
    env = jinja2.Environment("{%", "%}", "{", "}")
    cp = _parse(model)
    broken = []
    for sec in cp.sections():
        if not sec.startswith("gcode_macro ") or not cp.has_option(sec, "gcode"):
            continue
        # No hand-stripping: _parse() already read this with klippy's own
        # inline_comment_prefixes, so the body here is the body Jinja gets.
        src = cp.get(sec, "gcode")
        try:
            env.from_string(src)
        except jinja2.TemplateSyntaxError as exc:
            broken.append("  [%s] line %s: %s" % (sec, exc.lineno, exc.message))
    assert not broken, "macros klippy would reject on %s:\n%s" % (
        model, "\n".join(broken))


@pytest.mark.parametrize("model", MODELS)
def test_the_chamber_heater_fan_matches_the_model(model):
    """The point of the move: the Pro binds the fan to the heater, the plain
    Creator 5 cannot, and neither may leave the section in printer.base.cfg."""
    cp = _parse(model)
    base = (CONFIG / "printer.base.cfg").read_text(encoding="utf-8")
    assert not re.search(r"^\[\w+ chamber_heat_fan\]", base, re.M), (
        "chamber_heat_fan must live in chamber/<model>.cfg, not printer.base.cfg: "
        "a section left in both claims PD12 twice")

    if model == "Creator5Pro":
        sec = "heater_fan chamber_heat_fan"
        assert sec in cp.sections(), "the Pro's element fan must follow the heater"
        assert cp.get(sec, "heater").strip() == "chamber_heater"
        assert cp.get(sec, "pin").strip() == "PD12"
    else:
        sec = "fan_generic chamber_heat_fan"
        assert sec in cp.sections(), (
            "the plain Creator 5 has no chamber_heater, so a [heater_fan] here "
            "would fail lookup_heater() at klippy:ready")
        assert cp.get(sec, "pin").strip() == "PD12"
        assert "heater_fan chamber_heat_fan" not in cp.sections()
