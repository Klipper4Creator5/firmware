"""bin/ff-startup.py -- everything before HelixScreen, and the panel saying so.

Two contracts, and only the second is once-per-install.

EVERY BOOT it waits for the printer to actually be up -- the toolhead boards
handed over from their bootloaders by ff_mcu_bringup.py, then klipper and
moonraker ready -- and names on the panel whichever one is holding things up.

FIRST BOOT, once that has happened, it runs FF_IMPORT_FIRMWARE_CONFIG +
SAVE_CONFIG over the moonraker API, waits out the restart that save causes,
and stamps the install. A stamped printer still does the waiting; it just
skips the migration.

Klipper and moonraker are the only services involved, and the tests below pin
that: nothing here asks about a browser UI. Which one is installed --
Mainsail, Fluidd, none at all -- is a build-time choice this migration has no
stake in, and a printer with MOD_WEB=0 still gets its calibration.

The other half of the contract is what it does NOT do: no stamp is written
unless the values are verifiably saved, so a printer whose heater board needed
another few klippy restarts simply tries again on the next boot instead of
recording a failure forever. That is the single most valuable assertion in
this file -- a stamp written early is a printer that has silently lost its
factory calibration for good, and no later boot will try again.

WHAT IS LEFT. This was forty-nine tests and is eight. Everything about the
PANEL is gone -- which phase it narrates, that a panel which throws does not
stop the migration, that each failure reason has a drawable message. Those are
words a person reads while waiting; the migration underneath them is what
cannot go wrong, and qa/replica/test_boot_screen.py already renders the real
thing on the real machine. Kept is the stamp discipline, the handover order,
and the two ways this program can strand a printer: never restarting klippy,
and importing over somebody else's pending save.

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
    # anvil-core's payload/bin goes on sys.path first, because that is what
    # the runtime
    # looks like: python puts a script's own directory there, and ff-startup
    # imports ffscreen and ff_mcu_bringup by plain name on the strength of
    # it. Loading it here without that would test a program whose siblings
    # are missing -- which is a real failure mode, but not the usual one.
    path = os.path.join(ROOT, "pkgs", "anvil-core", "payload", "bin")
    if path not in sys.path:
        sys.path.insert(0, path)
    spec = importlib.util.spec_from_file_location(
        "ff_startup", os.path.join(path, "ff-startup.py"))
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
    # Mirrors main()'s parser in ff-startup.py. It is spelled out rather than
    # built by calling the parser so a test can ask for a combination the
    # command line cannot produce -- but that means a new flag has to be added
    # here too, and one that is missing surfaces as AttributeError deep inside
    # run(), not as a helpful failure.
    ns = imp.argparse.Namespace(
        stamp=str(tmp_path / "stamp"), dir=str(jsondir),
        moonraker="http://127.0.0.1:7125", timeout=60.0,
        mcu_timeout=5.0, klipper_tries=3, no_klipper=True,
        s6_svc="/nonexistent/s6-svc",
        klipper_svcdir="/nonexistent/svc/klipper",
        only_bringup=False, no_bringup=False,
        no_import=False, fb=None, fb_geometry=None, no_screen=True,
        dry_run=False)
    for k, v in over.items():
        setattr(ns, k, v)
    return ns


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


# -- waiting for the toolhead boards, every boot ---------------------------
#
# ff_mcu_bringup.py is a module here, not a subprocess and not a file to poll:
# this program owns when klippy opens the ports, so it owns handing the boards
# over first. The callback is what makes that worth owning -- it names the
# board being waited for while the wait is happening.


class FakeBringup:
    DEFAULT_PORTS = ("/dev/ttyS4", "/dev/ttyS5", "/dev/ttyS7")

    def __init__(self, script=(), explode=False, result=True):
        self.script = list(script)      # what to report, in order
        self.explode = explode
        self.result = result
        self.calls = []

    def bringup(self, devs, timeout, on_progress=None):
        self.calls.append((tuple(devs), timeout))
        if self.explode:
            raise RuntimeError("the port went away")
        for devs_working in self.script:
            on_progress(list(devs_working))
        on_progress([])
        return self.result


def with_bringup(monkeypatch, fake):
    monkeypatch.setattr(imp, "bringup", fake)
    return fake


# -- owning klipper's start ------------------------------------------------
#
# Owned here rather than by a shell wrapper tailing printer.log, which is the
# only signal such a script has: the retry that actually fixes a stranded
# board is "hand it over again, then reopen the port", so the thing doing the
# handshake has to be the thing restarting klippy.


class FakeKlipper:
    """klipper's supervisor, as the one command ff-startup runs against it.

    There is no start.sh and no separate stop any more: under s6-rc the retry
    is a single `s6-svc -wr -t` on klipper's live servicedir, which terminates
    klippy and does not return until s6 has it running again. One restart is
    one call, so there is nothing left to count stops with.
    """

    def __init__(self, stack, comes_up=True, after=1):
        self.stack = stack
        self.comes_up = comes_up
        self.after = after          # how many restarts before it is ready
        self.restarts = 0
        self.running = False

    def run(self, argv, **kw):
        if "-t" in argv and argv[-1].endswith("klipper"):
            self.restarts += 1
            self.running = True
            if self.comes_up and self.restarts >= self.after:
                self.stack.klippy_state = "ready"
            return _Completed(b"")
        raise AssertionError("unexpected command %r" % (argv,))


class _Completed:
    def __init__(self, out):
        self.stdout = out
        self.returncode = 0


def with_klipper(monkeypatch, fake):
    monkeypatch.setattr(imp.subprocess, "run", fake.run)
    monkeypatch.setattr(imp, "klippy_running", lambda: fake.running)
    return fake


def klipper_args(tmp_path, **over):
    """Args pointing at an s6-svc that really exists -- the program checks."""
    s6_svc = tmp_path / "s6-svc"
    s6_svc.write_text("#!/bin/sh\nexit 0\n")
    over.setdefault("no_klipper", False)
    over.setdefault("s6_svc", str(s6_svc))
    over.setdefault("klipper_svcdir", str(tmp_path / "svc" / "klipper"))
    return args(tmp_path, **over)


# -- the happy path, and the stamp discipline that guards it ---------------


def test_first_boot_imports_saves_and_stamps(tmp_path, stack):
    a = args(tmp_path)
    assert imp.run(a) == 0
    assert stack.scripts == ["FF_IMPORT_FIRMWARE_CONFIG", "SAVE_CONFIG"]
    assert os.path.exists(a.stamp)
    assert stack.calibrated


def test_no_stamp_unless_the_values_are_verifiably_saved(tmp_path, stack, capsys):
    """The four ways the migration can fail, and the one rule for all of them.

    A stamp is a promise that this printer has its factory calibration. Write
    it on an import that errored, an import that changed nothing, a save that
    did not persist, or a klippy that never came back, and the printer is
    stranded: every later boot sees the stamp, skips the migration, and the
    numbers are gone for good. Failing without a stamp costs one more boot.
    """
    def fresh(**over):
        s = Stack()
        monkey.setattr(imp.Moonraker, "_open",
                       lambda self, req, timeout: s.open(req, timeout))
        for k, v in over.items():
            setattr(s, k, v)
        return s

    monkey = pytest.MonkeyPatch()
    try:
        # klippy restarts on SAVE_CONFIG and this one never comes back
        def restart_never_finishes(url):
            if "SAVE_CONFIG" in "".join(never.scripts):
                never.klippy_state = "startup"

        never = fresh()
        never.on_request = restart_never_finishes

        cases = [
            ("the import errored",
             fresh(import_fails="ff_legacy: extruder.json could not be read"),
             ["FF_IMPORT_FIRMWARE_CONFIG"]),
            ("the import landed nothing", fresh(import_lands=False),
             ["FF_IMPORT_FIRMWARE_CONFIG"]),
            ("the save did not persist", fresh(save_persists=False),
             ["FF_IMPORT_FIRMWARE_CONFIG", "SAVE_CONFIG"]),
            ("klipper never came back", never,
             ["FF_IMPORT_FIRMWARE_CONFIG", "SAVE_CONFIG"]),
        ]
        for why, scripted, expect_scripts in cases:
            monkey.setattr(imp.Moonraker, "_open",
                           lambda self, req, timeout, s=scripted: s.open(req, timeout))
            a = args(tmp_path, stamp=str(tmp_path / ("stamp-" + why.split()[1])),
                     timeout=10.0)
            assert imp.run(a) == 1, why
            assert scripted.scripts == expect_scripts, why
            assert not os.path.exists(a.stamp), (
                "stamped after %s -- this printer will never migrate again" % why)
    finally:
        monkey.undo()

    # The klipper-side message is the whole diagnosis; it must reach the log.
    assert "extruder.json could not be read" in capsys.readouterr().out


def test_the_migration_runs_once_and_only_when_there_is_something_to_do(
        tmp_path, stack):
    """Three ways to have nothing to do. Re-running the import on a printer
    that has been tuned since would overwrite the tuning with factory
    numbers, so 'already done' has to be recognised from three directions:
    our own stamp, a printer klippy already reports as calibrated, and no
    factory JSON to read in the first place."""
    a = args(tmp_path)
    assert imp.run(a) == 0
    stack.scripts = []
    assert imp.run(a) == 0        # the wait still happens; the migration does not
    assert stack.scripts == []

    stack.calibrated = True
    b = args(tmp_path, stamp=str(tmp_path / "stamp-cal"))
    assert imp.run(b) == 0
    assert stack.scripts == []
    assert os.path.exists(b.stamp), "nothing left for a later boot to do"

    empty = tmp_path / "empty"
    empty.mkdir()
    stack.calibrated = False
    c = args(tmp_path, dir=str(empty), stamp=str(tmp_path / "stamp-empty"))
    assert imp.run(c) == 0
    assert stack.scripts == []
    # NOT stamped: plugging the stock config back in should still be importable.
    assert not os.path.exists(c.stamp)


def test_someone_elses_pending_save_stands_us_down(tmp_path, stack):
    """Our SAVE_CONFIG would write their half-finished changes to
    printer.cfg and restart klippy under them."""
    stack.save_pending = True
    a = args(tmp_path)
    assert imp.run(a) == 1
    assert stack.scripts == []
    assert not os.path.exists(a.stamp)


def test_a_missing_hard_dependency_means_no_import_and_no_stamp(tmp_path, stack):
    """Neither moonraker nor klipper being up is a reason to give up on the
    migration -- only a reason to leave it for the next boot."""
    for broken in ("moonraker", "klipper"):
        stack.moonraker = broken != "moonraker"
        stack.klippy_state = "startup" if broken == "klipper" else "ready"
        stack.scripts = []
        a = args(tmp_path, timeout=10.0,
                 stamp=str(tmp_path / ("stamp-" + broken)))
        assert imp.run(a) == 1, broken
        assert stack.scripts == [], broken
        assert not os.path.exists(a.stamp), broken


# -- the every-boot half: the boards, then klipper -------------------------


def test_the_boards_are_handed_over_before_klipper_and_again_on_every_retry(
        tmp_path, stack, monkeypatch):
    """Why this program owns klippy's start at all.

    klippy opening a port at a board still sitting in its bootloader is the
    failure this exists to prevent, and the retry that fixes a board which
    missed its window is 'hand it over AGAIN, then reopen the port'. A retry
    loop that restarts klippy without re-running the bring-up would spin
    three times and strand the printer just the same.
    """
    stack.klippy_state = "error"
    fake = with_klipper(monkeypatch, FakeKlipper(stack, after=3))
    bringups = with_bringup(monkeypatch, FakeBringup())
    assert imp.run(klipper_args(tmp_path, klipper_tries=3)) == 0
    assert bringups.calls[0][0] == FakeBringup.DEFAULT_PORTS
    assert fake.restarts == 3
    assert len(bringups.calls) == 3, "a restart without a fresh handover"


def test_klipper_that_cannot_be_started_is_reported_not_ignored(
        tmp_path, stack, monkeypatch):
    """No s6-svc means klippy cannot be restarted, so a board that missed its
    window never gets a second chance -- the worst outcome the mod has. It
    must reach the panel, not just the log."""
    stack.klippy_state = "startup"
    screen = with_screen(monkeypatch, FakeScreen())
    with_bringup(monkeypatch, FakeBringup())
    monkeypatch.setattr(imp, "klippy_running", lambda: False)
    a = args(tmp_path, no_screen=False, no_klipper=False, timeout=20.0,
             s6_svc=str(tmp_path / "absent-s6-svc"))
    assert imp.run(a) == 1
    details = [d for _, _, _, d in screen.frames if d]
    assert any("KLIPPER COULD NOT BE STARTED" in d for d in details), details


# -- it has to import its siblings when run the way the wrapper runs it ----


def test_run_by_path_from_elsewhere_finds_its_siblings(tmp_path):
    """The whole premise of importing ffscreen and ff_mcu_bringup by plain
    name: python puts the SCRIPT's directory on sys.path, not the caller's.
    Run from somewhere else entirely, the imports must still resolve -- and
    a missing bring-up must be loud, because silent means klippy opens the
    ports at boards still in their bootloaders."""
    import subprocess
    script = os.path.join(ROOT, "pkgs", "anvil-core", "payload", "bin", "ff-startup.py")
    out = subprocess.run([sys.executable, script, "--selftest"],
                         cwd=str(tmp_path), capture_output=True, text=True)
    assert out.returncode == 0, out.stdout + out.stderr
    for expect in ("ffscreen: yes", "ff_mcu_bringup: yes", "ports: 3",
                   "selftest: ok"):
        assert expect in out.stdout, out.stdout

    with pytest.MonkeyPatch.context() as m:
        m.setattr(imp, "bringup", None)
        assert imp.selftest() == 1
