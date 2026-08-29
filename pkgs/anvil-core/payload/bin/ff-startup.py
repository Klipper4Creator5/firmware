#!/usr/bin/env python3
# Everything that has to happen before HelixScreen, and the panel that says so.
#
# The firmwareExe wrapper runs this after the init.d services and before the
# UI. It does two jobs, and only the second is once-per-install:
#
#   EVERY BOOT   wait until the printer is genuinely up -- the toolhead boards
#                handed over from their bootloaders, then klipper and
#                moonraker ready -- naming on the panel whatever is being
#                waited for. This machine takes its time: three of the four
#                boards need a handshake before they answer (see
#                bin/ff_mcu_bringup.py) and the heater board routinely costs
#                klippy a restart or two. Without this the wait happens behind
#                a black screen with HelixScreen up and reporting a
#                disconnected printer, which tells an owner nothing about
#                which board is missing.
#
#   FIRST BOOT   carry this unit's factory calibration from firmwareExe's JSON
#                into Klipper, then stamp the install so it never runs again.
#
# WHY THIS IS ITS OWN PROGRAM, rather than a klippy:ready hook in [ff_legacy].
# klippy:ready is the one event where the printer is least able to say whether
# the rest of the machine is healthy -- it fires with moonraker possibly not
# yet listening and nginx possibly not yet serving. And a boot-time migration
# is a property of the INSTALL, not of every klippy start, so it wants a stamp
# on disk rather than a "has anything been calibrated yet" guess re-evaluated
# on every ready.
#
# So it is a separate program, run from the firmwareExe wrapper before
# HelixScreen:
#
#   1. Hand the toolhead boards over from their bootloaders, by calling
#      ff_mcu_bringup.py directly -- it is a module here, not a subprocess --
#      naming on the panel whichever board is still being waited for.
#   2. Launch klipper (start.sh, told not to redo the bring-up) and wait for
#      klippy and moonraker to be ready. If a board never answered, klippy
#      says so and names it, and so do we; then stop klippy, redo the
#      bring-up and try again, which is what reopening the port achieves.
#   3. If the install is already stamped, stop here -- the rest is the
#      migration, and it has been done.
#   4. Otherwise run FF_IMPORT_FIRMWARE_CONFIG, then SAVE_CONFIG (which
#      restarts klippy), wait for it to come back, and only then stamp.
#
# WHY THIS OWNS KLIPPER'S START. The bring-up has to happen before klippy
# opens the serial ports, and the retry that actually fixes a board which
# missed its window is "close the port, hand it over again, reopen" -- so
# whatever does the bring-up has to be the same thing that starts and
# restarts klippy. Splitting them across two processes meant this program
# could only watch, through a file, work it was not allowed to do. init.d/
# S70klipper stands aside when this program is going to run and takes the job
# back when it cannot: klipper starting is the single most important thing
# the mod does, and it must not depend on a python interpreter.
#
# Anything short of a verified success leaves NO stamp: the next boot tries
# again. That is deliberate. The heater board on this machine routinely needs
# several klippy restarts before it answers (see init.d/S70klipper), so "the
# stack was not ready in time" is a normal event to retry, not a failure to
# record forever.
#
# THE BROWSER UI IS DELIBERATELY NOT CONSULTED. Everything here travels over
# moonraker's API, so klipper and moonraker are the only services involved.
# Which browser UI is installed -- Mainsail, Fluidd, or nothing at all on a
# BUILD_MAINSAIL=0 build -- is a packaging choice that this migration has no
# stake in, so it is not waited for, not checked, and not mentioned again.
#
# WHAT THE PANEL SHOWS. All of this happens before HelixScreen starts, so the
# screen is black for as long as it takes -- which on a first boot is the
# longest wait of the whole install. ffscreen.py paints a line of text and a
# progress bar straight onto /dev/fb0 so the machine does not look bricked
# and nobody reaches for the power switch mid-SAVE_CONFIG. It is decoration:
# if it cannot draw, the migration proceeds exactly the same. --no-screen
# turns it off.
#
#   usage: ff-startup.py [--stamp F] [--dir D] [--moonraker URL] [--timeout S]
#                        [--no-import] [--no-klipper] [--klipper-tries N]
#                        [--start-sh P] [--daemon P] [--mcu-timeout S]
#                        [--fb DEV] [--fb-geometry G] [--no-screen] [--dry-run]
#
# Exit 0 = the printer came up, and the migration either was not needed or
# succeeded. Exit 1 = something did not finish; no stamp was written.
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

# Both sit beside this script, so running it by absolute path finds them:
# python puts the script's own directory on sys.path. Either being absent is
# survivable and neither is fatal -- no ffscreen means no panel, and no
# bring-up means the boards are left to klippy, which reports a board that
# never answered better than we could anyway.
try:
    import ffscreen
except ImportError:
    ffscreen = None

try:
    import ff_mcu_bringup as bringup
except ImportError:
    bringup = None

STAMP = '/usr/data/anvil/.firmware-config-imported'
JSON_DIR = '/usr/data/firmwareRes/config'
MOONRAKER = 'http://127.0.0.1:7125'
START_SH = '/usr/prog/klipper/start.sh'
DAEMON = '/usr/prog/klipper/klipperDaemon'
UDS = '/tmp/uds'
TIMEOUT = 240.0
MCU_TIMEOUT = 30.0
KLIPPER_TRIES = 6
EXTRUDER_COUNT = 4

# What to call each board on the panel. The serial port is what ff_mcu_bringup
# publishes and what klipper names in its own errors; neither string means
# anything to the person standing in front of the machine.
BOARDS = {
    '/dev/ttyS2': 'THE MAIN BOARD',
    '/dev/ttyS5': 'THE EXTRUDER BOARD',
    '/dev/ttyS4': 'THE HEATER BOARD',
    '/dev/ttyS7': 'THE LEVEL BOARD',
    'mcu': 'THE MAIN BOARD',
    'eboard': 'THE EXTRUDER BOARD',
    'eheaterboard': 'THE HEATER BOARD',
    'levelboard': 'THE LEVEL BOARD',
}

TITLE = 'SETTING UP YOUR PRINTER'
KEEP_POWER = 'DO NOT TURN THE PRINTER OFF'
RETRY = 'SETUP WILL RETRY ON NEXT START'
LOGFILE = '/USR/DATA/LOGS/ANVIL-BOOT.LOG'


def log(msg):
    # The boot log is where somebody looks when the printer did not come up,
    # so the prefix has to be the name of the thing they would then go and
    # read. This said 'ff-import' for as long as that was the whole job; it
    # now waits for the boards and owns klipper on every boot, and a line
    # saying 'ff-import: starting klipper' sends the reader to the wrong file.
    sys.stdout.write('ff-startup: %s\n' % msg)
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

    def _open(self, request, timeout):
        return urllib.request.urlopen(request, timeout=timeout)

    def get(self, path, timeout=5.0):
        """Return an endpoint's "result" object, or None if it is not there
        yet. Every failure mode -- connection refused, a timeout, an HTTP
        error, a body that is not JSON -- means the same thing to us (not
        ready), so they collapse into one None."""
        request = urllib.request.Request(self.base + path, method='GET')
        try:
            with self._open(request, timeout) as fh:
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
        payload = json.dumps({'script': script}).encode('utf-8')
        request = urllib.request.Request(
            self.base + '/printer/gcode/script', data=payload,
            headers={'Content-Type': 'application/json'}, method='POST')
        try:
            with self._open(request, timeout) as fh:
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
        server_info = self.get('/server/info')
        if server_info is None:
            return None
        return server_info.get('klippy_state')

    def tools(self):
        """[ff_tool n] status for every tool, as a list of dicts (or None)."""
        query = '&'.join('ff_tool%%20%d' % index
                         for index in range(EXTRUDER_COUNT))
        result = self.get('/printer/objects/query?' + query)
        if result is None:
            return None
        status = result.get('status', {})
        return [status.get('ff_tool %d' % index)
                for index in range(EXTRUDER_COUNT)]

    def save_pending(self):
        result = self.get(
            '/printer/objects/query?configfile=save_config_pending')
        if result is None:
            return None
        configfile = result.get('status', {}).get('configfile', {})
        return bool(configfile.get('save_config_pending'))


def any_calibrated(tools):
    return any(tool and tool.get('calibrated') for tool in tools or [])


def board_name(key):
    """A serial port or a klipper mcu name -> something a person can act on."""
    return BOARDS.get(key, str(key).upper())


def hand_over_boards(panel, timeout):
    """Bring the toolhead boards out of their bootloaders.

    Called directly rather than run as a subprocess: this program owns when
    klippy opens the ports, so it owns doing this first. The callback is the
    whole reason it is worth owning -- it names the board still being waited
    for while the wait is happening.
    """
    if bringup is None:
        return
    def progress(devices):
        if not devices:
            return
        names = [board_name(device) for device in devices]
        panel.say('WAKING ' + ' AND '.join(names[:2]), 0.08)
    panel.say('WAKING THE TOOLHEAD BOARDS', 0.05)
    try:
        all_awake = bringup.bringup(list(bringup.DEFAULT_PORTS), timeout,
                                    on_progress=progress)
    except Exception as exc:
        # A board is klippy's problem to report; ours is to not die here.
        log('mcu bring-up raised (%s) -- going on to klipper' % exc)
        return
    log('mcu bring-up %s' % ('ok' if all_awake else 'reported a problem'))


# --------------------------------------------------------------- klipper

def klippy_running():
    """Is there a klippy? The socket first, then /proc -- pgrep is not
    guaranteed to exist on this rootfs and this is cheaper anyway."""
    if os.path.exists(UDS):
        return True
    try:
        pids = [entry for entry in os.listdir('/proc') if entry.isdigit()]
    except OSError:
        return False
    for pid in pids:
        try:
            with open('/proc/%s/cmdline' % pid, 'rb') as fh:
                if b'klippy.py' in fh.read():
                    return True
        except (IOError, OSError):
            continue
    return False


def start_klipper(args):
    """Run start.sh, telling it the bring-up is already done.

    It is not left to run in the background: everything it does after the
    bring-up we skipped is quick, and knowing it finished is what makes the
    wait that follows meaningful."""
    if not os.path.exists(args.start_sh):
        log('no %s -- cannot start klipper' % args.start_sh)
        return False
    env = dict(os.environ)
    env['FF_SKIP_MCU_BRINGUP'] = '1'
    log('starting klipper (%s)' % args.start_sh)
    try:
        completed = subprocess.run(['/bin/sh', args.start_sh], env=env,
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=120)
    except subprocess.TimeoutExpired:
        log('start.sh did not return within 120s')
        return False
    except Exception as exc:
        log('start.sh could not be run (%s)' % exc)
        return False
    for line in (completed.stdout
                 or b'').decode('utf-8', 'replace').splitlines():
        log('  start.sh: %s' % line)
    return True


def stop_klipper(args):
    """Stop klippy and wait for it to actually go.

    Reopening the port is what toggles DTR/RTS and gives a board that missed
    its window another chance, so the stop has to be real before the next
    attempt is worth making."""
    try:
        subprocess.run([args.daemon, 'stop'], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=30)
    except Exception as exc:
        log('klipperDaemon stop failed (%s)' % exc)
    for _ in range(15):
        if not klippy_running():
            break
        time.sleep(1.0)
    # start.sh refuses to run while the socket is there, so clear a stale one
    # -- but only once klippy is definitely gone.
    if not klippy_running():
        try:
            os.remove(UDS)
        except OSError:
            pass


def klippy_fault(moonraker):
    """The board klippy is complaining about, if it names one.

    On a failed connect klippy's state_message is "MCU 'eheaterboard' error
    during connect ..." -- the only place the guilty board is named, and
    exactly what an owner needs to know."""
    printer_info = moonraker.get('/printer/info')
    if not printer_info:
        return None
    message = printer_info.get('state_message') or ''
    for key in BOARDS:
        if "'%s'" % key in message:
            return board_name(key)
    return None


def report_stack_failure(moonraker, panel):
    """The one frame someone is left looking at, naming what did not come up."""
    state = moonraker.klippy_state()
    if state is None:
        panel.failed('MOONRAKER IS NOT RESPONDING')
    elif state == 'error':
        board = klippy_fault(moonraker)
        if board:
            panel.failed('%s DID NOT ANSWER' % board)
        else:
            panel.failed('KLIPPER REPORTED AN ERROR')
    else:
        panel.failed('KLIPPER DID NOT FINISH STARTING (%s)'
                     % str(state).upper())


def wait_for_stack(moonraker, panel, deadline, started, quiet=False):
    """Block until klipper and moonraker are both up, or time runs out.
    Reports their state once per change so the boot log says which one
    everybody is waiting on, and creeps the panel's bar along with the wait
    so a long MCU hunt still looks like progress rather than a freeze."""
    last_state = None
    window = max(1.0, deadline - started)
    while True:
        state = moonraker.klippy_state()
        if state != last_state:
            log('waiting: moonraker=%s klipper=%s'
                % ('up' if state is not None else 'down', state or 'unknown'))
            last_state = state
        elapsed_fraction = 0.3 * (time.time() - started) / window
        if state is None:
            panel.say('STARTING SERVICES', 0.05 + elapsed_fraction)
        elif state != 'ready':
            panel.say('WAITING FOR THE PRINTER', 0.05 + elapsed_fraction)
        if state == 'ready':
            return True
        if state == 'error' and quiet:
            # A failed connect is final until something reopens the ports,
            # so waiting out the deadline here only delays the retry that
            # can actually fix it.
            log('klipper reported an error -- not waiting it out')
            return False
        if time.time() >= deadline:
            log('klipper and moonraker did not come up in time (moonraker=%s'
                ' klipper=%s)'
                % ('up' if state is not None else 'down', state or 'unknown'))
            # Between retries the caller stays quiet: a fault frame that is
            # replaced two seconds later by another attempt reads as a
            # failure the printer then ignored.
            if not quiet:
                report_stack_failure(moonraker, panel)
            return False
        time.sleep(2.0)


def wait_for_ready(moonraker, deadline):
    """Wait for klippy alone -- used after the SAVE_CONFIG restart, where
    moonraker never went away and mainsail was never in question."""
    while True:
        if moonraker.klippy_state() == 'ready':
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
    started = time.time()
    deadline = started + args.timeout
    moonraker = Moonraker(args.moonraker)
    panel = Panel(args.fb, args.fb_geometry, enabled=not args.no_screen)
    panel.say('STARTING SERVICES', 0.05)
    try:
        return startup(args, moonraker, panel, started, deadline)
    finally:
        # Whatever happened, hand HelixScreen a clean panel.
        panel.done()


def bring_up_printer(args, moonraker, panel, started, deadline):
    """Boards out of their bootloaders, klippy up, and retry until it is.

    This is what init.d/S70klipper's supervise() used to do by tailing
    printer.log for markers, which was the only signal a shell script had.
    Here the signal is moonraker's, and the retry can do the thing that
    actually helps: hand the boards over again before reopening the ports.
    """
    for attempt in range(1, args.klipper_tries + 1):
        if not klippy_running():
            hand_over_boards(panel, min(args.mcu_timeout,
                                        max(1.0, deadline - time.time())))
            if not args.no_klipper and not start_klipper(args):
                panel.failed('KLIPPER COULD NOT BE STARTED')
                return False
        if wait_for_stack(moonraker, panel, deadline, started, quiet=True):
            return True
        if time.time() >= deadline or attempt == args.klipper_tries:
            break
        # Reopening the port toggles DTR/RTS, which is what gives a board
        # that missed its window another chance -- so the restart is the
        # fix, not merely another go at the same thing.
        board = klippy_fault(moonraker)
        log('attempt %d/%d failed (%s) -- restarting klipper'
            % (attempt, args.klipper_tries, board or 'no board named'))
        panel.say('RETRYING %s' % (board or 'THE PRINTER'), 0.15,
                  detail='ATTEMPT %d OF %d' % (attempt + 1,
                                               args.klipper_tries))
        stop_klipper(args)
    report_stack_failure(moonraker, panel)
    return False


def startup(args, moonraker, panel, started, deadline):
    # -- every boot ------------------------------------------------------
    if not bring_up_printer(args, moonraker, panel, started, deadline):
        return 1

    # -- first boot only -------------------------------------------------
    if args.no_import:
        return 0
    if os.path.exists(args.stamp):
        log('already migrated (%s) -- nothing else to do' % args.stamp)
        return 0
    extruder_json = os.path.join(args.dir, 'extruder.json')
    if not os.path.exists(extruder_json):
        # Not a unit migrated from stock firmware (or the files were wiped).
        log('no %s -- nothing to import' % extruder_json)
        return 0
    log('first boot: importing this unit\'s factory calibration from %s'
        % args.dir)
    return migrate(args, moonraker, panel)


def migrate(args, moonraker, panel):
    deadline = time.time() + args.timeout
    tools = moonraker.tools()
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

    pending = moonraker.save_pending()
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
    applied, detail = moonraker.gcode('FF_IMPORT_FIRMWARE_CONFIG')
    if not applied:
        log('FF_IMPORT_FIRMWARE_CONFIG failed: %s' % detail)
        panel.failed('THE PRINTER REFUSED FF_IMPORT_FIRMWARE_CONFIG')
        return 1
    tools = moonraker.tools()
    if not any_calibrated(tools):
        # The command ran but the JSON held nothing usable. Saving now would
        # persist nothing and restart klippy for no reason.
        log('the import landed no nozzle positions -- not saving')
        panel.failed('NO CALIBRATION FOUND IN THE FACTORY DATA')
        return 1

    log('imported; persisting with SAVE_CONFIG -- klipper restarts once')
    panel.say('SAVING CALIBRATION', 0.7)
    applied, detail = moonraker.gcode('SAVE_CONFIG', timeout=20.0)
    if not applied:
        # Expected: the restart cuts the connection before moonraker answers.
        log('SAVE_CONFIG did not answer (%s) -- klipper is restarting' % detail)

    panel.say('RESTARTING THE PRINTER', 0.85)
    if not wait_for_ready(moonraker, max(deadline, time.time() + 90.0)):
        log('klipper did not come back after SAVE_CONFIG -- no stamp')
        panel.failed('KLIPPER DID NOT RESTART AFTER SAVING')
        return 1
    tools = moonraker.tools()
    if not any_calibrated(tools):
        log('klipper came back with no saved nozzle position -- the save did'
            ' not take, no stamp')
        panel.failed('THE CALIBRATION DID NOT SAVE')
        return 1

    log('done: the factory calibration is saved in printer.cfg')
    panel.say('SETUP COMPLETE', 1.0, note='')
    stamp(args.stamp, 'imported %s' % args.dir)
    return 0


def selftest():
    """Report what this script can actually reach, and exit.

    The imports above are the kind that work when a developer runs the file
    and fail in the field: they resolve only because python puts the script's
    own directory on sys.path, which is true when it is run by path and NOT
    true when something loads it through importlib. So the check has to be
    the script running itself, which is what this is for -- the replica gate
    calls it, and it is worth having on a printer over ssh too.
    """
    passed = True
    print('ffscreen: %s' % ('yes' if ffscreen is not None else 'NO'))
    if ffscreen is None:
        passed = False
    print('ff_mcu_bringup: %s' % ('yes' if bringup is not None else 'NO'))
    if bringup is None:
        passed = False
    else:
        ports = list(bringup.DEFAULT_PORTS)
        print('ports: %d (%s)' % (len(ports), ' '.join(ports)))
        unnamed = [port for port in ports
                   if not board_name(port).startswith('THE ')]
        print('named: %s' % ('yes' if not unnamed else 'NO %s' % unnamed))
        if unnamed:
            passed = False
    print('selftest: %s' % ('ok' if passed else 'FAILED'))
    return 0 if passed else 1


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stamp', default=STAMP)
    parser.add_argument('--dir', default=JSON_DIR)
    parser.add_argument('--moonraker', default=MOONRAKER)
    parser.add_argument('--timeout', type=float, default=TIMEOUT)
    parser.add_argument('--mcu-timeout', type=float, default=MCU_TIMEOUT,
                        help="how long one bring-up pass may take")
    parser.add_argument('--klipper-tries', type=int, default=KLIPPER_TRIES,
                        help="how many times to hand the boards over and retry")
    parser.add_argument('--start-sh', default=START_SH)
    parser.add_argument('--daemon', default=DAEMON)
    parser.add_argument('--no-klipper', action='store_true',
                        help="do not start klipper; only wait for it")
    parser.add_argument('--no-import', action='store_true',
                        help="only bring the printer up; never migrate")
    parser.add_argument('--fb', default=None,
                        help='framebuffer to draw the boot screen on')
    parser.add_argument('--fb-geometry', default=None,
                        help="panel size as WxH@BPP, skipping the sysfs probe")
    parser.add_argument('--no-screen', action='store_true',
                        help='do not draw anything on the panel')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--selftest', action='store_true',
                        help='report what this script can reach, and exit')
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    try:
        return run(args)
    except KeyboardInterrupt:
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
