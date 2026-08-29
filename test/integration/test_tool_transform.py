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
ff_tool = _load("ff_tool")


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


class FakeGcmd:
    """Only get_int/respond_info -- the clear path needs nothing else."""

    def __init__(self, params):
        self.params = params
        self.messages = []

    def get_int(self, name, default=None, minval=None, maxval=None):
        return int(self.params.get(name, default))

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


# ------------------------------------------------- the third layer, z_adjust

class FakeConfigfile:
    def __init__(self):
        self.staged = []

    def set(self, section, option, value):
        self.staged.append((section, option, value))


def make_tool(z_adjust=0.0):
    tool = ff_tool.FFTool.__new__(ff_tool.FFTool)
    tool.name = "ff_tool 2"
    tool.index = 2
    tool.z_adjust = z_adjust
    configfile = FakeConfigfile()
    tool.printer = FakePrinter(None)
    tool.printer.objects["configfile"] = configfile
    return tool, configfile


def test_a_z_adjust_takes_effect_without_being_saved():
    # The whole point: a first layer is going down and SAVE_CONFIG is a
    # restart. Applying and persisting are separate acts.
    tool, configfile = make_tool()
    tool.set_z_adjust(-0.02)
    assert tool.z_adjust == pytest.approx(-0.02)
    assert configfile.staged == []


def test_saving_a_z_adjust_stages_it_for_save_config():
    tool, configfile = make_tool()
    tool.set_z_adjust(-0.02, save=True)
    assert tool.z_adjust == pytest.approx(-0.02)
    assert configfile.staged == [("ff_tool 2", "z_adjust", "-0.020000")]


def test_a_saved_z_adjust_is_still_live_immediately():
    # SAVE=1 must not mean "on the next restart".
    tool, configfile = make_tool(z_adjust=0.1)
    tool.set_z_adjust(0.25, save=True)
    assert tool.z_adjust == pytest.approx(0.25)
    assert len(configfile.staged) == 1


# ------------------------------------------- the transform exists in time

def test_the_transform_is_built_before_the_first_refresh():
    """refresh_offsets() reads gcode_transform to decide whether
    gcode_move's cache needs invalidating, and __init__ calls it. On a
    calibrated machine the derived offsets differ from the [0.0] seed, so
    the read happens -- and a transform created further down __init__ meant
    AttributeError at config parse on every printer that had ever been
    calibrated. The uncalibrated case, where nothing differs and the read
    is short-circuited, is exactly the one the replica boots in."""
    source = inspect.getsource(ff_toolchange.FFToolchange.__init__)
    built = source.index("self.gcode_transform = _ToolTransform(self)")
    refreshed = source.index("self.refresh_offsets()")
    assert built < refreshed


def test_the_three_offset_series_are_three_lists():
    """self.offset_x = self.offset_y = self.offset_z = [0.] * N binds ONE
    list to three names, so a later write to any of them writes all three."""
    source = inspect.getsource(ff_toolchange.FFToolchange.__init__)
    assert "self.offset_x = self.offset_y" not in source


def test_refreshing_before_the_transform_is_installed_does_not_reset():
    tc = make(OFFSETS)
    tc.gcode_transform.next_transform = None
    tc.offset_base = 0
    tc.tools = [FakeTool() for _ in OFFSETS]
    tc._station_z = lambda: None
    tc._derive_offsets = lambda base: ([9.] * 4, [9.] * 4, [9.] * 4)
    assert tc.refresh_offsets() is True
    assert tc.gcode_move.resets == 0


# ------------------------------------------------------ the job Z is its own

def test_the_job_term_rides_on_the_tool_frame():
    tc = make(OFFSETS)
    tc.gcode_transform.tool = 1
    tc.job_z = 0.04
    tc.gcode_transform.move([10., 20., 5., 1.], 60.)
    sent = tc.gcode_transform.next_transform.moves[0][0]
    assert sent[2] == pytest.approx(5. + 3.19 + 0.04)


def test_the_job_term_is_off_in_raw_machine_coordinates():
    """Dock moves and the offset calibration address the machine. Both
    suspend the frame, and the job term has to go with it."""
    tc = make(OFFSETS)
    tc.job_z = 0.04
    tc.gcode_transform.move([10., 20., 5., 1.], 60.)
    assert tc.gcode_transform.next_transform.moves[0][0] == [10., 20., 5., 1.]


def test_clearing_the_print_offset_leaves_the_tool_frame_alone():
    tc = make(OFFSETS)
    tc.gcode_transform.tool = 2
    tc.job_z = 0.04
    gcmd = FakeGcmd({"CLEAR": 1})
    tc.cmd_TOOLCHANGE_SET_PRINT_OFFSET(gcmd)
    assert tc.job_z == 0.0
    assert tc.gcode_transform.tool == 2
    assert tc.gcode_transform._offsets()[2] == pytest.approx(3.11)
    assert "0.040" in gcmd.messages[0]


def test_the_print_offset_is_absolute_not_cumulative():
    """END_PRINT used to clear this with SET_GCODE_OFFSET Z=0, which took
    the operator's babystep with it. A per-layer caller must also not be
    able to stack the term on itself."""
    tc = make(OFFSETS)
    tc.job_z = 0.04
    source = inspect.getsource(
        ff_toolchange.FFToolchange.cmd_TOOLCHANGE_SET_PRINT_OFFSET)
    assert "self.job_z = z" in source
    assert "self.job_z +=" not in source


# ------------------------------------------------- an uncalibrated tool warns

def test_applying_an_uncalibrated_frame_says_z_zero_is_below_the_bed():
    tc = make(OFFSETS, calibrated=False)
    tc._set_tool_frame(2)
    assert any("no nozzle calibration" in m for m in tc.gcode.messages)


def test_applying_a_calibrated_frame_is_quiet():
    tc = make(OFFSETS)
    tc._set_tool_frame(2)
    assert tc.gcode.messages == []


def test_dropping_the_frame_never_warns():
    tc = make(OFFSETS, calibrated=False)
    tc._set_tool_frame(None)
    assert tc.gcode.messages == []
