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
#   3. Otherwise wait for the whole stack to be genuinely up -- klipper ready,
#      moonraker answering, mainsail served -- because a half-started printer
#      is exactly where an import lands values nobody can see or correct.
#   4. Run FF_IMPORT_FIRMWARE_CONFIG, then SAVE_CONFIG (which restarts klippy),
#      wait for it to come back, and only then write the stamp.
#
# Anything short of a verified success leaves NO stamp: the next boot tries
# again. That is deliberate. The heater board on this machine routinely needs
# several klippy restarts before it answers (see init.d/S70klipper), so "the
# stack was not ready in time" is a normal event to retry, not a failure to
# record forever.
#
#   usage: ff-firstboot-import.py [--stamp F] [--dir D] [--moonraker URL]
#                                 [--mainsail URL] [--timeout S] [--dry-run]
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

STAMP = '/usr/data/anvil/.firmware-config-imported'
JSON_DIR = '/usr/data/firmwareRes/config'
MOONRAKER = 'http://127.0.0.1:7125'
MAINSAIL = 'http://127.0.0.1/'
TIMEOUT = 240.0
EXTRUDER_COUNT = 4


def log(msg):
    sys.stdout.write('ff-import: %s\n' % msg)
    sys.stdout.flush()


class Moonraker:
    """The smallest possible client: three GETs and one POST."""

    def __init__(self, base, mainsail):
        self.base = base.rstrip('/')
        self.mainsail = mainsail

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

    def mainsail_ok(self, timeout=5.0):
        req = urllib.request.Request(self.mainsail, method='GET')
        try:
            with self._open(req, timeout) as fh:
                fh.read(1)
                return fh.getcode() == 200
        except Exception:
            return False

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


def wait_for_stack(mr, deadline):
    """Block until klipper, moonraker AND mainsail are all up, or time runs
    out. Reports each subsystem's state once per change so the boot log says
    which one everybody is waiting on."""
    last = None
    while True:
        state = mr.klippy_state()
        mainsail = mr.mainsail_ok() if state == 'ready' else False
        now = (state, mainsail)
        if now != last:
            log('waiting: moonraker=%s klipper=%s mainsail=%s'
                % ('up' if state is not None else 'down',
                   state or 'unknown', 'up' if mainsail else 'down'))
            last = now
        if state == 'ready' and mainsail:
            return True
        if time.time() >= deadline:
            log('the stack did not come up in time (moonraker=%s klipper=%s'
                ' mainsail=%s) -- no stamp, the next boot tries again'
                % ('up' if state is not None else 'down', state or 'unknown',
                   'up' if mainsail else 'down'))
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
    deadline = time.time() + args.timeout
    mr = Moonraker(args.moonraker, args.mainsail)
    if not wait_for_stack(mr, deadline):
        return 1

    tools = mr.tools()
    if tools is None:
        log('could not read the ff_tool objects -- no stamp')
        return 1
    if any_calibrated(tools):
        # Someone got there first: a hand calibration, or a restored config.
        # Importing over it would throw away the better numbers.
        log('a tool already carries a nozzle position -- nothing to import')
        stamp(args.stamp, 'already calibrated; nothing imported')
        return 0

    pending = mr.save_pending()
    if pending is None:
        log('could not read save_config_pending -- no stamp')
        return 1
    if pending:
        # SAVE_CONFIG commits EVERY staged value, so if something else is
        # already pending, the save that follows would not be ours to make.
        log('another SAVE_CONFIG is already pending -- standing down')
        return 1

    if args.dry_run:
        log('dry run: would run FF_IMPORT_FIRMWARE_CONFIG and SAVE_CONFIG')
        return 0

    ok, detail = mr.gcode('FF_IMPORT_FIRMWARE_CONFIG')
    if not ok:
        log('FF_IMPORT_FIRMWARE_CONFIG failed: %s' % detail)
        return 1
    tools = mr.tools()
    if not any_calibrated(tools):
        # The command ran but the JSON held nothing usable. Saving now would
        # persist nothing and restart klippy for no reason.
        log('the import landed no nozzle positions -- not saving')
        return 1

    log('imported; persisting with SAVE_CONFIG -- klipper restarts once')
    ok, detail = mr.gcode('SAVE_CONFIG', timeout=20.0)
    if not ok:
        # Expected: the restart cuts the connection before moonraker answers.
        log('SAVE_CONFIG did not answer (%s) -- klipper is restarting' % detail)

    if not wait_for_ready(mr, max(deadline, time.time() + 90.0)):
        log('klipper did not come back after SAVE_CONFIG -- no stamp')
        return 1
    tools = mr.tools()
    if not any_calibrated(tools):
        log('klipper came back with no saved nozzle position -- the save did'
            ' not take, no stamp')
        return 1

    log('done: the factory calibration is saved in printer.cfg')
    stamp(args.stamp, 'imported %s' % args.dir)
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--stamp', default=STAMP)
    ap.add_argument('--dir', default=JSON_DIR)
    ap.add_argument('--moonraker', default=MOONRAKER)
    ap.add_argument('--mainsail', default=MAINSAIL)
    ap.add_argument('--timeout', type=float, default=TIMEOUT)
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args(argv)
    try:
        return run(args)
    except KeyboardInterrupt:
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
