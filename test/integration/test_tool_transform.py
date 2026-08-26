"""The per-tool G-code frame in ff_toolchange.

Per-tool XYZ used to be folded into Klipper's single homing_origin, which
forced a shadow copy of "which part of that number is ours" (_z_tool_term)
and meant SET_GCODE_OFFSET Z=0 -- issued by the end/cancel block -- wiped
the tool's ~3.2 mm nozzle-to-station gap along with the babystep. It is a
move transform below gcode_move now, so the two layers are independent:
homing_origin is the operator's, the transform is the tool's.

What these pin down is the arithmetic and the bookkeeping around it. The
transform itself is four lines; everything that can go wrong is at the
edges -- a frame left applied while probing in machine coordinates, a
gcode_move position cache not invalidated when the frame changed, an offset
read from a snapshot instead of live.

gcode_move and the toolhead are faked. They are Klipper's, not ours, and
_ToolTransform touches exactly two things on each: move()/get_position()
below it and reset_last_position() above.
"""
import importlib.util
import os

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load():
    path = os.path.join(ROOT, "payload", "klipper", "extras",
                        "ff_toolchange.py")
    spec = importlib.util.spec_from_file_location("ff_toolchange", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ff_toolchange = _load()


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


def make(offsets, mounted=None):
    """A toolchanger with only the parts the frame API touches. __init__
    wants a whole klippy config; none of this needs one."""
    tc = ff_toolchange.FFToolchange.__new__(ff_toolchange.FFToolchange)
    tc.offset_x = [o[0] for o in offsets]
    tc.offset_y = [o[1] for o in offsets]
    tc.offset_z = [o[2] for o in offsets]
    tc.gcode_move = FakeGcodeMove()
    tc.printer = FakePrinter(tc.gcode_move)
    tc.gcode_transform = ff_toolchange._ToolTransform(tc)
    tc.gcode_transform.next_transform = FakeToolhead()
    tc._current_tool_or_none = lambda: (mounted, "fake")
    return tc


OFFSETS = [(0.0, 0.0, 3.15), (-0.30, 0.07, 3.19),
           (0.12, -0.04, 3.11), (0.05, 0.21, 3.24)]


# ------------------------------------------------------------- arithmetic

def test_no_tool_passes_the_move_through_untouched():
    tc = make(OFFSETS)
    tc.gcode_transform.move([10., 20., 5., 1.], 60.)
    assert tc.gcode_transform.next_transform.moves[0][0] == [10., 20., 5., 1.]


def test_a_mounted_tool_adds_its_offsets():
    tc = make(OFFSETS)
    tc.gcode_transform.tool = 1
    tc.gcode_transform.move([10., 20., 5., 1.], 60.)
    sent = tc.gcode_transform.next_transform.moves[0][0]
    assert sent[:3] == pytest.approx([9.70, 20.07, 8.19])


def test_the_extruder_axis_is_never_touched():
    # newpos[3:] is the extruder position -- adding a Z offset to it would
    # extrude the offset.
    tc = make(OFFSETS)
    tc.gcode_transform.tool = 3
    tc.gcode_transform.move([10., 20., 5., 42.5], 60.)
    assert tc.gcode_transform.next_transform.moves[0][0][3] == 42.5


def test_get_position_undoes_what_move_did():
    # The round trip is the whole contract: G-code coordinates stay
    # tool-independent, so M114 reports the frame the file is written in.
    tc = make(OFFSETS)
    for tool in range(len(OFFSETS)):
        tc.gcode_transform.tool = tool
        asked = [10., 20., 5., 1.]
        tc.gcode_transform.move(asked, 60.)
        assert tc.gcode_transform.get_position() == pytest.approx(asked)


def test_get_position_with_no_tool_is_the_machine_position():
    tc = make(OFFSETS)
    tc.gcode_transform.next_transform.position = [1., 2., 3., 4.]
    assert tc.gcode_transform.get_position() == [1., 2., 3., 4.]


def test_offsets_are_read_live_not_snapshotted():
    # This is what lets a per-tool Z tune apply mid-print: refresh_offsets()
    # rewrites the lists and the frame follows, with no re-apply and no
    # config write.
    tc = make(OFFSETS)
    tc.gcode_transform.tool = 2
    tc.offset_z[2] = 9.99
    tc.gcode_transform.move([0., 0., 0., 0.], 60.)
    assert tc.gcode_transform.next_transform.moves[0][0][2] == pytest.approx(9.99)


# ---------------------------------------------------------- the frame API

def test_selecting_a_tool_invalidates_the_position_cache():
    # gcode_move caches last_position from position_with_transform(). Change
    # the frame without resetting it and the next move starts from a point
    # the toolhead is not at.
    tc = make(OFFSETS)
    before = tc.gcode_move.resets
    tc._set_tool_frame(1)
    assert tc.gcode_transform.tool == 1
    assert tc.gcode_move.resets == before + 1


def test_suspending_the_frame_drops_to_machine_coordinates():
    # The offset calibration probes in raw coordinates. Zeroing Klipper's
    # G-code offset does NOT reach this layer.
    tc = make(OFFSETS, mounted=1)
    tc._set_tool_frame(1)
    assert tc.suspend_tool_frame() == 1
    assert tc.gcode_transform.tool is None
    tc.gcode_transform.move([10., 20., 5., 0.], 60.)
    assert tc.gcode_transform.next_transform.moves[-1][0][:3] == [10., 20., 5.]


def test_restoring_the_frame_asks_the_sensors_not_the_memory():
    # After a calibration the carriage may hold a different tool than the
    # one suspended -- or none. What is mounted is the honest answer.
    tc = make(OFFSETS, mounted=3)
    tc._set_tool_frame(1)
    tc.suspend_tool_frame()
    assert tc.restore_tool_frame() is True
    assert tc.gcode_transform.tool == 3


def test_restoring_with_an_empty_carriage_leaves_no_frame():
    tc = make(OFFSETS, mounted=-1)
    tc._set_tool_frame(2)
    assert tc.restore_tool_frame() is False
    assert tc.gcode_transform.tool is None


def test_restoring_when_the_sensors_cannot_say_leaves_no_frame():
    tc = make(OFFSETS, mounted=None)
    tc._set_tool_frame(2)
    assert tc.restore_tool_frame() is False
    assert tc.gcode_transform.tool is None
