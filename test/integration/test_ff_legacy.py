"""FF_IMPORT_FIRMWARE_CONFIG -- reading firmwareExe's per-unit JSON.

The contract under test is the command alone: given the three JSON files the
stock firmware keeps, it applies the nozzle/dock/station numbers live AND
stages them for SAVE_CONFIG, so one SAVE_CONFIG afterwards persists the lot.

It has no startup behaviour to test. Deciding WHEN to run this on a fresh
install belongs to bin/ff-startup.py (see test_startup.py),
which drives the command from outside klippy once the whole stack is up. The
options that used to do it here, auto_import and auto_save, are gone.

These run against pkg/klipper/prog/klippy/extras/ff_legacy.py with the klippy
objects
stubbed -- the extra only touches gcode, configfile and the ff_tool objects,
all narrow enough to fake honestly. The replica lane cannot cover this:
klippy itself does not run there.
"""
import importlib.util
import json
import os

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load_ff_legacy():
    path = os.path.join(ROOT, "pkg", "klipper", "prog", "klippy", "extras", "ff_legacy.py")
    spec = importlib.util.spec_from_file_location("ff_legacy", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ff_legacy = _load_ff_legacy()


class FakeReactor:
    def __init__(self):
        self.callbacks = []

    def monotonic(self):
        return 0.0

    def register_callback(self, cb):
        self.callbacks.append(cb)

    def run_pending(self):
        cbs, self.callbacks = self.callbacks, []
        for cb in cbs:
            cb(self.monotonic())


class FakeConfigfile:
    def __init__(self):
        self.staged = {}
        self.pending = False

    def set(self, section, option, value):
        self.staged[(section, option)] = value
        self.pending = True

    def get_status(self, eventtime):
        return {"save_config_pending": self.pending}


class FakeGcode:
    def __init__(self):
        self.commands = {}
        self.messages = []
        self.scripts = []
        self.fail_scripts = False

    def register_command(self, name, fn, desc=None):
        self.commands[name] = fn

    def respond_info(self, msg):
        self.messages.append(msg)

    def run_script(self, script):
        if self.fail_scripts:
            raise RuntimeError("shutdown")
        self.scripts.append(script)


class FakeTool:
    def __init__(self):
        self.nozzle = None
        self.dock_x = None
        self.dock_y = None
        self.z_adjust = 0.0

    def calibrated(self):
        return self.nozzle is not None


class FakePrinter:
    def __init__(self, objects, reactor):
        self.objects = objects
        self.reactor = reactor
        self.handlers = {}

    def lookup_object(self, name, default="raise"):
        if name in self.objects:
            return self.objects[name]
        if default == "raise":
            raise KeyError(name)
        return default

    def register_event_handler(self, event, fn):
        self.handlers[event] = fn

    def get_reactor(self):
        return self.reactor


class FakeConfig:
    def __init__(self, printer, values):
        self.printer = printer
        self.values = values

    def get_printer(self):
        return self.printer

    def get_name(self):
        return "ff_legacy"

    def getboolean(self, name, default):
        return self.values.get(name, default)

    def get(self, name, default=None):
        return self.values.get(name, default)


def write_firmware_json(directory):
    """The three files firmwareExe keeps, in their real not-quite-JSON shape:
    a JSON object followed by a trailing C comment."""
    ext = {"x_station_pos": 100.0, "y_station_pos": 200.0, "z_station_pos": -3.0}
    for n in range(4):
        sfx = "" if n == 0 else "%d" % n
        ext["x_check_pos" + sfx] = 10.0 + n
        ext["y_check_pos" + sfx] = 20.0 + n
        ext["t%d_offset_x" % n] = 1.0 + n
        ext["t%d_offset_y" % n] = 2.0 + n
        ext["t%d_offset_z" % n] = 3.0 + n
    for name, obj in (("extruder", ext), ("test", {}), ("zoffset", {})):
        with open(os.path.join(directory, name + ".json"), "w") as fh:
            fh.write(json.dumps(obj) + "\n/* firmwareExe trailer */\n")


@pytest.fixture
def rig(tmp_path):
    write_firmware_json(str(tmp_path))
    reactor = FakeReactor()
    gcode = FakeGcode()
    configfile = FakeConfigfile()
    objects = {"gcode": gcode, "configfile": configfile}
    for n in range(4):
        objects["ff_tool %d" % n] = FakeTool()
    printer = FakePrinter(objects, reactor)
    return printer, reactor, gcode, configfile, str(tmp_path)


def make(printer, values):
    config = FakeConfig(printer, values)
    return ff_legacy.FFLegacy(config)


class FakeGcmd:
    """Just enough of a gcode command: parameters in, respond_info out."""

    def __init__(self, params=None):
        self.params = params or {}
        self.responses = []

    def get(self, name, default=None):
        return self.params.get(name, default)

    def get_int(self, name, default, minval=None, maxval=None):
        return int(self.params.get(name, default))

    def respond_info(self, msg):
        self.responses.append(msg)

    def error(self, msg):
        return ValueError(msg)


def run_import(printer, values, params=None):
    legacy = make(printer, values)
    gcmd = FakeGcmd(params)
    legacy.cmd_FF_IMPORT_FIRMWARE_CONFIG(gcmd)
    return "\n".join(gcmd.responses)


def test_the_command_is_all_it_registers(rig):
    printer, reactor, gcode, configfile, jdir = rig
    make(printer, {"firmware_config_dir": jdir})
    assert list(gcode.commands) == ["FF_IMPORT_FIRMWARE_CONFIG"]
    # No klippy:ready hook: nothing happens to a printer merely by booting.
    assert printer.handlers == {}


def test_import_applies_live_and_stages_for_save(rig):
    printer, reactor, gcode, configfile, jdir = rig
    out = run_import(printer, {"firmware_config_dir": jdir})
    # applied live: every tool got its nozzle triple and its dock
    for n in range(4):
        tool = printer.objects["ff_tool %d" % n]
        assert tool.nozzle == (1.0 + n, 2.0 + n, 3.0 + n)
        assert (tool.dock_x, tool.dock_y) == (10.0 + n, 20.0 + n)
    # staged, so a single SAVE_CONFIG afterwards persists everything
    assert ("ff_tool 0", "nozzle_x") in configfile.staged
    assert ("ff_tool 3", "dock_y") in configfile.staged
    assert ("ff_tool_offset", "station_z") in configfile.staged
    assert configfile.pending
    assert "Then run SAVE_CONFIG" in out
    # and it saves nothing by itself -- that is the caller's move now
    assert gcode.scripts == []


def test_apply_zero_only_reports(rig):
    printer, reactor, gcode, configfile, jdir = rig
    out = run_import(printer, {"firmware_config_dir": jdir}, {"APPLY": 0})
    assert configfile.staged == {}
    assert printer.objects["ff_tool 0"].nozzle is None
    assert "would stage" in out


def test_dir_parameter_wins_over_the_configured_default(rig, tmp_path):
    printer, reactor, gcode, configfile, jdir = rig
    other = tmp_path / "other"
    other.mkdir()
    write_firmware_json(str(other))
    out = run_import(printer, {"firmware_config_dir": "/nonexistent"},
                     {"DIR": str(other)})
    assert str(other) in out
    assert printer.objects["ff_tool 0"].nozzle == (1.0, 2.0, 3.0)


def test_missing_json_is_a_command_error(rig, tmp_path):
    printer, reactor, gcode, configfile, _ = rig
    empty = tmp_path / "empty"
    empty.mkdir()
    with pytest.raises(ValueError):
        run_import(printer, {"firmware_config_dir": str(empty)})
    assert configfile.staged == {}


def test_json_without_tool_data_stages_nothing(rig, tmp_path):
    # extruder.json exists but carries nothing usable: the command succeeds
    # and reports it, and no tool comes out calibrated -- which is what the
    # first-boot importer checks before it decides to SAVE_CONFIG.
    printer, reactor, gcode, configfile, _ = rig
    bare = tmp_path / "bare"
    bare.mkdir()
    with open(os.path.join(str(bare), "extruder.json"), "w") as fh:
        fh.write('{"irrelevant": 1}\n/* trailer */\n')
    run_import(printer, {"firmware_config_dir": str(bare)})
    assert configfile.staged == {}
    assert not printer.objects["ff_tool 0"].calibrated()
