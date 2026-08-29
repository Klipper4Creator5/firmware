"""ffscreen.py -- the few lines of text the first boot puts on /dev/fb0.

The contract under test is mostly about restraint. It must refuse to draw at
all rather than guess at a pixel format it does not know, write pixels that
land inside the buffer, and treat every failure as "no screen" instead of an
exception -- it decorates the first-boot migration, and an exception out of a
progress message would take the migration with it.

WHAT IS LEFT. This was thirty-three tests and is five. The geometry probe, the
stride rules, parse_geometry's typo handling, the repaint cache and the text
fit were dropped: their failure mode is a panel that looks wrong, and
qa/replica/test_boot_screen.py already renders real frames on the real machine
and checks the bytes against arithmetic done on the host. What is kept is the
five ways this file can do HARM -- scribble outside the buffer, scribble a
format it does not understand, raise into the migration, or turn the picture.

Geometry does not come from sysfs by default: sysfs reports the wrong panel
size on real hardware, so every real caller passes an explicit geometry, and
the probe only runs when geometry=None is passed in.
"""
import importlib.util
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load():
    path = os.path.join(ROOT, "pkgs", "anvil-core", "payload", "bin", "ffscreen.py")
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
    return ffscreen.Screen(str(dev), str(sysfs), geometry=None), dev


def test_it_draws_nothing_on_a_screen_it_does_not_understand(tmp_path):
    """Guessing at a packing we do not know would scribble diagonal garbage
    across a customer's panel. Not drawing is the correct outcome, and it is
    the outcome for every way the question can fail to have an answer."""
    for bpp in (8, 24, 0):                       # a packing we cannot write
        screen, dev = panel(tmp_path, bpp=bpp)
        assert not screen.ok, bpp
        screen.show("SETTING UP YOUR PRINTER", "WAITING", "", 0.5)
        assert dev.read_bytes() == b"", bpp

    dev = tmp_path / "fb0"
    dev.write_bytes(b"")
    no_sysfs = ffscreen.Screen(str(dev), str(tmp_path / "absent"), geometry=None)
    assert not no_sysfs.ok
    no_sysfs.show("TITLE", "STATUS", "", 0.5)
    assert dev.read_bytes() == b""

    sysfs = tmp_path / "fb0sys"
    assert not ffscreen.Screen(str(tmp_path / "absent"), str(sysfs)).ok
    # an explicit geometry is checked exactly as hard as a probed one
    assert not ffscreen.Screen(str(dev), geometry=(1024, 600, 24)).ok
    assert not ffscreen.Screen(str(dev), geometry=(0, 600, 32)).ok
    assert not ffscreen.Screen(str(dev), geometry=(480, 800, 32), rotate=45).ok


def test_a_frame_is_exactly_one_screen_and_is_painted(tmp_path):
    """Never a byte more than the panel, never a byte less, whatever the
    geometry -- a short write leaves the previous frame showing through the
    bottom of the panel, a long one is somebody else's memory."""
    for width, height, bpp in ((1024, 600, 32),    # the landscape panel
                               (320, 240, 16),     # two bytes a pixel
                               (480, 800, 32)):    # portrait, drawn rotated
        where = "%dx%d@%d" % (width, height, bpp)
        screen, dev = panel(tmp_path, width=width, height=height, bpp=bpp)
        assert screen.ok, where
        screen.show("SETTING UP YOUR PRINTER", "WAITING FOR THE PRINTER", "", None)
        buf = dev.read_bytes()
        assert len(buf) == width * height * (bpp // 8), where
        assert len(buf) == screen.stride * screen.buf_h, where
        assert buf[:bpp // 8] == screen._pixel(ffscreen.BACKGROUND), where
        assert buf.count(screen._pixel(ffscreen.TITLE)) > 0, where


def test_nothing_escapes_the_buffer_whatever_it_is_asked_to_draw(tmp_path):
    """A tiny panel with the longest messages, a full progress bar, and
    characters the font has never heard of. The clip in _rect is what keeps a
    long line from running off the end of a row and shearing the image."""
    screen, dev = panel(tmp_path, width=120, height=90)
    screen.show("SETTING UP YOUR PRINTER", "READING FACTORY CALIBRATION",
                "DO NOT TURN THE PRINTER OFF", 1.0)
    assert len(dev.read_bytes()) == screen.stride * screen.buf_h
    screen.show("SETUP (100%) — wait", "", "", None)
    assert len(dev.read_bytes()) == screen.stride * screen.buf_h
    # The messages are written elsewhere; this is what stops one of them from
    # quietly rendering as a row of gaps.
    used = set("SETTING UP YOUR PRINTER" "STARTING SERVICES"
               "WAITING FOR THE PRINTER" "READING FACTORY CALIBRATION"
               "SAVING CALIBRATION" "RESTARTING THE PRINTER"
               "ALREADY CALIBRATED" "SETUP COMPLETE"
               "SETUP WILL RETRY ON NEXT START"
               "DO NOT TURN THE PRINTER OFF")
    assert used <= set(ffscreen.FONT)


def test_a_device_that_stops_accepting_writes_retires_itself(tmp_path):
    """The failure that must not become an exception: ff-startup draws from
    inside its wait loop, and a raise there ends the migration."""
    screen, _ = panel(tmp_path)
    screen.device = str(tmp_path / "gone" / "fb0")
    screen.show("SETTING UP YOUR PRINTER", "WAITING", "", 0.2)
    assert not screen.ok       # and every later call is a no-op


def test_a_rotated_rectangle_lands_where_the_eye_expects(tmp_path):
    """This machine's framebuffer is PORTRAIT 480x800 while the panel is
    landscape 800x480: the display is the buffer turned 90 degrees clockwise.
    Established from FlashForge's own /usr/prog/start.img, which is 1536000
    bytes and only decodes into a picture at 480x800x4. The whole rotation
    reduces to this -- the top-left of what a person sees is the bottom-left
    of the buffer -- and getting it wrong puts every word on sideways."""
    dev = tmp_path / "fb0"
    dev.write_bytes(b"")

    def at(buf, screen, bx, by):
        step = screen.bpp // 8
        off = by * screen.stride + bx * step
        return bytes(buf[off:off + step])

    screen = ffscreen.Screen(str(dev), geometry=(480, 800, 32), rotate=90)
    assert (screen.width, screen.height) == (800, 480)   # what callers draw on
    buf = screen._blank()
    screen._rect(buf, 0, 0, 4, 4, ffscreen.TITLE)        # display top-left
    assert at(buf, screen, 0, screen.buf_h - 1) == screen._pixel(ffscreen.TITLE)
    assert at(buf, screen, 0, 0) == screen._pixel(ffscreen.BACKGROUND)
    # a display-x move walks DOWN the buffer, not across it
    buf = screen._blank()
    screen._rect(buf, 100, 0, 4, 4, ffscreen.TITLE)
    assert at(buf, screen, 0, screen.buf_h - 101) == screen._pixel(ffscreen.TITLE)

    # 270 is the mirror of it, and a landscape buffer is left alone
    screen = ffscreen.Screen(str(dev), geometry=(480, 800, 32), rotate=270)
    buf = screen._blank()
    screen._rect(buf, 0, 0, 4, 4, ffscreen.TITLE)
    assert at(buf, screen, screen.buf_w - 1, 0) == screen._pixel(ffscreen.TITLE)
    assert ffscreen.Screen(str(dev), geometry=(1024, 600, 32)).rotate == 0
