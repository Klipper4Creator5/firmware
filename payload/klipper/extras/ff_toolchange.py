# Native toolchange for the FlashForge Creator 5 Pro.
#
# A faithful port of firmwareExe's own sequences, recovered from the binary:
#   CommMgr::doGrabExtruderLatest    @ 0x7a8190
#   CommMgr::doReleaseExtruderLatest @ 0x7aa394
# See docs/notes/30-toolchange.md.
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
# Install: copy ff_tool.py and ff_toolchange.py to
# /usr/prog/klipper/klippy/extras/, then see config/ff-toolchange.cfg.
#
# Klipper calls Tn only for lines that reach the gcode engine. We ship upstream
# virtual_sdcard, which passes tool lines straight through, so a bare "Tn" from
# any slicer lands here -- no marker comment needed.

import contextlib
import logging

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

# Firmware error codes. Per-tool families report E<base + tool>; both grab
# and release map through the LANG_SRC table built at 0x689838.
ERR_NOT_IN_DOCK_BASE = 127      # E0127+t  tool not detected in its dock (grab)
ERR_GRAB_VERIFY_BASE = 51       # E0051+t  pickup could not be verified
ERR_ALREADY_IN_DOCK_BASE = 131  # E0131+t  release precheck: dock not empty
ERR_RELEASE_FAILED_BASE = 135   # E0135+t  unlock endstop never triggered
ERR_RELEASE_STATE = 144         # E0144    state error after release verify


# ---------------------------------------------------------------------------
# Where the numbers come from
#
# Everything per-unit lives in Klipper's own config:
#   [ff_tool <n>]   dock_x/dock_y <- FF_IMPORT_FIRMWARE_CONFIG via SAVE_CONFIG
#                   z_adjust      <- TOOL_Z_ADJUST          via SAVE_CONFIG
#                   nozzle_x/y/z  <- TOOL_OFFSET_CALIBRATE via SAVE_CONFIG
#   [ff_tool_offset] station_x/y/z <- STATION_CALIBRATE  via SAVE_CONFIG
#   [ff_toolchange]  feeds, x_correction, temp_offset, staging positions
# firmwareExe's JSON (extruder.json / test.json / zoffset.json) is no longer
# read at runtime; ff_legacy.py's FF_IMPORT_FIRMWARE_CONFIG copies the
# factory numbers into the layout above once.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# klipper-toolchanger-shaped status surface
#
# UIs with native tool-changer support (HelixScreen, anything written for
# viesturz/klipper-toolchanger) discover a toolchanger by object NAME in
# objects/list: `toolchanger` plus one `tool <name>` per tool. We register
# those names as read-only views over this module and the [ff_tool n]
# sections, and provide the commands such UIs send (SELECT_TOOL,
# UNSELECT_TOOL, INITIALIZE_TOOLCHANGER, ASSIGN_TOOL). Always on: nothing else
# on this machine could own those names.
#
# HelixScreen subscribes (src/api/moonraker_discovery_sequence.cpp):
#   toolchanger : status (ready|changing|error|uninitialized), tool_number,
#                 tool_numbers[, tool_names, tool]
#   tool T<n>   : active, mounted, extruder, fan, gcode_x/y/z_offset,
#                 detect_state (from this tool's on-carriage grab sensor)
# ---------------------------------------------------------------------------

class _ToolchangerView:
    def __init__(self, tc):
        self.tc = tc

    def get_status(self, eventtime):
        st = self.tc.get_status(eventtime)
        cur = st['current_tool']
        if self.tc.changing:
            status = 'changing'
        elif not st['state_ok']:
            status = 'error'
        else:
            status = 'ready'
        # Upstream separates the COMMANDED tool (tool/tool_number) from the
        # one the hardware reports (detected_tool/detected_tool_number). We
        # keep no commanded state: every answer here is derived from the dock
        # and grab sensors, so the two are the same value by construction.
        # They are reported separately anyway, because a UI that only reads
        # detected_* must still see a tool.
        name = 'T%d' % cur if cur >= 0 else None
        return {'name': 'toolchanger',
                'status': status,
                'tool_number': cur,
                'tool_numbers': list(range(EXTRUDER_COUNT)),
                'tool_names': ['T%d' % i for i in range(EXTRUDER_COUNT)],
                'tool': name,
                'detected_tool': name,
                'detected_tool_number': cur,
                'has_detection': True,
                'state_reason': st['state_reason'],
                'print_offset_ready': st['print_offset_ready']}


class _ToolView:
    def __init__(self, tc, index):
        self.tc = tc
        self.index = index

    def get_status(self, eventtime):
        tc = self.tc
        cur = tc.get_status(eventtime)['current_tool']
        t = tc.tools[self.index]
        # klipper-toolchanger's detect_state: is THIS tool seen on the
        # carriage -- our per-tool grab sensor. 'unavailable' if unreadable.
        # 'mounted' is upstream's spelling of present (DETECT_PRESENT).
        try:
            detect = ('mounted' if tc._sensor(tc.grab_sensors[self.index],
                                              eventtime) else 'absent')
        except (FFToolchangeError, IndexError):
            detect = 'unavailable'
        return {'tool_number': self.index,
                'name': 'T%d' % self.index,
                'toolchanger': 'toolchanger',
                'active': cur == self.index,
                'mounted': cur == self.index,
                'detect_state': detect,
                'extruder': t.extruder_name,
                # In Klipper the extruder object IS its heater, and this
                # machine has no separate [extruder_stepper] sections, so
                # upstream's third name has nothing to point at.
                'heater': t.extruder_name,
                'extruder_stepper': None,
                'fan': tc.part_fan,
                # the differences actually applied on a grab
                'gcode_x_offset': tc.off_x[self.index],
                'gcode_y_offset': tc.off_y[self.index],
                'gcode_z_offset': tc.off_z[self.index],
                'calibrated': t.calibrated()}


class FFToolchangeError(Exception):
    """A toolchange step failed or the sensors report an unusable state."""


class FFToolchange:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')
        self.name = config.get_name()

        # Per-tool sections. load_object() resolves them regardless of the
        # order they appear in printer.cfg.
        self.tools = []
        for i in range(EXTRUDER_COUNT):
            try:
                self.tools.append(
                    self.printer.load_object(config, 'ff_tool %d' % i))
            except Exception:
                raise config.error(
                    "%s: section [ff_tool %d] is required (an empty"
                    " section is enough; FF_IMPORT_FIRMWARE_CONFIG fills"
                    " in dock and nozzle data)" % (self.name, i))
        # testConfig()+8 grabOffset in the app.
        self.x_correction = config.getfloat('x_correction', 0.0)
        # degC-to-mm thermal term of the print-start Z offset
        # ((nozzle_temp - 120) * temp_offset); testConfig()+0xc in the app.
        self.temp_offset = config.getfloat('temp_offset', 0.00045)

        # Per-tool G-code offsets -- differences against a base tool, exactly
        # as CommMgr::setGrabGcodeOffsetMgr computes them. See _derive_offsets
        # and docs/notes/40-offsets.md.
        self.offset_base = config.getint('offset_base', 0,
                                         minval=0, maxval=EXTRUDER_COUNT - 1)
        self.off_x = self.off_y = self.off_z = [0.0] * EXTRUDER_COUNT
        self.refresh_offsets()
        # True while a T<n>/TOOLCHANGE sequence is running (reported as
        # toolchanger.status = 'changing').
        self.changing = False
        # Reported as every tool's `fan`: the part-cooling fan is shared on
        # this machine (fanM106 via M106 P1); heat_fan / heat_fan1..3 are the
        # hotend fans.
        self.part_fan = config.get('part_fan', 'fan_generic fanM106')
        for oname, view in [('toolchanger', _ToolchangerView(self))] + [
                ('tool T%d' % i, _ToolView(self, i))
                for i in range(EXTRUDER_COUNT)]:
            if self.printer.lookup_object(oname, None) is not None:
                raise config.error(
                    "%s: Klipper object '%s' already exists (real"
                    " klipper-toolchanger installed?)" % (self.name, oname))
            self.printer.add_object(oname, view)
        # The tool-derived part of the Z offset we last applied. The remainder
        # of Klipper's gcode Z offset is the user's babystep, which the app
        # keeps separately at CommMgr+0x130 and re-adds on every change so a
        # toolchange does not discard it. Reset on restart, as the app's is.
        self._z_tool_term = 0.0

        # Staging positions. These are code constants in the app, not config.
        self.x_safe = config.getfloat('x_safe', 250.0)
        self.x_approach = config.getfloat('x_approach', 280.0)
        self.grab_pullback = config.getfloat('grab_pullback', 20.0)

        # Feeds (mm/min). The app reads grabSpeed/grabSpeedSlow (mm/s) from
        # test.json and multiplies by 60 -- 500/90 on this unit, i.e.
        # 30000/5400 -- falling back to 24000/6000 (5400 on release) when the
        # stored value is <= 0. Defaults here are the factory numbers.
        self.fast_feed = config.getint('fast_feed', 30000, minval=1)
        self.slow_feed = config.getint('slow_feed', 5400, minval=1)
        self.release_slow_feed = config.getint('release_slow_feed', 5400,
                                               minval=1)
        self.grab_retreat_feed = config.getint('grab_retreat_feed', 1500)
        self.release_retreat_feed = config.getint('release_retreat_feed', 4800)
        self.accel_move = config.getint('accel_move', 8000)
        # Post-sequence accel. The app hardcodes 20000; unset, we restore the
        # limit that was live when the sequence started (a user with a lower
        # [printer] max_accel must not come out of a toolchange faster).
        self.accel_restore = config.getint('accel_restore', None)

        # klipper-toolchanger's RESTORE_AXIS. Empty means restore nothing,
        # which is what this machine did before the parameter existed -- a
        # stock file's own start block places the toolhead itself, and moving
        # it again behind the file's back would be a surprise. Set it here to
        # give T<n> and a bare SELECT_TOOL a default.
        self.restore_axis = self._parse_axes(
            config.get('restore_axis', ''), config.error, 'restore_axis')
        self.restore_feed = config.getint('restore_feed', 9000, minval=1)

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

        # Runout / clog sensors. firmwareExe (setFilamentWheelManager
        # @0x79b060) keeps only the MOUNTED tool's filament_motion_sensor
        # enabled -- all four off, then RESET + ENABLE=1 for the current
        # channel -- and pauses on the mounted channel's switch sensor from
        # its print-engine loop (serialPrint @0x7a0d4c). Here both kinds are
        # armed for the mounted tool on every grab and disarmed on release;
        # what a runout DOES is decided by the sensors' runout_gcode
        # (config/ff-runout.cfg: _FF_RUNOUT). Names are <prefix><tool>;
        # an empty prefix, or no section with that prefix at all, turns
        # that kind off.
        self.runout_switch_prefix = config.get('runout_switch_prefix',
                                               'fd_ex').strip()
        self.runout_motion_prefix = config.get('runout_motion_prefix',
                                               'fm_ex').strip()
        self.runout_switch = []     # full object names, resolved at connect
        self.runout_motion = []
        self.armed_tool = -1

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
            'TOOLCHANGE_SET_PRINT_OFFSET', self.cmd_TOOLCHANGE_SET_PRINT_OFFSET,
            desc=self.cmd_TOOLCHANGE_SET_PRINT_OFFSET_help)
        self.gcode.register_command(
            'TOOL_Z_ADJUST', self.cmd_TOOL_Z_ADJUST,
            desc=self.cmd_TOOL_Z_ADJUST_help)
        # klipper-toolchanger command names
        self.gcode.register_command(
            'SELECT_TOOL', self.cmd_SELECT_TOOL, desc=self.cmd_SELECT_TOOL_help)
        self.gcode.register_command(
            'UNSELECT_TOOL', self.cmd_UNSELECT_TOOL,
            desc=self.cmd_UNSELECT_TOOL_help)
        self.gcode.register_command(
            'INITIALIZE_TOOLCHANGER', self.cmd_INITIALIZE_TOOLCHANGER,
            desc=self.cmd_INITIALIZE_TOOLCHANGER_help)
        self.gcode.register_command(
            'ASSIGN_TOOL', self.cmd_ASSIGN_TOOL, desc=self.cmd_ASSIGN_TOOL_help)
        self.gcode.register_command(
            'SET_TOOL_TEMPERATURE', self.cmd_SET_TOOL_TEMPERATURE,
            desc=self.cmd_SET_TOOL_TEMPERATURE_help)
        self.gcode.register_command(
            'VERIFY_TOOL_DETECTED', self.cmd_VERIFY_TOOL_DETECTED,
            desc=self.cmd_VERIFY_TOOL_DETECTED_help)
        self.gcode.register_command(
            'SELECT_TOOL_ERROR', self.cmd_SELECT_TOOL_ERROR,
            desc=self.cmd_SELECT_TOOL_ERROR_help)
        self.gcode.register_command(
            'FF_RUNOUT_ARM', self.cmd_FF_RUNOUT_ARM,
            desc=self.cmd_FF_RUNOUT_ARM_help)
        self.gcode.register_command(
            'FF_RUNOUT_DISARM', self.cmd_FF_RUNOUT_DISARM,
            desc=self.cmd_FF_RUNOUT_DISARM_help)

        self.printer.register_event_handler('klippy:connect',
                                            self._handle_connect)
        self.printer.register_event_handler('klippy:ready',
                                            self._handle_ready)

    def _derive_offsets(self, base):
        """Per-tool G-code offsets.

            X = nozzle_x[tool] - nozzle_x[base]
            Y = nozzle_y[tool] - nozzle_y[base]
            Z = z_adjust[tool] + (nozzle_z[tool] - station_z)

        X/Y are DIFFERENCES against a base tool (T0 by default), as
        CommMgr::setGrabGcodeOffsetMgr @0x77f1dc computes them. Z is
        ABSOLUTE: nozzle_z - station_z is this tool's nozzle-to-eddy-trigger
        gap (~3.2 mm), the raw-eddy-frame-to-bed-frame conversion the app
        only applies at print start (setZOffsetWhenPrint). Applying it on
        every grab instead means Z=0 is the bed plane whenever a tool is
        mounted, so a manual move after T<n> cannot drive the nozzle into
        the plate. The print-only terms (thermal, bed, thin layer) are
        added by TOOLCHANGE_SET_PRINT_OFFSET on top.

        nozzle_* are the station-bore centre measured with each tool's
        nozzle ([ff_tool n], written by TOOL_OFFSET_CALIBRATE); z_adjust is
        the user's per-tool Z tune (the app's zoffset.json).

        Without station_z (STATION_CALIBRATE) Z falls back to the app's
        relative form, nozzle_z[tool] - nozzle_z[base]. A tool without a
        calibration contributes no MEASURED offset -- X and Y are zero, and Z
        is that tool's z_adjust, which is not zero if one was ever set. Such
        tools are listed by TOOLCHANGE_STATUS / warned about at ready. If the BASE tool is
        uncalibrated X/Y are zero for every tool, since nothing can be
        measured against it.
        """
        tools = self.tools
        z_station = self._station_z()
        base_ok = tools[base].calibrated()
        bx, by, bz = tools[base].nozzle if base_ok else (0.0, 0.0, 0.0)
        xs, ys, zs = [], [], []
        for t in tools:
            if t.calibrated() and base_ok:
                xs.append(t.nozzle[0] - bx)
                ys.append(t.nozzle[1] - by)
            else:
                xs.append(0.0)
                ys.append(0.0)
            if t.calibrated() and z_station is not None:
                zs.append(t.z_adjust + (t.nozzle[2] - z_station))
            elif t.calibrated() and base_ok:
                zs.append(t.z_adjust + (t.nozzle[2] - bz))
            else:
                zs.append(t.z_adjust)
        return xs, ys, zs

    def refresh_offsets(self, gcmd=None):
        """Re-derive after a calibration changed an [ff_tool] live."""
        fx, fy, fz = self._derive_offsets(self.offset_base)
        changed = (fx, fy, fz) != (self.off_x, self.off_y, self.off_z)
        self.off_x, self.off_y, self.off_z = fx, fy, fz
        if gcmd is not None:
            gcmd.respond_info("ff_toolchange: offsets %s"
                              % ("updated" if changed else "unchanged"))
        return changed

    def uncalibrated_tools(self):
        return [t.index for t in self.tools if not t.calibrated()]

    def _station_z(self):
        """station_z from [ff_tool_offset] (STATION_CALIBRATE), or None."""
        st = self.printer.lookup_object('ff_tool_offset', None)
        if st is None or st.station is None:
            return None
        return st.station[2]

    # ---------------- plumbing ----------------

    def _handle_connect(self):
        """Validate every name we will later look up, all at once.

        A misspelled button, extruder or macro name would otherwise only
        surface mid-toolchange, with the carriage already at a dock."""
        # [ff_tool_offset] may be included after this section, so station_z
        # was not visible to the refresh_offsets() in __init__ -- re-derive
        # now that every object exists, or Z would stay in the relative form.
        self.refresh_offsets()
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

        self.runout_switch = self._resolve_runout_sensors(
            'filament_switch_sensor', self.runout_switch_prefix, missing)
        self.runout_motion = self._resolve_runout_sensors(
            'filament_motion_sensor', self.runout_motion_prefix, missing)

        if missing:
            raise self.printer.config_error(
                "%s: configured objects not found: %s"
                % (self.name, ", ".join(missing)))

    def _resolve_runout_sensors(self, module, prefix, missing):
        """[] when the kind is off (empty prefix / no such sections);
        all four names when complete; a config error when only some exist."""
        if not prefix:
            return []
        names = ['%s %s%d' % (module, prefix, i)
                 for i in range(EXTRUDER_COUNT)]
        found = [n for n in names
                 if self.printer.lookup_object(n, None) is not None]
        if not found:
            logging.info("%s: no [%s %s*] sections -- runout arming off",
                         self.name, module, prefix)
            return []
        missing.extend(n for n in names if n not in found)
        return names

    def _handle_ready(self):
        # Mirror the sensors to whatever is on the carriage after a
        # restart (the app re-arms at print start only; arming outside a
        # print is harmless -- _FF_RUNOUT ignores it unless printing).
        tool, _why = self._current_tool_or_none()
        if tool is None or tool < 0:
            self._disarm_runout()
        else:
            # No RESET here: the motion sensors' own klippy:ready handler
            # (which may run after ours) already starts them fresh.
            self._arm_runout(tool, reset=False)
        missing = self.uncalibrated_tools()
        if missing:
            self.gcode.respond_info(
                "ff_toolchange: WARNING: no nozzle calibration for %s --"
                " those tools get ZERO X/Y and only their z_adjust in Z."
                " Run"
                " TOOL_OFFSET_CALIBRATE (or FF_IMPORT_FIRMWARE_CONFIG once)"
                " and SAVE_CONFIG." % ", ".join("T%d" % i for i in missing))

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

    # ---------------- runout / clog sensor arming ----------------

    def _set_sensor_enabled(self, objname, enable):
        # Both sensor kinds keep their flag in RunoutHelper.sensor_enabled
        # (filament_switch_sensor.py); set it directly so this also works
        # from klippy:ready, with the gcode command as fallback.
        obj = self.printer.lookup_object(objname, None)
        helper = getattr(obj, 'runout_helper', None)
        if helper is not None and hasattr(helper, 'sensor_enabled'):
            helper.sensor_enabled = 1 if enable else 0
        elif obj is not None:
            self._run('SET_FILAMENT_SENSOR SENSOR=%s ENABLE=%d'
                      % (objname.split(None, 1)[1], 1 if enable else 0))

    def _reset_motion_sensor(self, objname):
        # The app's RESET_FILAMENT_SENSOR before ENABLE=1: move the runout
        # position ahead of the extruder so a sensor that sat disabled while
        # its extruder moved does not fire the moment it is enabled.
        obj = self.printer.lookup_object(objname, None)
        if obj is not None and hasattr(obj, '_update_filament_runout_pos'):
            obj._update_filament_runout_pos()
        elif obj is not None:
            self._run('RESET_FILAMENT_SENSOR SENSOR=%s'
                      % objname.split(None, 1)[1])

    def _arm_runout(self, tool, reset=True):
        """setFilamentWheelManager(tool, true): every sensor off, then
        only the mounted tool's on (motion sensor reset first)."""
        if tool < 0 or tool >= EXTRUDER_COUNT:
            self._disarm_runout()
            return
        for group in (self.runout_switch, self.runout_motion):
            for i, name in enumerate(group):
                if i != tool:
                    self._set_sensor_enabled(name, False)
        if self.runout_motion:
            if reset:
                self._reset_motion_sensor(self.runout_motion[tool])
            self._set_sensor_enabled(self.runout_motion[tool], True)
        if self.runout_switch:
            self._set_sensor_enabled(self.runout_switch[tool], True)
        self.armed_tool = tool

    def _disarm_runout(self):
        """setFilamentWheelManager(_, false): everything off."""
        for group in (self.runout_switch, self.runout_motion):
            for name in group:
                self._set_sensor_enabled(name, False)
        self.armed_tool = -1

    def _armed_sensors(self):
        if self.armed_tool < 0:
            return []
        return [g[self.armed_tool] for g in (self.runout_switch,
                                             self.runout_motion) if g]

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
        t = self.tools[tool]
        if not t.has_dock():
            raise FFToolchangeError(
                "T%d has no dock position ([ff_tool %d] dock_x/dock_y) --"
                " run FF_IMPORT_FIRMWARE_CONFIG and SAVE_CONFIG" % (tool, tool))
        return t.dock_x + self.x_correction, t.dock_y

    def _extruder_name(self, tool):
        return self.tools[tool].extruder_name

    def _current_max_accel(self):
        toolhead = self.printer.lookup_object('toolhead')
        return toolhead.get_status(self.reactor.monotonic())['max_accel']

    @staticmethod
    def _parse_axes(raw, error, what):
        """'xyz' -> 'XYZ', rejecting anything that is not an axis letter."""
        axes = ''.join(sorted(set(raw.strip().upper())))
        bad = [a for a in axes if a not in 'XYZ']
        if bad:
            raise error("%s: expected letters from XYZ, got '%s'"
                        % (what, raw))
        return axes

    def _restore_axis_arg(self, gcmd):
        return self._parse_axes(gcmd.get('RESTORE_AXIS', self.restore_axis),
                                gcmd.error, 'RESTORE_AXIS')

    def _capture_position(self):
        """The G-code position the change is about to disturb."""
        gm = self.printer.lookup_object('gcode_move')
        return list(gm.get_status()['gcode_position'])

    def _restore_position(self, axes, pos):
        """Put the toolhead back where the change found it.

        A GCODE position is captured and replayed, not a machine one, so it
        is read back through whatever offsets are in force AFTER the change:
        the new tool's nozzle goes where the old tool's nozzle was, which is
        the point of the parameter.

        X/Y first and Z last: descending before the carriage is over the
        target would drag the nozzle across the part.

        Restoring Z after a PARK is the one sharp edge. Parking zeroes the
        tool offsets, so the same G-code Z is a different machine Z -- by
        this tool's nozzle-to-eddy-trigger gap (~3.2 mm). Ask for Z on an
        UNSELECT_TOOL only if you mean it; XY is the safe default.
        """
        if not axes:
            return
        xy = ' '.join('%s%.3f' % (a, pos[i])
                      for i, a in enumerate('XY') if a in axes)
        # The sequence has already put the modal state back; borrow it and
        # return it rather than leaving G90 and the restore feed behind.
        self._run('SAVE_GCODE_STATE NAME=_ff_restore_axis')
        try:
            self._run('G90')
            if xy:
                self._run('G1 %s F%d' % (xy, self.restore_feed))
            if 'Z' in axes:
                self._run('G1 Z%.3f F%d' % (pos[2], self.restore_feed))
        finally:
            self._run('RESTORE_GCODE_STATE NAME=_ff_restore_axis')

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

    def _ensure_homed(self, axes='xyz'):
        """Docking is an X/Y motion only (the docks ride on the gantry), so
        a release needs just 'xy' -- that is what lets the G28 wrapper in
        ff-toolchange.cfg dock a mounted tool before homing Z."""
        toolhead = self.printer.lookup_object('toolhead')
        homed = toolhead.get_status(self.reactor.monotonic())['homed_axes']
        if not all(a in homed for a in axes):
            if not self.auto_home:
                raise FFToolchangeError(
                    "printer is not homed -- run G28 first "
                    "(or set auto_home: True in [ff_toolchange])")
            self._run('G28 ' + ' '.join(axes.upper()))

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
            # Tool is on the carriage and verified: its runout / clog
            # sensors become the live ones (the app does this 3 s later
            # from a thread; here the grab moves are already complete).
            self._arm_runout(tool)

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

        # Sensors off first (changeExtruderChannel @0x79750c disarms before
        # the head swap): nothing the carriage does at the dock may fire a
        # runout.
        self._disarm_runout()

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
        # Resolved here rather than per command, so T<n> and TOOLCHANGE --
        # which is what a file actually issues -- honour RESTORE_AXIS and the
        # [ff_toolchange] restore_axis default the same way SELECT_TOOL does.
        restore_axis = self._restore_axis_arg(gcmd)
        # Captured before anything moves; replayed only if the change
        # succeeded, since a half-finished sequence has no position worth
        # returning to.
        resume = self._capture_position() if restore_axis else None
        self.changing = True
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
                self._arm_runout(tool)
            # No channel to announce. FlashForge's virtual_sdcard tracked one
            # so it could rewrite bare M104/M109 to " T<channel>" and
            # SET_PRESSURE_ADVANCE to pa_value_t<channel>. Upstream does no
            # such rewriting and needs none: both apply to the ACTIVE
            # extruder, which _grab (or the ACTIVATE_EXTRUDER above) has just
            # set to this tool. The stock start block's bare `M104 S<t>` lands
            # on the right hotend for exactly that reason.
            if resume is not None:
                self._restore_position(restore_axis, resume)
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
        finally:
            self.changing = False

    def _gcode_z_offset(self):
        gm = self.printer.lookup_object('gcode_move')
        return gm.get_status(self.reactor.monotonic())['homing_origin'].z

    def _apply_tool_diff_offsets(self, tool):
        """Apply this tool's offsets after a successful grab.
        Port of CommMgr::setGrabGcodeOffsetMgr(tool, onlyZ=false).

        off_x/off_y are small tool-to-tool DIFFERENCES against the base
        tool; off_z is this tool's ABSOLUTE gap to the bed plane (~+3.2 mm,
        see _derive_offsets). Unlike the app, which sets that gap once per
        print (setZOffsetWhenPrint) and carries it across changes, every
        grab establishes it here -- so the only thing carried is whatever
        sits on top of it: TOOLCHANGE_SET_PRINT_OFFSET's job terms and the
        user's live babystep.

            new Z = off_z[new] + (old Z - off_z[old])
                  = [t_new_z - z_station + zoff[new]] + job terms + babystep

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
        against the fixed under-bed sensor. Derivation: docs/notes/40-offsets.md.

        The gap term (nozzle_z - station_z + z_adjust) is already the grab
        offset (off_z, applied by every T<n>); this command re-asserts it and
        adds the job terms, which the next _apply_tool_diff_offsets then
        carries as "babystep" -- the app re-adds m_zOffset on every grab.
        END/CANCEL must reset with SET_GCODE_OFFSET Z=0 MOVE=1 (app exit
        block @0x7a25f0)."""
        nozzle = gcmd.get_float('NOZZLE')
        bed = gcmd.get_float('BED', 0.)
        layer = gcmd.get_float('LAYER', 0.)
        tool = gcmd.get_int('TOOL', -1, minval=-1, maxval=EXTRUDER_COUNT - 1)
        if tool < 0:
            current, _why = self._current_tool_or_none()
            tool = current if current is not None and current >= 0 else 0

        z_station = self._station_z()
        temp_coeff = self.temp_offset
        if not self.tools[tool].calibrated() or z_station is None:
            raise gcmd.error(
                "TOOLCHANGE_SET_PRINT_OFFSET: T%d nozzle_z and/or"
                " [ff_tool_offset] station_z are not calibrated -- cannot"
                " compute the print Z offset. Without it the eddy-homed Z is"
                " several mm too low; NOT printing is the safe choice. Run"
                " STATION_CALIBRATE / TOOL_OFFSET_CALIBRATE (or"
                " FF_IMPORT_FIRMWARE_CONFIG) and SAVE_CONFIG." % tool)
        tools = [t.nozzle or (0.0, 0.0, 0.0) for t in self.tools]
        zoff = [t.z_adjust for t in self.tools]
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
        # off_z[tool] is the gap + z_adjust part of z (station_z and the
        # calibration were checked above); the remainder is the job terms.
        self._z_tool_term = self.off_z[tool]

    cmd_TOOL_Z_ADJUST_help = (
        "Per-tool persistent Z correction: TOOL_Z_ADJUST TOOL=<0..3> "
        "(ADJUST=<+/-mm> | VALUE=<mm>); SAVE_CONFIG to persist")

    def cmd_TOOL_Z_ADJUST(self, gcmd):
        """The per-tool counterpart of SET_GCODE_OFFSET Z_ADJUST.

        Klipper's babystep is one global number; this edits [ff_tool n]
        z_adjust instead, which _apply_tool_diff_offsets adds on every grab of
        that tool only. If the tool is mounted right now the new value is
        applied immediately through the same path (so the live babystep is
        preserved), and the change is staged for SAVE_CONFIG."""
        tool = gcmd.get_int('TOOL', minval=0, maxval=EXTRUDER_COUNT - 1)
        adjust = gcmd.get_float('ADJUST', None)
        value = gcmd.get_float('VALUE', None)
        if (adjust is None) == (value is None):
            raise gcmd.error("TOOL_Z_ADJUST: give exactly one of ADJUST= or"
                             " VALUE=")
        t = self.tools[tool]
        old = t.z_adjust
        new = value if value is not None else old + adjust
        t.set_z_adjust(new)
        self.refresh_offsets()
        applied = ""
        try:
            self._wait_moves()
            current, _why = self._current_tool_or_none()
        except FFToolchangeError:
            current = None
        if current == tool:
            self._apply_tool_diff_offsets(tool)
            applied = ", applied now"
        gcmd.respond_info(
            "T%d z_adjust %.3f -> %.3f%s. The SAVE_CONFIG command will update"
            " the printer config file and restart the printer."
            % (tool, old, new, applied))

    # ---------------- klipper-toolchanger command aliases ----------------

    def _tool_arg(self, gcmd, required=True):
        """klipper-toolchanger accepts T=<number> or TOOL=<name>."""
        t = gcmd.get_int('T', None)
        if t is None:
            name = gcmd.get('TOOL', None)
            if name is not None:
                name = name.strip()
                if name.upper().startswith('T') and name[1:].isdigit():
                    t = int(name[1:])
                else:
                    raise gcmd.error("TOOL must be T0..T%d, got '%s'"
                                     % (EXTRUDER_COUNT - 1, name))
        if t is None:
            if required:
                raise gcmd.error("T=<n> or TOOL=T<n> is required")
            return None
        if not 0 <= t < EXTRUDER_COUNT:
            raise gcmd.error("T must be 0..%d" % (EXTRUDER_COUNT - 1))
        return t

    cmd_SELECT_TOOL_help = ("Select a tool (T=<n> | TOOL=T<n>); same as"
                            " T<n>. RESTORE_AXIS=<xyz> returns the toolhead")

    def cmd_SELECT_TOOL(self, gcmd):
        self._toolchange(gcmd, self._tool_arg(gcmd))

    cmd_UNSELECT_TOOL_help = ("Dock the mounted tool; same as"
                              " TOOLCHANGE_PARK. RESTORE_AXIS=<xyz> returns"
                              " the toolhead")

    def cmd_UNSELECT_TOOL(self, gcmd):
        t = self._tool_arg(gcmd, required=False)
        if t is not None:
            cur, _why = self._current_tool_or_none()
            if cur != t:
                raise gcmd.error("UNSELECT_TOOL: T%d is not the mounted tool"
                                 " (current %s)" % (t, cur))
        self.cmd_TOOLCHANGE_PARK(gcmd)

    cmd_INITIALIZE_TOOLCHANGER_help = (
        "Re-derive toolchanger state from the dock sensors (no motion)")

    def cmd_INITIALIZE_TOOLCHANGER(self, gcmd):
        self._wait_moves()
        cur, why = self._current_tool_or_none()
        if cur is None:
            raise gcmd.error("toolchanger state not derivable: %s" % why)
        gcmd.respond_info("toolchanger ready, tool_number=%d (%s)"
                          % (cur, why))

    cmd_ASSIGN_TOOL_help = "Not supported on this toolchanger"

    def cmd_ASSIGN_TOOL(self, gcmd):
        raise gcmd.error(
            "ASSIGN_TOOL: logical-to-physical tool remapping is not supported"
            " here; remap in the slicer (the fork's"
            " SDCARD_SET_GCODE_EX_USED_BASE table is the future home)")

    cmd_SET_TOOL_TEMPERATURE_help = (
        "Set a tool's hotend target (T=<n> | TOOL=T<n>, default the mounted"
        " tool); TARGET=<temp> [WAIT=1]")

    def cmd_SET_TOOL_TEMPERATURE(self, gcmd):
        """Upstream addresses a tool by name; we address the extruder behind
        it. Naming the tool rather than the extruder is the whole point --
        a UI knows it is heating T2, not that T2 means [extruder2]."""
        tool = self._tool_arg(gcmd, required=False)
        if tool is None:
            tool, why = self._current_tool_or_none()
            if tool is None or tool < 0:
                raise gcmd.error("SET_TOOL_TEMPERATURE: no tool mounted, so"
                                 " T=<n> or TOOL=T<n> is required (%s)" % why)
        target = gcmd.get_float('TARGET', 0.)
        heater = self._extruder_name(tool)
        self._run('SET_HEATER_TEMPERATURE HEATER=%s TARGET=%.1f'
                  % (heater, target))
        # WAIT only waits for heat-UP, like Klipper's own TEMPERATURE_WAIT
        # MINIMUM: there is nothing to wait for on the way down, and a
        # TARGET of 0 would never be reached.
        if gcmd.get_int('WAIT', 0) and target > 0.:
            self._run('TEMPERATURE_WAIT SENSOR=%s MINIMUM=%.1f'
                      % (heater, target))

    cmd_VERIFY_TOOL_DETECTED_help = (
        "Check the sensors agree with the expected tool (T=<n> | TOOL=T<n>,"
        " default: just that the state is readable)")

    def cmd_VERIFY_TOOL_DETECTED(self, gcmd):
        """ASYNC is accepted and ignored. Upstream defers the check into the
        motion queue; ours reads switches after a wait_moves, which costs
        nothing to do inline."""
        gcmd.get_int('ASYNC', 0)
        expect = self._tool_arg(gcmd, required=False)
        self._wait_moves()
        cur, why = self._current_tool_or_none()
        if cur is None:
            raise gcmd.error("VERIFY_TOOL_DETECTED: toolchanger state not"
                             " derivable: %s" % why)
        if expect is not None and cur != expect:
            raise gcmd.error("VERIFY_TOOL_DETECTED: expected T%d, sensors say"
                             " %s (%s)"
                             % (expect,
                                'T%d' % cur if cur >= 0 else 'no tool', why))
        gcmd.respond_info("detected %s (%s)"
                          % ('T%d' % cur if cur >= 0 else 'no tool', why))

    cmd_SELECT_TOOL_ERROR_help = "Abort the running script: a tool change failed"

    def cmd_SELECT_TOOL_ERROR(self, gcmd):
        """Upstream latches the changer into its error state and hands off to
        an on_tool_change_error script. We hold no latch -- status is derived
        from the sensors every time it is asked for -- so the useful half is
        stopping the script that called this."""
        raise gcmd.error(gcmd.get('MESSAGE', 'tool change failed'))

    cmd_FF_RUNOUT_ARM_help = ("Enable the mounted tool's runout/clog sensors"
                              " (and disable the others); TOOL= overrides")

    def cmd_FF_RUNOUT_ARM(self, gcmd):
        tool = gcmd.get_int('TOOL', -1)
        if tool < 0:
            tool, why = self._current_tool_or_none()
            if tool is None or tool < 0:
                raise gcmd.error("FF_RUNOUT_ARM: no tool mounted (%s)" % why)
        elif tool >= EXTRUDER_COUNT:
            raise gcmd.error("FF_RUNOUT_ARM: TOOL must be 0..%d"
                             % (EXTRUDER_COUNT - 1))
        if not (self.runout_switch or self.runout_motion):
            gcmd.respond_info("FF_RUNOUT_ARM: no runout sensors configured")
            return
        self._arm_runout(tool)
        gcmd.respond_info("runout sensors armed for T%d: %s"
                          % (tool, ", ".join(self._armed_sensors())))

    cmd_FF_RUNOUT_DISARM_help = "Disable every runout/clog sensor"

    def cmd_FF_RUNOUT_DISARM(self, gcmd):
        self._disarm_runout()
        gcmd.respond_info("runout sensors disarmed")

    cmd_TOOLCHANGE_STATUS_help = "Report toolchanger sensor state"

    def cmd_TOOLCHANGE_STATUS(self, gcmd):
        self._wait_moves()
        tool, why = self._current_tool_or_none()
        if tool is None:
            lines = ["current_tool=UNKNOWN", "  ! %s" % why]
        else:
            lines = ["current_tool=%d  (%s)" % (tool, why)]
        lines.append("  (derived from the dock sensors; nothing is stored)")
        if self.runout_switch or self.runout_motion:
            lines.append("  runout sensors armed: %s"
                         % (", ".join(self._armed_sensors()) or "none"))
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

        lines.append("geometry ([ff_tool n] / [ff_toolchange]):")
        for t in self.tools:
            if t.calibrated():
                lines.append("  T%d nozzle (%.4f, %.4f, %.4f)  z_adjust %+.3f"
                             % (t.index, t.nozzle[0], t.nozzle[1],
                                t.nozzle[2], t.z_adjust))
            else:
                lines.append("  T%d nozzle NOT CALIBRATED"
                             " (zero X/Y, z_adjust only in Z)"
                             % t.index)
        sz = self._station_z()
        lines.append("  station_z     %s"
                     % ("%.4f" % sz if sz is not None else "NOT CALIBRATED"))

        def series_line(option, values):
            lines.append("  %-14s[%s]"
                         % (option, ", ".join("%.4f" % v for v in values)))

        series_line('dock_x', [t.dock_x if t.has_dock() else float('nan')
                               for t in self.tools])
        series_line('dock_y', [t.dock_y if t.has_dock() else float('nan')
                               for t in self.tools])
        missing = [t.index for t in self.tools if not t.has_dock()]
        if missing:
            lines.append("  ! no dock position for T%s -- run"
                         " FF_IMPORT_FIRMWARE_CONFIG and SAVE_CONFIG"
                         % ", T".join(str(i) for i in missing))
        series_line('offset_z', self.off_z)
        series_line('offset_x', self.off_x)
        series_line('offset_y', self.off_y)
        lines.append("  offset_base   T%d" % self.offset_base)
        lines.append("  x_correction  %.4f" % self.x_correction)
        lines.append("  fast_feed     %d" % self.fast_feed)
        lines.append("  slow_feed     %d" % self.slow_feed)
        lines.append("  release_slow_feed %d" % self.release_slow_feed)
        lines.append("  temp_offset   %.6f" % self.temp_offset)
        gcmd.respond_info("\n".join(lines))

    cmd_TOOLCHANGE_PARK_help = "Dock whatever tool is currently mounted"

    def cmd_TOOLCHANGE_PARK(self, gcmd):
        restore_axis = self._restore_axis_arg(gcmd)
        resume = self._capture_position() if restore_axis else None
        try:
            self._wait_moves()
            current, why = self._derive_current_tool()
        except FFToolchangeError as e:
            raise gcmd.error(str(e))
        if current < 0:
            gcmd.respond_info("no tool mounted (%s)" % why)
            return
        try:
            self._ensure_homed('xy')
            self._release(current)
            if resume is not None:
                self._restore_position(restore_axis, resume)
        except FFToolchangeError as e:
            raise gcmd.error(str(e))

    def print_offset_ready(self, tool=None):
        """Can TOOLCHANGE_SET_PRINT_OFFSET succeed? Needs station_z and
        nozzle_z of the tool (all tools when tool is None)."""
        if self._station_z() is None:
            return False
        if tool is None:
            return not self.uncalibrated_tools()
        return self.tools[tool].calibrated()

    def get_status(self, eventtime):
        tool, why = self._current_tool_or_none(eventtime)
        return {'current_tool': -1 if tool is None else tool,
                'state_ok': tool is not None,
                'state_reason': why,
                'calibrated_tools': [t.index for t in self.tools
                                     if t.calibrated()],
                'station_z': self._station_z(),
                # True when every tool and the station are calibrated, i.e.
                # a print's Z frame can be established for any tool.
                'print_offset_ready': self.print_offset_ready(),
                # Tools currently sitting in their docks (dock switch
                # pressed). A tool is available for a print when it is
                # docked or is the mounted one (_FF_PREFLIGHT).
                'docked_tools': [i for i in range(EXTRUDER_COUNT)
                                 if self._in_location(i, eventtime)],
                # Tool whose runout/clog sensors are enabled (-1 = none)
                # and those sensors' object names.
                'runout_armed': self.armed_tool,
                'runout_sensors': self._armed_sensors()}


def load_config(config):
    return FFToolchange(config)
