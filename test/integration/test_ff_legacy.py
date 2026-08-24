"""ff_legacy's automatic import-and-save at first boot.

The contract under test: on a printer fresh from stock firmware -- no
[ff_tool n] has a saved nozzle position -- the first klippy:ready imports
firmwareExe's per-unit JSON and, with auto_save (the default), persists it
with a SAVE_CONFIG that klipper issues itself. Once. The restart that save
causes is exactly the point: it happens right after ready, before a UI is up,
so the wizard never sees an uncalibrated machine.

These run against payload/klipper/extras/ff_legacy.py with the klippy objects
stubbed -- the extra only touches gcode, configfile, reactor and the ff_tool
objects, all narrow enough to fake honestly. The replica lane cannot cover
this: klippy itself does not run there.
"""
import importlib.util
import json
import os

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load_ff_legacy():
    path = os.path.join(ROOT, "payload", "klipper", "extras", "ff_legacy.py")
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


def ready(printer):
    printer.handlers["klippy:ready"]()


def test_first_boot_imports_and_saves(rig):
    printer, reactor, gcode, configfile, jdir = rig
    make(printer, {"firmware_config_dir": jdir})
    ready(printer)
    # applied live: every tool got its nozzle triple
    for n in range(4):
        assert printer.objects["ff_tool %d" % n].nozzle == (1.0 + n, 2.0 + n, 3.0 + n)
    # staged for the save that is about to happen
    assert ("ff_tool 0", "nozzle_x") in configfile.staged
    assert ("ff_tool_offset", "station_z") in configfile.staged
    # the save is deferred to after the ready handlers, then actually issued
    assert gcode.scripts == []
    assert len(reactor.callbacks) == 1
    reactor.run_pending()
    assert gcode.scripts == ["SAVE_CONFIG"]
    assert any("restarts once" in m for m in gcode.messages)


def test_never_a_second_time(rig):
    printer, reactor, gcode, configfile, jdir = rig
    make(printer, {"firmware_config_dir": jdir})
    ready(printer)
    reactor.run_pending()
    # after the save-restart the tools come back calibrated; ready again must
    # neither re-import nor schedule another save -- this is the "once"
    ready(printer)
    assert reactor.callbacks == []
    assert gcode.scripts == ["SAVE_CONFIG"]


def test_auto_save_off_keeps_the_old_contract(rig):
    printer, reactor, gcode, configfile, jdir = rig
    make(printer, {"firmware_config_dir": jdir, "auto_save": False})
    ready(printer)
    assert reactor.callbacks == []
    assert gcode.scripts == []
    assert any("run SAVE_CONFIG to keep it" in m for m in gcode.messages)
    # the values are still applied live, exactly as before
    assert printer.objects["ff_tool 0"].nozzle == (1.0, 2.0, 3.0)


def test_someone_elses_pending_save_is_not_committed(rig):
    printer, reactor, gcode, configfile, jdir = rig
    configfile.pending = True  # staged by something else before ready
    make(printer, {"firmware_config_dir": jdir})
    ready(printer)
    assert reactor.callbacks == []
    assert gcode.scripts == []
    assert any("run SAVE_CONFIG to keep it" in m for m in gcode.messages)


def test_no_json_no_import_no_restart(rig, tmp_path):
    printer, reactor, gcode, configfile, _ = rig
    empty = tmp_path / "empty"
    empty.mkdir()
    make(printer, {"firmware_config_dir": str(empty)})
    ready(printer)
    assert reactor.callbacks == []
    assert configfile.staged == {}
    assert gcode.messages == []


def test_nothing_landed_no_restart(rig, tmp_path):
    # extruder.json exists but carries no usable tool data: importing stages
    # nothing a restart would be worth, so no save is scheduled.
    printer, reactor, gcode, configfile, _ = rig
    bare = tmp_path / "bare"
    bare.mkdir()
    with open(os.path.join(str(bare), "extruder.json"), "w") as fh:
        fh.write('{"irrelevant": 1}\n/* trailer */\n')
    make(printer, {"firmware_config_dir": str(bare)})
    ready(printer)
    assert reactor.callbacks == []
    assert gcode.scripts == []


def test_failed_save_does_not_raise(rig):
    # SAVE_CONFIG can refuse (read-only config, a conflict); the callback must
    # swallow it -- the values are live, the next boot retries, and a failed
    # save never restarted klippy so there is no loop to fear.
    printer, reactor, gcode, configfile, jdir = rig
    gcode.fail_scripts = True
    make(printer, {"firmware_config_dir": jdir})
    ready(printer)
    reactor.run_pending()  # must not raise
    assert gcode.scripts == []
