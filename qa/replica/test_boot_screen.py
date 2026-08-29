"""The first-boot screen, drawn by the printer's own interpreter.

A port of the retired test/integration/printer/case-boot-screen.sh.

WHAT THIS ADDS OVER test/integration/test_ffscreen.py. That file is the
host-side unit coverage -- pixel formats, buffer bounds, rotation arithmetic,
degradation to "no screen" -- and it runs ffscreen.py on the DEVELOPER's
CPython. None of it can say whether the file executes on the machine it ships
to. What only a replica can answer:

  * whether $MODDIR/bin/python3.13 -- our own cross-built CPython 3.13,
    running here under qemu-mipsel -- executes this code at all. ffscreen.py
    is stdlib-only and that has been reasoned about; reasoning has not been
    enough before, so the interpreter runs it.
  * whether anvil-env.sh, the file every real caller sources, actually
    resolves FF_PYTHON to that interpreter.
  * whether ff-startup.py finds its two siblings when run BY PATH, which is
    the only way its plain-name imports resolve. A silently missing
    ff_mcu_bringup means the boards are never handed over and klippy opens
    ports at bootloaders; a silently missing ffscreen means a black panel
    forever. Both imports are optional by design, so neither failure is loud.
  * whether the bytes land where the arithmetic says, on this kernel and this
    interpreter. A stride or bpp error produces a sheared panel, not an
    exception, so the check has to be on the buffer itself.

WHAT IS REAL HERE AND WHAT IS NOT

NO PANEL IS INVOLVED. There is no framebuffer driver, no display and no
kernel fb device in the replica: assemble.sh:103 creates /dev/fb0 as an empty
REGULAR FILE (`: > $R/dev/fb0`, so that the stock installer's
`cat start.img > /dev/fb0` works). That is exactly what a framebuffer is from
a writer's point of view -- open, seekless write of one screen's worth of
bytes -- so the code path under test is the real one, but "it drew" here
means "it wrote the right bytes to a file", never "a picture appeared".
test_the_replica_has_only_a_stand_in_framebuffer asserts that stand-in rather
than leaving it as an assumption, because a test that passes when nothing was
drawn is worse than no test.

GEOMETRY IS PASSED EXPLICITLY, for the same reason the case script passed it:
assemble.sh mounts the host's /sys read-only, so a sysfs probe in here would
describe the developer's monitor. The numbers are the machine's real ones --
a PORTRAIT 480x800 framebuffer at 32bpp shown on a landscape 800x480 panel
turned 90 degrees clockwise -- established from FlashForge's own
/usr/prog/start.img, which is 1536000 bytes and only decodes into a picture
when read that way.

WHAT WAS DROPPED FROM THE CASE SCRIPT

  * its whole staging preamble -- unpacking /mnt/py.tgz into $MODDIR and
    `cp /tmp/payload/bin/*.py` -- and with it gates.py's boot_screen() Skip
    when nothing had built an interpreter. The `printer` fixture installs the
    real package through the printer's own app_startup.sh, so the
    interpreter and the three scripts are there because the INSTALLER put
    them there. test_the_installer_placed_the_boot_screen_scripts asserts
    that, which is strictly more than the case script could ask: it hand-fed
    itself the files it then checked for.
  * `ok`/`bad` and the FAIL counter. Each of them is a test below.

Not in scope: tools/replica/printer/case-boot-screen-dump.sh, which renders
frames as base64 PNGs for a human to look at under `make boot-screen-sim`. It
is a viewer, not a test.
"""
import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
PY = MODDIR + "/bin/python3.13"
FB = "/dev/fb0"

# The panel, as the machine really has it: see the module docstring.
W, H, BPP = 480, 800, 32
ONE_SCREEN = W * H * BPP // 8          # 1536000, and start.img's own size

# What the eye sees, once the 90-degree turn is applied.
LANDSCAPE = (800, 480)

SCRIPTS = ("ffscreen.py", "ff-startup.py", "ff_mcu_bringup.py")

# Every action below runs through the file the boot runs through. MODDIR must
# be set BEFORE sourcing: anvil-env.sh's own FF_PYTHON line reads $MODDIR, so
# without it FF_PYTHON resolves to the empty-prefix "/bin/python3.13" -- the
# trap the case script carried an alias for.
ENV = 'MODDIR=%s; . %s/anvil-env.sh; ' % (MODDIR, MODDIR)

# ffscreen.py lives beside the scripts that import it, not on a path any
# interpreter knows about; ff-startup.py gets this for free by being run by
# path, and `python -c` does not.
IMPORT = "import sys; sys.path.insert(0, %r); import ffscreen" % (MODDIR + "/bin")


def _pack32(rgb):
    """One 32bpp pixel, as the usual Linux packing has it: B, G, R, ignored.

    Computed HERE rather than by calling ffscreen._pixel inside the replica,
    which is what the case script did. That made the buffer check ask the
    packing arithmetic to confirm its own output -- a swapped R and B would
    have matched itself perfectly. The palette still comes from the shipped
    file (see the `palette` fixture); only the packing is independent.
    """
    r, g, b = rgb
    return bytes((b, g, r, 0xFF))


@pytest.fixture(scope="module")
def box(printer):
    """The installed machine, checked once for the things every test needs.

    Once, here, because a package built before the CPython switch fails every
    test below for the same single reason, and twelve identical failures hide
    which one thing is wrong.
    """
    if not printer.file(PY).executable:
        pytest.fail(
            "this package ships no interpreter for the boot screen: %s is "
            "missing, so nothing here can run. FF_PYTHON has pointed at our "
            "own cross-built CPython 3.13 since the switch -- build a package "
            "from this tree (`make build`) and the replica lane picks up the "
            "newest work/out/*.tgz." % PY)
    return printer


@pytest.fixture(scope="module")
def palette(box):
    """BACKGROUND, TITLE and BAR_FG as the SHIPPED ffscreen.py defines them.

    Read out of the replica rather than repeated here, so that restyling the
    screen does not fail this module for a colour change. What is asserted is
    that those three colours reach the buffer, not what they are.
    """
    got = box.sh(ENV + '"$FF_PYTHON" -c "%s\n'
                 'print(ffscreen.BACKGROUND, ffscreen.TITLE, ffscreen.BAR_FG)" 2>&1'
                 % IMPORT)
    assert got.ok, "could not read ffscreen's palette: %s" % got.text
    numbers = [int(n) for n in got.text.replace("(", " ").replace(")", " ")
               .replace(",", " ").split()]
    assert len(numbers) == 9, "unexpected palette output: %s" % got.text
    return {"background": _pack32(numbers[0:3]),
            "title": _pack32(numbers[3:6]),
            "bar": _pack32(numbers[6:9])}


@pytest.fixture(scope="module")
def frame(box, palette):
    """Draw one real frame onto the replica's /dev/fb0 and read it back.

    ACTION HERE, ASSERTIONS BELOW. The drawing is one shot -- truncate the
    device, paint, then reopen it and report facts -- because each `docker
    exec` starts a fresh qemu-mipsel interpreter and a test per fact would
    pay for twelve of them. Every number this returns is measured inside the
    machine; nothing in this fixture decides pass or fail.

    The four-byte patterns are counted with `bytes.count`, which is a C-level
    scan of 1.5MB rather than a python loop over 384000 pixels on a 1GHz MIPS
    core under emulation.

    The device is truncated first so that "the background was painted" means
    something: the file starts at zero bytes.
    """
    box.sh(": > %s" % FB)
    drawn = box.sh(ENV + '"$FF_PYTHON" -c "\n'
                   '%s\n'
                   "s = ffscreen.Screen(%r, geometry=(%d, %d, %d))\n"
                   "if not s.ok:\n"
                   "    print('refused: screen is not ok'); raise SystemExit(1)\n"
                   # The first-boot frame itself: title, status, note,
                   # progress -- the same call ff-startup.py makes while
                   # klipper is finding its MCUs.
                   "s.show('SETTING UP YOUR PRINTER', 'READING FACTORY CALIBRATION',\n"
                   "       'DO NOT TURN THE PRINTER OFF', 0.5)\n"
                   "buf = open(%r, 'rb').read()\n"
                   "print('stride', s.stride)\n"
                   "print('rotate', s.rotate)\n"
                   "print('surface', s.width, s.height)\n"
                   "print('size', len(buf))\n"
                   "print('corner', buf[:4].hex())\n"
                   # Hex rather than a bytes repr: a repr goes through this
                   # command's own double quotes, and a palette value that
                   # happened to be 0x27 would put an apostrophe in there and
                   # end the shell string early.
                   "print('background', buf.count(bytes.fromhex('%s')))\n"
                   "print('title', buf.count(bytes.fromhex('%s')))\n"
                   "print('bar', buf.count(bytes.fromhex('%s')))\n"
                   '" 2>&1'
                   % (IMPORT, FB, W, H, BPP, FB,
                      palette["background"].hex(), palette["title"].hex(),
                      palette["bar"].hex()))
    facts = {}
    for line in drawn.text.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            facts[parts[0]] = parts[1:]
    facts["_text"] = drawn.text
    facts["_ok"] = drawn.ok
    return facts


# ------------------------------------------------- what the machine supplies

def test_the_replica_has_only_a_stand_in_framebuffer(box):
    """Stated as a test so nothing below can be read as more than it is.

    assemble.sh makes /dev/fb0 a plain file. If a real character device ever
    appeared here, every "it drew" assertion in this module would be asking a
    different and much better question -- and this failing is how anyone would
    find that out, rather than by trusting the docstring.
    """
    assert box.file(FB).exists, (
        "%s is absent, so this module tests nothing. assemble.sh creates it "
        "as an empty regular file -- see assemble.sh:103." % FB)
    kind = box.sh("[ -f %s ] && echo regular || echo other" % FB).first_line
    assert kind == "regular", (
        "%s is %r, not the regular file assemble.sh creates. If the replica "
        "has grown a real framebuffer, this module's claim that no panel is "
        "involved is out of date." % (FB, kind))


def test_the_installer_placed_the_boot_screen_scripts(box):
    """The case script COPIED these out of /tmp/payload and then checked they
    had arrived, which only ever tested its own `cp`. Here the package was
    installed by the printer's own app_startup.sh, so this asks whether the
    installer shipped them."""
    missing = [name for name in SCRIPTS
               if not box.file(MODDIR + "/bin/" + name).exists]
    assert not missing, (
        "the installed package has no %s in %s/bin -- anvil-core stages "
        "pkgs/anvil-core/payload/bin wholesale, so a name missing here means "
        "the recipe or the install dropped it"
        % (", ".join(missing), MODDIR))


def test_ff_startup_is_executable(box):
    """It is run by path by the s6 service, not by `python ff-startup.py`."""
    assert box.file(MODDIR + "/bin/ff-startup.py").executable, (
        "%s/bin/ff-startup.py is not executable -- anvil-core's build.sh "
        "chmods +x over payload/bin, so this means it did not." % MODDIR)


# ----------------------------------------------------------- the environment

def test_anvil_env_resolves_ff_python_to_our_own_interpreter(box):
    """Sourced, not retyped: a copy of these exports in the harness is what
    let this check drift away from the real ones before."""
    got = box.sh(ENV + 'echo "$FF_PYTHON"')
    assert got.first_line == PY, (
        "anvil-env.sh set FF_PYTHON to %r, expected %s"
        % (got.first_line, PY))


def test_ff_python_is_the_interpreter_that_is_there(box):
    assert box.file(PY).executable, "%s is not executable" % PY


# ------------------------------------------------------- it runs on 3.13/qemu

def test_ffscreen_imports_on_the_printers_interpreter(box):
    """The whole reason this gate is on a replica: ffscreen.py's stdlib-only
    imports have been checked against CPython's removed-in-3.13 list by
    reading, and reading has not been enough before."""
    got = box.sh(ENV + '"$FF_PYTHON" -c "%s; print(\'glyphs\', len(ffscreen.FONT))" 2>&1'
                 % IMPORT)
    assert got.ok, "ffscreen does not import on %s: %s" % (PY, got.text)
    assert "glyphs" in got.text, got.text
    glyphs = int(got.text.split("glyphs")[1].split()[0])
    assert glyphs > 40, "the font has only %d glyphs: %s" % (glyphs, got.text)


def test_ff_startup_runs_under_the_printers_interpreter(box):
    """--help exits before any I/O, so this is purely "does this interpreter
    accept the syntax and the imports"."""
    got = box.sh(ENV + '"$FF_PYTHON" %s/bin/ff-startup.py --help 2>&1' % MODDIR)
    assert got.ok, "ff-startup.py --help failed: %s" % got.text


def test_ff_startup_reaches_both_of_its_siblings(box):
    """ff-startup.py imports ffscreen and ff_mcu_bringup by PLAIN NAME, which
    resolves only because python puts a script's own directory on sys.path --
    true when the s6 service runs it by path, false the moment anything loads
    it another way. Both imports are wrapped in try/except by design, so a
    failure is silent: no ffscreen means a black panel for the whole install,
    and no ff_mcu_bringup means the boards are never handed over and klippy
    opens the ports at bootloaders. Only the script running ITSELF can tell,
    which is what --selftest is."""
    got = box.sh(ENV + '"$FF_PYTHON" %s/bin/ff-startup.py --selftest 2>&1' % MODDIR)
    assert got.ok, "ff-startup.py --selftest exited %d: %s" % (got.code, got.text)
    lines = got.text.splitlines()
    assert "ffscreen: yes" in lines, got.text
    assert "ff_mcu_bringup: yes" in lines, got.text
    assert "selftest: ok" in lines, got.text


def test_the_selftest_names_all_three_boards(box):
    """Three ports, each with a name of its own -- board_name() falling back
    to "THE ..." is what the selftest's `named:` line reports."""
    got = box.sh(ENV + '"$FF_PYTHON" %s/bin/ff-startup.py --selftest 2>&1' % MODDIR)
    ports = [ln for ln in got.text.splitlines() if ln.startswith("ports: ")]
    assert ports, "the selftest reported no ports at all: %s" % got.text
    assert ports[0].startswith("ports: 3"), ports[0]
    assert "named: yes" in got.text.splitlines(), got.text


# --------------------------------------------------------------- the frame

def test_a_frame_is_drawn(frame):
    """Everything below reads this same frame, so its failure is reported
    once here rather than as eight mysterious KeyErrors."""
    assert frame["_ok"], "drawing failed: %s" % frame["_text"]
    assert "stride" in frame, "no stride reported: %s" % frame["_text"]
    assert int(frame["stride"][0]) == W * (BPP // 8), (
        "stride is %s, expected %d for %dx%d@%d"
        % (frame["stride"][0], W * (BPP // 8), W, H, BPP))


def test_the_frame_is_exactly_one_screen(frame):
    """A stride or bpp mistake shows up here as a short or long file, long
    before anyone sees a sheared panel. 1536000 is also start.img's own size,
    which is where the geometry came from."""
    assert "size" in frame, frame["_text"]
    assert int(frame["size"][0]) == ONE_SCREEN, (
        "the frame is %s bytes, expected %d (%dx%d at %dbpp)"
        % (frame["size"][0], ONE_SCREEN, W, H, BPP))


def test_the_frame_is_rotated_for_the_panel(frame):
    """A portrait buffer means a panel mounted sideways: 480x800 stored,
    800x480 drawn on. Everything above _rect works in landscape, so getting
    this wrong is a frame drawn into a fifth of the screen."""
    assert "rotate" in frame, frame["_text"]
    assert int(frame["rotate"][0]) == 90, (
        "rotate is %s, expected 90 for a %dx%d buffer"
        % (frame["rotate"][0], W, H))
    surface = tuple(int(n) for n in frame["surface"])
    assert surface == LANDSCAPE, (
        "the drawing surface is %s, expected %s" % (surface, LANDSCAPE))


def test_the_background_was_painted(frame, palette):
    """The device was truncated to zero bytes first, so a background-coloured
    pixel in the top-left corner is proof that this frame was written, rather
    than that the file happens to exist. The corner is also the one pixel no
    text or bar can reach, so it is background or it is a bug."""
    assert "corner" in frame, frame["_text"]
    corner = frame["corner"][0]
    assert corner == palette["background"].hex(), (
        "the first pixel is %s, expected the background %s -- an all-zero "
        "corner means nothing was drawn, anything else means the packing or "
        "the stride is wrong" % (corner, palette["background"].hex()))
    assert int(frame["background"][0]) > 0, (
        "not one background pixel in the buffer: %s" % frame["_text"])


def test_the_title_reached_the_buffer(frame):
    """Text, not just a painted rectangle: the title's white has to appear
    somewhere, which it only does if _text and _rect agreed on coordinates."""
    assert int(frame["title"][0]) > 0, (
        "no title-coloured pixel anywhere in the frame: %s" % frame["_text"])


def test_the_progress_bar_reached_the_buffer(frame):
    assert int(frame["bar"][0]) > 0, (
        "no progress-bar pixel anywhere in the frame, though the frame was "
        "drawn with progress=0.5: %s" % frame["_text"])


def test_clear_leaves_the_panel_black(frame, box):
    """HelixScreen paints its own splash on top of whatever is there, so a
    frame left behind is our text under their UI. Depends on `frame` both for
    ordering -- there must be something to clear -- and because it destroys
    what the tests above read."""
    got = box.sh(ENV + '"$FF_PYTHON" -c "\n'
                 "%s\n"
                 "ffscreen.Screen(%r, geometry=(%d, %d, %d)).clear()\n"
                 "buf = open(%r, 'rb').read()\n"
                 "print('size', len(buf))\n"
                 "print('nonzero', len(buf) - buf.count(b'\\x00'))\n"
                 '" 2>&1' % (IMPORT, FB, W, H, BPP, FB))
    assert got.ok, "clear() failed: %s" % got.text
    assert "nonzero 0" in got.text.splitlines(), (
        "clear() left something on the panel: %s" % got.text)
    assert "size %d" % ONE_SCREEN in got.text.splitlines(), (
        "clear() wrote a buffer that is not one screen: %s" % got.text)


# -------------------------------------------------------------- no panel

def test_a_missing_framebuffer_is_a_no_op_not_an_error(box):
    """This runs on EVERY first boot, and a printer with no panel -- or a
    panel that stops accepting writes -- must still get its calibration. So
    the absent case has to be silent, not fatal. Asked on the machine rather
    than only on the host, because the failure that matters is an interpreter
    raising something the host's does not."""
    got = box.sh(ENV + '"$FF_PYTHON" -c "\n'
                 "%s\n"
                 "s = ffscreen.Screen('/dev/does-not-exist', geometry=(%d, %d, %d))\n"
                 "print('ok', s.ok)\n"
                 "s.show('T', 'S', 'N', 0.5)\n"
                 "s.clear()\n"
                 "print('survived')\n"
                 '" 2>&1' % (IMPORT, W, H, BPP))
    assert got.ok, "a missing framebuffer raised: %s" % got.text
    lines = got.text.splitlines()
    assert "ok False" in lines, (
        "Screen reported ok for a device that does not exist: %s" % got.text)
    assert "survived" in lines, (
        "show() or clear() did not return on a screen with no device: %s"
        % got.text)
