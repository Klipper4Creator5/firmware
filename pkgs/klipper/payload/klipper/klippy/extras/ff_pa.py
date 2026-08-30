# Automatic pressure advance for the FlashForge Creator 5 Pro.
#
# A port of the sweep the touchscreen runs inside its pre-print nozzle clean,
# recovered from the firmwareExe binary (MIPS machine code):
#   CommMgr::paTestMgr                        @0x791640  (the whole procedure)
#   CalibrationDialog::testPaTest             @0x82d054  (an inlined 2nd copy)
#   CommMgr::resetTmcPa                       @0x79350c  (the exit block)
# Full walkthrough: docs/notes/51-pa-calibration-recovered.md
#
# Four things about this are not obvious from the code:
#
#   * THE MEASUREMENT IS NOT OURS. Each line is scored by the closed eBoard
#     MCU, which watches 16-bit samples arriving on its second UART from a
#     transducer we have not identified and answers one number. We ship that
#     firmware unchanged, so we get the same verdicts the touchscreen does.
#     [pa_adjust] is the 40-line forwarder that carries the two commands.
#
#   * THE LINES ARE EXTRUDED IN FREE AIR, ~8 mm above the bed, and nothing
#     ever looks at them. They exist only to make a pressure transient at the
#     two 10x flow steps. There is no first layer here and no adhesion to
#     get right -- just about a gram of loose filament on the plate.
#
#   * THE MISSING M400 IS DELIBERATE. pa_action is an immediate MCU command,
#     so ACTION=0 fires while motion is still queued; what bounds it is
#     Klipper throttling G-code input at BUFFER_TIME_HIGH (toolhead.py
#     _check_pause, 2.0 s) against a line that is ~4.94 s long. The eBoard is
#     not handed a tight window -- it is told "a line is coming" and "that was
#     the last one" and finds the event itself. The app hits the same
#     throttle. Do NOT add barriers inside a line to "fix" this; the scorer
#     was tuned against this timing.
#
#   * THIS REPORTS. It does not save the number, does not touch printer.cfg
#     and does not apply anything on a toolchange. The extruder's own
#     pressure advance is put back on exit -- which the app does not do,
#     because it immediately overrides it via SET_PA_ADVANCE and we do not.
#
# A Python extra rather than a macro because PA_GET only respond_info()s its
# value: a gcode_macro cannot read another command's output, and the sweep is
# a retry loop with a sort in it.

import contextlib

EXTRUDER_COUNT = 4

# Constants read from the binary (51-pa-calibration-recovered.md section 3).
# The candidate order is scrambled while the Y ladder is not, so adjacent
# lines on the plate are never adjacent in PA -- a slow drift (nozzle
# temperature, plate tilt) cannot bias a contiguous band.
CANDIDATES = ('0.0100', '0.0200', '0.0150', '0.0350',
              '0.0250', '0.0300', '0.0400')   # @0x791ae0..0x791d70
PASS_VALUE = 9             # @0x792878  bne $v1, 9 -- the ONLY passing verdict
MAX_SWEEPS = 5             # @0x791de8  slti 5
WINNERS = 3                # mean of exactly three; 3.0f @0xdb6a80
Y_START = 50.0             # Y = 50 + 5*i, "%.3f"
Y_STEP = 5.0
X_START = 40.0
# (x, e, feed) per segment, E for the segment ENDING at x. E is a constant
# 0.0567865 mm/mm throughout -- 1.13573/20 == 2.27146/40 -- so only the SPEED
# changes, 18 mm/s against 183 mm/s. The two fast bursts are the only place
# pressure advance can show up.
SEGMENTS = ((60.0, 1.13573, 1080), (100.0, 2.27146, 10980),
            (120.0, 1.13573, 1080), (140.0, 1.13573, 1080),
            (180.0, 2.27146, 10980), (200.0, 1.13573, 1080))
TRAVEL_FEED = 30000
SWEEP_ACCEL = 5000.0       # SET_VELOCITY_LIMIT ACCEL=5000
SWEEP_SCV = 9.0            # SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY=9
ACTION_START = 11          # the firmware tests == 11 for start ...
ACTION_STOP = 0            # ... and treats everything else as stop
ACTION_PC = 666            # the app's "material" code; inert on this eBoard
LINE_Z = 8.0               # RAW eddy frame, == _FF_FILAMENT's purge_z
LINE_Z_FEED = 3000
TMC_PINS = ('enable_pin_tmc_x', 'enable_pin_tmc_y')
FILAMENT_AREA_175 = 2.405  # mm^2, for the cross-section warning


def _parse_segments(raw, error):
    """'x:e:feed, x:e:feed, ...' -> ((x, e, feed), ...)."""
    segments = []
    for chunk in raw.split(','):
        chunk = chunk.strip()
        if not chunk:
            continue
        parts = chunk.split(':')
        if len(parts) != 3:
            raise error("segments: expected 'x:e:feed' triples, got '%s'"
                        % chunk)
        try:
            segments.append((float(parts[0]), float(parts[1]), int(parts[2])))
        except ValueError:
            raise error("segments: '%s' is not 'x:e:feed' with numbers"
                        % chunk)
    if not segments:
        raise error("segments: at least one 'x:e:feed' triple is required")
    return tuple(segments)


class FFPAError(Exception):
    pass


class FFPA:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')
        self.name = config.get_name()

        candidates = config.getlist('candidates', list(CANDIDATES))
        self.candidates = [c.strip() for c in candidates if c.strip()]
        if not self.candidates:
            raise config.error("%s: candidates is empty" % self.name)
        for text in self.candidates:
            try:
                float(text)
            except ValueError:
                raise config.error("%s: candidate '%s' is not a number"
                                   % (self.name, text))
        self.pass_value = config.getint('pass_value', PASS_VALUE)
        self.sweeps = config.getint('sweeps', MAX_SWEEPS, minval=1)
        self.winners = config.getint('winners', WINNERS, minval=1)
        if self.winners > self.sweeps:
            raise config.error(
                "%s: winners (%d) cannot exceed sweeps (%d) -- the run could"
                " never succeed" % (self.name, self.winners, self.sweeps))

        self.x_start = config.getfloat('x_start', X_START)
        raw_segments = config.get('segments', '').strip()
        if raw_segments:
            self.segments = _parse_segments(raw_segments, config.error)
        else:
            self.segments = SEGMENTS
        self.y_start = config.getfloat('y_start', Y_START)
        self.y_step = config.getfloat('y_step', Y_STEP)
        self.travel_feed = config.getint('travel_feed', TRAVEL_FEED, minval=1)
        self.sweep_accel = config.getfloat('sweep_accel', SWEEP_ACCEL,
                                           above=0.)
        self.sweep_scv = config.getfloat('sweep_square_corner_velocity',
                                         SWEEP_SCV, minval=0.)
        # None = follow [gcode_macro _FF_FILAMENT]'s purge_z, so there is one
        # definition of "8 mm above the plate" in the tree.
        self.line_z = config.getfloat('line_z', None)
        self.line_z_feed = config.getint('line_z_feed', LINE_Z_FEED, minval=1)
        self.tmc_pin_names = [n.strip() for n
                              in config.getlist('tmc_pins', list(TMC_PINS))
                              if n.strip()]
        self.action_start = config.getint('action_start', ACTION_START)
        self.action_stop = config.getint('action_stop', ACTION_STOP)
        self.action_pc = config.getint('action_pc', ACTION_PC)
        self.require_discrimination = config.getboolean(
            'require_discrimination', True)
        self.require_filament_sensor = config.getboolean(
            'require_filament_sensor', True)
        self.min_temp_margin = config.getfloat('min_temp_margin', 3.0,
                                               minval=0.)

        self.toolchange = None
        self.pa_adjust = None
        self.tmc_pins = []
        self.dry_run = False
        self.running = False
        self.last = None

        self.gcode.register_command('FF_PA_CALIBRATE',
                                    self.cmd_FF_PA_CALIBRATE,
                                    desc=self.cmd_FF_PA_CALIBRATE_help)
        self.gcode.register_command('FF_PA_PROBE', self.cmd_FF_PA_PROBE,
                                    desc=self.cmd_FF_PA_PROBE_help)
        self.gcode.register_command('FF_PA_STATUS', self.cmd_FF_PA_STATUS,
                                    desc=self.cmd_FF_PA_STATUS_help)
        self.printer.register_event_handler('klippy:connect',
                                            self._handle_connect)

    # ---------------- plumbing ----------------

    def _handle_connect(self):
        """Resolve optional dependencies. Deliberately NOT a config_error for
        a missing [pa_adjust] or [ff_toolchange]: this extra is inert until
        someone types the command, and taking the whole printer down at
        startup over a report-only tool is the wrong trade. A tmc_pins entry
        that does not resolve IS a config error -- that is a typo in our own
        config, not an absent feature."""
        self.toolchange = self.printer.lookup_object('ff_toolchange', None)
        self.pa_adjust = self.printer.lookup_object('pa_adjust', None)
        missing = []
        for pin_name in self.tmc_pin_names:
            pin = self.printer.lookup_object('output_pin %s' % pin_name, None)
            if pin is None:
                missing.append('output_pin %s' % pin_name)
            self.tmc_pins.append((pin_name, pin))
        if missing:
            raise self.printer.config_error(
                "%s: tmc_pins names a section that does not exist: %s"
                % (self.name, ", ".join(missing)))

    def _eboard_cmds(self):
        """[pa_adjust]'s own MCU command wrappers, resolved on FIRST USE.

        Not at klippy:connect: pa_adjust binds these from a
        mcu.register_config_callback, and whether that has run before our
        connect handler depends only on section order in printer.cfg, which
        nothing enforces. First use is unambiguously later.

        We borrow rather than declare our own. Declaring our own would be
        safe -- MCU.lookup_query_command builds a fresh wrapper per call and
        registers no lasting handler (SerialRetryCommand registers per send
        and unregisters after) -- but it would put a second copy of a closed
        MCU's protocol strings in our tree to drift out of sync on a fork
        bump, and it would need a register_config_callback on [mcu eboard],
        making a report-only tool able to block startup on a machine whose
        eBoard is unplugged.

        getattr rather than attribute access so fork drift surfaces as a
        sentence instead of an AttributeError traceback."""
        if self.pa_adjust is None:
            raise FFPAError(
                "[pa_adjust] is not loaded. It is what forwards pa_action /"
                " get_emcu_pa_value to [mcu eboard], and without it there is"
                " no verdict to read -- printer.base.cfg ships it.")
        action = getattr(self.pa_adjust, '_pa_action_cmd', None)
        query = getattr(self.pa_adjust, '_pa_value_get_cmd', None)
        if action is None or query is None:
            raise FFPAError(
                "[pa_adjust] has not bound its eBoard commands -- 'mcu"
                " eboard' never finished its config handshake. Check"
                " klippy.log for the eboard MCU coming up.")
        return action, query

    def _run(self, script):
        if self.dry_run:
            self.gcode.respond_info("  [dry] %s" % script)
            return
        self.gcode.run_script_from_command(script)

    def _wait_moves(self):
        self.printer.lookup_object('toolhead').wait_moves()

    def _toolhead_status(self):
        toolhead = self.printer.lookup_object('toolhead')
        return toolhead, toolhead.get_status(self.reactor.monotonic())

    def _check_homed(self, gcmd):
        _toolhead, status = self._toolhead_status()
        homed = status['homed_axes']
        if not all(axis in homed for axis in 'xyz'):
            raise gcmd.error("%s: home all axes first (homed: '%s')"
                             % (self.name, homed))

    def _resolve_tool(self, gcmd):
        """The mounted tool, or the one TOOL= asks for -- selecting it if it
        is not the one on the carriage. Same shape as
        TOOL_CALIBRATE_TOOL_OFFSET: this measures what is mounted."""
        if self.toolchange is None:
            raise gcmd.error("%s: [ff_toolchange] not loaded -- there is no"
                             " mounted tool to measure." % self.name)
        status = self.toolchange.get_status(self.reactor.monotonic())
        current = status.get('current_tool', -1)
        if not status.get('state_ok'):
            raise gcmd.error(
                "%s: the mounted tool is not known (%s). Fix that before"
                " extruding." % (self.name, status.get('state_reason')))
        tool = gcmd.get_int('TOOL', current, minval=0,
                            maxval=EXTRUDER_COUNT - 1)
        if tool != current:
            self._run('SELECT_TOOL T=%d' % tool)
            self._wait_moves()
        elif current < 0:
            raise gcmd.error(
                "%s: no tool is mounted. SELECT_TOOL T=<0..%d> first, or"
                " pass TOOL=." % (self.name, EXTRUDER_COUNT - 1))
        return tool

    def _extruder(self):
        return self.printer.lookup_object('toolhead').get_extruder()

    def _ensure_extruder(self, tool):
        """Make sure the mounted tool's extruder is the active one.

        [ff_toolchange] activates it on every grab and re-select, so this is
        normally already true -- but we skip SELECT_TOOL when the requested
        tool is the one already mounted, and a bare ACTIVATE_EXTRUDER in
        between would leave us heating and measuring different extruders."""
        tool_view = self.printer.lookup_object('tool T%d' % tool, None)
        if tool_view is None:
            return
        want = tool_view.get_status(self.reactor.monotonic()).get('extruder')
        if want and want != self._extruder().get_name():
            self._run('ACTIVATE_EXTRUDER EXTRUDER=%s' % want)

    def _check_can_extrude(self, gcmd, extruder):
        """Refuse cold up front instead of discovering it mid-line.

        Without this the first 'G1 ... E' raises "Extrude below minimum
        temp" from extruder.check_move -- AFTER ACTION=11 armed the eBoard
        and the driver pins latched. The guard unwinds that correctly, but a
        one-line refusal beats a half-run abort."""
        status = extruder.get_status(self.reactor.monotonic())
        if status.get('can_extrude'):
            return
        raise gcmd.error(
            "%s: %s is at %.1f C and will not extrude (min_extrude_temp)."
            " Heat it -- M109 S<temp> T<tool> -- or pass TEMP=."
            % (self.name, extruder.get_name(), status.get('temperature', 0.)))

    def _check_filament(self, gcmd, tool):
        if not self.require_filament_sensor:
            return
        sensor = self.printer.lookup_object(
            'filament_switch_sensor fd_ex%d' % tool, None)
        helper = getattr(sensor, 'runout_helper', None)
        if helper is None:
            return
        if not helper.filament_present:
            raise gcmd.error(
                "%s: fd_ex%d reports no filament. An unloaded tool extrudes"
                " nothing and scores nothing, quietly -- load it, or set"
                " require_filament_sensor: False if the switch is wrong."
                % (self.name, tool))

    def _check_bounds(self, gcmd):
        """The ladder must fit the machine. The defaults sit well inside a
        Creator 5's envelope; an overridden ladder need not."""
        _toolhead, status = self._toolhead_status()
        low, high = status.get('axis_minimum'), status.get('axis_maximum')
        if low is None or high is None:
            return
        xs = [self.x_start] + [seg[0] for seg in self.segments]
        ys = [self.y_start + self.y_step * i
              for i in range(len(self.candidates))]
        for axis, values, lo, hi in (('X', xs, low.x, high.x),
                                     ('Y', ys, low.y, high.y)):
            if min(values) < lo or max(values) > hi:
                raise gcmd.error(
                    "%s: the %s ladder spans %.1f..%.1f, outside the"
                    " machine's %.1f..%.1f. Adjust x_start/segments or"
                    " y_start/y_step."
                    % (self.name, axis, min(values), max(values), lo, hi))

    def _cross_section_note(self, extruder):
        """Klipper caps extrude cross-section at 4*nozzle^2. The sweep's
        0.137 mm^2 is comfortable on a 0.4 nozzle and tight on a 0.2."""
        settings = self.printer.lookup_object('configfile').get_status(
            self.reactor.monotonic())['settings']
        section = settings.get(extruder.get_name(), {})
        nozzle = section.get('nozzle_diameter')
        if not nozzle:
            return None
        axis_r = self.segments[0][1] / (self.segments[0][0] - self.x_start)
        area = axis_r * FILAMENT_AREA_175
        cap = 4.0 * nozzle * nozzle
        if area * 1.5 < cap:
            return None
        return ("  ! the line's cross-section is %.3f mm2 against Klipper's"
                " %.3f mm2 cap for a %.2f mm nozzle -- little headroom."
                % (area, cap, nozzle))

    def _line_z(self, gcmd, tool):
        """8 mm above the plate in the RAW eddy frame -> a G-code Z.

        Three layers sit between a G-code Z and the machine with a tool
        mounted, and all three come off: the operator's babystep, the tool's
        own frame, and the job term that frame also carries. Subtracting only
        the first parks the nozzle ~3.2 mm high -- see _FF_NOZZLE_WIPE in
        ff-filament.cfg, where that was a real bug. Here it only changes how
        far the extrudate falls, so it is comfort rather than crash, but the
        arithmetic is the same and there is no reason to get it wrong."""
        raw = self.line_z
        if raw is None:
            ff = self.printer.lookup_object('gcode_macro _FF_FILAMENT', None)
            if ff is not None:
                raw = ff.get_status(
                    self.reactor.monotonic()).get('purge_z', LINE_Z)
            else:
                raw = LINE_Z
        raw = gcmd.get_float('Z', raw)
        now = self.reactor.monotonic()
        gcode_move = self.printer.lookup_object('gcode_move')
        z = raw - gcode_move.get_status(now)['homing_origin'].z
        tool_view = self.printer.lookup_object('tool T%d' % tool, None)
        if tool_view is not None:
            z -= tool_view.get_status(now).get('gcode_z_offset', 0.)
        changer = self.printer.lookup_object('toolchanger', None)
        if changer is not None:
            z -= changer.get_status(now).get('print_z_offset', 0.)
        return raw, z

    # ---------------- the sweep ----------------

    def _prologue(self, z_target):
        """The app's prologue, plus SAVE_GCODE_STATE and an explicit G90 --
        it leaks its modal state and we do not."""
        self._run('SAVE_GCODE_STATE NAME=_ff_pa')
        self._run('G90')
        self._run('G92 E0')
        self._run('M83')
        self._run('SET_VELOCITY_LIMIT ACCEL=%.0f' % self.sweep_accel)
        self._run('SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY=%.3f'
                  % self.sweep_scv)
        for pin_name, _pin in self.tmc_pins:
            self._run('SET_PIN PIN=%s VALUE=1.00' % pin_name)
        self._wait_moves()
        # Raise before travelling, never lower -- same rule as the purge in
        # ff-filament.cfg. The XY travel is the first line's own G1.
        _toolhead, status = self._toolhead_status()
        if self.dry_run or status['position'].z < z_target:
            self._run('G1 Z%.3f F%d' % (z_target, self.line_z_feed))
            self._wait_moves()

    def _one_line(self, index, pa_text, extruder_name, verbose):
        """One candidate: arm, set PA, draw the line, disarm, read a verdict.

        THE BARRIERS HERE ARE THE APP'S AND THEY ARE DELIBERATE. There is no
        M400 between the last G1 and ACTION=0 -- see the module header. Do
        not add one.
        """
        action_cmd, query_cmd = self._eboard_cmds()
        y = self.y_start + self.y_step * index

        if self.dry_run:
            self.gcode.respond_info("  [dry] PA_ACTION ACTION=%d PC=%d"
                                    % (self.action_start, self.action_pc))
        else:
            action_cmd.send([self.action_start, self.action_pc])

        # EXTRUDER= is named explicitly. The app omits it and leans on the
        # mux default, which resolves to the same active extruder; naming it
        # is behaviour-identical and makes the transcript unambiguous.
        self._run('SET_PRESSURE_ADVANCE EXTRUDER=%s ADVANCE=%s'
                  % (extruder_name, pa_text))
        self._run('G1 X%.3f Y%.3f F%d' % (self.x_start, y, self.travel_feed))
        for x, e, feed in self.segments:
            self._run('G1 F%d' % feed)
            self._run('G1 X%.3f E%.5f' % (x, e))
        # >>> NO _wait_moves() HERE. <<<

        unflushed = None
        if verbose and not self.dry_run:
            _toolhead, status = self._toolhead_status()
            unflushed = status['print_time'] - status['estimated_print_time']
        if not self.dry_run:
            action_cmd.send([self.action_stop, self.action_pc])

        self._wait_moves()          # the app's M400, after ACTION=0

        if self.dry_run:
            self.gcode.respond_info("  [dry] PA_GET")
            return None, unflushed
        try:
            verdict = int(query_cmd.send()['value'])
        except self.printer.command_error as err:
            raise FFPAError(
                "the eBoard did not answer get_emcu_pa_value (%s). That is a"
                " comms failure, not a verdict, so the run stops here rather"
                " than scoring it as a miss." % err)
        return verdict, unflushed

    def _sweep(self, gcmd, extruder_name, verbose):
        best = []
        census = {}
        rows = []
        for sweep in range(self.sweeps):
            if self.printer.is_shutdown():
                raise FFPAError("printer shut down mid-sweep")
            good = []
            row = []
            for index, pa_text in enumerate(self.candidates):
                verdict, unflushed = self._one_line(index, pa_text,
                                                    extruder_name, verbose)
                census[verdict] = census.get(verdict, 0) + 1
                row.append((pa_text, verdict))
                if verdict == self.pass_value:
                    good.append(float(pa_text))
                if verbose:
                    extra = ''
                    if unflushed is not None:
                        extra = ('   (%.2f s of motion still unflushed at'
                                 ' ACTION=0)' % unflushed)
                    gcmd.respond_info("    %s -> %s%s"
                                      % (pa_text, verdict, extra))
            # min() on floats, not the app's lexicographic sort of its
            # fixed-width strings. Identical for its own seven values, and
            # correct for an override with mixed decimal widths where a
            # string sort would put 0.1 before 0.05.
            winner = min(good) if good else None
            if winner is not None:
                best.append(winner)
            rows.append((sweep, row, winner))
            gcmd.respond_info(self._format_row(sweep, row, winner))
            if len(best) >= self.winners:
                break
        return best, census, rows

    def _format_row(self, sweep, row, winner):
        cells = "  ".join("%s=%s" % (pa, verdict) for pa, verdict in row)
        tail = "-> %.4f" % winner if winner is not None else "-> (none passed)"
        return "  sweep %d: %s   %s" % (sweep + 1, cells, tail)

    # ---------------- state ----------------

    @contextlib.contextmanager
    def _guarded(self, extruder):
        """Snapshot on entry, restore unconditionally on exit, every step
        guarded on its own so one failure neither masks the original error
        nor skips the rest -- during a shutdown run_script_from_command
        raises, and the raw MCU send is the one with a chance of landing."""
        now = self.reactor.monotonic()
        _toolhead, th = self._toolhead_status()
        ext = extruder.get_status(now)
        snapshot = {
            'accel': th['max_accel'],
            'scv': th['square_corner_velocity'],
            'pa': ext.get('pressure_advance', 0.),
            'smooth': ext.get('smooth_time', 0.),
            'name': extruder.get_name(),
            'pins': [(n, (p.get_status(now)['value'] if p is not None else 0.))
                     for n, p in self.tmc_pins],
        }
        try:
            yield snapshot
        finally:
            self._restore(snapshot)

    def _restore(self, snapshot):
        # 1. Disarm the eBoard first, and unconditionally. If we bailed
        #    mid-line its capture is still armed with timers and DMA
        #    running -- the one piece of state that outlives klippy.
        if not self.dry_run:
            try:
                action_cmd, _query = self._eboard_cmds()
                action_cmd.send([self.action_stop, self.action_pc])
            except (FFPAError, self.printer.command_error):
                pass
        # 2. Driver pins back to what they were, not to the app's hardcoded
        #    0.00. Left latched, whatever they gate stays energised.
        for pin_name, value in snapshot['pins']:
            try:
                self._run('SET_PIN PIN=%s VALUE=%.2f' % (pin_name, value))
            except self.printer.command_error:
                pass
        # 3. Motion limits. The shipped values are 30000/9, so the sweep's
        #    5000 is a real reduction that must not leak into the next print.
        try:
            self._run('SET_VELOCITY_LIMIT ACCEL=%.0f'
                      ' SQUARE_CORNER_VELOCITY=%.3f'
                      % (snapshot['accel'], snapshot['scv']))
        except self.printer.command_error:
            pass
        # 4. Pressure advance. The app never does this -- it can leave the
        #    last candidate installed because SET_PA_ADVANCE overrides it
        #    immediately. We only report, so leaving 0.0400 in place would
        #    mean the command silently applied something, and the wrong
        #    thing.
        try:
            self._run('SET_PRESSURE_ADVANCE EXTRUDER=%s ADVANCE=%.6f'
                      ' SMOOTH_TIME=%.6f'
                      % (snapshot['name'], snapshot['pa'], snapshot['smooth']))
        except self.printer.command_error:
            pass
        try:
            self._run('RESTORE_GCODE_STATE NAME=_ff_pa')
        except self.printer.command_error:
            pass
        # The app's resetTmcPa also replays SET_KINEMATIC_POSITION. That is
        # NOT ported and must not be: it needs it because its caller
        # force-drove the axes, while our sweep is plain G1 under Klipper's
        # own kinematics. Replaying it here would only lie to Klipper about
        # where the carriage is.

    def _heat(self, gcmd, tool, extruder):
        temp = gcmd.get_float('TEMP', None)
        if temp is None:
            return
        self._run('M104 S%.1f T%d' % (temp, tool))
        self._run('TEMPERATURE_WAIT SENSOR=%s MINIMUM=%.1f MAXIMUM=%.1f'
                  % (extruder.get_name(), temp - self.min_temp_margin,
                     temp + self.min_temp_margin))

    # ---------------- commands ----------------

    cmd_FF_PA_CALIBRATE_help = (
        "Measure pressure advance on the MOUNTED tool by sweeping candidates"
        " through the eBoard's scorer. Extrudes ~1 g in free air onto the"
        " plate and REPORTS a number -- it saves nothing and applies nothing"
        " ([TOOL=] [TEMP=] [SWEEPS=] [WINNERS=] [CANDIDATES=] [PASS_VALUE=]"
        " [Y_START=] [Y_STEP=] [Z=] [VERBOSE=1] [DRY_RUN=1])")

    def cmd_FF_PA_CALIBRATE(self, gcmd):
        if self.running:
            raise gcmd.error("%s: a calibration is already running"
                             % self.name)
        saved = (self.candidates, self.sweeps, self.winners,
                 self.pass_value, self.y_start, self.y_step)
        self.dry_run = bool(gcmd.get_int('DRY_RUN', 0, minval=0, maxval=1))
        verbose = bool(gcmd.get_int('VERBOSE', 0, minval=0, maxval=1))
        try:
            self.running = True
            self._apply_overrides(gcmd)
            self._calibrate(gcmd, verbose)
        finally:
            self.running = False
            self.dry_run = False
            (self.candidates, self.sweeps, self.winners, self.pass_value,
             self.y_start, self.y_step) = saved

    def _apply_overrides(self, gcmd):
        raw = gcmd.get('CANDIDATES', None)
        if raw:
            values = [c.strip() for c in raw.split(',') if c.strip()]
            for text in values:
                try:
                    float(text)
                except ValueError:
                    raise gcmd.error("%s: candidate '%s' is not a number"
                                     % (self.name, text))
            self.candidates = values
        self.sweeps = gcmd.get_int('SWEEPS', self.sweeps, minval=1)
        self.winners = gcmd.get_int('WINNERS', self.winners, minval=1)
        if self.winners > self.sweeps:
            raise gcmd.error(
                "%s: WINNERS (%d) cannot exceed SWEEPS (%d) -- the run could"
                " never succeed" % (self.name, self.winners, self.sweeps))
        self.pass_value = gcmd.get_int('PASS_VALUE', self.pass_value)
        self.y_start = gcmd.get_float('Y_START', self.y_start)
        self.y_step = gcmd.get_float('Y_STEP', self.y_step)
        if self.dry_run:
            # A dry run never collects a winner, so it would otherwise print
            # every sweep. One is what anyone wants to read.
            self.sweeps = self.winners = 1

    def _calibrate(self, gcmd, verbose):
        tool = self._resolve_tool(gcmd)
        self._check_homed(gcmd)
        self._check_filament(gcmd, tool)
        self._check_bounds(gcmd)
        self._ensure_extruder(tool)
        extruder = self._extruder()
        self._heat(gcmd, tool, extruder)
        extruder = self._extruder()
        if not self.dry_run:
            self._check_can_extrude(gcmd, extruder)
        raw_z, z_target = self._line_z(gcmd, tool)

        lines = ["%s: T%d (%s), %d candidates x up to %d sweeps"
                 % (self.name, tool, extruder.get_name(),
                    len(self.candidates), self.sweeps),
                 "  lines are extruded in FREE AIR at Z %.3f raw / Z %.3f"
                 " gcode. Nothing prints them and nothing inspects them --"
                 " expect ~1 g of loose filament on the plate."
                 % (raw_z, z_target)]
        note = self._cross_section_note(extruder)
        if note:
            lines.append(note)
        gcmd.respond_info("\n".join(lines))

        extruder_name = extruder.get_name()
        with self._guarded(extruder):
            try:
                self._prologue(z_target)
                best, census, rows = self._sweep(gcmd, extruder_name, verbose)
            except FFPAError as err:
                raise gcmd.error("%s: %s" % (self.name, err))
        if self.dry_run:
            gcmd.respond_info("%s: dry run, nothing was measured."
                              % self.name)
            return
        # 'need' is the effective winners count for THIS run: a WINNERS=
        # override is rolled back before get_status can be read.
        self.last = {'tool': tool, 'rows': rows, 'census': census,
                     'winners': best, 'need': self.winners}
        self._report(gcmd, tool, extruder_name, best, census)

    def _report(self, gcmd, tool, extruder_name, best, census):
        seen = "  ".join("%s(%d)" % (v, n) for v, n in sorted(
            census.items(), key=lambda kv: (kv[0] is None, kv[0])))
        total = sum(census.values())
        # The dangerous case. If every line came back with the pass value,
        # min(good) is candidates[0] on every sweep and the mean below is
        # the smallest candidate wearing a measurement's clothes.
        if len(census) == 1:
            only = next(iter(census))
            message = (
                "the eBoard returned %s for all %d lines. It is not"
                " discriminating between candidates, so any number from this"
                " run would just be the smallest candidate and would mean"
                " nothing. Check that filament is really being extruded and"
                " that the transducer on the eBoard's second UART is"
                " connected." % (only, total))
            if self.require_discrimination:
                raise gcmd.error("%s: %s" % (self.name, message))
            gcmd.respond_info("%s: !! %s" % (self.name, message))
        if len(best) < self.winners:
            raise gcmd.error(
                "%s: only %d of %d sweeps produced a passing candidate, need"
                " %d. Verdicts seen across %d lines: %s. No number is"
                " reported -- averaging fewer winners would be a different"
                " estimator, not this one."
                % (self.name, len(best), self.sweeps, self.winners, total,
                   seen))
        used = best[:self.winners]
        result = sum(used) / len(used)
        gcmd.respond_info(
            "%s: T%d pressure_advance = %.6f   (mean of %d sweep winners:"
            " %s)\n"
            "  verdicts across %d lines: %s\n"
            "  NOT saved and NOT applied. To keep it, put it in printer.cfg"
            " yourself:\n"
            "      [%s]\n"
            "      pressure_advance: %.6f\n"
            "  or try it for this session:\n"
            "      SET_PRESSURE_ADVANCE EXTRUDER=%s ADVANCE=%.6f\n"
            "  %s's own pressure advance has been restored; this run changed"
            " nothing.\n"
            "  Note: the rule is \"smallest passing candidate wins\", so this"
            " can never report below %s. Cross-check against a PA tower"
            " before trusting it."
            % (self.name, tool, result, len(used),
               ", ".join("%.4f" % v for v in used), total, seen,
               extruder_name, result, extruder_name, result, extruder_name,
               min(self.candidates, key=float)))

    cmd_FF_PA_PROBE_help = (
        "Draw ONE calibration line and print its eBoard verdict. The"
        " bring-up tool: run it across the candidates by hand and confirm"
        " you get more than one distinct answer before trusting an averaged"
        " number ([PA=] [Y=] [TOOL=] [TEMP=] [Z=] [DRY_RUN=1])")

    def cmd_FF_PA_PROBE(self, gcmd):
        if self.running:
            raise gcmd.error("%s: a calibration is already running"
                             % self.name)
        self.dry_run = bool(gcmd.get_int('DRY_RUN', 0, minval=0, maxval=1))
        try:
            self.running = True
            self._probe(gcmd)
        finally:
            self.running = False
            self.dry_run = False

    def _probe(self, gcmd):
        pa_text = gcmd.get('PA', self.candidates[0])
        try:
            float(pa_text)
        except ValueError:
            raise gcmd.error("%s: PA='%s' is not a number"
                             % (self.name, pa_text))
        y = gcmd.get_float('Y', self.y_start)
        tool = self._resolve_tool(gcmd)
        self._check_homed(gcmd)
        self._check_filament(gcmd, tool)
        self._check_bounds(gcmd)
        self._ensure_extruder(tool)
        extruder = self._extruder()
        self._heat(gcmd, tool, extruder)
        extruder = self._extruder()
        if not self.dry_run:
            self._check_can_extrude(gcmd, extruder)
        _raw_z, z_target = self._line_z(gcmd, tool)
        extruder_name = extruder.get_name()
        # One line at the requested Y: index 0 with the ladder rebased.
        saved_y = self.y_start
        with self._guarded(extruder):
            try:
                self.y_start = y
                self._prologue(z_target)
                verdict, unflushed = self._one_line(0, pa_text, extruder_name,
                                                    True)
            except FFPAError as err:
                raise gcmd.error("%s: %s" % (self.name, err))
            finally:
                self.y_start = saved_y
        if self.dry_run:
            return
        extra = ''
        if unflushed is not None:
            extra = ("   (%.2f s of motion still unflushed at ACTION=0)"
                     % unflushed)
        gcmd.respond_info(
            "%s: T%d PA=%s at Y%.3f -> verdict %s   (pass value is %d)%s"
            % (self.name, tool, pa_text, y, verdict, self.pass_value, extra))

    cmd_FF_PA_STATUS_help = (
        "Show the PA calibration config in force, whether the eBoard"
        " commands are bound, and the last run's table")

    def cmd_FF_PA_STATUS(self, gcmd):
        action = query = None
        bound = "no ([pa_adjust] not loaded)"
        if self.pa_adjust is not None:
            action = getattr(self.pa_adjust, '_pa_action_cmd', None)
            query = getattr(self.pa_adjust, '_pa_value_get_cmd', None)
            bound = "yes" if (action and query) else "no (eBoard not up?)"
        now = self.reactor.monotonic()
        pins = ", ".join(
            "%s=%.2f" % (n, p.get_status(now)['value'])
            for n, p in self.tmc_pins if p is not None) or "(none)"
        lines = ["%s:" % self.name,
                 "  candidates: %s" % ", ".join(self.candidates),
                 "  pass_value %d, sweeps %d, winners %d"
                 % (self.pass_value, self.sweeps, self.winners),
                 "  ladder: X%.1f..%.1f, Y%.1f step %.1f"
                 % (self.x_start, self.segments[-1][0], self.y_start,
                    self.y_step),
                 "  eBoard commands bound: %s" % bound,
                 "  toolchanger: %s"
                 % ("loaded" if self.toolchange is not None else "MISSING"),
                 "  driver pins: %s" % pins]
        if self.last is None:
            lines.append("  no run yet")
        else:
            lines.append("  last run: T%d, winners %s"
                         % (self.last['tool'],
                            ", ".join("%.4f" % v
                                      for v in self.last['winners'])))
            for sweep, row, winner in self.last['rows']:
                lines.append(self._format_row(sweep, row, winner))
        gcmd.respond_info("\n".join(lines))

    def get_status(self, eventtime):
        if self.last is None:
            return {'last_tool': -1, 'last_winners': [], 'last_result': None}
        winners = self.last['winners']
        # last_result stays None unless the run actually succeeded. A mean of
        # one or two winners is a different estimator, and exposing it here
        # would let a macro read a number the command itself refused to
        # report.
        result = None
        need = self.last.get('need', self.winners)
        if len(winners) >= need:
            used = winners[:need]
            result = sum(used) / len(used)
        return {'last_tool': self.last['tool'],
                'last_winners': list(winners),
                'last_result': result}


def load_config(config):
    return FFPA(config)
