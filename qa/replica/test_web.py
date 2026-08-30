"""The web half of the boot, which is the half a replica can actually run.

WHY THIS IS NOT IN test_s6rc.py. That module's `booted` fixture runs the real
firmwareExe and waits for `ok-all`, and on a replica `ok-all` is unreachable:
there are no /dev/ttyS4,5,7 so klippy never connects, and no /dev/video* so
camera times out. Worse for a test that wants a live daemon, `ff-startup` then
sits out its 300000ms timeout-up waiting for klipper WHILE HOLDING THE S6-RC
LOCK, so nothing can even be asked of the tree during that window.

nginx and moonraker need none of that hardware and do come up -- measured, with
moonraker reaching `ready`. So this module brings up exactly those two and
asserts what `case-nginx.sh` and `case-moonraker313-s6.sh` asserted before they
were retired with the S* wrappers they drove.

Bringing up a subset is a departure from "run the real boot, do not
reimplement it", and it is a deliberate one: the alternative is asserting
nothing about supervision until somebody builds the simulated-MCU lane. The
departure is kept honest by going through the SAME compiled database and the
same s6-rc the boot uses -- only the transition's argument differs.

Its own module, so it gets its own container: the fixture must run before
anything takes the s6-rc lock.
"""
import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
SCANDIR = MODDIR + "/etc/s6"
LIVE = "/run/s6-rc"
DB = MODDIR + "/etc/s6-rc/compiled/current"

# As firmwareExe: s6-rc and s6-rc-init default to TAIN_INFINITE_RELATIVE, which
# does not fit a 32-bit time_t, so every call carries a finite deadline or dies
# with EOVERFLOW before it does anything.
S6RC_T = 30000
CHANGE_T = 120000


@pytest.fixture(scope="module")
def web(printer):
    """nginx and moonraker up, under the s6 we shipped."""
    if not printer.file(MODDIR + "/bin/s6-svscan").executable:
        pytest.fail("this package ships no supervisor: %s/bin/s6-svscan is "
                    "missing. Build a package from this tree -- `make build`."
                    % MODDIR)

    printer.sh("mkdir -p %s" % SCANDIR)
    printer.sh("setsid %s/bin/s6-svscan %s >>%s/etc/s6-svscan.log 2>&1 &"
               % (MODDIR, SCANDIR, MODDIR))
    for _ in range(20):
        if printer.sh("%s/bin/s6-svscanctl -a %s" % (MODDIR, SCANDIR)).ok:
            break
        printer.sh("sleep 1")
    else:
        pytest.fail("s6-svscan never answered on %s" % SCANDIR)

    started = printer.sh("%s/bin/s6-rc-init -t %d -c %s -l %s %s 2>&1"
                         % (MODDIR, S6RC_T, DB, LIVE, SCANDIR))
    assert started.ok, "s6-rc-init failed: %s" % started.text

    change = printer.sh("%s/bin/s6-rc -l %s -t %d -u change nginx moonraker 2>&1"
                        % (MODDIR, LIVE, CHANGE_T))
    assert change.ok, "could not bring up nginx and moonraker: %s" % change.text
    return printer


def _svstat(box, service):
    return box.sh("%s/bin/s6-svstat %s/servicedirs/%s" % (MODDIR, LIVE, service)).text


# ------------------------------------------------------------------ nginx

def test_nginx_is_up(web):
    assert _svstat(web, "nginx").startswith("up"), _svstat(web, "nginx")


def test_nginx_is_listening(web):
    """Serving, not merely forked -- the distinction case-nginx.sh existed for."""
    assert web.listening(80), "nothing is listening on :80"


def test_nginx_comes_back_after_a_kill(web):
    """The reason for shipping a supervisor at all. `s6-svc -wr` does not
    return until s6 has it running again, so this is a verdict rather than a
    sleep."""
    before = web.pgrep("nginx")
    assert before, "no nginx to kill"
    web.sh("%s/bin/s6-svc -wr -T 60000 -t %s/servicedirs/nginx"
           % (MODDIR, LIVE))
    after = web.pgrep("nginx")
    assert after, "nginx did not come back after being killed"
    assert {p.pid for p in after} != {p.pid for p in before}, (
        "the same pids are still there -- nothing was actually restarted")


def test_a_stopped_nginx_stays_stopped(web):
    """A supervisor that restarts a deliberate stop is worse than none: it
    makes the machine impossible to service. Restored afterwards, because the
    module shares one container."""
    try:
        web.sh("%s/bin/s6-svc -wd -T 60000 -d %s/servicedirs/nginx"
               % (MODDIR, LIVE))
        web.sh("sleep 3")
        assert _svstat(web, "nginx").startswith("down"), _svstat(web, "nginx")
        assert not web.listening(80), "still serving after a stop"
    finally:
        web.sh("%s/bin/s6-svc -wu -T 60000 -u %s/servicedirs/nginx"
               % (MODDIR, LIVE))


# -------------------------------------------------------------- moonraker

def test_moonraker_is_up_and_ready(web):
    """`ready` is s6's, off the notification-fd -- moonraker said so itself,
    rather than the harness deciding that a fork counts."""
    state = _svstat(web, "moonraker")
    assert state.startswith("up"), state
    assert "ready" in state, state


def test_moonraker_answers_on_7125(web):
    assert web.listening(7125), "moonraker is not serving on :7125"


def test_moonraker_runs_on_our_own_interpreter(web):
    """The whole point of cross-building CPython 3.13: moonraker must be on
    OUR interpreter out of $MODDIR, not FlashForge's 3.8.2 on /usr/prog. Read
    from /proc, because busybox `ps` truncates and qemu prefixes every cmdline
    with the emulator."""
    procs = web.pgrep("moonraker.py")
    assert procs, "no moonraker.py in the process table"
    line = procs[0].cmdline
    assert MODDIR + "/bin/python3" in line, line
    assert MODDIR + "/moonraker/moonraker.py" in line, line


# -------------------------------------------------------------- timelapse

def _moonraker_get(box, path):
    """GET off the live moonraker. wget, because the printer has no curl and
    this container has no route to the host's python."""
    return box.sh("wget -q -O - 'http://127.0.0.1:7125%s'" % path).text


def test_timelapse_component_loaded(web):
    """The component is anvil-timelapse's, and moonraker.conf's [timelapse]
    section is anvil-moonraker's. Moonraker dies on a section with no
    component, so `ready` above already proves a lot -- this proves the
    component did more than import: registering the directory is the first
    thing it does with moonraker's own machinery."""
    info = _moonraker_get(web, "/server/info")
    assert '"timelapse"' in info, (
        "moonraker did not register the timelapse directory: %s" % info)


def test_timelapse_writes_where_the_flash_is(web):
    """output_path and frame_path, both off /tmp. A default frame_path on this
    printer is tmpfs, and a tall print's frames would be RAM the print needs."""
    assert web.file("/usr/data/timelapse").is_dir
    assert web.file("/usr/data/anvil-timelapse").is_dir


def test_our_ffmpeg_runs(web):
    """Ours, static, out of $MODDIR -- not FlashForge's on /usr/prog."""
    out = web.sh("%s/bin/ffmpeg -version" % MODDIR)
    assert out.ok, "our ffmpeg did not run: %s" % out.text
    assert "ffmpeg version 4.4.5" in out.text, out.text


def test_our_ffmpeg_has_the_filters_flashforges_lacks(web):
    """THE REASON THIS PACKAGE EXISTS. timelapse.py emits -vf 'transpose=1',
    'hflip,vflip' and friends straight from the webcam's rotation and flip
    settings, and FlashForge's --disable-everything build has none of them --
    so a rotated camera rendered nothing at all."""
    out = web.sh("%s/bin/ffmpeg -hide_banner -filters" % MODDIR)
    assert out.ok, out.text
    for _f in ("hflip", "vflip", "transpose", "rotate"):
        assert (" %s " % _f) in out.text, (
            "%s is missing, so a webcam configured with a rotation or a flip "
            "still cannot render: %s" % (_f, out.text))


# A 64x64 JPEG, standing in for one mjpg-streamer snapshot. A constant, because
# neither obvious way to make one on the printer works: our Pillow is built
# without libjpeg (it is there for PNG gcode thumbnails), and ffmpeg's own
# testsrc needs lavfi, which FlashForge's --disable-everything took out.
PROBE_JPEG_B64 = (
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9"
    "PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhC"
    "Y2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2P/wAAR"
    "CABAAEADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA"
    "AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK"
    "FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG"
    "h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl"
    "5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA"
    "AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYk"
    "NOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE"
    "hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk"
    "5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDFooor1jiCiiigAooooAKKKKACiiigAooo"
    "oAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAP/9k=")


def test_ffmpeg_encodes_the_render_the_component_asks_for(web):
    """The real render, not a smoke test: the same image2-to-libx264-mp4 shape
    timelapse.py builds, with its -threads/-g/-crf/-pix_fmt flags.

    Plus -preset ultrafast, which moonraker.conf appends: software x264 is
    the only encoder this SoC can offer, so the render is tuned for speed.
    """
    web.sh("rm -rf /tmp/tl-probe && mkdir -p /tmp/tl-probe")
    web.write("/tmp/tl-probe/frame.b64", PROBE_JPEG_B64)
    # Decoded by our own interpreter: `write` sends text, the printer has no
    # base64 applet, and this needs only the stdlib.
    made = web.sh(
        ". %s/anvil-env.sh; %s/bin/python3.13 -c \"import base64, pathlib; "
        "d = base64.b64decode(pathlib.Path('/tmp/tl-probe/frame.b64').read_text()); "
        "[pathlib.Path('/tmp/tl-probe/frame%%06d.jpg' %% i).write_bytes(d) "
        "for i in range(1, 4)]\" 2>&1" % (MODDIR, MODDIR))
    assert made.ok, "could not write probe frames: %s" % made.text

    out = web.sh(
        "%s/bin/ffmpeg -r 30 -i '/tmp/tl-probe/frame%%06d.jpg' "
        "-threads 2 -g 5 -crf 23 -vcodec libx264 -pix_fmt yuv420p -an "
        "-preset ultrafast '/tmp/tl-probe/out.mp4' -y 2>&1" % MODDIR)
    assert out.ok, "the component's own render command failed: %s" % out.text
    assert not web.file("/tmp/tl-probe/out.mp4").empty, "wrote an empty mp4"


def test_a_rotated_webcam_renders(web):
    """The failure this package was built to fix, end to end: the exact -vf
    timelapse.py emits for a camera at rotation 90."""
    out = web.sh(
        "%s/bin/ffmpeg -r 30 -i '/tmp/tl-probe/frame%%06d.jpg' "
        "-vf 'transpose=1' -threads 2 -g 5 -crf 23 -vcodec libx264 "
        "-pix_fmt yuv420p -an -preset ultrafast "
        "'/tmp/tl-probe/rot.mp4' -y 2>&1" % MODDIR)
    assert out.ok, "a rotated render failed: %s" % out.text
    assert not web.file("/tmp/tl-probe/rot.mp4").empty, "wrote an empty mp4"
