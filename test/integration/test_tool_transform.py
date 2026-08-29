"""The per-tool G-code frame in ff_toolchange.

Per-tool XYZ used to be folded into Klipper's single homing_origin, which
forced a shadow copy of "which part of that number is ours" (_z_tool_term)
and meant SET_GCODE_OFFSET Z=0 -- issued by the end/cancel block -- wiped
the tool's ~3.2 mm nozzle-to-station gap along with the babystep. It is a
move transform below gcode_move now, so the two layers are independent:
homing_origin is the operator's, the transform is the tool's.

WHAT IS LEFT. This was twenty-four tests and is seven. Everything kept is a
mistake whose symptom is a MOVE TO THE WRONG PLACE -- an offset with the wrong
sign, a frame still applied while probing in machine coordinates, a gcode_move
cache not invalidated when the frame changed, or a klippy that will not parse
its config on any printer that has been calibrated. The bookkeeping around
them -- z_adjust staging for SAVE_CONFIG, the per-job Z term, the
uncalibrated-tool warning -- is dropped: those are wrong numbers reported to a
person, not a nozzle in the bed.

gcode_move and the toolhead are faked. They are Klipper's, not ours, and
_ToolTransform touches exactly two things on each: move()/get_position()
below it and reset_last_position() above.
"""
import importlib.util
import inspect
import os

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load(name):
    path = os.path.join(ROOT, "pkgs", "klipper", "payload", "klipper", "klippy", "extras", name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ff_toolchange = _load("ff_toolchange")


class FakeToolhead:
    """Whatever the transform chains down to. Records what it was asked."""

    def __init__(self, position=(0., 0., 0., 0.)):
        self.position = list(position)
        self.moves = []

    def move(self, newpos, speed):
        self.moves.append((list(newpos), speed))
        self.position = list(newpos)

    def get_position(self):
        return list(self.position)


class FakeGcodeMove:
    def __init__(self):
        self.resets = 0

    def reset_last_position(self):
        self.resets += 1


class FakePrinter:
    def __init__(self, gcode_move):
        self.objects = {"gcode_move": gcode_move}

    def lookup_object(self, name, default=None):
        return self.objects.get(name, default)


class FakeGcode:
    def __init__(self):
        self.messages = []

    def respond_info(self, message):
        self.messages.append(message)


class FakeTool:
    """Only what _set_tool_frame's calibration warning asks about."""

    def __init__(self, calibrated=True):
        self._calibrated = calibrated

    def calibrated(self):
        return self._calibrated


def make(offsets, mounted=None, calibrated=True):
    """A toolchanger with only the parts the frame API touches. __init__
    wants a whole klippy config; none of this needs one."""
    tc = ff_toolchange.FFToolchange.__new__(ff_toolchange.FFToolchange)
    tc.offset_x = [o[0] for o in offsets]
    tc.offset_y = [o[1] for o in offsets]
    tc.offset_z = [o[2] for o in offsets]
    tc.job_z = 0.0
    tc.tools = [FakeTool(calibrated) for _ in offsets]
    tc.gcode = FakeGcode()
    tc.gcode_move = FakeGcodeMove()
    tc.printer = FakePrinter(tc.gcode_move)
    tc.gcode_transform = ff_toolchange._ToolTransform(tc)
    tc.gcode_transform.next_transform = FakeToolhead()
    tc._current_tool_or_none = lambda: (mounted, "fake")
    return tc


OFFSETS = [(0.0, 0.0, 3.15), (-0.30, 0.07, 3.19),
           (0.12, -0.04, 3.11), (0.05, 0.21, 3.24)]


# ------------------------------------------------------------- arithmetic

def test_a_mounted_tool_adds_its_offsets():
    """The signs, against numbers worked out by hand.

    The round trip below cannot see this: an offset applied with the wrong
    sign and removed with the wrong sign agrees with itself perfectly.
    """
    tc = make(OFFSETS)
    tc.gcode_transform.tool = 1
    tc.gcode_transform.move([10., 20., 5., 1.], 60.)
    sent = tc.gcode_transform.next_transform.moves[0][0]
    assert sent[:3] == pytest.approx([9.70, 20.07, 8.19])


def test_get_position_undoes_what_move_did():
    """The round trip is the whole contract: G-code coordinates stay
    tool-independent, so M114 reports the frame the file is written in."""
    tc = make(OFFSETS)
    for tool in range(len(OFFSETS)):
        tc.gcode_transform.tool = tool
        asked = [10., 20., 5., 1.]
        tc.gcode_transform.move(asked, 60.)
        assert tc.gcode_transform.get_position() == pytest.approx(asked)


def test_the_extruder_axis_is_never_touched():
    """newpos[3:] is the extruder position -- adding a Z offset to it would
    extrude the offset."""
    tc = make(OFFSETS)
    tc.gcode_transform.tool = 3
    tc.gcode_transform.move([10., 20., 5., 42.5], 60.)
    assert tc.gcode_transform.next_transform.moves[0][0][3] == 42.5


# ---------------------------------------------------------- the frame API

def test_selecting_a_tool_invalidates_the_position_cache():
    """gcode_move caches last_position from position_with_transform(). Change
    the frame without resetting it and the next move starts from a point the
    toolhead is not at."""
    tc = make(OFFSETS)
    before = tc.gcode_move.resets
    tc._set_tool_frame(1)
    assert tc.gcode_transform.tool == 1
    assert tc.gcode_move.resets == before + 1


def test_suspending_the_frame_drops_to_machine_coordinates():
    """The offset calibration and the dock moves address the machine. Zeroing
    Klipper's G-code offset does NOT reach this layer, and the per-job Z term
    has to come off with the tool's -- both are the frame."""
    tc = make(OFFSETS, mounted=1)
    tc.job_z = 0.04
    tc._set_tool_frame(1)
    assert tc.suspend_tool_frame() == 1
    assert tc.gcode_transform.tool is None
    tc.gcode_transform.move([10., 20., 5., 0.], 60.)
    assert tc.gcode_transform.next_transform.moves[-1][0][:3] == [10., 20., 5.]


def test_restoring_the_frame_asks_the_sensors_not_the_memory():
    """After a calibration the carriage may hold a different tool than the one
    suspended -- or none. What is mounted is the honest answer, and an
    unanswerable question leaves no frame rather than the last one."""
    tc = make(OFFSETS, mounted=3)
    tc._set_tool_frame(1)
    tc.suspend_tool_frame()
    assert tc.restore_tool_frame() is True
    assert tc.gcode_transform.tool == 3

    for sensors_say in (-1, None):               # empty carriage, no answer
        tc = make(OFFSETS, mounted=sensors_say)
        tc._set_tool_frame(2)
        assert tc.restore_tool_frame() is False
        assert tc.gcode_transform.tool is None


# ------------------------------------------- the transform exists in time

def test_init_builds_the_transform_before_it_is_read():
    """Two ways __init__ has broken klippy at config parse, both static.

    refresh_offsets() reads gcode_transform to decide whether gcode_move's
    cache needs invalidating, and __init__ calls it. On a calibrated machine
    the derived offsets differ from the [0.0] seed, so the read happens -- and
    a transform created further down __init__ meant AttributeError at config
    parse on every printer that had ever been calibrated. The uncalibrated
    case, where nothing differs and the read is short-circuited, is exactly
    the one the replica boots in, so no replica gate can see this.

    And `self.offset_x = self.offset_y = self.offset_z = [0.] * N` binds ONE
    list to three names, so a later write to any of them writes all three --
    every tool would get X's offset on all three axes.
    """
    source = inspect.getsource(ff_toolchange.FFToolchange.__init__)
    built = source.index("self.gcode_transform = _ToolTransform(self)")
    refreshed = source.index("self.refresh_offsets()")
    assert built < refreshed, (
        "refresh_offsets() runs before the transform exists -- klippy will "
        "not parse its config on a calibrated printer")
    assert "self.offset_x = self.offset_y" not in source, (
        "the three offset series are chain-assigned, so they are one list")
