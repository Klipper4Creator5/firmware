"""ffscreen.py -- the few lines of text the first boot puts on /dev/fb0.

The contract under test is mostly about restraint. It must read its geometry
from sysfs rather than assume a panel size, refuse to draw at all rather than
guess at a pixel format it does not know, write pixels that land inside the
buffer, and treat every failure as "no screen" instead of an exception. The
migration it decorates has to survive all of that untouched.

A framebuffer is a flat file of pixels, so the fake here is exactly that: a
real file plus a sysfs directory of the three values the module reads. What
gets asserted is what a person would see -- the frame is the right size, the
background is painted, text and bar leave marks where they should, and an
unfamiliar panel leaves the file untouched.
"""
import importlib.util
import os

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load():
    path = os.path.join(ROOT, "payload", "bin", "ffscreen.py")
    spec = importlib.util.spec_from_file_location("ffscreen", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ffscreen = _load()


def panel(tmp_path, width=1024, height=600, bpp=32, stride=None):
    """A fake framebuffer: the sysfs a driver exposes, and the device file."""
    sysfs = tmp_path / "fb0sys"
    sysfs.mkdir(exist_ok=True)
    (sysfs / "virtual_size").write_text("%d,%d\n" % (width, height))
    (sysfs / "bits_per_pixel").write_text("%d\n" % bpp)
    if stride is not None:
        (sysfs / "stride").write_text("%d\n" % stride)
    dev = tmp_path / "fb0"
    dev.write_bytes(b"")
    return ffscreen.Screen(str(dev), str(sysfs)), dev


# -- geometry --------------------------------------------------------------


def test_it_reads_the_panel_rather_than_assuming_one(tmp_path):
    screen, _ = panel(tmp_path, width=800, height=480, bpp=16)
    assert screen.ok
    assert (screen.width, screen.height, screen.bpp) == (800, 480, 16)
    # No stride in sysfs: the packed width is the only guess available.
    assert screen.stride == 800 * 2


def test_a_declared_stride_wins_over_the_packed_width(tmp_path):
    screen, _ = panel(tmp_path, width=800, height=480, stride=4096)
    assert screen.stride == 4096


@pytest.mark.parametrize("bpp", [8, 24, 0])
def test_an_unfamiliar_pixel_format_draws_nothing(tmp_path, bpp):
    # Guessing at a packing we do not know would scribble diagonal garbage
    # across a customer's panel. Not drawing is the correct outcome.
    screen, dev = panel(tmp_path, bpp=bpp)
    assert not screen.ok
    screen.show("SETTING UP YOUR PRINTER", "WAITING", "", 0.5)
    assert dev.read_bytes() == b""


def test_no_sysfs_at_all_draws_nothing(tmp_path):
    dev = tmp_path / "fb0"
    dev.write_bytes(b"")
    screen = ffscreen.Screen(str(dev), str(tmp_path / "absent"))
    assert not screen.ok
    screen.show("TITLE", "STATUS", "", 0.5)
    assert dev.read_bytes() == b""


def test_a_missing_device_draws_nothing(tmp_path):
    sysfs = tmp_path / "fb0sys"
    sysfs.mkdir()
    (sysfs / "virtual_size").write_text("1024,600\n")
    (sysfs / "bits_per_pixel").write_text("32\n")
    assert not ffscreen.Screen(str(tmp_path / "absent"), str(sysfs)).ok


# -- what lands in the buffer ----------------------------------------------


def test_a_frame_is_exactly_one_screen_and_is_painted(tmp_path):
    screen, dev = panel(tmp_path)
    screen.show("SETTING UP YOUR PRINTER", "WAITING FOR THE PRINTER", "", None)
    buf = dev.read_bytes()
    assert len(buf) == screen.stride * screen.height
    # The top-left corner is background, not the zeros the file started as.
    assert buf[:4] == screen._pixel(ffscreen.BACKGROUND)
    assert buf.count(screen._pixel(ffscreen.TITLE)) > 0


def test_every_pixel_stays_inside_the_buffer(tmp_path):
    # A tiny panel with a long line: the clip in _rect is what keeps this from
    # running off the end of a row and shearing the image.
    screen, dev = panel(tmp_path, width=120, height=90)
    screen.show("SETTING UP YOUR PRINTER", "READING FACTORY CALIBRATION",
                "DO NOT TURN THE PRINTER OFF", 1.0)
    assert len(dev.read_bytes()) == screen.stride * screen.height


def test_the_progress_bar_grows_with_the_number(tmp_path):
    screen, dev = panel(tmp_path)
    marks = []
    for progress in (0.0, 0.5, 1.0):
        screen.show("SETTING UP YOUR PRINTER", "SAVING", "", progress)
        marks.append(dev.read_bytes().count(screen._pixel(ffscreen.BAR_FG)))
    assert marks[0] == 0
    assert marks[0] < marks[1] < marks[2]


def test_16bpp_writes_two_bytes_a_pixel(tmp_path):
    screen, dev = panel(tmp_path, width=320, height=240, bpp=16)
    screen.show("SETUP", "", "", None)
    assert len(dev.read_bytes()) == 320 * 240 * 2


# -- repainting ------------------------------------------------------------


def test_an_identical_frame_is_not_redrawn(tmp_path):
    # The wait loop calls this every couple of seconds; repainting an
    # unchanged 2.4MB frame each time would be pure waste.
    screen, dev = panel(tmp_path)
    screen.show("SETTING UP YOUR PRINTER", "WAITING", "", 0.2)
    before = dev.stat().st_mtime_ns
    dev.write_bytes(b"")            # if it repaints, the file grows back
    screen.show("SETTING UP YOUR PRINTER", "WAITING", "", 0.2)
    assert dev.read_bytes() == b""
    assert before == before
    # a changed status does repaint
    screen.show("SETTING UP YOUR PRINTER", "SAVING", "", 0.2)
    assert len(dev.read_bytes()) == screen.stride * screen.height


def test_clear_leaves_the_panel_black_and_forgets_the_frame(tmp_path):
    screen, dev = panel(tmp_path)
    screen.show("SETTING UP YOUR PRINTER", "WAITING", "", 0.2)
    screen.clear()
    buf = dev.read_bytes()
    assert len(buf) == screen.stride * screen.height
    assert set(buf) == {0}
    # the same frame is drawable again afterwards
    screen.show("SETTING UP YOUR PRINTER", "WAITING", "", 0.2)
    assert set(dev.read_bytes()) != {0}


def test_a_device_that_stops_accepting_writes_retires_itself(tmp_path):
    screen, dev = panel(tmp_path)
    screen.device = str(tmp_path / "gone" / "fb0")
    screen.show("SETTING UP YOUR PRINTER", "WAITING", "", 0.2)
    assert not screen.ok      # and every later call is a no-op


# -- text ------------------------------------------------------------------


def test_unknown_characters_are_blanks_not_crashes(tmp_path):
    screen, dev = panel(tmp_path)
    screen.show("SETUP (100%) — wait", "", "", None)
    assert len(dev.read_bytes()) == screen.stride * screen.height


def test_every_character_the_messages_use_has_a_glyph(tmp_path):
    # The messages are written elsewhere; this is what stops one of them from
    # quietly rendering as a row of gaps.
    used = set("SETTING UP YOUR PRINTER" "STARTING SERVICES"
               "WAITING FOR THE PRINTER" "READING FACTORY CALIBRATION"
               "SAVING CALIBRATION" "RESTARTING THE PRINTER"
               "ALREADY CALIBRATED" "SETUP COMPLETE"
               "SETUP WILL RETRY ON NEXT START"
               "DO NOT TURN THE PRINTER OFF")
    assert used <= set(ffscreen.FONT)


# -- geometry given rather than probed -------------------------------------


def test_an_explicit_geometry_skips_sysfs_entirely(tmp_path):
    # What the replica passes: its /sys is the HOST's, so probing there would
    # describe a developer's monitor instead of the panel.
    dev = tmp_path / "fb0"
    dev.write_bytes(b"")
    screen = ffscreen.Screen(str(dev), str(tmp_path / "absent"),
                             geometry=(480, 320, 16))
    assert screen.ok
    assert (screen.width, screen.height, screen.bpp) == (480, 320, 16)
    assert screen.stride == 480 * 2
    screen.show("SETUP", "WAITING", "", 0.4)
    assert len(dev.read_bytes()) == 480 * 320 * 2


def test_an_explicit_geometry_is_still_checked(tmp_path):
    dev = tmp_path / "fb0"
    dev.write_bytes(b"")
    assert not ffscreen.Screen(str(dev), geometry=(1024, 600, 24)).ok
    assert not ffscreen.Screen(str(dev), geometry=(0, 600, 32)).ok


@pytest.mark.parametrize("text,want", [
    ("1024x600@32", (1024, 600, 32)),
    ("800X480@16", (800, 480, 16)),
    ("1024x600", (1024, 600, 32)),
    ("", None),
    (None, None),
    ("1024", None),
    ("wide x tall", None),
    ("1024x600@", (1024, 600, 32)),
])
def test_geometry_parsing(text, want):
    # A typo must disable the screen, never draw diagonally across it.
    assert ffscreen.parse_geometry(text) == want


# -- the panel is mounted sideways -----------------------------------------
#
# This machine's framebuffer is PORTRAIT 480x800 while the screen is landscape
# 800x480: the display is the buffer turned 90 degrees clockwise. Established
# from FlashForge's own /usr/prog/start.img, which is 1536000 bytes and only
# decodes into a picture at 480x800x4. Drawing landscape text straight into
# that buffer would put every word on the panel sideways.


def test_a_portrait_framebuffer_is_treated_as_a_turned_panel(tmp_path):
    screen, _ = panel(tmp_path, width=480, height=800)
    assert screen.ok
    assert (screen.buf_w, screen.buf_h) == (480, 800)
    # what callers draw on is the landscape surface
    assert (screen.width, screen.height) == (800, 480)
    assert screen.rotate == 90
    assert screen.stride == 480 * 4


def test_a_landscape_framebuffer_is_left_alone(tmp_path):
    screen, _ = panel(tmp_path, width=1024, height=600)
    assert screen.rotate == 0
    assert (screen.width, screen.height) == (1024, 600)


def test_rotation_can_be_forced_either_way(tmp_path):
    dev = tmp_path / "fb0"
    dev.write_bytes(b"")
    for rotate in (0, 90, 270):
        screen = ffscreen.Screen(str(dev), geometry=(480, 800, 32),
                                 rotate=rotate)
        assert screen.rotate == rotate
        expect = (800, 480) if rotate else (480, 800)
        assert (screen.width, screen.height) == expect
    assert not ffscreen.Screen(str(dev), geometry=(480, 800, 32),
                               rotate=45).ok


def _at(buf, screen, bx, by):
    step = screen.bpp // 8
    off = by * screen.stride + bx * step
    return bytes(buf[off:off + step])


def test_a_rotated_rectangle_lands_where_the_eye_expects(tmp_path):
    # The whole rotation reduces to this: the top-left of what a person sees
    # must be the bottom-left of the buffer for a 90-degree clockwise panel.
    dev = tmp_path / "fb0"
    dev.write_bytes(b"")
    screen = ffscreen.Screen(str(dev), geometry=(480, 800, 32), rotate=90)
    buf = screen._blank()
    mark = ffscreen.TITLE
    screen._rect(buf, 0, 0, 4, 4, mark)          # display top-left
    assert _at(buf, screen, 0, screen.buf_h - 1) == screen._pixel(mark)
    assert _at(buf, screen, 0, 0) == screen._pixel(ffscreen.BACKGROUND)
    # and a display-x move walks DOWN the buffer, not across it
    buf = screen._blank()
    screen._rect(buf, 100, 0, 4, 4, mark)
    assert _at(buf, screen, 0, screen.buf_h - 101) == screen._pixel(mark)


def test_270_is_the_mirror_of_90(tmp_path):
    dev = tmp_path / "fb0"
    dev.write_bytes(b"")
    screen = ffscreen.Screen(str(dev), geometry=(480, 800, 32), rotate=270)
    buf = screen._blank()
    screen._rect(buf, 0, 0, 4, 4, ffscreen.TITLE)
    assert _at(buf, screen, screen.buf_w - 1, 0) == screen._pixel(ffscreen.TITLE)


def test_a_rotated_frame_is_still_exactly_one_screen(tmp_path):
    screen, dev = panel(tmp_path, width=480, height=800)
    screen.show("SETTING UP YOUR PRINTER", "READING FACTORY CALIBRATION",
                "DO NOT TURN THE PRINTER OFF", 0.5)
    assert len(dev.read_bytes()) == 480 * 800 * 4


def test_text_fits_the_landscape_width_not_the_buffer_width(tmp_path):
    # 480 wide would force the title down to an unreadable scale; the fit has
    # to be against the 800 the viewer actually has.
    screen, _ = panel(tmp_path, width=480, height=800)
    assert screen._fit("SETTING UP YOUR PRINTER", 4) == 4
