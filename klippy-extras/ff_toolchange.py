# Native toolchange for the FlashForge Creator 5 Pro.
#
# A faithful port of firmwareExe's own sequences, recovered from the binary:
#   CommMgr::doGrabExtruderLatest    @ 0x7a8190
#   CommMgr::doReleaseExtruderLatest @ 0x7aa394
# See OKF/31-recovered-toolchange-sequences.md and
# firmwareExe-decompiled/recovered/toolchange.c.
#
# This exists as a Python extra rather than a set of gcode_macros because the
# original is a polling state machine: it waits for sensors, retries, and only
# energises the lock motor once the grab sensor reads active. A gcode_macro
# renders its whole template before executing any of it, so it cannot poll.
#
# It deliberately does NOT reimplement current supervision. The app only ever
# logs motor_value ("extruderGrab/motorValue: %d / %f") and always decides on
# switch state; E0145 "Lock motor current abnormal" is raised Klipper/MCU-side.
# Driving the same MOTOR_* macros therefore inherits that behaviour unchanged.
#
# Install: copy to /usr/prog/klipper/klippy/extras/ff_toolchange.py, then in
# /usr/data/config/printer.cfg:
#     [ff_toolchange]
#     dock_x: ...
#
# Klipper calls Tn only for lines that reach the gcode engine; a bare "Tn" in a
# printing file is still swallowed by the FlashForge virtual_sdcard fork, so
# touchscreen jobs are unaffected.

import contextlib
import json
import logging
import math
import os

EXTRUDER_COUNT = 4

# Timings and retry counts, straight from doGrabExtruderLatest and
# doReleaseExtruderLatest. The app's waits are "N tries x usleep(50000)"; we
# express them as wall-clock deadlines (N * 50 ms) because reactor.pause can
# return later than asked on a busy reactor -- counting iterations would
# understate the wait (see _poll_until).
POLL_INTERVAL = 0.050       # usleep(50000)
BACKOFF_WAIT = 0.100        # usleep(100000)
LOCATION_TIMEOUT = 20 * POLL_INTERVAL   # dock prechecks, 0x14 tries
SEAT_TIMEOUT = 20 * POLL_INTERVAL       # sensor gates inside an attempt
VERIFY_TIMEOUT = 20 * POLL_INTERVAL     # post-sequence verification
GRAB_ATTEMPTS = 3
RELEASE_ATTEMPTS = 3
RELEASE_RETRIES = 3         # MOTOR_RELEASE sends per attempt (fail on 3rd)
RELEASE_STAGE_BACKOFF = 10.0    # release staging "G1 X<dock-10>" (@0xdb6af8)
PULLBACK_FEED = 4800            # grab pullback's literal " F4800" (@0xdb4d40)

# Feed fallbacks (mm/min) the app uses when testConfig() has no usable value.
FAST_FEED_DEFAULT = 24000.
SLOW_FEED_DEFAULT = 6000.           # grab side
RELEASE_SLOW_FEED_DEFAULT = 5400.   # release reads the same grabSpeedSlow but
                                    # substitutes 5400 (0x1518), not 6000

# Firmware error codes. Per-tool families report E<base + tool>; both grab
# and release map through the LANG_SRC table built at 0x689838.
ERR_NOT_IN_DOCK_BASE = 127      # E0127+t  tool not detected in its dock (grab)
ERR_GRAB_VERIFY_BASE = 51       # E0051+t  pickup could not be verified
ERR_ALREADY_IN_DOCK_BASE = 131  # E0131+t  release precheck: dock not empty
ERR_RELEASE_FAILED_BASE = 135   # E0135+t  unlock endstop never triggered
ERR_RELEASE_STATE = 144         # E0144    state error after release verify


# ---------------------------------------------------------------------------
# FlashForge's own per-unit configuration.
#
# The values this module needs already exist on the printer, written by the
# factory calibration and maintained by firmwareExe. Duplicating them into a
# Klipper .cfg guarantees the two drift apart the moment anything recalibrates,
# so we read the originals and treat the .cfg purely as an override layer.
#
# Config::extruderConfig() / testConfig() / zOffsetConfig() are backed by these
# files. Note they are NOT strict JSON: each ends with a trailing C-style
# comment after the closing brace ("/* Printer Extruder Offset Config */"),
# which makes json.loads() raise "Extra data". raw_decode() stops at the end of
# the first value and ignores the tail.
#
# There is exactly ONE config directory. initManagers() @0x412efc checks for
# /usr/data/config/test.json and, if present, FileManager::copy()s it into
# /usr/data/firmwareRes/config/ and then FileManager::remove()s the original --
# it is a one-shot drop-in install hook, not a second search path. Every reader
# then calls Config::load("/usr/data/firmwareRes/config") exactly once.
#
# Key names and their order were read off the binary's symbol table and the
# load functions themselves (Config::loadExtruderConfig @0x64f7f8,
# loadTestConfig @0x654380, loadZOffsetConfig @0x65621c), so the struct offsets
# quoted below are the app's real layout:
#   t0..t3_offset_x/y/z          +0x00..+0x2c
#   x_check_pos ,y_check_pos     +0x30/+0x34    (X and Y interleaved per tool)
#   x_check_pos1,y_check_pos1    +0x38/+0x3c
#   x_check_pos2,y_check_pos2    +0x40/+0x44
#   x_check_pos3,y_check_pos3    +0x48/+0x4c
#   x/y/z_station_pos            +0x50/+0x54/+0x58
#   now_extruder                 +0x5c
#   test.json: grabSpeed +0, grabSpeedSlow +4, grabOffset +8
#
# We never WRITE these files. Config::syncExtruderConfig @0x651388 rewrites the
# whole of extruder.json from the app's in-memory struct, so anything we wrote
# would be silently clobbered (and could revert unrelated keys). We do not
# mirror now_extruder either -- the mounted tool is derived from the dock
# sensors on demand and nothing is stored. See OKF/34-mounted-tool-state.md.
# ---------------------------------------------------------------------------


FIRMWARE_CONFIG_DIR = '/usr/data/firmwareRes/config'


class FFFirmwareConfig:
    """Read-only view of firmwareExe's per-unit JSON configuration."""

    def __init__(self, directory):
        self.dir = directory
        self.files = {}
        self.errors = []
        self.load()

    def load(self):
        self.files = {}
        self.errors = []
        for name in ('extruder', 'test', 'zoffset'):
            path = os.path.join(self.dir, name + '.json')
            try:
                with open(path, 'r') as fh:
                    text = fh.read()
            except IOError as e:
                self.errors.append("%s: %s" % (path, e))
                continue
            try:
                # raw_decode, not loads -- see the note above.
                obj, _ = json.JSONDecoder().raw_decode(text.lstrip())
            except ValueError as e:
                self.errors.append("%s: not valid JSON (%s)" % (path, e))
                continue
            if not isinstance(obj, dict):
                self.errors.append("%s: expected a JSON object" % path)
                continue
            self.files[name] = obj
            logging.info("ff_toolchange: loaded %s (%d keys)",
                         path, len(obj))
        for msg in self.errors:
            logging.warning("ff_toolchange: %s", msg)

    # -- primitives ---------------------------------------------------------

    def _num(self, fname, key):
        obj = self.files.get(fname)
        if obj is None:
            return None
        val = obj.get(key)
        if isinstance(val, bool) or not isinstance(val, (int, float)):
            return None
        if not math.isfinite(val):
            logging.warning("ff_toolchange: %s.json: %s is not finite (%r),"
                            " ignoring", fname, key, val)
            return None
        return float(val)

    def _series(self, fname, keys):
        """All-or-nothing -- a DELIBERATE divergence from the app.

        Config::loadExtruderConfig reads each key as
        Json::Value::get(key, <current member>), so a missing key silently
        falls back to the app's compiled-in init default (initExtruderConfig
        @0x65119c: x_check_pos 298.219, x_check_pos1 298.605, ...). Those are
        generic values, ~1.7 mm from this unit's calibration, and substituting
        one into a dock approach would drive the carriage to the wrong place
        with no indication anything was wrong.

        We would rather fail loudly, so a series is used only if every key of
        it is present."""
        vals = [self._num(fname, k) for k in keys]
        if any(v is None for v in vals):
            return None
        return vals

    # -- the quantities the toolchanger needs -------------------------------

    def dock_x(self):
        # extruderConfig() +0x30/+0x38/+0x40/+0x48
        return self._series('extruder', ['x_check_pos', 'x_check_pos1',
                                         'x_check_pos2', 'x_check_pos3'])

    def dock_y(self):
        # extruderConfig() +0x34/+0x3c/+0x44/+0x4c
        return self._series('extruder', ['y_check_pos', 'y_check_pos1',
                                         'y_check_pos2', 'y_check_pos3'])

    def x_correction(self):
        # testConfig()+8
        return self._num('test', 'grabOffset')

    def _speed(self, key, fallback):
        # The app reads a mm/s word and multiplies by 60, falling back to a
        # constant when the stored value is <= 0.
        val = self._num('test', key)
        if val is None:
            return None
        val *= 60.0
        return val if val > 0 else float(fallback)

    def fast_feed(self):
        # testConfig()+0
        return self._speed('grabSpeed', FAST_FEED_DEFAULT)

    def slow_feed(self):
        # testConfig()+4
        return self._speed('grabSpeedSlow', SLOW_FEED_DEFAULT)

    def slow_feed_release(self):
        # doReleaseExtruderLatest reads the same testConfig()+4 word but its
        # <= 0 fallback is 5400, not the grab side's 6000.
        return self._speed('grabSpeedSlow', RELEASE_SLOW_FEED_DEFAULT)

    def offset_z(self):
        # zoffset.json is 1-BASED: z_offset_t1 is tool 0.
        return self._series('zoffset',
                            ['z_offset_t%d' % (i + 1) for i in range(4)])

    def tool_offsets(self):
        """t0..t3_offset_x/y/z, exactly as OffsetMgr::rebootInitValue @0x6593e8
        loads them into its map: map[Tn] = extruderConfig()+{0,4,8} + 0xc*n.
        No transformation is applied there and none is applied here."""
        rows = []
        for n in range(EXTRUDER_COUNT):
            v = [self._num('extruder', 't%d_offset_%s' % (n, a))
                 for a in ('x', 'y', 'z')]
            if any(x is None for x in v):
                return None
            rows.append(v)
        return rows

    def z_station_pos(self):
        # extruderConfig()+0x58 -- the Z at which the EDDY probe triggered
        # over the fixed nozzle-touch sensor during calibration (the sensor
        # sits below the bed plane; negative on this unit). t<n>_offset_z is
        # the Z at which tool n's NOZZLE touched that same sensor, so
        # (t<n>_offset_z - z_station_pos) is the absolute gap between the
        # eddy trigger plane and tool n's nozzle plane -- the core of the
        # print-start Z offset (BuildPage::startPrint @0x9fc148).
        return self._num('extruder', 'z_station_pos')

    def temp_offset(self):
        # testConfig()+0xc -- degC-to-mm thermal compensation factor in the
        # print-start Z offset: (nozzle_temp - 120) * tempOffset.
        return self._num('test', 'tempOffset')

    def now_extruder(self):
        # extruderConfig()+0x5c -- the app's own active-tool index.
        val = self._num('extruder', 'now_extruder')
        # _num already rejects non-finite values, but guard int() anyway.
        if val is None or not math.isfinite(val):
            return None
        return int(val)


class FFToolchangeError(Exception):
    """A toolchange step failed or the sensors report an unusable state."""


class FFToolchange:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')
        self.name = config.get_name()

        # --- where the numbers come from -----------------------------------
        # Precedence, highest first:
        #   1. an option explicitly set in this printer.cfg section
        #   2. firmwareExe's own per-unit JSON under firmware_config_dir
        #   3. the app's hardcoded fallback
        # So a stock machine needs no geometry in the .cfg at all, and anything
        # you do write here is an intentional override of the factory value.
        self.fw_dir = config.get('firmware_config_dir', FIRMWARE_CONFIG_DIR)
        self.fw = FFFirmwareConfig(self.fw_dir)
        self.sources = {}

        def _resolve(option, fw_value, fallback, getter):
            """Return (value, provenance) honouring the precedence above."""
            cfg_value = getter(option, None)
            if cfg_value is not None:
                self.sources[option] = 'printer.cfg'
                return cfg_value
            if fw_value is not None:
                self.sources[option] = 'firmware'
                return fw_value
            self.sources[option] = 'default'
            return fallback

        def scalar(option, fw_value, fallback):
            return _resolve(option, fw_value, fallback, config.getfloat)

        def series(option, fw_value, fallback):
            def getter(opt, _default):
                raw = config.get(opt, None)
                if raw is None:
                    return None
                vals = [float(v.strip()) for v in raw.split(',')]
                if len(vals) != EXTRUDER_COUNT:
                    raise config.error(
                        "%s: %s needs %d comma-separated values"
                        % (self.name, opt, EXTRUDER_COUNT))
                return vals
            return _resolve(option, fw_value, fallback, getter)

        # Per-unit dock geometry -- extruderConfig() +0x30..+0x4c.
        self.dock_x = series('dock_x', self.fw.dock_x(), None)
        self.dock_y = series('dock_y', self.fw.dock_y(), None)
        if self.dock_x is None or self.dock_y is None:
            raise config.error(
                "%s: dock coordinates unavailable -- %s could not be read (%s)."
                " Set dock_x/dock_y explicitly, or point firmware_config_dir at"
                " a copy of the printer's firmwareRes/config directory."
                % (self.name, self.fw_dir,
                   "; ".join(self.fw.errors) or "keys missing"))
        # testConfig()+8.
        self.x_correction = scalar('x_correction', self.fw.x_correction(), 0.0)

        # Per-tool G-code offsets -- differences against a base tool, exactly
        # as CommMgr::setGrabGcodeOffsetMgr computes them. See _derive_offsets
        # and OKF/33-per-tool-offsets.md.
        self.offset_base = config.getint('offset_base', 0,
                                         minval=0, maxval=EXTRUDER_COUNT - 1)
        fx, fy, fz = self._derive_offsets(self.offset_base)
        self.off_x = series('offset_x', fx, [0.0] * EXTRUDER_COUNT)
        self.off_y = series('offset_y', fy, [0.0] * EXTRUDER_COUNT)
        self.off_z = series('offset_z', fz, [0.0] * EXTRUDER_COUNT)
        # The tool-derived part of the Z offset we last applied. The remainder
        # of Klipper's gcode Z offset is the user's babystep, which the app
        # keeps separately at CommMgr+0x130 and re-adds on every change so a
        # toolchange does not discard it. Reset on restart, as the app's is.
        self._z_tool_term = 0.0

        # Staging positions. These are code constants in the app, not config.
        self.x_safe = config.getfloat('x_safe', 250.0)
        self.x_approach = config.getfloat('x_approach', 280.0)
        self.grab_pullback = config.getfloat('grab_pullback', 20.0)

        # Feeds. testConfig()+0 and +4 are mm/s and get multiplied by 60, with
        # the app falling back to 24000/6000 when the stored value is <= 0.
        self.fast_feed = int(scalar('fast_feed', self.fw.fast_feed(),
                                    FAST_FEED_DEFAULT))
        self.slow_feed = int(scalar('slow_feed', self.fw.slow_feed(),
                                    SLOW_FEED_DEFAULT))
        self.release_slow_feed = int(scalar(
            'release_slow_feed', self.fw.slow_feed_release(),
            RELEASE_SLOW_FEED_DEFAULT))
        self.grab_retreat_feed = config.getint('grab_retreat_feed', 1500)
        self.release_retreat_feed = config.getint('release_retreat_feed', 4800)
        self.accel_move = config.getint('accel_move', 8000)
        # Post-sequence accel. The app hardcodes 20000; unset, we restore the
        # limit that was live when the sequence started (a user with a lower
        # [printer] max_accel must not come out of a toolchange faster).
        self.accel_restore = config.getint('accel_restore', None)

        # Sensor names.
        #  position buttons: one per tool, PRESSED == that tool is in its dock
        #    (CommMgr::checkInLocation indexes these by tool)
        #  grab buttons: OR'd together == something is currently grabbed
        #    (CommMgr::getGrabSensorStatus). VERIFY THIS SET ON HARDWARE with
        #    TOOLCHANGE_STATUS before trusting it -- the exact bit packing of
        #    ExtruderGrabInfo was not fully pinned down from the decompile.
        self.dock_sensors = config.get(
            'dock_sensors',
            'extruder_pos1, extruder_pos2, extruder_pos3, extruder_pos4')
        self.dock_sensors = [s.strip() for s in self.dock_sensors.split(',')]
        if len(self.dock_sensors) != EXTRUDER_COUNT:
            raise config.error("%s: dock_sensors needs %d names"
                               % (self.name, EXTRUDER_COUNT))
        self.grab_sensors = [s.strip() for s in config.get(
            'grab_sensors',
            'extruder_grab1, extruder_grab2, extruder_grab3, extruder_grab4'
        ).split(',') if s.strip()]
        if not self.grab_sensors:
            raise config.error("%s: grab_sensors needs at least one name"
                               % self.name)
        self.grab_macro = config.get('grab_macro', 'MOTOR_GRAB')
        self.grab2_macro = config.get('grab2_macro', 'MOTOR_GRAB2')
        self.release_macro = config.get('release_macro', 'MOTOR_RELEASE')
        self.stop_macro = config.get('stop_macro', 'MOTOR_STOP')
        # firmwareExe auto-homes in doGrabExtruderLatest when not homed, but
        # there the user is standing at the touchscreen. A remote T<n> that
        # silently starts G28 can crash into whatever is on the bed, so the
        # default here is to abort and let the user home deliberately.
        self.auto_home = config.getboolean('auto_home', False)

        self.gcode.register_command(
            'TOOLCHANGE', self.cmd_TOOLCHANGE, desc=self.cmd_TOOLCHANGE_help)
        for i in range(EXTRUDER_COUNT):
            self.gcode.register_command(
                'T%d' % i, self._make_tn(i), desc="Select tool %d" % i)
        self.gcode.register_command(
            'TOOLCHANGE_STATUS', self.cmd_TOOLCHANGE_STATUS,
            desc=self.cmd_TOOLCHANGE_STATUS_help)
        self.gcode.register_command(
            'TOOLCHANGE_PARK', self.cmd_TOOLCHANGE_PARK,
            desc=self.cmd_TOOLCHANGE_PARK_help)
        self.gcode.register_command(
            'TOOLCHANGE_RELOAD', self.cmd_TOOLCHANGE_RELOAD,
            desc=self.cmd_TOOLCHANGE_RELOAD_help)
        self.gcode.register_command(
            'TOOLCHANGE_SET_PRINT_OFFSET', self.cmd_TOOLCHANGE_SET_PRINT_OFFSET,
            desc=self.cmd_TOOLCHANGE_SET_PRINT_OFFSET_help)

        self.printer.register_event_handler('klippy:connect',
                                            self._handle_connect)
        self.printer.register_event_handler('klippy:ready',
                                            self._handle_ready)

    def _derive_offsets(self, base):
        """Per-tool G-code offsets, as CommMgr::setGrabGcodeOffsetMgr @0x77f1dc
        computes them.

            X = t<tool>_offset_x - t<base>_offset_x
            Y = t<tool>_offset_y - t<base>_offset_y
            Z = z_offset_t<tool+1> + (t<tool>_offset_z - t<base>_offset_z)

        i.e. DIFFERENCES against a base tool, not absolute positions. The base
        is CommMgr+0x59c, zeroed by the constructor (so T0) and changed only by
        setBaseExtruder(), which the touchscreen calls from serialPrint and
        BuildPage::compareExtruderFromMf.

        The values come from OffsetMgr, which loads extruderConfig() verbatim,
        and the z term's zoffset part is CommMgr::getAdjustOffset @0x77efd4 =
        zOffsetConfig()[tool].

        Do NOT confuse this with CommMgr::getStationExOffset @0x79a508, which
        computes (x_station_pos - tN_offset_x) ~= 12 mm. That one is only used
        by the calibration dialogs and moveCylinderPos -- it is not on the
        print-offset path.

        Returns (xs, ys, zs), or (None, None, None) if the data is unavailable.
        """
        tools = self.fw.tool_offsets()
        zoff = self.fw.offset_z()
        if tools is None:
            return None, None, None
        bx, by, bz = tools[base]
        xs = [t[0] - bx for t in tools]
        ys = [t[1] - by for t in tools]
        if zoff is None:
            zs = None
        else:
            zs = [zoff[i] + (tools[i][2] - bz) for i in range(EXTRUDER_COUNT)]
        return xs, ys, zs

    # ---------------- plumbing ----------------

    def _handle_connect(self):
        """Validate every name we will later look up, all at once.

        A misspelled button, extruder or macro name would otherwise only
        surface mid-toolchange, with the carriage already at a dock."""
        missing = []

        for name in self.dock_sensors + self.grab_sensors:
            if self.printer.lookup_object(
                    'gcode_button %s' % name, None) is None:
                missing.append("gcode_button %s" % name)

        for tool in range(EXTRUDER_COUNT):
            ename = self._extruder_name(tool)
            if self.printer.lookup_object(ename, None) is None:
                missing.append(ename)

        # gcode_macro objects keep the section name's casing, but the command
        # each registers is name.upper() (gcode_macro.py: alias = name.upper())
        # -- so compare case-insensitively against the registered macros.
        macros = set()
        for oname, _obj in self.printer.lookup_objects(module='gcode_macro'):
            parts = oname.split(None, 1)
            if len(parts) == 2:
                macros.add(parts[1].upper())

        for mname in (self.grab_macro, self.grab2_macro,
                      self.release_macro, self.stop_macro):
            cmd = mname.split()[0]
            if cmd.upper() not in macros:
                missing.append("gcode_macro %s" % cmd)

        if missing:
            raise self.printer.config_error(
                "%s: configured objects not found: %s"
                % (self.name, ", ".join(missing)))

    def _handle_ready(self):
        if any(self.sources.get(k) == 'default'
               for k in ('offset_x', 'offset_y', 'offset_z')):
            self.gcode.respond_info(
                "ff_toolchange: WARNING: per-tool offsets not found in"
                " firmware JSON and not set in printer.cfg -- all tools"
                " assume zero offset. Check %s." % self.fw_dir)

    def _make_tn(self, index):
        def handler(gcmd):
            self._toolchange(gcmd, index)
        return handler

    def _run(self, script):
        self.gcode.run_script_from_command(script)

    def _wait_moves(self):
        # Equivalent of the app's M400 before sampling sensors.
        self.printer.lookup_object('toolhead').wait_moves()

    def _sleep(self, seconds):
        self.reactor.pause(self.reactor.monotonic() + seconds)

    def _poll_until(self, check, timeout):
        """Wait for check() to go true, sampling every POLL_INTERVAL.

        Deadline-chained like heaters.py:358 rather than iteration-counted:
        reactor.pause() returns the ACTUAL wakeup time, which can be later
        than asked on a busy reactor, and an emergency shutdown must end the
        wait immediately instead of spinning it out. Returns the final
        check() result."""
        eventtime = self.reactor.monotonic()
        deadline = eventtime + timeout
        while eventtime < deadline:
            if self.printer.is_shutdown():
                raise FFToolchangeError(
                    "printer shut down while waiting for a toolchange sensor")
            if check():
                return True
            eventtime = self.reactor.pause(eventtime + POLL_INTERVAL)
        return bool(check())

    def _sensor(self, name, eventtime=None):
        # lookup_object is a plain dict hit (klippy.py:76); not worth caching.
        # _handle_connect has already verified every configured name exists.
        obj = self.printer.lookup_object('gcode_button %s' % name, None)
        if obj is None:
            raise FFToolchangeError(
                "gcode_button '%s' is not configured" % name)
        if eventtime is None:
            eventtime = self.reactor.monotonic()
        return obj.get_status(eventtime)['state'] == 'PRESSED'

    def _in_location(self, tool, eventtime=None):
        """CommMgr::checkInLocation -- is `tool` sitting in its dock?"""
        return self._sensor(self.dock_sensors[tool], eventtime)

    def _grab_sensor(self, eventtime=None):
        """CommMgr::getGrabSensorStatus -- is anything currently grabbed?"""
        return any(self._sensor(n, eventtime) for n in self.grab_sensors)

    # ---------------- which tool is mounted ----------------
    #
    # Derived from the dock sensors every time it is needed. Nothing is stored.
    #
    # firmwareExe cannot do this. Its getGrabSensorStatus(info, tool) @0x76f294
    # ignores its `tool` argument entirely -- it ORs the four grab bytes and
    # returns a bare "something is held". So the app never learns WHICH tool it
    # is carrying and has to keep an imperative index
    # (extruderConfig()+0x5c / now_extruder): set on grab, reset to -1 on
    # release and on every home, persisted by syncExtruderConfig, and read in
    # ~30 places as the truth. checkInstallExtruder @0x781a34 shows the seam:
    #     installed = dock_sensor[tool] || (anyGrabbed && now_extruder == tool)
    # -- sensors first, the stored index only to name the held tool.
    #
    # Our extruder_pos1..4 are per-tool, so they carry that identity directly:
    # the mounted tool is the one whose dock is empty. Nothing to store means
    # nothing to go stale after a touchscreen print, a power cut mid-change, or
    # a manual swap -- and no persistent state of any kind.
    #
    # Anything the sensors cannot explain raises, rather than guessing. Guessing
    # wrong here means releasing the wrong tool: driving to another tool's dock
    # and dropping the tool actually being carried into it.

    def _derive_current_tool(self, eventtime=None):
        """Return (tool, reason); tool is -1 for 'nothing on the carriage'.

        Raises FFToolchangeError on any state the sensors cannot explain."""
        absent = [i for i in range(EXTRUDER_COUNT)
                  if not self._in_location(i, eventtime)]
        grabbed = self._grab_sensor(eventtime)
        names = ",".join("T%d" % i for i in absent)

        if grabbed and not absent:
            raise FFToolchangeError(
                "sensor state is impossible: a tool is grabbed but all %d "
                "tools are in their docks. Either a switch is faulty (check "
                "with TOOLCHANGE_STATUS) or the carriage is physically mated "
                "with a docked tool -- e.g. after a restart mid-change. In "
                "that case run %s, jog the carriage clear in +X, and retry."
                % (EXTRUDER_COUNT, self.release_macro))
        if not absent:
            return -1, "all docks occupied, nothing grabbed"
        if not grabbed:
            # Dock(s) empty with nothing held: those tools are out of the
            # machine. Nothing is on the carriage, which is a valid answer --
            # asking to pick one of them up fails later, in _grab, by name.
            return -1, "%s not in the machine (dock empty, nothing grabbed)" % names
        if len(absent) == 1:
            return absent[0], "T%d out of its dock and grabbed" % absent[0]
        raise FFToolchangeError(
            "cannot identify the mounted tool: a tool is grabbed but %d docks "
            "are empty (%s). Dock the tools that are not in use, then retry."
            % (len(absent), names))

    def _current_tool_or_none(self, eventtime=None):
        """Non-throwing variant, for reporting only."""
        try:
            return self._derive_current_tool(eventtime)
        except FFToolchangeError as e:
            return None, str(e)

    def _dock(self, tool):
        return self.dock_x[tool] + self.x_correction, self.dock_y[tool]

    def _extruder_name(self, tool):
        return 'extruder' if tool == 0 else 'extruder%d' % tool

    def _current_max_accel(self):
        toolhead = self.printer.lookup_object('toolhead')
        return toolhead.get_status(self.reactor.monotonic())['max_accel']

    @contextlib.contextmanager
    def _snapshot_motion_state(self):
        """Snapshot the motion state on entry, put it back on exit.

        Captured before the sequence touches anything: the live accel limit
        and the modal G-code state. The exit is unconditional, success and
        failure alike, matching the app (MOTOR_STOP + SET_VELOCITY_LIMIT
        ACCEL=20000 run on every path of doGrab/doReleaseExtruderLatest past
        their prechecks), so a raw Klipper error cannot leak reduced accel
        or an energised lock driver.

        The dock moves force G90 and leave the modal feedrate at the last
        sequence feed; the app leaks both (its user is the touchscreen,
        which never issues a bare G1), but a slicer move without F after a
        mid-print toolchange must not run at dock speeds -- so the exit also
        restores the pre-sequence mode and feedrate."""
        # gcode_move always exists -- toolhead.py:297 loads it
        # unconditionally with its other standard modules.
        st = self.printer.lookup_object('gcode_move').get_status()
        absolute, speed = (st['absolute_coordinates'], st['speed'])

        accel = self.accel_restore or self._current_max_accel()
        try:
            yield
        finally:
            self._run(self.stop_macro)
            self._run('SET_VELOCITY_LIMIT ACCEL=%d' % accel)

            if not absolute:
                self._run('G91')
            if speed > 0.:
                self._run('G1 F%.3f' % speed)

    def _ensure_homed(self):
        toolhead = self.printer.lookup_object('toolhead')
        homed = toolhead.get_status(self.reactor.monotonic())['homed_axes']
        if not all(a in homed for a in 'xyz'):
            if not self.auto_home:
                raise FFToolchangeError(
                    "printer is not homed -- run G28 first "
                    "(or set auto_home: True in [ff_toolchange])")
            self._run('G28')

    # ---------------- grab ----------------

    def _grab(self, tool):
        """Port of CommMgr::doGrabExtruderLatest @0x7a8190."""
        dx, dy = self._dock(tool)

        # Precheck: the target must be detected in its dock (20 x 50 ms).
        # No motion at all on failure.
        self._wait_moves()
        if not self._poll_until(lambda: self._in_location(tool),
                                LOCATION_TIMEOUT):
            raise FFToolchangeError(
                "T%d is not in its dock -- cannot pick it up "
                "(firmware error E%04d)" % (tool, ERR_NOT_IN_DOCK_BASE + tool))

        with self._snapshot_motion_state():
            self._run('SET_VELOCITY_LIMIT ACCEL=%d' % self.accel_move)
            self._run('SET_GCODE_OFFSET X=0 Y=0 MOVE=1 MOVE_SPEED=100')
            self._run('G90')
            self._run('G1 X%.3f F%d' % (self.x_safe, self.fast_feed))
            self._run('G1 Y%.3f' % dy)
            self._run('G1 X%.3f' % self.x_approach)

            # Up to 3 attempts; within each, poll up to 1 s for the grab
            # sensor before energising the motor.
            for attempt in range(GRAB_ATTEMPTS):
                # Re-engage the dock at the top of EVERY attempt. The app
                # emits this move twice: once before the retry loop and again
                # as the first statement of each iteration, so that the
                # back-off to x_approach below is undone before the next
                # round of polling. Without it, attempts 2 and 3 poll from
                # the backed-off position and can never mate.
                self._run('G1 X%.3f F%d' % (dx, self.slow_feed))
                self._wait_moves()

                # the app sleeps before its first poll
                # TODO: do we need this? only experiment can show that
                # self._sleep(POLL_INTERVAL)

                if self._poll_until(self._grab_sensor, SEAT_TIMEOUT):
                    self._run(self.grab_macro)
                    # The pullback feed is the app's literal F4800
                    # (@0x7a9074), NOT the calibrated slow feed.
                    self._run('G1 X%.3f F%d'
                              % (dx - self.grab_pullback, PULLBACK_FEED))
                    self._run(self.grab2_macro)
                    break

                logging.info("ff_toolchange: grab attempt %d/%d for T%d"
                             " failed, backing off",
                             attempt + 1, GRAB_ATTEMPTS, tool)

                self._run('G1 X%.3f' % self.x_approach)
                self._wait_moves()
                self._sleep(BACKOFF_WAIT)

            else:
                raise FFToolchangeError(
                    "grab sensor never activated for T%d after %d attempts"
                    % (tool, GRAB_ATTEMPTS))

            self._run('G1 X%.3f F%d' % (self.x_safe, self.grab_retreat_feed))
            self._wait_moves()

            # Verify: the tool must have LEFT its dock and the grab sensor
            # must be engaged. (doGrabExtruderLatest: !inLocation && grab)
            ok = self._poll_until(
                lambda: (not self._in_location(tool)) and self._grab_sensor(),
                VERIFY_TIMEOUT)
            if not ok:
                raise FFToolchangeError(
                    "T%d pickup could not be verified: in_dock=%s"
                    " grab_sensor=%s (firmware error E%04d)"
                    % (tool, self._in_location(tool), self._grab_sensor(),
                       ERR_GRAB_VERIFY_BASE + tool))

            # The app activates the extruder and applies the tool offsets
            # INSIDE doGrabExtruderLatest (toolchange.c 3207-3218), before
            # MOTOR_STOP and while accel is still 8000 -- so the two
            # SET_GCODE_OFFSET MOVE=1 moves run at approach accel, not at
            # the restored limit.
            self._run('ACTIVATE_EXTRUDER EXTRUDER=%s'
                      % self._extruder_name(tool))
            self._apply_tool_diff_offsets(tool)

    # ---------------- release ----------------

    def _release(self, tool):
        """Port of CommMgr::doReleaseExtruderLatest @0x7aa394.

        The app supervises the lock stepper by polling getManualStepperStatus
        (0 = no report yet, 1 = endstop triggered, 2 = move ended without
        trigger) -- values its doApiResponse greps out of the raw gcode
        response text. In-process we get the same signal synchronously: this
        fork's manual_stepper re-raises on "endstop not triggered"
        (manual_stepper.py:98-106, via homing.py's "No trigger on
        manual_stepper gear_stepper"), so MOTOR_RELEASE returning normally IS
        status 1 and raising IS status 2. The app's 40 x 50 ms wait window
        therefore has nothing left to wait for. One micro-divergence,
        deliberate: after the third failed unlock the app fires a fourth
        MOTOR_RELEASE it never supervises (it re-issues before checking its
        counter); we stop at three rather than energise the motor with no one
        watching."""
        dx, dy = self._dock(tool)

        # Precheck: this tool's dock must read EMPTY (the tool is on the
        # carriage). 20 x 50 ms; no motion at all on failure.
        self._wait_moves()
        if not self._poll_until(lambda: not self._in_location(tool),
                                LOCATION_TIMEOUT):
            raise FFToolchangeError(
                "T%d reads as already in its dock -- cannot release "
                "(firmware error E%04d)"
                % (tool, ERR_ALREADY_IN_DOCK_BASE + tool))

        with self._snapshot_motion_state():
            self._run('SET_VELOCITY_LIMIT ACCEL=%d' % self.accel_move)
            self._run('SET_GCODE_OFFSET X=0 Y=0 MOVE=1 MOVE_SPEED=100')
            self._run('G90')
            # Release approach: X250 then dock Y, once, outside the retry
            # loop. There is NO X280 stage here -- that is grab-only; the
            # release staging point is dockX-10 below.
            self._run('G1 X%.3f F%d' % (self.x_safe, self.fast_feed))
            self._run('G1 Y%.3f' % dy)

            for attempt in range(RELEASE_ATTEMPTS):
                # The app emits G1 X<dock-10> with NO F (inheriting the
                # modal feed: fast on attempt 1, the slow feed on retries)
                # and the final mate at the release slow feed.
                self._run('G1 X%.3f' % (dx - RELEASE_STAGE_BACKOFF))
                self._run('G1 X%.3f F%d' % (dx, self.release_slow_feed))
                self._wait_moves()

                # Unlock only once the dock sensor confirms the tool has
                # seated -- releasing early drops the tool on the floor.
                if not self._poll_until(lambda: self._in_location(tool),
                                        SEAT_TIMEOUT):
                    logging.info(
                        "ff_toolchange: release attempt %d/%d for T%d: tool"
                        " never read as seated, re-approaching",
                        attempt + 1, RELEASE_ATTEMPTS, tool)
                    continue

                for _ in range(RELEASE_RETRIES):
                    try:
                        self._run(self.release_macro)
                        break
                    except self.printer.command_error:
                        logging.info(
                            "ff_toolchange: MOTOR_RELEASE endstop not"
                            " triggered for T%d, re-issuing", tool)
                else:
                    continue

                break

            else:
                # The app picks the message text by which sensor disagrees
                # (E0146 "Unlock sensor not triggered" vs E0140 "Extruder
                # dock sensor not triggered").
                detail = ("unlock endstop never triggered"
                          if self._in_location(tool)
                          else "tool never read as seated in its dock")
                raise FFToolchangeError(
                    "T%d release failed: %s (firmware error E%04d)"
                    % (tool, detail, ERR_RELEASE_FAILED_BASE + tool))

            # Retreat happens only on success; on failure the app leaves the
            # carriage at the dock (and so do we -- the finally-clause only
            # de-energises and restores limits, it does not move).
            self._run('G1 X%.3f F%d'
                      % (self.x_safe, self.release_retreat_feed))
            self._wait_moves()

            # Verify: tool in its dock AND nothing held.
            # (doReleaseExtruderLatest: inLocation && !grab)
            ok = self._poll_until(
                lambda: self._in_location(tool) and not self._grab_sensor(),
                VERIFY_TIMEOUT)
            if not ok:
                raise FFToolchangeError(
                    "state error after releasing T%d: in_dock=%s"
                    " grab_sensor=%s (firmware error E%04d)"
                    % (tool, self._in_location(tool), self._grab_sensor(),
                       ERR_RELEASE_STATE))

    # ---------------- commands ----------------

    cmd_TOOLCHANGE_help = "Change to tool INDEX=0..3"

    def cmd_TOOLCHANGE(self, gcmd):
        self._toolchange(gcmd, gcmd.get_int('INDEX'))

    def _toolchange(self, gcmd, tool):
        if tool < 0 or tool >= EXTRUDER_COUNT:
            raise gcmd.error("TOOLCHANGE: INDEX must be 0..%d, got %d"
                             % (EXTRUDER_COUNT - 1, tool))
        try:
            self._wait_moves()
            self._ensure_homed()
            # Strict derivation here: acting on a stale or ambiguous hint
            # would mean releasing the wrong tool -- moving to another tool's
            # dock and dropping the one we are actually carrying into it.
            current, _ = self._derive_current_tool()
            if current != tool:
                if current >= 0:
                    self._release(current)
                # _grab activates the extruder and applies the tool offsets,
                # as the app does inside doGrabExtruderLatest.
                self._grab(tool)
            else:
                # Same tool re-selected: still re-activate and re-apply, so
                # the first Tn after a RESTART (which wiped the gcode
                # offsets) does not leave the mounted tool offset-less. Both
                # calls are idempotent.
                self._run('ACTIVATE_EXTRUDER EXTRUDER=%s'
                          % self._extruder_name(tool))
                self._apply_tool_diff_offsets(tool)
            # Keep the fork's channel state coherent: bare M104/M109 get
            # " T<channel>" appended and SET_PRESSURE_ADVANCE is rewritten to
            # pa_value_t<channel> (virtual_sdcard.py:543 / :479).
            self._run('SDCARD_SET_CHANNEL CHANNEL=%d' % tool)
        except FFToolchangeError as e:
            raise gcmd.error(str(e))
        except self.printer.command_error:
            # A raw Klipper error (move out of range, shutdown, macro fault)
            # escaped the sequence. The finally-clauses restored accel,
            # motor, and modal state, but the gcode X/Y offsets may still be
            # zeroed and no tool offsets applied -- tell the operator before
            # they resume anything.
            self.gcode.respond_info(
                "ff_toolchange: toolchange aborted mid-sequence; gcode"
                " offsets may be zeroed. Run TOOLCHANGE_STATUS, then T<n>"
                " again before resuming a print.")
            raise

    def _gcode_z_offset(self):
        gm = self.printer.lookup_object('gcode_move')
        return gm.get_status(self.reactor.monotonic())['homing_origin'].z

    def _apply_tool_diff_offsets(self, tool):
        """Apply this tool's RELATIVE offsets after a successful grab.
        Port of CommMgr::setGrabGcodeOffsetMgr(tool, onlyZ=false).

        These are small tool-to-tool DIFFERENCES (fractions of a mm), not
        absolute positions: off_x/off_y/off_z are each tool's calibration
        value minus the base tool's (see _derive_offsets). The big absolute
        print offset (~+3.2 mm, the raw-eddy-frame-to-bed-frame conversion)
        is NOT set here -- it is set once per print by
        TOOLCHANGE_SET_PRINT_OFFSET and *carried* through every toolchange
        by the babystep recovery below.

        Which base? The app measures its diffs against the print's FIRST
        tool (setBaseExtruder from serialPrint / compareExtruderFromMf);
        we use the fixed offset_base (T0 by default). The choice cancels:

            new Z = off_z[new] + (old Z - off_z[old])
                  = zoff[new] + (t_new_z - t_base_z)
                    + [t_old_z - z_station + job terms + zoff[old]]
                    - [zoff[old] + (t_old_z - t_base_z)]
                  = t_new_z - z_station + job terms + zoff[new]

        t_base_z drops out, so after a print-start on ANY initial tool
        (T0..T3) every grab lands on that tool's own absolute gap. E.g. a
        T3-first job: base 3.258 set by the print-offset command, change to
        T0 -> 0.018 diff removed -> 3.240, back to T3 -> 3.258 again.

        The app sends two commands, different move speeds, 3-decimal
        formatting (BaseFunction::float_to_string(v, 3)):

            SET_GCODE_OFFSET X=<x> Y=<y> MOVE=1 MOVE_SPEED=100
            SET_GCODE_OFFSET Z=<z> MOVE=1 MOVE_SPEED=40

        Both real toolchange paths (changeExtruderChannel @0x7979b8 and
        serialPrint @0x79d2c8) pass true for the argument that gates this
        call, so it happens on every change -- it is not optional.

        The Z carry: the app adds CommMgr+0x130 (set by setZOffsetWhenPrint)
        to the tool diff on every grab. During a print that member holds the
        ABSOLUTE print-start offset plus any live Z tuning from the UI --
        not just a babystep. Klipper folds all of that into the one gcode Z
        offset, so we recover the aggregate as (current offset - the tool
        term we last applied); after TOOLCHANGE_SET_PRINT_OFFSET this is
        exactly m_zOffset, and repeated toolchanges neither lose nor double
        it. Outside a print the recovered aggregate is ~0 and this reduces
        to plain tool diffs in the raw frame, which is what the stock app's
        calibration flows expect."""
        babystep = self._gcode_z_offset() - self._z_tool_term
        z_term = self.off_z[tool]
        self._run('SET_GCODE_OFFSET X=%.3f Y=%.3f MOVE=1 MOVE_SPEED=100'
                  % (self.off_x[tool], self.off_y[tool]))
        self._run('SET_GCODE_OFFSET Z=%.3f MOVE=1 MOVE_SPEED=40'
                  % (z_term + babystep))
        self._z_tool_term = z_term

    cmd_TOOLCHANGE_SET_PRINT_OFFSET_help = (
        "Apply the app's absolute print-start Z offset "
        "(NOZZLE=<degC> [BED=<degC>] [LAYER=<mm>] [TOOL=<0..3>])")

    def cmd_TOOLCHANGE_SET_PRINT_OFFSET(self, gcmd):
        """Absolute print-start Z offset, ported from BuildPage::startPrint
        @0x9fc148 (eddy G28 Z leaves the nozzle several mm below the nominal
        coordinate; the app fixes that with one SET_GCODE_OFFSET before M24):

            Z = t<tool>_offset_z - z_station_pos    (both extruder.json)
              + (nozzle_temp - 120) * tempOffset    (test.json)
              + 0.08  if bed_temp >= 100
              - 0.06  if 0 < trunc(layer*100) <= 10
              + zoffset.json[tool]                  (user's UI Z-tune)

        Magic constants, all read from the binary's startPrint body:
          120     nozzle reference temp, immediate `addiu -0x78` @0x9fc5e0
          0.08    hot-bed term, float @0xedc9b0; bed threshold 100 is the
                  `slti 0x64` @0x9fc628
          -0.06   thin-layer term, float @0xedc9b4; layer*100 uses float
                  100.0 @0xedc950, cutoff 10 is the `slti 0xb` @0x9fc6c8
        The JSON-sourced factors: tempOffset (testConfig+0xc, 0.00045 here),
        t*_offset_z / z_station_pos = nozzle-touch vs eddy-touch calibration
        against the fixed under-bed sensor. Derivation: OKF/62.

        _z_tool_term is deliberately NOT updated -- the next _apply_tool_diff_offsets
        recovers this base as "babystep", as the app re-adds m_zOffset on
        every grab. END/CANCEL must reset with SET_GCODE_OFFSET Z=0 MOVE=1
        (app exit block @0x7a25f0)."""
        nozzle = gcmd.get_float('NOZZLE')
        bed = gcmd.get_float('BED', 0.)
        layer = gcmd.get_float('LAYER', 0.)
        tool = gcmd.get_int('TOOL', -1, minval=-1, maxval=EXTRUDER_COUNT - 1)
        if tool < 0:
            current, _why = self._current_tool_or_none()
            tool = current if current is not None and current >= 0 else 0

        tools = self.fw.tool_offsets()
        z_station = self.fw.z_station_pos()
        temp_coeff = self.fw.temp_offset()
        if tools is None or z_station is None or temp_coeff is None:
            raise gcmd.error(
                "TOOLCHANGE_SET_PRINT_OFFSET: t*_offset_z / z_station_pos /"
                " tempOffset unavailable from firmware JSON (%s) -- cannot"
                " compute the print Z offset. Without it the eddy-homed Z is"
                " several mm too low; NOT printing is the safe choice."
                % self.fw_dir)
        zoff = self.fw.offset_z() or [0.0] * EXTRUDER_COUNT
        z = tools[tool][2] - z_station + (nozzle - 120.0) * temp_coeff
        if bed >= 100.0:
            z += 0.08
        int_layer = int(layer * 100.0)
        if 0 < int_layer <= 10:
            z += -0.06
        z += zoff[tool]
        gcmd.respond_info(
            "print Z offset for T%d: %.3f (gap %.3f, temp %+.3f,"
            " bed %+.2f, layer %+.2f, user %+.3f)"
            % (tool, z, tools[tool][2] - z_station,
               (nozzle - 120.0) * temp_coeff,
               0.08 if bed >= 100.0 else 0.0,
               -0.06 if 0 < int_layer <= 10 else 0.0, zoff[tool]))
        self._run('SET_GCODE_OFFSET X=%.3f Y=%.3f Z=%.3f'
                  ' MOVE=1 MOVE_SPEED=100'
                  % (self.off_x[tool], self.off_y[tool], z))

    cmd_TOOLCHANGE_STATUS_help = "Report toolchanger sensor state"

    def cmd_TOOLCHANGE_STATUS(self, gcmd):
        self._wait_moves()
        tool, why = self._current_tool_or_none()
        if tool is None:
            lines = ["current_tool=UNKNOWN", "  ! %s" % why]
        else:
            lines = ["current_tool=%d  (%s)" % (tool, why)]
        lines.append("  (derived from the dock sensors; nothing is stored)")
        for i, n in enumerate(self.dock_sensors):
            try:
                lines.append("  T%d in dock (%s): %s"
                             % (i, n, self._sensor(n)))
            except FFToolchangeError as e:
                lines.append("  T%d (%s): %s" % (i, n, e))
        for n in self.grab_sensors:
            try:
                lines.append("  grab (%s): %s" % (n, self._sensor(n)))
            except FFToolchangeError as e:
                lines.append("  grab (%s): %s" % (n, e))

        lines.append("firmware config: %s" % self.fw_dir)
        for msg in self.fw.errors:
            lines.append("  ! %s" % msg)

        def series_line(option, values):
            lines.append("  %-14s[%s] (%s)"
                         % (option, ", ".join("%.4f" % v for v in values),
                            self.sources.get(option)))

        series_line('dock_x', self.dock_x)
        series_line('dock_y', self.dock_y)
        series_line('offset_z', self.off_z)
        series_line('offset_x', self.off_x)
        series_line('offset_y', self.off_y)
        lines.append("  offset_base   T%d" % self.offset_base)
        lines.append("  x_correction  %.4f (%s)"
                     % (self.x_correction, self.sources.get('x_correction')))
        lines.append("  fast_feed     %d (%s)"
                     % (self.fast_feed, self.sources.get('fast_feed')))
        lines.append("  slow_feed     %d (%s)"
                     % (self.slow_feed, self.sources.get('slow_feed')))
        lines.append("  release_slow_feed %d (%s)"
                     % (self.release_slow_feed,
                        self.sources.get('release_slow_feed')))

        # firmwareExe keeps its own active-tool index (extruderConfig()+0x5c,
        # persisted as now_extruder). We do not write it -- the app holds the
        # struct in memory and rewrites the whole file, so our write would be
        # clobbered. Surfacing a disagreement is the useful part.
        now = self.fw.now_extruder()
        if now is not None:
            # Informational only. The app resets its index to -1 on every
            # home, so the two legitimately differ much of the time.
            flag = "" if now == tool else "   (differs from ours)"
            lines.append("  now_extruder  %d (firmwareExe's own index)%s"
                         % (now, flag))
        gcmd.respond_info("\n".join(lines))

    cmd_TOOLCHANGE_PARK_help = "Dock whatever tool is currently mounted"

    def cmd_TOOLCHANGE_PARK(self, gcmd):
        try:
            self._wait_moves()
            current, why = self._derive_current_tool()
        except FFToolchangeError as e:
            raise gcmd.error(str(e))
        if current < 0:
            gcmd.respond_info("no tool mounted (%s)" % why)
            return
        try:
            self._ensure_homed()
            self._release(current)
        except FFToolchangeError as e:
            raise gcmd.error(str(e))

    cmd_TOOLCHANGE_RELOAD_help = ("Re-read firmwareExe's per-unit JSON config "
                                  "(dock coordinates, feeds, Z offsets)")

    def cmd_TOOLCHANGE_RELOAD(self, gcmd):
        """Pick up recalibration done from the touchscreen without a restart.

        Options explicitly set in printer.cfg still win -- reloading cannot
        silently override a deliberate local override."""
        self.fw.load()
        changed = []

        def adopt(option, attr, fw_value, fmt):
            if self.sources.get(option) == 'printer.cfg' or fw_value is None:
                return
            if getattr(self, attr) != fw_value:
                changed.append("%s: %s -> %s" % (option, fmt(getattr(self, attr)),
                                                 fmt(fw_value)))
                setattr(self, attr, fw_value)
                self.sources[option] = 'firmware'

        def fmt_series(v):
            return "[%s]" % ", ".join("%.4f" % x for x in v)

        def fmt_num(v):
            return "%.4f" % v

        fx, fy, fz = self._derive_offsets(self.offset_base)
        adopt('offset_x', 'off_x', fx, fmt_series)
        adopt('offset_y', 'off_y', fy, fmt_series)
        adopt('offset_z', 'off_z', fz, fmt_series)
        adopt('dock_x', 'dock_x', self.fw.dock_x(), fmt_series)
        adopt('dock_y', 'dock_y', self.fw.dock_y(), fmt_series)
        adopt('x_correction', 'x_correction', self.fw.x_correction(), fmt_num)
        ff, sf = self.fw.fast_feed(), self.fw.slow_feed()
        adopt('fast_feed', 'fast_feed', None if ff is None else int(ff),
              lambda v: "%d" % v)
        adopt('slow_feed', 'slow_feed', None if sf is None else int(sf),
              lambda v: "%d" % v)
        rsf = self.fw.slow_feed_release()
        adopt('release_slow_feed', 'release_slow_feed',
              None if rsf is None else int(rsf), lambda v: "%d" % v)

        out = ["reloaded %s" % self.fw_dir]
        out += ["  ! %s" % m for m in self.fw.errors]
        out += ["  %s" % c for c in changed] or ["  no changes"]
        gcmd.respond_info("\n".join(out))

    def get_status(self, eventtime):
        tool, why = self._current_tool_or_none(eventtime)
        return {'current_tool': -1 if tool is None else tool,
                'state_ok': tool is not None,
                'state_reason': why}


def load_config(config):
    return FFToolchange(config)
