# Nozzle XY/Z offset calibration for the FlashForge Creator 5 Pro.
#
# A port of the touchscreen's "Extruder offset" calibration, recovered from
# the firmwareExe binary (MIPS machine code -- Ghidra truncated these bodies):
#   CalibrationDialog::testEddyExtruderOffsetForwardTwoCheck  @0x806490  (tools)
#   CalibrationDialog::testStationPosFourPointTwoCheck        @0x7edf10  (station)
#   CommMgr::moveCylinderPos                                  @0x789a1c / @0x78a610
#   CommMgr::estopManager                                     @0x788738
#   BaseFunction::fitCircleStable / fitCircleByLeastSquares   @0x6467f8 / @0x645b10
# Full walkthrough: docs/notes/46-offset-calibration-recovered.md
#
# The setup: a fixed inductive "cylinder" station under the bed (levelboard
# PD0, exposed as [e_stop X]/[e_stop Y]/[e_stop Z] -- one pin, three axis
# wrappers). The nozzle is lowered into its bore until the sensor fires (Z),
# then driven outward from the bore centre along +X, +Y, -X, -Y until the wall
# fires it. Four boundary points -> least-squares circle -> the bore axis in
# this tool's nozzle frame. Done twice, the second pass centred on the first
# fit with Z re-probed there; the second result is stored as [ff_tool n]'s
# nozzle_x/y/z -- RAW machine coordinates with the G-code offset zeroed.
# Tool-to-tool differences of those are what the toolchanger applies.
#
# The same pass with an EMPTY carriage measures the station position.
# station_z is the eddy-frame reference the print-start Z offset is computed
# against, so it must be measured with the same station and mechanics.
#
# Results are stored the way Klipper's own calibrators store theirs:
# configfile.set() into the SAVE_CONFIG block of printer.cfg, applied live at
# once and persisted by SAVE_CONFIG (which restarts). firmwareExe's
# extruder.json is not touched; ff_legacy.py can import it once.
#
# A Python extra rather than a macro because each ESTOP result feeds the next
# move, and a gcode_macro renders its whole template before anything executes.

import math

EXTRUDER_COUNT = 4

# Constants read from the binary's .rodata (offset-calibration.md section 2):
NOZZLE_X_SHIFT = 12.5      # @0xdfdba8  tool pass starts at cylinder_x - 12.5
PROBE_TRAVEL = 14.0        # 7.0 + 7.0 (@0xdfdb98)  ESTOP target = centre +/- 14
Z_TARGET = -3.0            # our default: the app's own station pass-2 value.
                           # The app used -5.0 (@0xdfdb8c) for tools and for
                           # station pass 1; -3 is 1.3 mm below the deepest
                           # expected trigger and 2 mm less crash depth if the
                           # plate is still on. Override with z_target.
Z_TARGET_STATION_2 = -3.0  # station second Z probe (moveCylinderPos @0x78a610)
Z_CLEAR = 0.6              # @0xdfdb90  probing height above the Z trigger
Z_LIFT = 3.0               # @0xdfdba0  lift between the two passes
Z_START = 10.0             # @0xdfdbac  "G1 Z10" before the Z probe
Z_FINAL = 15.0             # "G1 Z15 F1200" on exit
FEED_POSITION = 12000      # G1 X Y F12000 to the start point
FEED_PASS1 = 1200          # returns to centre in pass 1, and all Z moves
FEED_PASS2 = 2400          # returns to centre in pass 2
PROBE_ACCEL = 100.0        # SET_VELOCITY_LIMIT ACCEL=100 while probing
                           # (restored to the pre-run limit afterwards, not to
                           # the app's literal 20000)

# test.json defaults (Config::initTestConfig) for the station start point.
CYLINDER_X_DEFAULT = 28.5
CYLINDER_Y_DEFAULT = 214.5


# ---------------------------------------------------------------------------
# Circle fit -- port of BaseFunction::fitCircleStable @0x6467f8
# (centroid-shifted algebraic least squares, cv::solve DECOMP_LU on the 3x3
# normal equations):
#     A = [2x', 2y', 1],  b = x'^2 + y'^2,  (A^T A) p = A^T b
#     centre = (p0 + centroid_x, p1 + centroid_y),  r = sqrt(p2 + p0^2 + p1^2)
# For the 4 symmetric points this sequence produces, this and the shipped
# unshifted variant both reduce to the midpoints; the shifted form is kept for
# numerical hygiene and accepts >= 3 points. Pure Python on purpose: numpy is
# not guaranteed on the X2000 rootfs.
# ---------------------------------------------------------------------------

def fit_circle(points):
    """Return (center_x, center_y, radius, residuals); raise ValueError if
    unfittable."""
    point_count = len(points)
    if point_count < 3:
        raise ValueError("circle fit needs at least 3 points, got %d"
                         % point_count)
    centroid_x = sum(point[0] for point in points) / point_count
    centroid_y = sum(point[1] for point in points) / point_count
    normal_matrix = [[0.0] * 3 for _ in range(3)]
    normal_rhs = [0.0] * 3
    for x, y in points:
        shifted_x, shifted_y = x - centroid_x, y - centroid_y
        design_row = (2.0 * shifted_x, 2.0 * shifted_y, 1.0)
        squared_radius_term = shifted_x * shifted_x + shifted_y * shifted_y
        for i in range(3):
            normal_rhs[i] += design_row[i] * squared_radius_term
            for j in range(3):
                normal_matrix[i][j] += design_row[i] * design_row[j]
    solution = _solve3(normal_matrix, normal_rhs)
    if solution is None:
        raise ValueError("circle fit is singular (points collinear?)")
    center_x = solution[0] + centroid_x
    center_y = solution[1] + centroid_y
    radius_squared = (solution[2] + solution[0] * solution[0]
                      + solution[1] * solution[1])
    if radius_squared <= 0.0:
        raise ValueError("circle fit gave radius^2 = %.6f" % radius_squared)
    radius = math.sqrt(radius_squared)
    residuals = [math.hypot(x - center_x, y - center_y) - radius
                 for x, y in points]
    return center_x, center_y, radius, residuals


def _solve3(matrix, rhs):
    """Gauss-Jordan with partial pivoting on the augmented 3x4 system."""
    augmented = [matrix[i][:] + [rhs[i]] for i in range(3)]
    for col in range(3):
        pivot_row = max(range(col, 3), key=lambda r: abs(augmented[r][col]))
        if abs(augmented[pivot_row][col]) < 1e-12:
            return None
        augmented[col], augmented[pivot_row] = (augmented[pivot_row],
                                                augmented[col])
        for row in range(3):
            if row != col:
                factor = augmented[row][col] / augmented[col][col]
                for term in range(col, 4):
                    augmented[row][term] -= factor * augmented[col][term]
    return [augmented[i][3] / augmented[i][i] for i in range(3)]


def _combine(positions, how):
    """klipper-toolchanger's samples_result. 'median' of an even count is
    the mean of the middle two, as upstream's _calc_median does."""
    ordered = sorted(positions)
    if how == 'median':
        middle = len(ordered) // 2
        if len(ordered) % 2:
            return ordered[middle]
        return 0.5 * (ordered[middle - 1] + ordered[middle])
    return sum(ordered) / len(ordered)


class FFToolOffsetError(Exception):
    pass


class FFToolOffset:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')
        self.name = config.get_name()

        # Start point. The app reads cylinder_x/y from test.json (28.5 /
        # 214.5 on a stock unit, equal to its compiled-in defaults).
        self.cfg_cylinder_x = config.getfloat('cylinder_x', None)
        self.cfg_cylinder_y = config.getfloat('cylinder_y', None)
        self.nozzle_x_shift = config.getfloat('nozzle_x_shift', NOZZLE_X_SHIFT)
        self.probe_travel = config.getfloat('probe_travel', PROBE_TRAVEL,
                                            above=0.)
        self.z_target = config.getfloat('z_target', Z_TARGET)
        # Once a trigger height is known (nozzle_z / station_z already
        # calibrated) the Z probe stops this far below it instead of going
        # all the way to z_target.
        self.z_margin = config.getfloat('z_margin', 2.0, above=0.)
        self.z_target_station_2 = config.getfloat('z_target_station_2',
                                                  Z_TARGET_STATION_2)
        self.z_clear = config.getfloat('z_clear', Z_CLEAR, above=0.)
        self.z_lift = config.getfloat('z_lift', Z_LIFT, above=0.)
        self.z_start = config.getfloat('z_start', Z_START)
        self.z_final = config.getfloat('z_final', Z_FINAL)
        self.probe_accel = config.getfloat('probe_accel', PROBE_ACCEL, above=0.)
        # Probe sampling, klipper-toolchanger's names. None everywhere means
        # "whatever [e_stop <axis>] already does" -- see _sampling(). Set
        # any of these to override that for every probe of a calibration
        # run; the command line overrides them again per run.
        self.samples = config.getint('samples', None, minval=1)
        self.samples_tolerance = config.getfloat('samples_tolerance', None,
                                                 minval=0.)
        self.samples_retries = config.getint('samples_tolerance_retries',
                                             None, minval=0)
        self.samples_result = config.getchoice(
            'samples_result', {'average': 'average', 'median': 'median'},
            'average')
        # Retract between samples; None = the fork's back_v.
        self.sample_retract_dist = config.getfloat('sample_retract_dist',
                                                   None, above=0.)
        # Probe feed; None = the [e_stop <axis>] speed.
        self.probe_speed = config.getfloat('probe_speed', None, above=0.)
        # None = restore the accel limit that was live when we started
        # (same policy as ff_toolchange); set to force the app's 20000.
        self.accel_restore = config.getfloat('accel_restore', None)
        # Residual guard, which the app has none of -- any four numbers are
        # accepted. With four symmetric points one bad point of error e shows
        # up as a residual of only ~e/4 while moving the centre by e/2, so
        # 0.05 catches centre errors of ~0.1 mm. 0 disables.
        self.max_residual = config.getfloat('max_residual', 0.05, minval=0.)
        # Sanity window for the fitted bore radius (0 disables).
        self.min_radius = config.getfloat('min_radius', 0.0, minval=0.)
        self.max_radius = config.getfloat('max_radius', 0.0, minval=0.)
        # Plausibility of nozzle_z against station_z: the nozzle fires the
        # station ~3.2 mm above where the empty carriage does. A value far
        # outside that means a bad probe, and a bad nozzle_z is what drives
        # the first layer into the plate. Checked only when station_z is
        # known; 0 disables.
        self.gap_min = config.getfloat('gap_min', 1.5)
        self.gap_max = config.getfloat('gap_max', 5.0)
        # Plate check (empty carriage, before any nozzle descends): the
        # station Z must not land more than plate_z_tolerance ABOVE the
        # calibrated station_z -- one-sided, because a plate can only hold the
        # probe high -- and a sideways probe must find the circle's edge. 0
        # disables.
        self.plate_check = config.getboolean('plate_check', True)
        self.plate_z_tolerance = config.getfloat('plate_z_tolerance', 0.8,
                                                 above=0.)

        # Station position measured with the empty carriage
        # (TOOL_LOCATE_SENSOR), autosaved here as station_x/y/z.
        station_x = config.getfloat('station_x', None)
        station_y = config.getfloat('station_y', None)
        station_z = config.getfloat('station_z', None)
        station = (station_x, station_y, station_z)
        if station != (None, None, None) and None in station:
            raise config.error("%s: station_x, station_y and station_z must"
                               " be set together" % self.name)
        self.station = None if station_x is None else station

        # Klipper's own G-code offset, held while probing runs in raw
        # machine coordinates. None when we are not in the raw frame.
        self._saved_gcode_offset = None
        self.estop = {}
        self.tools = []
        for i in range(EXTRUDER_COUNT):
            self.tools.append(self.printer.load_object(config, 'ff_tool %d' % i))
        self.toolchange = None
        self.last = {}

        self.gcode.register_command(
            'TOOL_CALIBRATE_TOOL_OFFSET', self.cmd_TOOL_CALIBRATE_TOOL_OFFSET,
            desc=self.cmd_TOOL_CALIBRATE_TOOL_OFFSET_help)
        self.gcode.register_command(
            'TOOL_LOCATE_SENSOR', self.cmd_TOOL_LOCATE_SENSOR,
            desc=self.cmd_TOOL_LOCATE_SENSOR_help)
        self.gcode.register_command(
            'TOOL_OFFSET_STATUS', self.cmd_TOOL_OFFSET_STATUS,
            desc=self.cmd_TOOL_OFFSET_STATUS_help)
        self.printer.register_event_handler('klippy:connect',
                                            self._handle_connect)

    # ---------------- plumbing ----------------

    def _handle_connect(self):
        missing = []
        for axis in 'XYZ':
            axis_probe = self.printer.lookup_object('e_stop %s' % axis, None)
            if axis_probe is None or not hasattr(axis_probe, 'run_probe'):
                missing.append('e_stop %s' % axis)
            self.estop[axis] = axis_probe
        if missing:
            raise self.printer.config_error(
                "%s: required sections not found: %s (the station sensor is"
                " exposed through the fork's [e_stop X|Y|Z])"
                % (self.name, ", ".join(missing)))
        self.toolchange = self.printer.lookup_object('ff_toolchange', None)

    def _run(self, script):
        self.gcode.run_script_from_command(script)

    def _enter_raw_frame(self):
        """Probe in raw machine coordinates.

        There are TWO frames to get out of the way, not one. Klipper's own
        G-code offset (the operator's babystep, plus whatever
        TOOLCHANGE_SET_PRINT_OFFSET left) is zeroed here and put back by
        _leave_raw_frame -- it used to be zeroed and simply abandoned, which
        threw away the babystep on every calibration. The per-tool frame
        lives under it in [ff_toolchange]'s move transform and has to be
        suspended separately; zeroing the G-code offset does NOT reach it,
        and a calibration run with the previous tool's offsets still applied
        measures numbers that look entirely plausible and are wrong by that
        tool's offsets."""
        if self._saved_gcode_offset is None:
            gcode_move = self.printer.lookup_object('gcode_move')
            origin = gcode_move.get_status(
                self.reactor.monotonic())['homing_origin']
            self._saved_gcode_offset = (origin.x, origin.y, origin.z)
        self._run('SET_GCODE_OFFSET X=0 Y=0 Z=0 MOVE=0 MOVE_SPEED=600')
        if self.toolchange is not None \
           and hasattr(self.toolchange, 'suspend_tool_frame'):
            self.toolchange.suspend_tool_frame()

    def _leave_raw_frame(self, gcmd=None):
        """Put both frames back: the operator's G-code offset as it was,
        and the per-tool frame of whatever is actually mounted now."""
        saved, self._saved_gcode_offset = self._saved_gcode_offset, None
        if saved is not None:
            self._run('SET_GCODE_OFFSET X=%.4f Y=%.4f Z=%.4f MOVE=0'
                      % saved)
        if self.toolchange is not None \
           and hasattr(self.toolchange, 'restore_tool_frame'):
            self.toolchange.restore_tool_frame(gcmd)

    def _wait_moves(self):
        self.printer.lookup_object('toolhead').wait_moves()

    def _cylinder(self):
        x, y = self.cfg_cylinder_x, self.cfg_cylinder_y
        if x is None:
            x = CYLINDER_X_DEFAULT
        if y is None:
            y = CYLINDER_Y_DEFAULT
        return x, y

    def _check_homed(self, gcmd):
        toolhead = self.printer.lookup_object('toolhead')
        homed = toolhead.get_status(self.reactor.monotonic())['homed_axes']
        if not all(axis in homed for axis in 'xyz'):
            raise gcmd.error("%s: home all axes first (homed: '%s')"
                             % (self.name, homed))

    def _current_accel(self):
        toolhead = self.printer.lookup_object('toolhead')
        return toolhead.get_status(self.reactor.monotonic())['max_accel']

    def _touch(self, gcmd, axis_probe, axis, target, speed):
        """One approach-trigger-retract against the fork's e_stop object,
        calling it directly instead of parsing ESTOP's JSON reply.

        _probe(speed) is the fork's single touch: it refuses to start on an
        already-triggered pin, moves to position_offset, and backs off
        back_v before returning. run_probe() is the fork's own averaging
        loop built on it (sub_cycle_cnt touches, spread rejected above
        error_v, retried main_cycle_cnt times) -- we do that loop ourselves
        in _estop so the sample count, tolerance and median are reachable
        from the command line, and fall back to run_probe on an e_stop that
        does not expose _probe."""
        single = getattr(axis_probe, '_probe', None)
        try:
            if single is None:
                triggered_at = axis_probe.run_probe(gcmd)
            else:
                triggered_at = single(speed)
                # e_stop_move reports a failed move as the sentinel 9999
                # rather than raising, and the fork's run_probe just spins
                # on it. Bounded here: it is a failure like any other.
                if triggered_at == 9999:
                    raise FFToolOffsetError(
                        "ESTOP %s TARGET=%.3f: probe move failed"
                        % (axis, target))
        except self.printer.command_error as err:
            raise FFToolOffsetError("ESTOP %s TARGET=%.3f failed: %s"
                                    % (axis, target, err))
        if triggered_at is None:
            raise FFToolOffsetError("ESTOP %s returned no position" % axis)
        return float(triggered_at)

    def _sampling(self, gcmd, axis_probe, single_touch):
        """klipper-toolchanger's probe sampling parameters.

        Defaults come from the fork's own [e_stop <axis>] settings, so a
        command with none of these passed probes exactly as it did before
        this was configurable: sub_cycle_cnt touches, spread rejected above
        error_v, retried main_cycle_cnt times, averaged. Upstream's
        LIFT_SPEED has no counterpart -- the retract between touches is
        along the probe axis, inside the fork's _probe, at PROBE_SPEED."""
        if self.samples is not None:
            default_samples = self.samples
        elif single_touch:
            default_samples = int(getattr(axis_probe, 'sub_cnt', 1) or 1)
        else:
            # run_probe already took sub_cycle_cnt of its own.
            default_samples = 1
        if self.samples_tolerance is not None:
            default_tolerance = self.samples_tolerance
        else:
            default_tolerance = float(getattr(axis_probe, 'err_v', 0.0))
        if self.samples_retries is not None:
            default_retries = self.samples_retries
        else:
            default_retries = int(getattr(axis_probe, 'main_cnt', 0) or 0)
        result = gcmd.get('SAMPLES_RESULT', self.samples_result).lower()
        if result not in ('average', 'median'):
            raise gcmd.error("SAMPLES_RESULT must be average or median")
        return {
            'samples': gcmd.get_int('SAMPLES', default_samples, minval=1),
            'tolerance': gcmd.get_float('SAMPLES_TOLERANCE',
                                        default_tolerance, minval=0.),
            'retries': gcmd.get_int('SAMPLES_TOLERANCE_RETRIES',
                                    default_retries, minval=0),
            'result': result,
            'retract': gcmd.get_float('SAMPLE_RETRACT_DIST',
                                      self.sample_retract_dist, above=0.),
            'speed': gcmd.get_float('PROBE_SPEED', self.probe_speed,
                                    above=0.),
        }

    def _estop(self, gcmd, axis, target):
        """ESTOP AXES=<axis> TARGET=<target>, sampled per _sampling()."""
        axis_probe = self.estop[axis]
        axis_probe.position_offset = target
        single_touch = hasattr(axis_probe, '_probe')
        opts = self._sampling(gcmd, axis_probe, single_touch)
        speed = opts['speed']
        if speed is None:
            speed = float(getattr(axis_probe, 'speed', 5.0))
        # The retract between touches is the fork's own back_v, so
        # SAMPLE_RETRACT_DIST is applied by lending it ours for the run.
        restore_back_v = None
        if opts['retract'] is not None and hasattr(axis_probe, 'back_v'):
            restore_back_v = axis_probe.back_v
            axis_probe.back_v = opts['retract']
        try:
            # Spread is judged after every touch, not at the end of the
            # round: the fork's run_probe does that, and a round already
            # known to be bad is not worth finishing.
            attempt = 0
            positions = []
            while len(positions) < opts['samples']:
                positions.append(self._touch(gcmd, axis_probe, axis,
                                             target, speed))
                if len(positions) < 2 or not opts['tolerance']:
                    continue
                spread = max(positions) - min(positions)
                if spread <= opts['tolerance']:
                    continue
                if attempt >= opts['retries']:
                    raise FFToolOffsetError(
                        "ESTOP %s TARGET=%.3f: sample spread %.4f over"
                        " samples_tolerance %.4f after %d retries (%s)"
                        % (axis, target, spread, opts['tolerance'],
                           attempt, ", ".join("%.4f" % p
                                              for p in positions)))
                attempt += 1
                gcmd.respond_info(
                    "  ESTOP %s spread %.4f over %.4f, retrying (%d/%d)"
                    % (axis, spread, opts['tolerance'], attempt,
                       opts['retries']))
                positions = []
        finally:
            if restore_back_v is not None:
                axis_probe.back_v = restore_back_v
        return _combine(positions, opts['result'])

    # ---------------- the recovered sequence ----------------

    def _four_points(self, gcmd, x0, y0, return_feed, pass2):
        """One 4-point pass around (x0, y0) at the current Z.

        Order and return moves are the app's: +X, +Y, -X, -Y, always from the
        centre outward, straight back through the centre between points (pass
        1: one G1 X Y F1200; pass 2: G1 Y then G1 X at F2400). No Z lift."""
        def back():
            if pass2:
                self._run('G1 Y%.3f F%d' % (y0, return_feed))
                self._run('G1 X%.3f F%d' % (x0, return_feed))
            else:
                self._run('G1 X%.3f Y%.3f F%d' % (x0, y0, return_feed))
            self._run('M400')

        reach = self.probe_travel
        x_plus = self._estop(gcmd, 'X', x0 + reach)
        back()
        y_plus = self._estop(gcmd, 'Y', y0 + reach)
        back()
        x_minus = self._estop(gcmd, 'X', x0 - reach)
        back()
        y_minus = self._estop(gcmd, 'Y', y0 - reach)
        back()
        points = [(x_plus, y0), (x0, y_plus), (x_minus, y0), (x0, y_minus)]
        for index, point in enumerate(points):
            gcmd.respond_info("  Point%d: %.4f, %.4f"
                              % (index + 1, point[0], point[1]))
        try:
            center_x, center_y, radius, residuals = fit_circle(points)
        except ValueError as err:
            raise FFToolOffsetError("circle fit failed: %s" % err)
        worst_residual = max(abs(residual) for residual in residuals)
        gcmd.respond_info("  centre %.4f, %.4f  radius %.4f  max residual %.4f"
                          % (center_x, center_y, radius, worst_residual))
        if self.max_residual and worst_residual > self.max_residual:
            raise FFToolOffsetError(
                "fit residual %.4f exceeds max_residual %.4f -- a probe"
                " mis-triggered; nothing saved"
                % (worst_residual, self.max_residual))
        if self.min_radius and radius < self.min_radius:
            raise FFToolOffsetError("fitted radius %.4f below min_radius"
                                    % radius)
        if self.max_radius and radius > self.max_radius:
            raise FFToolOffsetError("fitted radius %.4f above max_radius"
                                    % radius)
        return center_x, center_y, radius

    def _z_target_for(self, nominal, expected):
        """Stop z_margin below a known trigger height instead of going all
        the way to the nominal target."""
        if expected is None:
            return nominal
        return max(nominal, expected - self.z_margin)

    def _plate_check(self, gcmd):
        """Empty-carriage look at the station before anything descends with
        a nozzle.

        This is the ONLY guard that the build plate is off, and deliberately
        so: it measures, where the PLATE_REMOVED=1 flag it replaced only
        asked the operator to promise. The station's sensor sees the
        circle's edge when nothing covers it; with the build plate on, the Z
        probe lands on the sheet (or never triggers) and the sideways probe
        finds no edge. Raises FFToolOffsetError either way, so nothing is
        damaged and nothing is saved. Runs inside _with_accel_guard."""
        cylinder_x, cylinder_y = self._cylinder()
        expected_z = self.station[2] if self.station is not None else None
        z_target = self._z_target_for(self.z_target, expected_z)
        self._enter_raw_frame()
        self._run('M400')
        self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
        self._run('G1 X%.3f Y%.3f F%d'
                  % (cylinder_x, cylinder_y, FEED_POSITION))
        self._run('SET_VELOCITY_LIMIT ACCEL=%.0f' % self.probe_accel)
        self._run('M400')
        hint = (" -- is the build plate still on? Nothing has moved with"
                " a nozzle. Remove the plate, or plate_check: False in"
                " [ff_tool_offset] if you are sure.")
        try:
            station_z = self._estop(gcmd, 'Z', z_target)
        except FFToolOffsetError as err:
            raise FFToolOffsetError("plate check: station Z probe failed"
                                    " (%s)%s" % (err, hint))
        gcmd.respond_info("  plate check: station Z %.3f" % station_z)
        if expected_z is not None \
           and station_z > expected_z + self.plate_z_tolerance:
            raise FFToolOffsetError(
                "plate check: station Z %.3f is %.2f mm above the"
                " calibrated %.3f%s"
                % (station_z, station_z - expected_z, expected_z, hint))
        self._run('G1 X%.3f Y%.3f F%d' % (cylinder_x, cylinder_y, FEED_PASS1))
        self._run('G1 Z%.3f F%d' % (station_z + self.z_clear, FEED_PASS1))
        self._run('M400')
        try:
            edge_x = self._estop(gcmd, 'X', cylinder_x + self.probe_travel)
        except FFToolOffsetError as err:
            raise FFToolOffsetError(
                "plate check: no circle edge within %.0f mm of the start"
                " point (%s)%s" % (self.probe_travel, err, hint))
        self._run('G1 X%.3f F%d' % (cylinder_x, FEED_PASS1))
        self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
        self._run('M400')
        gcmd.respond_info("  plate check: circle edge at X %.3f (%+.2f from"
                          " the start point) -- plate is off"
                          % (edge_x, edge_x - cylinder_x))

    def _run_plate_check(self, gcmd):
        """Park whatever is mounted, then _plate_check. Shared prologue of
        both calibration commands; PLATE_CHECK=0 on the command skips it.

        Returns True when the check ran -- the carriage is then empty, and
        TOOL_CALIBRATE_TOOL_OFFSET has to pick its tool back up."""
        if not gcmd.get_int('PLATE_CHECK', 1 if self.plate_check else 0,
                            minval=0, maxval=1):
            return False
        if self.toolchange is not None:
            carriage = self.toolchange.get_status(self.reactor.monotonic())
            if carriage.get('current_tool', -1) != -1:
                self._run('TOOLCHANGE_PARK')
                self._wait_moves()
            carriage = self.toolchange.get_status(self.reactor.monotonic())
            if carriage.get('current_tool', -1) != -1 \
               or not carriage.get('state_ok'):
                raise gcmd.error(
                    "%s: carriage is not verifiably empty (%s) -- cannot run"
                    " the plate check"
                    % (self.name, carriage.get('state_reason')))
        self._with_accel_guard(gcmd, lambda: self._plate_check(gcmd))
        return True

    def _two_pass(self, gcmd, x0, y0, z_target_2, expected_z=None):
        """moveCylinderPos + both passes.

        Returns (center_x_pass2, center_y_pass2, z_trigger_pass2).

        Caller has already put the right thing on the carriage (tool or
        nothing) and ensured we are homed. expected_z, when known, bounds
        both Z probes to expected_z - z_margin."""
        z_target_pass1 = self._z_target_for(self.z_target, expected_z)
        z_target_pass2 = self._z_target_for(z_target_2, expected_z)
        # moveCylinderPos: out of both frames (the grab put this tool's
        # offsets in the transform), lift, travel, Z probe.
        self._enter_raw_frame()
        self._run('M400')
        self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
        self._run('G1 X%.3f Y%.3f F%d' % (x0, y0, FEED_POSITION))
        self._run('SET_VELOCITY_LIMIT ACCEL=%.0f' % self.probe_accel)
        self._run('M400')
        self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
        gcmd.respond_info("  Z probe to %.3f" % z_target_pass1)
        z_trigger = self._estop(gcmd, 'Z', z_target_pass1)
        gcmd.respond_info("  Z probe pos: %.4f" % z_trigger)

        # pass 1
        self._run('G1 X%.3f Y%.3f F%d' % (x0, y0, FEED_PASS1))
        self._run('G1 Z%.3f F%d' % (z_trigger + self.z_clear, FEED_PASS1))
        self._run('M400')
        gcmd.respond_info(" pass 1 around %.3f, %.3f at Z %.3f"
                          % (x0, y0, z_trigger + self.z_clear))
        center_x, center_y, _radius = self._four_points(
            gcmd, x0, y0, FEED_PASS1, False)
        # G-code is formatted to 3 decimals (the app's float_to_string(v, 3)),
        # so the centre we actually return to is the rounded one; use that
        # for the pass-2 point coordinates too.
        center_x, center_y = round(center_x, 3), round(center_y, 3)

        # pass 2: centred on the fit, Z re-probed there
        self._run('G1 Z%.3f F%d' % (z_trigger + self.z_lift, FEED_PASS1))
        self._run('G1 Y%.3f F%d' % (center_y, FEED_PASS2))
        self._run('G1 X%.3f F%d' % (center_x, FEED_PASS2))
        self._run('M400')
        z_trigger_pass2 = self._estop(
            gcmd, 'Z', self._z_target_for(z_target_pass2, z_trigger))
        gcmd.respond_info("  double Z probe pos: %.4f" % z_trigger_pass2)
        self._run('G1 Z%.3f F%d'
                  % (z_trigger_pass2 + self.z_clear, FEED_PASS1))
        self._run('M400')
        gcmd.respond_info(" pass 2 around %.3f, %.3f at Z %.3f"
                          % (center_x, center_y,
                             z_trigger_pass2 + self.z_clear))
        center_x_pass2, center_y_pass2, _radius_pass2 = self._four_points(
            gcmd, center_x, center_y, FEED_PASS2, True)

        self._run('G1 Z%.3f F%d' % (self.z_final, FEED_PASS1))
        self._run('M400')
        return center_x_pass2, center_y_pass2, z_trigger_pass2

    def _with_accel_guard(self, gcmd, body):
        """Run body() with the app's exit block guaranteed: lift, restore
        accel. The app does G1 Z10 on an ESTOP failure and Z15 on success."""
        restore = self.accel_restore
        if restore is None:
            restore = self._current_accel()
        try:
            return body()
        except FFToolOffsetError as err:
            try:
                self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
                self._run('M400')
            except self.printer.command_error:
                pass
            raise gcmd.error("%s: %s" % (self.name, err))
        finally:
            try:
                self._run('SET_VELOCITY_LIMIT ACCEL=%.0f' % restore)
            except self.printer.command_error:
                pass

    # ---------------- persistence ----------------

    def set_station(self, x, y, z):
        self.station = (float(x), float(y), float(z))
        configfile = self.printer.lookup_object('configfile')
        configfile.set(self.name, 'station_x', "%.6f" % x)
        configfile.set(self.name, 'station_y', "%.6f" % y)
        configfile.set(self.name, 'station_z', "%.6f" % z)

    def _restore_offset_frame(self, gcmd):
        """Undo _enter_raw_frame: both frames back as they were."""
        self._leave_raw_frame(gcmd)

    def _refresh_toolchange(self, gcmd):
        if self.toolchange is not None \
           and hasattr(self.toolchange, 'refresh_offsets'):
            self.toolchange.refresh_offsets(gcmd)

    # ---------------- commands ----------------

    cmd_TOOL_CALIBRATE_TOOL_OFFSET_help = (
        "Measure the MOUNTED tool's nozzle position against the station "
        "([SAVE=1] [PLATE_CHECK=1] [SAMPLES=] [SAMPLES_TOLERANCE=]"
        " [SAMPLES_TOLERANCE_RETRIES=] [SAMPLES_RESULT=]"
        " [SAMPLE_RETRACT_DIST=] [PROBE_SPEED=])")

    def cmd_TOOL_CALIBRATE_TOOL_OFFSET(self, gcmd):
        """klipper-toolchanger's signature: no arguments, measures whatever
        is on the carriage. Select the tool first (SELECT_TOOL T=<n>, or
        T<n>), exactly as upstream's CALIBRATE_TOOL_OFFSETS loop does."""
        if self.toolchange is None:
            raise gcmd.error("%s: [ff_toolchange] not loaded -- there is no"
                             " mounted tool to measure." % self.name)
        tool = self.toolchange.get_status(
            self.reactor.monotonic()).get('current_tool', -1)
        if tool < 0:
            raise gcmd.error(
                "%s: no tool is mounted. SELECT_TOOL T=<0..%d> first --"
                " this measures the tool on the carriage, and with an empty"
                " one it would save the bare carriage as a nozzle position,"
                " ~3.2 mm out in the crash direction. (TOOL_LOCATE_SENSOR"
                " is the command that wants an empty carriage.)"
                % (self.name, EXTRUDER_COUNT - 1))
        save = gcmd.get_int('SAVE', 1, minval=0, maxval=1)
        try:
            self._check_homed(gcmd)
            # The plate check has to measure an EMPTY carriage, so it parks the
            # tool we were asked about. Pick it straight back up.
            if self._run_plate_check(gcmd):
                self._run('T%d' % tool)
                self._wait_moves()
            cylinder_x, cylinder_y = self._cylinder()
            x0, y0 = cylinder_x - self.nozzle_x_shift, cylinder_y
            gcmd.respond_info("T%d: offset calibration, start %.3f, %.3f"
                              % (tool, x0, y0))

            tool_object = self.tools[tool]
            expected_z = (tool_object.nozzle[2]
                          if tool_object.calibrated() else None)
            if expected_z is None and self.station is not None:
                # nozzle fires ~3.2 mm above the empty-carriage trigger
                expected_z = self.station[2] + 0.5 * (self.gap_min
                                                      + self.gap_max)

            def body():
                return self._two_pass(gcmd, x0, y0, self.z_target, expected_z)
            center_x, center_y, z_trigger = self._with_accel_guard(gcmd, body)
            if self.station is not None and (self.gap_min or self.gap_max):
                gap = z_trigger - self.station[2]
                if gap < self.gap_min or gap > self.gap_max:
                    raise gcmd.error(
                        "%s: T%d nozzle_z %.3f is %.3f above station_z %.3f,"
                        " outside gap_min/gap_max [%.2f, %.2f] -- probe"
                        " mis-trigger suspected, nothing saved"
                        % (self.name, tool, z_trigger, gap, self.station[2],
                           self.gap_min, self.gap_max))
            results = {tool: (center_x, center_y, z_trigger)}
            self.last['t%d' % tool] = (center_x, center_y, z_trigger)
            gcmd.respond_info("T%d: offset = (%.4f, %.4f, %.4f)"
                              % (tool, center_x, center_y, z_trigger))
            # Staged only once the guards above have passed, so a failed run
            # really does leave nothing saved -- which is what they promise.
            if save:
                tool_object.set_nozzle(center_x, center_y, z_trigger)

            # the app's exit block: heater off for the tool, Z15
            self._run('M104 S0 T%d' % tool)
            self._run('G1 Z%.3f F%d' % (self.z_final, FEED_PASS1))
            self._run('M400')
            if save:
                self._refresh_toolchange(gcmd)
                gcmd.respond_info(
                    "The SAVE_CONFIG command will update the printer"
                    " config file with the new nozzle position and restart"
                    " the printer.")
            # Probing zeroed the G-code offsets to work in raw coordinates. Put
            # the frame back before handing control to the operator: the
            # tool stays on the carriage, and leaving Z=0 at the eddy plane
            # means the next jog to Z0 puts the nozzle into the plate.
            self._restore_offset_frame(gcmd)
            self._report_diffs(gcmd, results)
        finally:
            # Both frames go back even when a probe raised: leaving the
            # G-code offset zeroed and the tool frame off puts Z=0 at the
            # eddy plane, ~3.2 mm into the plate, for whatever the
            # operator jogs next.
            self._leave_raw_frame()

    cmd_TOOL_LOCATE_SENSOR_help = (
        "Locate the station with an EMPTY carriage (station_x/y/z) "
        "([PARK=1] [SAVE=1] [PLATE_CHECK=1] [SAMPLES=] [SAMPLES_TOLERANCE=]"
        " [SAMPLES_TOLERANCE_RETRIES=] [SAMPLES_RESULT=]"
        " [SAMPLE_RETRACT_DIST=] [PROBE_SPEED=])")

    def cmd_TOOL_LOCATE_SENSOR(self, gcmd):
        park = gcmd.get_int('PARK', 1, minval=0, maxval=1)
        save = gcmd.get_int('SAVE', 1, minval=0, maxval=1)
        try:
            self._check_homed(gcmd)
            if self.toolchange is not None:
                if park:
                    # releaseFourExtruder: the carriage must be empty for TS.
                    self._run('TOOLCHANGE_PARK')
                    self._wait_moves()
                carriage = self.toolchange.get_status(self.reactor.monotonic())
                if carriage.get('current_tool', -1) != -1 \
                   or not carriage.get('state_ok'):
                    raise gcmd.error(
                        "%s: carriage is not verifiably empty (%s) -- the"
                        " station pass must run with no tool mounted"
                        % (self.name, carriage.get('state_reason')))
            elif park:
                raise gcmd.error("%s: [ff_toolchange] not loaded -- park"
                                 " the tool by hand and pass PARK=0."
                                 % self.name)
            self._run_plate_check(gcmd)
            cylinder_x, cylinder_y = self._cylinder()
            gcmd.respond_info("station calibration, start %.3f, %.3f"
                              % (cylinder_x, cylinder_y))

            expected_z = self.station[2] if self.station is not None else None

            def body():
                return self._two_pass(gcmd, cylinder_x, cylinder_y,
                                      self.z_target_station_2, expected_z)
            center_x, center_y, z_trigger = self._with_accel_guard(gcmd, body)
            self.last['station'] = (center_x, center_y, z_trigger)
            gcmd.respond_info("station = (%.4f, %.4f, %.4f)"
                              % (center_x, center_y, z_trigger))
            if save:
                self.set_station(center_x, center_y, z_trigger)
                self._refresh_toolchange(gcmd)
                gcmd.respond_info(
                    "The SAVE_CONFIG command will update the printer"
                    " config file with the new station position and restart"
                    " the printer.")
            # Usually nothing to re-apply -- this runs with an empty
            # carriage -- but the probing zeroed the operator's G-code
            # offset all the same, and that has to go back.
            self._restore_offset_frame(gcmd)
        finally:
            # Both frames go back even when a probe raised: leaving the
            # G-code offset zeroed and the tool frame off puts Z=0 at the
            # eddy plane, ~3.2 mm into the plate, for whatever the
            # operator jogs next.
            self._leave_raw_frame()

    cmd_TOOL_OFFSET_STATUS_help = "Show the configured nozzle/station positions"

    def cmd_TOOL_OFFSET_STATUS(self, gcmd):
        cylinder_x, cylinder_y = self._cylinder()
        lines = ["station start (cylinder_x/y): %.3f, %.3f"
                 % (cylinder_x, cylinder_y)]
        for tool in self.tools:
            if tool.calibrated():
                lines.append("[ff_tool %d] nozzle %.4f, %.4f, %.4f"
                             % (tool.index, tool.nozzle[0], tool.nozzle[1],
                                tool.nozzle[2]))
            else:
                lines.append("[ff_tool %d] nozzle NOT CALIBRATED" % tool.index)
        if self.station is not None:
            lines.append("[%s] station %.4f, %.4f, %.4f"
                         % ((self.name,) + self.station))
        else:
            lines.append("[%s] station NOT CALIBRATED" % self.name)
        configfile = self.printer.lookup_object('configfile')
        configfile_status = configfile.get_status(self.reactor.monotonic())
        if configfile_status.get('save_config_pending'):
            lines.append("! unsaved calibration pending -- run SAVE_CONFIG")
        gcmd.respond_info("\n".join(lines))

    def _report_diffs(self, gcmd, results):
        """What this run measured, and what a toolchange applies with it.

        The measured lines are the raw fit: the station-bore centre in
        machine coordinates and the nozzle's Z trigger height. The offsets
        table mirrors ff_toolchange._derive_offsets exactly: X/Y are
        differences against the toolchanger's base tool (offset_base,
        default T0), and Z is the ABSOLUTE offset every grab applies when a
        station calibration exists -- z_adjust + (nozzle_z - station_z),
        the tool's nozzle-to-eddy-trigger gap -- falling back to the
        base-relative form without one. The base tool's dX/dY are zero by
        definition; its Z is not."""
        base_tool = (self.toolchange.offset_base
                     if self.toolchange is not None else 0)
        lines = []
        for tool, (center_x, center_y, z_trigger) in sorted(results.items()):
            lines.append("T%d measured: nozzle centre %.4f, %.4f"
                         "  Z trigger %.4f"
                         % (tool, center_x, center_y, z_trigger))
        base_nozzle = None
        if base_tool in results:
            base_nozzle = results[base_tool]
        elif self.tools[base_tool].calibrated():
            base_nozzle = self.tools[base_tool].nozzle
        z_station = self.station[2] if self.station is not None else None
        if base_nozzle is not None:
            lines.append("offsets a toolchange applies (X/Y vs T%d; Z %s):"
                         % (base_tool,
                            "absolute: nozzle_z - station_z + z_adjust"
                            if z_station is not None
                            else "vs T%d, + z_adjust" % base_tool))
            for tool, (center_x, center_y, z_trigger) in sorted(
                    results.items()):
                z_adjust = self.tools[tool].z_adjust
                if z_station is not None:
                    z_applied = z_adjust + (z_trigger - z_station)
                else:
                    z_applied = z_adjust + (z_trigger - base_nozzle[2])
                lines.append("  T%d: dX %+.4f  dY %+.4f  Z %+.4f"
                             % (tool, center_x - base_nozzle[0],
                                center_y - base_nozzle[1], z_applied))
        gcmd.respond_info("\n".join(lines))

    def get_status(self, eventtime):
        measured = {}
        for what, position in self.last.items():
            measured[what] = {'x': position[0], 'y': position[1],
                              'z': position[2]}
        station_x, station_y, station_z = (self.station if self.station
                                           else (None, None, None))
        return {'last': measured, 'station_x': station_x,
                'station_y': station_y, 'station_z': station_z}


def load_config(config):
    return FFToolOffset(config)
