#!/usr/bin/env python3
# Carry this unit's factory calibration from firmwareExe's JSON into Klipper.
# Once, on the first boot after the mod is installed, and then never again.
#
# WHY THIS IS ITS OWN PROGRAM. The migration used to live inside Klipper:
# [ff_legacy] hooked klippy:ready, imported, and ran SAVE_CONFIG itself. That
# put a Creator-5-specific one-time chore inside a general-purpose extra, on
# the one event where the printer is least able to say whether the rest of the
# machine is healthy -- klippy:ready fires with moonraker possibly not yet
# listening and nginx possibly not yet serving. It is also the wrong lifetime:
# a boot-time migration is a property of the INSTALL, not of every klippy
# start, so it wants a stamp on disk rather than a "has anything been
# calibrated yet" guess re-evaluated on every ready.
#
# So it is a separate program with one job, run from the firmwareExe wrapper
# before HelixScreen:
#
#   1. If the stamp exists, exit immediately. This is every boot but the
#      first, and it must cost nothing -- the UI is waiting behind us.
#   2. If there is no firmwareRes JSON to import, exit immediately too.
#   3. Otherwise wait for klipper ready and moonraker answering -- a
#      half-started printer is exactly where an import lands values nobody can
#      see or correct.
#   4. Run FF_IMPORT_FIRMWARE_CONFIG, then SAVE_CONFIG (which restarts klippy),
#      wait for it to come back, and only then write the stamp.
#
# Anything short of a verified success leaves NO stamp: the next boot tries
# again. That is deliberate. The heater board on this machine routinely needs
# several klippy restarts before it answers (see init.d/S70klipper), so "the
# stack was not ready in time" is a normal event to retry, not a failure to
# record forever.
#
# THE BROWSER UI IS DELIBERATELY NOT CONSULTED. Everything here travels over
# moonraker's API, so klipper and moonraker are the only services involved.
# Which browser UI is installed -- Mainsail, Fluidd, none at all with
# MOD_WEB=0 -- is a build-time choice that this migration has no stake in, so
# it is not waited for, not checked, and not mentioned again.
#
# WHAT THE PANEL SHOWS. All of this happens before HelixScreen starts, so the
# screen is black for as long as it takes -- which on a first boot is the
# longest wait of the whole install. ffscreen.py paints a line of text and a
# progress bar straight onto /dev/fb0 so the machine does not look bricked
# and nobody reaches for the power switch mid-SAVE_CONFIG. It is decoration:
# if it cannot draw, the migration proceeds exactly the same. --no-screen
# turns it off.
#
#   usage: ff-firstboot-import.py [--stamp F] [--dir D] [--moonraker URL]
#                                 [--timeout S] [--fb DEV] [--no-screen]
#                                 [--dry-run]
#
# Exit 0 = nothing to do, or imported and saved. Exit 1 = tried and did not
# finish; no stamp was written.
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

try:
    # Sits beside this script, so running it by absolute path finds it.
    import ffscreen
except ImportError:
    ffscreen = None

STAMP = '/usr/data/anvil/.firmware-config-imported'
JSON_DIR = '/usr/data/firmwareRes/config'
MOONRAKER = 'http://127.0.0.1:7125'
TIMEOUT = 240.0
EXTRUDER_COUNT = 4

TITLE = 'SETTING UP YOUR PRINTER'
KEEP_POWER = 'DO NOT TURN THE PRINTER OFF'
RETRY = 'SETUP WILL RETRY ON NEXT START'
LOGFILE = '/USR/DATA/LOGS/ANVIL-BOOT.LOG'


def log(msg):
    sys.stdout.write('ff-import: %s\n' % msg)
    sys.stdout.flush()


class Panel:
    """The boot screen, reduced to "say this, you are about this far along".

    A null object when there is no framebuffer or --no-screen was passed, so
    the call sites never branch on whether a panel exists."""

    def __init__(self, device=None, geometry=None, enabled=True):
        self.screen = None
        if not enabled or ffscreen is None:
            return
        try:
            kwargs = {}
            if device:
                kwargs['device'] = device
            if geometry:
                kwargs['geometry'] = ffscreen.parse_geometry(geometry)
            screen = ffscreen.Screen(**kwargs)
        except Exception:
            return
        if screen.ok:
            self.screen = screen

    # Both of these swallow everything. This is the boundary where drawing
    # stops being allowed to matter: the migration below must run identically
    # on a printer with no panel, a panel that dies mid-write, or a panel that
    # throws something ffscreen did not anticipate. One failure retires the
    # screen for the rest of the run rather than failing again every 2s.

    def say(self, status, progress, note=KEEP_POWER, detail='', fault=False):
        if self.screen is None:
            return
        try:
            self.screen.show(TITLE, status, note, progress, detail, fault)
        except Exception as exc:
            log('the boot screen stopped working (%s) -- carrying on' % exc)
            self.screen = None

    def failed(self, reason):
        """The one frame a person is actually left looking at.

        "Setup will retry" on its own tells them nothing they can act on, so
        the reason goes underneath -- and the log line goes under that,
        because the reason has to be short and the log never is."""
        log('giving up: %s' % reason)
        self.say(RETRY, None, note='', fault=True,
                 detail='%s. DETAILS IN %s' % (reason.upper().rstrip('.'),
                                               LOGFILE))

    def done(self):
        if self.screen is None:
            return
        try:
            self.screen.clear()
        except Exception:
            pass
        self.screen = None


class Moonraker:
    """The smallest possible client: three GETs and one POST."""

    def __init__(self, base):
        self.base = base.rstrip('/')

    def _open(self, req, timeout):
        return urllib.request.urlopen(req, timeout=timeout)

    def get(self, path, timeout=5.0):
        """Return an endpoint's "result" object, or None if it is not there
        yet. Every failure mode -- connection refused, a timeout, an HTTP
        error, a body that is not JSON -- means the same thing to us (not
        ready), so they collapse into one None."""
        req = urllib.request.Request(self.base + path, method='GET')
        try:
            with self._open(req, timeout) as fh:
                body = fh.read()
        except Exception:
            return None
        try:
            return json.loads(body.decode('utf-8', 'replace')).get('result')
        except ValueError:
            return None

    def gcode(self, script, timeout=30.0):
        """Run one gcode script. Returns (ok, detail).

        SAVE_CONFIG restarts klippy while moonraker is still holding this
        request open, so a timeout or a dropped connection here is not an
        error -- it is the expected shape of success. The caller decides;
        we only report what happened."""
        data = json.dumps({'script': script}).encode('utf-8')
        req = urllib.request.Request(
            self.base + '/printer/gcode/script', data=data,
            headers={'Content-Type': 'application/json'}, method='POST')
        try:
            with self._open(req, timeout) as fh:
                fh.read()
            return True, 'ok'
        except urllib.error.HTTPError as exc:
            # Moonraker reports a klipper-side gcode error as 400 with the
            # message in the body; that message is the whole diagnosis.
            try:
                detail = json.loads(exc.read().decode('utf-8', 'replace'))
                detail = detail.get('error', {}).get('message') or str(exc)
            except Exception:
                detail = str(exc)
            return False, detail
        except Exception as exc:
            return False, '%s: %s' % (type(exc).__name__, exc)

    # -- the two questions we ask about klipper's state --------------------

    def klippy_state(self):
        info = self.get('/server/info')
        if info is None:
            return None
        return info.get('klippy_state')

    def tools(self):
        """[ff_tool n] status for every tool, as a list of dicts (or None)."""
        query = '&'.join('ff_tool%%20%d' % n for n in range(EXTRUDER_COUNT))
        res = self.get('/printer/objects/query?' + query)
        if res is None:
            return None
        status = res.get('status', {})
        return [status.get('ff_tool %d' % n) for n in range(EXTRUDER_COUNT)]

    def save_pending(self):
        res = self.get('/printer/objects/query?configfile=save_config_pending')
        if res is None:
            return None
        cf = res.get('status', {}).get('configfile', {})
        return bool(cf.get('save_config_pending'))


def any_calibrated(tools):
    return any(t and t.get('calibrated') for t in tools or [])


def wait_for_stack(mr, panel, deadline, started):
    """Block until klipper and moonraker are both up, or time runs out.
    Reports their state once per change so the boot log says which one
    everybody is waiting on, and creeps the panel's bar along with the wait
    so a long MCU hunt still looks like progress rather than a freeze."""
    last = None
    span = max(1.0, deadline - started)
    while True:
        state = mr.klippy_state()
        if state != last:
            log('waiting: moonraker=%s klipper=%s'
                % ('up' if state is not None else 'down', state or 'unknown'))
            last = state
        if state is None:
            panel.say('STARTING SERVICES', 0.05 + 0.3 * (time.time() - started) / span)
        elif state != 'ready':
            panel.say('WAITING FOR THE PRINTER',
                      0.05 + 0.3 * (time.time() - started) / span)
        if state == 'ready':
            return True
        if time.time() >= deadline:
            log('klipper and moonraker did not come up in time (moonraker=%s'
                ' klipper=%s) -- no stamp, the next boot tries again'
                % ('up' if state is not None else 'down', state or 'unknown'))
            # Name the service, not the timeout: "moonraker is not
            # responding" is something an owner can act on, and the three
            # cases have genuinely different causes.
            if state is None:
                panel.failed('MOONRAKER IS NOT RESPONDING')
            elif state == 'error':
                panel.failed('KLIPPER REPORTED AN ERROR')
            else:
                panel.failed('KLIPPER DID NOT FINISH STARTING (%s)'
                             % str(state).upper())
            return False
        time.sleep(2.0)


def wait_for_ready(mr, deadline):
    """Wait for klippy alone -- used after the SAVE_CONFIG restart, where
    moonraker never went away and mainsail was never in question."""
    while True:
        if mr.klippy_state() == 'ready':
            return True
        if time.time() >= deadline:
            return False
        time.sleep(2.0)


def stamp(path, note):
    try:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(path, 'w') as fh:
            fh.write('%s\n%s\n' % (note, time.strftime('%Y-%m-%d %H:%M:%S')))
        return True
    except OSError as exc:
        # The stamp is the only thing stopping a re-import on the next boot,
        # so failing to write it is worth shouting about -- but the values
        # ARE saved, and a second import of the same JSON is harmless
        # (already-calibrated short-circuits it), so this is not exit 1.
        log('WARNING could not write the stamp %s (%s) -- the import is saved'
            ' but the next boot will look again' % (path, exc))
        return False


def run(args):
    if os.path.exists(args.stamp):
        return 0  # the common case: say nothing, cost nothing
    extruder_json = os.path.join(args.dir, 'extruder.json')
    if not os.path.exists(extruder_json):
        # Not a unit migrated from stock firmware (or the files were wiped).
        # Nothing to import and nothing to wait for.
        log('no %s -- nothing to import' % extruder_json)
        return 0

    log('first boot: importing this unit\'s factory calibration from %s'
        % args.dir)
    started = time.time()
    deadline = started + args.timeout
    mr = Moonraker(args.moonraker)
    panel = Panel(args.fb, args.fb_geometry, enabled=not args.no_screen)
    panel.say('STARTING SERVICES', 0.05)
    try:
        return migrate(args, mr, panel, started, deadline)
    finally:
        # Whatever happened, hand HelixScreen a clean panel.
        panel.done()


def migrate(args, mr, panel, started, deadline):
    if not wait_for_stack(mr, panel, deadline, started):
        return 1

    tools = mr.tools()
    if tools is None:
        log('could not read the ff_tool objects -- no stamp')
        panel.failed('COULD NOT READ THE TOOL SETTINGS')
        return 1
    if any_calibrated(tools):
        # Someone got there first: a hand calibration, or a restored config.
        # Importing over it would throw away the better numbers.
        log('a tool already carries a nozzle position -- nothing to import')
        panel.say('ALREADY CALIBRATED', 1.0, note='')
        stamp(args.stamp, 'already calibrated; nothing imported')
        return 0

    pending = mr.save_pending()
    if pending is None:
        log('could not read save_config_pending -- no stamp')
        panel.failed('COULD NOT READ THE PRINTER CONFIGURATION')
        return 1
    if pending:
        # SAVE_CONFIG commits EVERY staged value, so if something else is
        # already pending, the save that follows would not be ours to make.
        log('another SAVE_CONFIG is already pending -- standing down')
        panel.failed('ANOTHER CONFIGURATION SAVE WAS ALREADY WAITING')
        return 1

    if args.dry_run:
        log('dry run: would run FF_IMPORT_FIRMWARE_CONFIG and SAVE_CONFIG')
        return 0

    panel.say('READING FACTORY CALIBRATION', 0.5)
    ok, detail = mr.gcode('FF_IMPORT_FIRMWARE_CONFIG')
    if not ok:
        log('FF_IMPORT_FIRMWARE_CONFIG failed: %s' % detail)
        panel.failed('THE PRINTER REFUSED FF_IMPORT_FIRMWARE_CONFIG')
        return 1
    tools = mr.tools()
    if not any_calibrated(tools):
        # The command ran but the JSON held nothing usable. Saving now would
        # persist nothing and restart klippy for no reason.
        log('the import landed no nozzle positions -- not saving')
        panel.failed('NO CALIBRATION FOUND IN THE FACTORY DATA')
        return 1

    log('imported; persisting with SAVE_CONFIG -- klipper restarts once')
    panel.say('SAVING CALIBRATION', 0.7)
    ok, detail = mr.gcode('SAVE_CONFIG', timeout=20.0)
    if not ok:
        # Expected: the restart cuts the connection before moonraker answers.
        log('SAVE_CONFIG did not answer (%s) -- klipper is restarting' % detail)

    panel.say('RESTARTING THE PRINTER', 0.85)
    if not wait_for_ready(mr, max(deadline, time.time() + 90.0)):
        log('klipper did not come back after SAVE_CONFIG -- no stamp')
        panel.failed('KLIPPER DID NOT RESTART AFTER SAVING')
        return 1
    tools = mr.tools()
    if not any_calibrated(tools):
        log('klipper came back with no saved nozzle position -- the save did'
            ' not take, no stamp')
        panel.failed('THE CALIBRATION DID NOT SAVE')
        return 1

    log('done: the factory calibration is saved in printer.cfg')
    panel.say('SETUP COMPLETE', 1.0, note='')
    stamp(args.stamp, 'imported %s' % args.dir)
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--stamp', default=STAMP)
    ap.add_argument('--dir', default=JSON_DIR)
    ap.add_argument('--moonraker', default=MOONRAKER)
    ap.add_argument('--timeout', type=float, default=TIMEOUT)
    ap.add_argument('--fb', default=None,
                    help='framebuffer to draw the boot screen on')
    ap.add_argument('--fb-geometry', default=None,
                    help="panel size as WxH@BPP, skipping the sysfs probe")
    ap.add_argument('--no-screen', action='store_true',
                    help='do not draw anything on the panel')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args(argv)
    try:
        return run(args)
    except KeyboardInterrupt:
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
