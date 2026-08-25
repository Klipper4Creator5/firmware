"""bin/ff-startup.py -- everything before HelixScreen, and the panel saying so.

Two contracts, and only the second is once-per-install.

EVERY BOOT it waits for the printer to actually be up -- the toolhead boards
handed over from their bootloaders by ff-mcu-bringup.py, then klipper and
moonraker ready -- and names on the panel whichever one is holding things up.

FIRST BOOT, once that has happened, it runs FF_IMPORT_FIRMWARE_CONFIG +
SAVE_CONFIG over the moonraker API, waits out the restart that save causes,
and stamps the install. A stamped printer still does the waiting; it just
skips the migration.

Klipper and moonraker are the only services involved, and the tests below pin
that: nothing here asks about a browser UI. Which one is installed --
Mainsail, Fluidd, none at all -- is a build-time choice this migration has no
stake in, and a printer with MOD_WEB=0 still gets its calibration.

The boot screen is covered separately in test_ffscreen.py; here it is only
checked for the property that matters to the migration, which is that it
cannot affect it.

The other half of the contract is what it does NOT do: no stamp is written
unless the values are verifiably saved, so a printer whose heater board needed
another few klippy restarts simply tries again on the next boot instead of
recording a failure forever.

The HTTP layer is faked at Moonraker._open -- the one call every request goes
through -- against a scripted stack whose state the test moves. That keeps the
URLs, the JSON shapes and the request bodies real.
"""
import importlib.util
import io
import json
import os
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load():
    path = os.path.join(ROOT, "payload", "bin", "ff-startup.py")
    spec = importlib.util.spec_from_file_location("ff_startup", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


imp = _load()


class FakeResponse(io.BytesIO):
    def __init__(self, body, code=200):
        io.BytesIO.__init__(self, body)
        self.code = code

    def getcode(self):
        return self.code

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Down(Exception):
    """Whatever a refused connection or a timeout looks like -- the program
    is required to treat them all as 'not ready yet'."""


class Stack:
    """A scripted printer: moonraker, klipper and mainsail, each of which the
    test can have up or down, plus the four ff_tool objects."""

    def __init__(self):
        self.moonraker = True
        self.klippy_state = "ready"
        self.state_message = "Printer is ready"
        self.calibrated = False
        self.save_pending = False
        self.scripts = []
        self.import_fails = None      # set to a message to make it fail
        self.import_lands = True      # does FF_IMPORT_FIRMWARE_CONFIG help?
        self.save_answers = False     # a real SAVE_CONFIG usually cuts us off
        self.save_persists = True
        self.on_request = None        # hook: called with the path each time

    # -- the fake transport ------------------------------------------------
    def open(self, req, timeout):
        url = req.full_url
        if self.on_request:
            self.on_request(url)
        assert not url.startswith("http://127.0.0.1/"), (
            "asked the web UI for %s -- nothing here needs one" % url)
        if not self.moonraker:
            raise Down("connection refused")
        path = url.split("127.0.0.1:7125", 1)[1]
        if req.get_method() == "POST":
            return self._post(path, json.loads(req.data.decode()))
        return self._get(path)

    def _get(self, path):
        if path.startswith("/server/info"):
            return self._json({"klippy_state": self.klippy_state,
                               "klippy_connected": True})
        if path.startswith("/printer/info"):
            return self._json({"state": self.klippy_state,
                               "state_message": self.state_message})
        if path.startswith("/printer/objects/query?configfile"):
            return self._json({"status": {"configfile": {
                "save_config_pending": self.save_pending}}})
        if path.startswith("/printer/objects/query?ff_tool"):
            status = {}
            for n in range(4):
                status["ff_tool %d" % n] = {
                    "index": n, "calibrated": self.calibrated,
                    "nozzle_x": 1.0 + n if self.calibrated else None}
            return self._json({"status": status})
        raise AssertionError("unexpected GET %s" % path)

    def _post(self, path, body):
        assert path == "/printer/gcode/script"
        script = body["script"]
        self.scripts.append(script)
        if script == "FF_IMPORT_FIRMWARE_CONFIG":
            if self.import_fails:
                raise imp.urllib.error.HTTPError(
                    path, 400, "Bad Request", {},
                    io.BytesIO(json.dumps(
                        {"error": {"message": self.import_fails}}).encode()))
            if self.import_lands:
                self.calibrated = True
                self.save_pending = True
            return self._json({})
        if script == "SAVE_CONFIG":
            # The real one restarts klippy, which is why it usually never
            # answers. Either way the pending flag clears on the way through.
            self.save_pending = False
            self.calibrated = self.save_persists
            if not self.save_answers:
                raise Down("connection reset by the restart")
            return self._json({})
        raise AssertionError("unexpected script %r" % script)

    @staticmethod
    def _json(result):
        return FakeResponse(json.dumps({"result": result}).encode())


@pytest.fixture
def stack(monkeypatch):
    s = Stack()
    monkeypatch.setattr(imp.Moonraker, "_open",
                        lambda self, req, timeout: s.open(req, timeout))
    # Nothing may actually sleep, but the clock must still advance or a
    # deadline would never arrive -- a hung stack has to be able to time out.
    clock = {"t": 1000.0}
    monkeypatch.setattr(imp.time, "sleep",
                        lambda seconds: clock.__setitem__("t",
                                                          clock["t"] + seconds))
    monkeypatch.setattr(imp.time, "time", lambda: clock["t"])
    return s


def args(tmp_path, **over):
    jsondir = tmp_path / "firmwareRes"
    jsondir.mkdir(exist_ok=True)
    (jsondir / "extruder.json").write_text('{"t0_offset_x": 1.0}\n/* tail */\n')
    ns = imp.argparse.Namespace(
        stamp=str(tmp_path / "stamp"), dir=str(jsondir),
        moonraker="http://127.0.0.1:7125", timeout=60.0,
        mcu_status=str(tmp_path / "mcu.status"), mcu_timeout=20.0,
        no_import=False, fb=None, fb_geometry=None, no_screen=True,
        dry_run=False)
    for k, v in over.items():
        setattr(ns, k, v)
    return ns


# -- the happy path --------------------------------------------------------


def test_first_boot_imports_saves_and_stamps(tmp_path, stack, capsys):
    a = args(tmp_path)
    assert imp.run(a) == 0
    assert stack.scripts == ["FF_IMPORT_FIRMWARE_CONFIG", "SAVE_CONFIG"]
    assert os.path.exists(a.stamp)
    assert stack.calibrated


def test_a_stamped_printer_waits_but_does_not_migrate(tmp_path, stack):
    a = args(tmp_path)
    assert imp.run(a) == 0
    stack.scripts = []
    # The wait still happens -- that is the every-boot half -- but nothing is
    # sent to the printer, because the migration is done.
    assert imp.run(a) == 0
    assert stack.scripts == []


def test_no_import_waits_and_stops(tmp_path, stack):
    # MOD_IMPORT=0: keep the wait, never migrate.
    a = args(tmp_path, no_import=True)
    assert imp.run(a) == 0
    assert stack.scripts == []
    assert not os.path.exists(a.stamp)


def test_a_save_that_answers_is_also_fine(tmp_path, stack):
    # Nothing says moonraker must be cut off mid-request; it just usually is.
    stack.save_answers = True
    assert imp.run(args(tmp_path)) == 0


# -- the health gate -------------------------------------------------------


def test_waits_for_the_stack_then_proceeds(tmp_path, stack):
    stack.moonraker = False
    stack.klippy_state = "startup"
    seen = []

    def wake(url):
        seen.append(url)
        if len(seen) == 2:
            stack.moonraker = True
        elif len(seen) == 4:
            stack.klippy_state = "ready"

    stack.on_request = wake
    assert imp.run(args(tmp_path)) == 0
    assert "FF_IMPORT_FIRMWARE_CONFIG" in stack.scripts


@pytest.mark.parametrize("broken", ["moonraker", "klipper"])
def test_a_missing_hard_dependency_means_no_import_and_no_stamp(
        tmp_path, stack, broken):
    if broken == "moonraker":
        stack.moonraker = False
    else:
        stack.klippy_state = "startup"
    a = args(tmp_path, timeout=10.0)
    assert imp.run(a) == 1
    assert stack.scripts == []
    assert not os.path.exists(a.stamp)


# -- reasons not to import -------------------------------------------------


def test_no_firmware_json_means_no_migration(tmp_path, stack):
    empty = tmp_path / "empty"
    empty.mkdir()
    a = args(tmp_path, dir=str(empty))
    assert imp.run(a) == 0
    assert stack.scripts == []
    # No stamp: plugging the stock config back in should still be importable.
    assert not os.path.exists(a.stamp)


def test_an_already_calibrated_printer_is_left_alone(tmp_path, stack):
    stack.calibrated = True
    a = args(tmp_path)
    assert imp.run(a) == 0
    assert stack.scripts == []
    # Stamped anyway: there is nothing left for a later boot to do.
    assert os.path.exists(a.stamp)


def test_someone_elses_pending_save_stands_us_down(tmp_path, stack):
    stack.save_pending = True
    a = args(tmp_path)
    assert imp.run(a) == 1
    assert stack.scripts == []
    assert not os.path.exists(a.stamp)


def test_dry_run_touches_nothing(tmp_path, stack):
    a = args(tmp_path, dry_run=True)
    assert imp.run(a) == 0
    assert stack.scripts == []
    assert not os.path.exists(a.stamp)


# -- failures leave the door open ------------------------------------------


def test_a_failing_import_leaves_no_stamp(tmp_path, stack, capsys):
    stack.import_fails = "ff_legacy: extruder.json could not be read"
    a = args(tmp_path)
    assert imp.run(a) == 1
    assert stack.scripts == ["FF_IMPORT_FIRMWARE_CONFIG"]
    assert not os.path.exists(a.stamp)
    # The klipper-side message is the whole diagnosis; it must reach the log.
    assert "extruder.json could not be read" in capsys.readouterr().out


def test_an_import_that_lands_nothing_is_not_saved(tmp_path, stack):
    stack.import_lands = False
    a = args(tmp_path)
    assert imp.run(a) == 1
    assert stack.scripts == ["FF_IMPORT_FIRMWARE_CONFIG"]
    assert not os.path.exists(a.stamp)


def test_a_save_that_did_not_take_leaves_no_stamp(tmp_path, stack):
    stack.save_persists = False
    a = args(tmp_path)
    assert imp.run(a) == 1
    assert stack.scripts == ["FF_IMPORT_FIRMWARE_CONFIG", "SAVE_CONFIG"]
    assert not os.path.exists(a.stamp)


def test_klipper_that_never_comes_back_leaves_no_stamp(tmp_path, stack):
    def after_save(url):
        if "SAVE_CONFIG" not in "".join(stack.scripts):
            return
        stack.klippy_state = "startup"

    stack.on_request = after_save
    a = args(tmp_path, timeout=10.0)
    assert imp.run(a) == 1
    assert not os.path.exists(a.stamp)


@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0,
                    reason="root writes through a read-only directory")
def test_an_unwritable_stamp_still_reports_success(tmp_path, stack, capsys):
    # The values ARE saved; only the bookkeeping failed. Re-importing next
    # boot is harmless (already-calibrated short-circuits it), so this must
    # not be reported to the wrapper as a failed migration.
    a = args(tmp_path, stamp=str(tmp_path / "nodir" / "x" / "stamp"))
    os.makedirs(os.path.dirname(os.path.dirname(a.stamp)))
    os.chmod(os.path.dirname(os.path.dirname(a.stamp)), 0o500)
    try:
        assert imp.run(a) == 0
        assert "WARNING" in capsys.readouterr().out
    finally:
        os.chmod(os.path.dirname(os.path.dirname(a.stamp)), 0o700)


# -- the boot screen cannot affect the migration ---------------------------


class FakeScreen:
    """Records what it was asked to paint. `ok` false models a panel that is
    not there at all -- no framebuffer, no permission, unknown pixel format."""

    def __init__(self, device=None, ok=True, explode=False):
        self.device = device
        self.ok = ok
        self.explode = explode
        self.frames = []
        self.cleared = 0

    def show(self, title, status, note, progress, detail="", fault=False):
        if self.explode:
            raise IOError("the panel went away")
        self.frames.append((title, status, progress, detail))

    def clear(self):
        if self.explode:
            raise IOError("the panel went away")
        self.cleared += 1


def with_screen(monkeypatch, screen):
    module = _StubModule(screen)
    monkeypatch.setattr(imp, "ffscreen", module)
    return screen


class _StubModule:
    def __init__(self, screen):
        self._screen = screen

    def Screen(self, device=None):
        self._screen.device = device
        return self._screen


def test_the_panel_narrates_each_phase(tmp_path, stack, monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen())
    a = args(tmp_path, no_screen=False)
    assert imp.run(a) == 0
    said = [status for _, status, _, _ in screen.frames]
    assert "READING FACTORY CALIBRATION" in said
    assert "SAVING CALIBRATION" in said
    assert "SETUP COMPLETE" in said
    # The bar only ever moves forward.
    progress = [p for _, _, p, _ in screen.frames if p is not None]
    assert progress == sorted(progress)
    # and the panel is handed back black for whatever starts next
    assert screen.cleared == 1


def test_a_panel_that_throws_does_not_stop_the_migration(
        tmp_path, stack, monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen(explode=True))
    a = args(tmp_path, no_screen=False)
    assert imp.run(a) == 0
    assert stack.scripts == ["FF_IMPORT_FIRMWARE_CONFIG", "SAVE_CONFIG"]
    assert os.path.exists(a.stamp)


def test_no_framebuffer_is_simply_no_screen(tmp_path, stack, monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen(ok=False))
    a = args(tmp_path, no_screen=False)
    assert imp.run(a) == 0
    assert screen.frames == []
    assert os.path.exists(a.stamp)


def test_a_timeout_leaves_a_message_rather_than_a_blank_panel(
        tmp_path, stack, monkeypatch):
    # The failure people actually see: nothing came up, we give up, and the
    # panel must say the printer will try again rather than just go dark.
    screen = with_screen(monkeypatch, FakeScreen())
    stack.klippy_state = "startup"
    a = args(tmp_path, no_screen=False, timeout=10.0)
    assert imp.run(a) == 1
    assert any("RETRY" in status for _, status, _, _ in screen.frames)


# -- the failure frame says what failed ------------------------------------
#
# "SETUP WILL RETRY ON NEXT START" on its own tells the owner nothing they can
# act on. Each way this can end badly names itself, and points at the log.


def _details(screen):
    return [d for _, _, _, d in screen.frames if d]


@pytest.mark.parametrize("state,expect", [
    (None, "MOONRAKER IS NOT RESPONDING"),
    ("error", "KLIPPER REPORTED AN ERROR"),
    ("startup", "KLIPPER DID NOT FINISH STARTING"),
])
def test_the_stack_timeout_names_the_service(tmp_path, stack, monkeypatch,
                                             state, expect):
    screen = with_screen(monkeypatch, FakeScreen())
    if state is None:
        stack.moonraker = False
    else:
        stack.klippy_state = state
    a = args(tmp_path, no_screen=False, timeout=10.0)
    assert imp.run(a) == 1
    assert any(expect in d for d in _details(screen)), _details(screen)


def test_a_refused_import_says_so(tmp_path, stack, monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen())
    stack.import_fails = "ff_legacy: extruder.json could not be read"
    a = args(tmp_path, no_screen=False)
    assert imp.run(a) == 1
    assert any("REFUSED FF_IMPORT_FIRMWARE_CONFIG" in d
               for d in _details(screen))


def test_empty_factory_data_says_so(tmp_path, stack, monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen())
    stack.import_lands = False
    a = args(tmp_path, no_screen=False)
    assert imp.run(a) == 1
    assert any("NO CALIBRATION FOUND" in d for d in _details(screen))


def test_a_save_that_did_not_take_says_so(tmp_path, stack, monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen())
    stack.save_persists = False
    a = args(tmp_path, no_screen=False)
    assert imp.run(a) == 1
    assert any("DID NOT SAVE" in d for d in _details(screen))


def test_a_pending_save_says_so(tmp_path, stack, monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen())
    stack.save_pending = True
    a = args(tmp_path, no_screen=False)
    assert imp.run(a) == 1
    assert any("ALREADY WAITING" in d for d in _details(screen))


def test_every_reason_points_at_the_log(tmp_path, stack, monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen())
    stack.import_lands = False
    assert imp.run(args(tmp_path, no_screen=False)) == 1
    assert all(imp.LOGFILE in d for d in _details(screen))


def test_every_reason_is_drawable(tmp_path):
    # A reason containing a character the font has no glyph for would render
    # as a gap exactly where the explanation is.
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "ffscreen", os.path.join(ROOT, "payload", "bin", "ffscreen.py"))
    ffscreen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ffscreen)
    reasons = [
        "MOONRAKER IS NOT RESPONDING", "KLIPPER REPORTED AN ERROR",
        "KLIPPER DID NOT FINISH STARTING (STARTUP)",
        "COULD NOT READ THE TOOL SETTINGS",
        "COULD NOT READ THE PRINTER CONFIGURATION",
        "ANOTHER CONFIGURATION SAVE WAS ALREADY WAITING",
        "THE PRINTER REFUSED FF_IMPORT_FIRMWARE_CONFIG",
        "NO CALIBRATION FOUND IN THE FACTORY DATA",
        "KLIPPER DID NOT RESTART AFTER SAVING",
        "THE CALIBRATION DID NOT SAVE",
        imp.LOGFILE, imp.RETRY,
    ]
    for reason in reasons:
        missing = set(reason.upper()) - set(ffscreen.FONT)
        assert not missing, "%r has no glyph for %s" % (reason, missing)


# -- waiting for the toolhead boards, every boot ---------------------------
#
# Three of the four boards answer only after ff-mcu-bringup.py hands them over
# from their bootloaders, and it runs alongside this program. It publishes
# what it is still working on; the point of reading that is to be able to say
# WAITING FOR THE HEATER BOARD instead of showing a bar that has not moved.


def write_mcu_status(path, state, working=(), done=()):
    lines = ["state %s" % state]
    lines += ["%s working" % d for d in working]
    lines += ["%s ok" % d for d in done]
    open(path, "w").write("\n".join(lines) + "\n")


def test_the_panel_names_the_board_being_waited_for(tmp_path, stack, monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen())
    a = args(tmp_path, no_screen=False)
    write_mcu_status(a.mcu_status, "running", working=["/dev/ttyS4"])
    seen = []

    def wake(url):
        seen.append(url)
        if len(seen) == 1:
            write_mcu_status(a.mcu_status, "finished", done=["/dev/ttyS4"])

    stack.on_request = wake
    assert imp.run(a) == 0
    assert any("THE HEATER BOARD" in s for _, s, _, _ in screen.frames)


def test_both_boards_are_named_while_both_are_working(tmp_path, stack,
                                                      monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen())
    a = args(tmp_path, no_screen=False)
    write_mcu_status(a.mcu_status, "running",
                     working=["/dev/ttyS4", "/dev/ttyS7"])
    seen = []

    def wake(url):
        seen.append(url)
        write_mcu_status(a.mcu_status, "finished")

    stack.on_request = wake
    assert imp.run(a) == 0
    said = " ".join(s for _, s, _, _ in screen.frames)
    assert "THE HEATER BOARD" in said and "THE LEVEL BOARD" in said


def test_a_bringup_that_never_reports_does_not_block_the_boot(tmp_path, stack):
    # ff-mcu-bringup.py may not have written anything yet, or at all. Klippy
    # is the real authority on whether a board answered, so this wait is one
    # we are happy to abandon.
    a = args(tmp_path, mcu_timeout=5.0)
    assert imp.run(a) == 0
    assert stack.scripts == ["FF_IMPORT_FIRMWARE_CONFIG", "SAVE_CONFIG"]
    assert os.path.exists(a.stamp)


def test_a_finished_bringup_is_not_waited_for_at_all(tmp_path, stack):
    a = args(tmp_path)
    write_mcu_status(a.mcu_status, "finished", done=["/dev/ttyS4", "/dev/ttyS7"])
    assert imp.run(a) == 0
    assert os.path.exists(a.stamp)


@pytest.mark.parametrize("text", [
    "", "state\n", "garbage\nlines\n", "state running\n/dev/ttyS4\n",
])
def test_an_unreadable_status_file_is_just_no_news(tmp_path, stack, text):
    # A malformed hint must never be the reason a printer does not boot.
    a = args(tmp_path, mcu_timeout=5.0)
    open(a.mcu_status, "w").write(text)
    assert imp.run(a) == 0


def test_status_parsing(tmp_path):
    path = str(tmp_path / "s")
    write_mcu_status(path, "running", working=["/dev/ttyS7"], done=["/dev/ttyS4"])
    assert imp.read_mcu_status(path) == ("running", ["/dev/ttyS7"])
    write_mcu_status(path, "finished", done=["/dev/ttyS4", "/dev/ttyS7"])
    assert imp.read_mcu_status(path) == ("finished", [])
    assert imp.read_mcu_status(str(tmp_path / "absent")) is None


def test_board_names_are_human_readable():
    assert imp.board_name("/dev/ttyS4") == "THE HEATER BOARD"
    assert imp.board_name("eheaterboard") == "THE HEATER BOARD"
    assert imp.board_name("/dev/ttyS7") == "THE LEVEL BOARD"
    # An unknown port still says something rather than nothing.
    assert imp.board_name("/dev/ttyS9") == "/DEV/TTYS9"


# -- klippy's own error names the board ------------------------------------


def test_a_failed_connect_names_the_board_klippy_blamed(tmp_path, stack,
                                                        monkeypatch):
    # This is the only place the guilty board is named: klippy's
    # state_message on a failed connect.
    screen = with_screen(monkeypatch, FakeScreen())
    stack.klippy_state = "error"
    stack.state_message = ("MCU 'eheaterboard' error during connect\n"
                           "Once the underlying issue is corrected, use the"
                           " \"FIRMWARE_RESTART\" command to reset the"
                           " firmware.")
    a = args(tmp_path, no_screen=False, timeout=10.0)
    assert imp.run(a) == 1
    assert any("THE HEATER BOARD DID NOT ANSWER" in d for d in _details(screen))


def test_an_error_naming_no_board_still_reports_something(tmp_path, stack,
                                                          monkeypatch):
    screen = with_screen(monkeypatch, FakeScreen())
    stack.klippy_state = "error"
    stack.state_message = "Option 'foo' is not valid in section 'bar'"
    a = args(tmp_path, no_screen=False, timeout=10.0)
    assert imp.run(a) == 1
    assert any("KLIPPER REPORTED AN ERROR" in d for d in _details(screen))
