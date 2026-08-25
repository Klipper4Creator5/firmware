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
# The physical setup: a fixed inductive "cylinder" station under the bed
# (levelboard PD0, exposed to Klipper as [e_stop X]/[e_stop Y]/[e_stop Z] --
# one pin, three axis wrappers). The nozzle is lowered into its bore until the
# sensor fires (Z), then driven outward from the bore centre along +X, +Y, -X,
# -Y until the bore wall fires it. Four boundary points -> least-squares circle
# -> the bore axis in this tool's nozzle frame. Done twice (the second pass is
# centred on the first fit and re-probes Z there); the second result is stored
# as [ff_tool n]'s nozzle_x/nozzle_y/nozzle_z -- RAW machine coordinates with
# the G-code offset
# zeroed, nothing subtracted. Tool-to-tool differences of those are what the
# toolchanger applies (ff_toolchange._derive_offsets).
#
# The same pass with an EMPTY carriage measures x/y/z_station_pos ("TS" in the
# app's CSV). z_station_pos is the eddy-frame reference the print-start Z
# offset is computed against (TOOLCHANGE_SET_PRINT_OFFSET), so it must be
# measured with the same station and the same mechanics as the tools.
#
# Results are stored the way Klipper's own calibrators store theirs
# (PID_CALIBRATE, SHAPER_CALIBRATE, PROBE_CALIBRATE): configfile.set() into
# the SAVE_CONFIG block of printer.cfg --
#   [ff_tool <n>]     nozzle_x / nozzle_y / nozzle_z   (ff_tool.py)
#   [ff_tool_offset]  station_x / station_y / station_z
# applied live at once and persisted by SAVE_CONFIG (which restarts).
# firmwareExe's extruder.json is not touched; ff_legacy.py can import it once.
#
# This is a Python extra rather than a macro because each ESTOP result feeds
# the next move (the second pass is centred on the first fit) and a gcode_macro
# renders its whole template before anything executes.

import logging
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
# Circle fit
#
# Port of BaseFunction::fitCircleStable @0x6467f8 (centroid-shifted algebraic
# least squares, cv::solve DECOMP_LU on the 3x3 normal equations):
#     A = [2x', 2y', 1],  b = x'^2 + y'^2,  (A^T A) p = A^T b
#     centre = (p0 + xbar, p1 + ybar),  r = sqrt(p2 + p0^2 + p1^2)
# The shipped variant calls fitCircleByLeastSquares @0x645b10, the same
# algebraic fit without the centroid shift; for the 4 symmetric points the
# sequence produces both reduce to cx = (px1+px3)/2, cy = (py2+py4)/2. We
# keep the shifted form for numerical hygiene and accept >= 3 points.
# Pure Python on purpose: numpy is not guaranteed on the X2000 rootfs.
# ---------------------------------------------------------------------------

def fit_circle(points):
    """Return (cx, cy, r, residuals); raise ValueError if unfittable."""
    n = len(points)
    if n < 3:
        raise ValueError("circle fit needs at least 3 points, got %d" % n)
    xbar = sum(p[0] for p in points) / n
    ybar = sum(p[1] for p in points) / n
    m = [[0.0] * 3 for _ in range(3)]
    v = [0.0] * 3
    for x, y in points:
        xs, ys = x - xbar, y - ybar
        row = (2.0 * xs, 2.0 * ys, 1.0)
        b = xs * xs + ys * ys
        for i in range(3):
            v[i] += row[i] * b
            for j in range(3):
                m[i][j] += row[i] * row[j]
    p = _solve3(m, v)
    if p is None:
        raise ValueError("circle fit is singular (points collinear?)")
    cx, cy = p[0] + xbar, p[1] + ybar
    rr = p[2] + p[0] * p[0] + p[1] * p[1]
    if rr <= 0.0:
        raise ValueError("circle fit gave radius^2 = %.6f" % rr)
    r = math.sqrt(rr)
    resid = [math.hypot(x - cx, y - cy) - r for x, y in points]
    return cx, cy, r, resid


def _solve3(m, v):
    a = [m[i][:] + [v[i]] for i in range(3)]
    for c in range(3):
        piv = max(range(c, 3), key=lambda r: abs(a[r][c]))
        if abs(a[piv][c]) < 1e-12:
            return None
        a[c], a[piv] = a[piv], a[c]
        for r in range(3):
            if r != c:
                f = a[r][c] / a[c][c]
                for k in range(c, 4):
                    a[r][k] -= f * a[c][k]
    return [a[i][3] / a[i][i] for i in range(3)]


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
        # None = restore the accel limit that was live when we started
        # (same policy as ff_toolchange); set to force the app's 20000.
        self.accel_restore = config.getfloat('accel_restore', None)
        # Residual guard. The app has NONE -- any four numbers are accepted.
        # A point off the fitted circle is what a mis-trigger looks like;
        # abort without saving. With four symmetric points one bad point of
        # error e shows up as a residual of only ~e/4 while moving the centre
        # by e/2, so 0.05 here catches centre errors of ~0.1 mm. 0 disables.
        self.max_residual = config.getfloat('max_residual', 0.05, minval=0.)
        # Sanity window for the fitted bore radius (0 disables).
        self.min_radius = config.getfloat('min_radius', 0.0, minval=0.)
        self.max_radius = config.getfloat('max_radius', 0.0, minval=0.)
        # Plausibility of nozzle_z against station_z: the nozzle fires the
        # station ~3.2 mm above where the empty carriage does (this unit
        # 3.19). A value far outside that means a bad probe, and a bad
        # nozzle_z is exactly what drives the first layer into the plate.
        # Checked only when station_z is known. 0 disables.
        self.gap_min = config.getfloat('gap_min', 1.5)
        self.gap_max = config.getfloat('gap_max', 5.0)
        # Plate check (empty carriage, before any nozzle descends): the
        # station Z must not land more than plate_z_tolerance ABOVE the
        # calibrated station_z -- one-sided, because a plate can only hold the
        # probe high -- and a sideways probe must find the circle's edge. With
        # the build plate still on, the Z probe stops high on the sheet (or
        # never triggers) and there is no edge. 0 disables the check.
        self.plate_check = config.getboolean('plate_check', True)
        self.plate_z_tolerance = config.getfloat('plate_z_tolerance', 0.8,
                                                 above=0.)

        # Station position measured with the empty carriage
        # (STATION_CALIBRATE), autosaved here as station_x/y/z.
        sx = config.getfloat('station_x', None)
        sy = config.getfloat('station_y', None)
        sz = config.getfloat('station_z', None)
        if (sx, sy, sz) != (None, None, None) and None in (sx, sy, sz):
            raise config.error("%s: station_x, station_y and station_z must"
                               " be set together" % self.name)
        self.station = None if sx is None else (sx, sy, sz)

        self.estop = {}
        self.tools = []
        for i in range(EXTRUDER_COUNT):
            self.tools.append(self.printer.load_object(config, 'ff_tool %d' % i))
        self.toolchange = None
        self.last = {}

        self.gcode.register_command(
            'TOOL_OFFSET_CALIBRATE', self.cmd_TOOL_OFFSET_CALIBRATE,
            desc=self.cmd_TOOL_OFFSET_CALIBRATE_help)
        self.gcode.register_command(
            'STATION_CALIBRATE', self.cmd_STATION_CALIBRATE,
            desc=self.cmd_STATION_CALIBRATE_help)
        self.gcode.register_command(
            'TOOL_OFFSET_STATUS', self.cmd_TOOL_OFFSET_STATUS,
            desc=self.cmd_TOOL_OFFSET_STATUS_help)
        self.printer.register_event_handler('klippy:connect',
                                            self._handle_connect)

    # ---------------- plumbing ----------------

    def _handle_connect(self):
        missing = []
        for axis in 'XYZ':
            obj = self.printer.lookup_object('e_stop %s' % axis, None)
            if obj is None or not hasattr(obj, 'run_probe'):
                missing.append('e_stop %s' % axis)
            self.estop[axis] = obj
        if missing:
            raise self.printer.config_error(
                "%s: required sections not found: %s (the station sensor is"
                " exposed through the fork's [e_stop X|Y|Z])"
                % (self.name, ", ".join(missing)))
        self.toolchange = self.printer.lookup_object('ff_toolchange', None)

    def _run(self, script):
        self.gcode.run_script_from_command(script)

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
        th = self.printer.lookup_object('toolhead')
        homed = th.get_status(self.reactor.monotonic())['homed_axes']
        if not all(a in homed for a in 'xyz'):
            raise gcmd.error("%s: home all axes first (homed: '%s')"
                             % (self.name, homed))

    def _current_accel(self):
        th = self.printer.lookup_object('toolhead')
        return th.get_status(self.reactor.monotonic())['max_accel']

    def _estop(self, gcmd, axis, target):
        """One ESTOP AXES=<axis> TARGET=<target>, calling the fork's e_stop
        object directly instead of parsing its JSON reply. Same code path as
        the command: run_probe() takes sub_cycle_cnt samples (3 in
        printer.base.cfg) each retracting back_v, rejects a spread above
        error_v, and raises on no-trigger / triggered-before-move."""
        obj = self.estop[axis]
        obj.position_offset = target
        try:
            pos = obj.run_probe(gcmd)
        except self.printer.command_error as e:
            raise FFToolOffsetError("ESTOP %s TARGET=%.3f failed: %s"
                                    % (axis, target, e))
        if pos is None:
            raise FFToolOffsetError("ESTOP %s returned no position" % axis)
        return float(pos)

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

        d = self.probe_travel
        px1 = self._estop(gcmd, 'X', x0 + d)
        back()
        py2 = self._estop(gcmd, 'Y', y0 + d)
        back()
        px3 = self._estop(gcmd, 'X', x0 - d)
        back()
        py4 = self._estop(gcmd, 'Y', y0 - d)
        back()
        pts = [(px1, y0), (x0, py2), (px3, y0), (x0, py4)]
        for i, p in enumerate(pts):
            gcmd.respond_info("  Point%d: %.4f, %.4f" % (i + 1, p[0], p[1]))
        try:
            cx, cy, r, resid = fit_circle(pts)
        except ValueError as e:
            raise FFToolOffsetError("circle fit failed: %s" % e)
        worst = max(abs(e) for e in resid)
        gcmd.respond_info("  centre %.4f, %.4f  radius %.4f  max residual %.4f"
                          % (cx, cy, r, worst))
        if self.max_residual and worst > self.max_residual:
            raise FFToolOffsetError(
                "fit residual %.4f exceeds max_residual %.4f -- a probe"
                " mis-triggered; nothing saved" % (worst, self.max_residual))
        if self.min_radius and r < self.min_radius:
            raise FFToolOffsetError("fitted radius %.4f below min_radius" % r)
        if self.max_radius and r > self.max_radius:
            raise FFToolOffsetError("fitted radius %.4f above max_radius" % r)
        return cx, cy, r

    def _z_target_for(self, nominal, expected):
        """Stop z_margin below a known trigger height instead of going all
        the way to the nominal target."""
        if expected is None:
            return nominal
        return max(nominal, expected - self.z_margin)

    def _require_plate_removed(self, gcmd):
        if not gcmd.get_int('PLATE_REMOVED', 0, minval=0, maxval=1):
            raise gcmd.error(
                "%s: the station sits BELOW the bed plane and the Z probe"
                " cannot tell a build plate from thin air. Take the PEI sheet"
                " off, then repeat with PLATE_REMOVED=1." % self.name)

    def _plate_check(self, gcmd):
        """Empty-carriage look at the station before anything descends with
        a nozzle -- PLATE_REMOVED=1 is only a promise. The station's sensor
        sees the circle's edge when nothing covers it; with the build plate
        on, the Z probe lands on the sheet (or never triggers) and the
        sideways probe finds no edge. Raises FFToolOffsetError either way,
        so nothing is damaged and nothing is saved. Runs inside
        _with_accel_guard."""
        cyl_x, cyl_y = self._cylinder()
        expected = self.station[2] if self.station is not None else None
        z_t = self._z_target_for(self.z_target, expected)
        self._run('SET_GCODE_OFFSET X=0 Y=0 Z=0 MOVE=0 MOVE_SPEED=600')
        self._run('M400')
        self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
        self._run('G1 X%.3f Y%.3f F%d' % (cyl_x, cyl_y, FEED_POSITION))
        self._run('SET_VELOCITY_LIMIT ACCEL=%.0f' % self.probe_accel)
        self._run('M400')
        hint = (" -- is the build plate still on? Nothing has moved with"
                " a nozzle. Remove the plate, or plate_check: False in"
                " [ff_tool_offset] if you are sure.")
        try:
            zp = self._estop(gcmd, 'Z', z_t)
        except FFToolOffsetError as e:
            raise FFToolOffsetError("plate check: station Z probe failed"
                                    " (%s)%s" % (e, hint))
        gcmd.respond_info("  plate check: station Z %.3f" % zp)
        if expected is not None and zp > expected + self.plate_z_tolerance:
            raise FFToolOffsetError(
                "plate check: station Z %.3f is %.2f mm above the"
                " calibrated %.3f%s" % (zp, zp - expected, expected, hint))
        self._run('G1 X%.3f Y%.3f F%d' % (cyl_x, cyl_y, FEED_PASS1))
        self._run('G1 Z%.3f F%d' % (zp + self.z_clear, FEED_PASS1))
        self._run('M400')
        try:
            px = self._estop(gcmd, 'X', cyl_x + self.probe_travel)
        except FFToolOffsetError as e:
            raise FFToolOffsetError(
                "plate check: no circle edge within %.0f mm of the start"
                " point (%s)%s" % (self.probe_travel, e, hint))
        self._run('G1 X%.3f F%d' % (cyl_x, FEED_PASS1))
        self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
        self._run('M400')
        gcmd.respond_info("  plate check: circle edge at X %.3f (%+.2f from"
                          " the start point) -- plate is off" % (px, px - cyl_x))

    def _run_plate_check(self, gcmd):
        """Park whatever is mounted, then _plate_check. Shared prologue of
        both calibration commands; PLATE_CHECK=0 on the command skips it."""
        if not gcmd.get_int('PLATE_CHECK', 1 if self.plate_check else 0,
                            minval=0, maxval=1):
            return
        if self.toolchange is not None:
            cur = self.toolchange.get_status(self.reactor.monotonic())
            if cur.get('current_tool', -1) != -1:
                self._run('TOOLCHANGE_PARK')
                self._wait_moves()
            cur = self.toolchange.get_status(self.reactor.monotonic())
            if cur.get('current_tool', -1) != -1 or not cur.get('state_ok'):
                raise gcmd.error(
                    "%s: carriage is not verifiably empty (%s) -- cannot run"
                    " the plate check" % (self.name, cur.get('state_reason')))
        self._with_accel_guard(gcmd, lambda: self._plate_check(gcmd))

    def _two_pass(self, gcmd, x0, y0, z_target_2, expected_z=None):
        """moveCylinderPos + both passes. Returns (cx2, cy2, zP2).

        Caller has already put the right thing on the carriage (tool or
        nothing) and ensured we are homed. expected_z, when known, bounds
        both Z probes to expected_z - z_margin."""
        z_t1 = self._z_target_for(self.z_target, expected_z)
        z_t2 = self._z_target_for(z_target_2, expected_z)
        # moveCylinderPos: zero the G-code offset (the grab applied this
        # tool's SET_GCODE_OFFSET), lift, travel, Z probe.
        self._run('SET_GCODE_OFFSET X=0 Y=0 Z=0 MOVE=0 MOVE_SPEED=600')
        self._run('M400')
        self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
        self._run('G1 X%.3f Y%.3f F%d' % (x0, y0, FEED_POSITION))
        self._run('SET_VELOCITY_LIMIT ACCEL=%.0f' % self.probe_accel)
        self._run('M400')
        self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
        gcmd.respond_info("  Z probe to %.3f" % z_t1)
        zp = self._estop(gcmd, 'Z', z_t1)
        gcmd.respond_info("  Z probe pos: %.4f" % zp)

        # pass 1
        self._run('G1 X%.3f Y%.3f F%d' % (x0, y0, FEED_PASS1))
        self._run('G1 Z%.3f F%d' % (zp + self.z_clear, FEED_PASS1))
        self._run('M400')
        gcmd.respond_info(" pass 1 around %.3f, %.3f at Z %.3f"
                          % (x0, y0, zp + self.z_clear))
        cx, cy, _r = self._four_points(gcmd, x0, y0, FEED_PASS1, False)
        # G-code is formatted to 3 decimals (the app's float_to_string(v, 3)),
        # so the centre we actually return to is the rounded one; use that
        # for the pass-2 point coordinates too.
        cx, cy = round(cx, 3), round(cy, 3)

        # pass 2: centred on the fit, Z re-probed there
        self._run('G1 Z%.3f F%d' % (zp + self.z_lift, FEED_PASS1))
        self._run('G1 Y%.3f F%d' % (cy, FEED_PASS2))
        self._run('G1 X%.3f F%d' % (cx, FEED_PASS2))
        self._run('M400')
        zp2 = self._estop(gcmd, 'Z', self._z_target_for(z_t2, zp))
        gcmd.respond_info("  double Z probe pos: %.4f" % zp2)
        self._run('G1 Z%.3f F%d' % (zp2 + self.z_clear, FEED_PASS1))
        self._run('M400')
        gcmd.respond_info(" pass 2 around %.3f, %.3f at Z %.3f"
                          % (cx, cy, zp2 + self.z_clear))
        cx2, cy2, _r2 = self._four_points(gcmd, cx, cy, FEED_PASS2, True)

        self._run('G1 Z%.3f F%d' % (self.z_final, FEED_PASS1))
        self._run('M400')
        return cx2, cy2, zp2

    def _with_accel_guard(self, gcmd, body):
        """Run body() with the app's exit block guaranteed: lift, restore
        accel. The app does G1 Z10 on an ESTOP failure and Z15 on success."""
        restore = self.accel_restore
        if restore is None:
            restore = self._current_accel()
        try:
            return body()
        except FFToolOffsetError as e:
            try:
                self._run('G1 Z%.3f F%d' % (self.z_start, FEED_PASS1))
                self._run('M400')
            except self.printer.command_error:
                pass
            raise gcmd.error("%s: %s" % (self.name, e))
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
        """Undo _two_pass's SET_GCODE_OFFSET zeroing (see ff_toolchange)."""
        if self.toolchange is not None \
           and hasattr(self.toolchange, 'reapply_offsets_after_external_zero'):
            self.toolchange.reapply_offsets_after_external_zero(gcmd)

    def _refresh_toolchange(self, gcmd):
        if self.toolchange is not None \
           and hasattr(self.toolchange, 'refresh_offsets'):
            self.toolchange.refresh_offsets(gcmd)

    # ---------------- commands ----------------

    cmd_TOOL_OFFSET_CALIBRATE_help = (
        "Measure a tool's nozzle position against the station "
        "(TOOL=<0..3|ALL> PLATE_REMOVED=1 [GRAB=1] [RELEASE=0] [SAVE=1]"
        " [PLATE_CHECK=1])")

    def cmd_TOOL_OFFSET_CALIBRATE(self, gcmd):
        raw = gcmd.get('TOOL')
        if raw.upper() == 'ALL':
            tools = list(range(EXTRUDER_COUNT))
        else:
            try:
                t = int(raw)
            except ValueError:
                raise gcmd.error("TOOL must be 0..%d or ALL"
                                 % (EXTRUDER_COUNT - 1))
            if not 0 <= t < EXTRUDER_COUNT:
                raise gcmd.error("TOOL must be 0..%d or ALL"
                                 % (EXTRUDER_COUNT - 1))
            tools = [t]
        grab = gcmd.get_int('GRAB', 1, minval=0, maxval=1)
        release = gcmd.get_int('RELEASE', 0, minval=0, maxval=1)
        save = gcmd.get_int('SAVE', 1, minval=0, maxval=1)
        if (grab or release) and self.toolchange is None:
            raise gcmd.error("%s: [ff_toolchange] not loaded -- cannot pick"
                             " up tools. Mount the tool by hand and pass"
                             " GRAB=0 RELEASE=0." % self.name)
        self._require_plate_removed(gcmd)
        self._check_homed(gcmd)
        # GRAB=0 means the operator mounted the tool by hand. The plate check
        # needs an EMPTY carriage, so it starts by parking whatever is mounted
        # -- which would silently undo that, measure the bare carriage and save
        # it as this tool's nozzle position, ~3.2 mm out in the crash
        # direction. Refuse instead of quietly doing the wrong thing; the gap
        # guard only catches it once a station_z exists.
        if not grab and self.toolchange is not None \
           and self.toolchange.get_status(
               self.reactor.monotonic()).get('current_tool', -1) != -1 \
           and gcmd.get_int('PLATE_CHECK', 1 if self.plate_check else 0,
                            minval=0, maxval=1):
            raise gcmd.error(
                "%s: GRAB=0 with a tool mounted, but the plate check has to"
                " park it to measure an empty carriage -- which would"
                " calibrate the bare carriage as T%s. Pass PLATE_CHECK=0 to"
                " keep the tool you mounted (you have already promised"
                " PLATE_REMOVED=1), or use GRAB=1 and let the toolchanger"
                " pick it up." % (self.name, tools[0] if tools else '?'))
        self._run_plate_check(gcmd)
        cyl_x, cyl_y = self._cylinder()
        x0, y0 = cyl_x - self.nozzle_x_shift, cyl_y

        results = {}
        for tool in tools:
            gcmd.respond_info("T%d: offset calibration, start %.3f, %.3f"
                              % (tool, x0, y0))
            if grab:
                # changeExtruderManager(ext, true, false): releases whatever
                # is mounted, grabs `tool`, applies its G-code offsets
                # (zeroed again by moveCylinderPos below).
                self._run('T%d' % tool)
                self._wait_moves()

            t = self.tools[tool]
            expected_z = t.nozzle[2] if t.calibrated() else None
            if expected_z is None and self.station is not None:
                # nozzle fires ~3.2 mm above the empty-carriage trigger
                expected_z = self.station[2] + 0.5 * (self.gap_min
                                                      + self.gap_max)

            def body():
                return self._two_pass(gcmd, x0, y0, self.z_target,
                                      expected_z)
            cx, cy, zp = self._with_accel_guard(gcmd, body)
            if self.station is not None and (self.gap_min or self.gap_max):
                gap = zp - self.station[2]
                if gap < self.gap_min or gap > self.gap_max:
                    raise gcmd.error(
                        "%s: T%d nozzle_z %.3f is %.3f above station_z %.3f,"
                        " outside gap_min/gap_max [%.2f, %.2f] -- probe"
                        " mis-trigger suspected, nothing saved"
                        % (self.name, tool, zp, gap, self.station[2],
                           self.gap_min, self.gap_max))
            results[tool] = (cx, cy, zp)
            self.last['t%d' % tool] = (cx, cy, zp)
            gcmd.respond_info("T%d: offset = (%.4f, %.4f, %.4f)"
                              % (tool, cx, cy, zp))
            if release:
                self._run('TOOLCHANGE_PARK')
                self._wait_moves()

        # Staged only once every tool has passed its guards, so that a failure
        # part-way through TOOL=ALL really does leave nothing saved -- which is
        # what the guard messages above promise.
        if save:
            for tool, (cx, cy, zp) in results.items():
                self.tools[tool].set_nozzle(cx, cy, zp)

        # the app's exit block: heater off for the tool(s), Z15
        for tool in tools:
            self._run('M104 S0 T%d' % tool)
        self._run('G1 Z%.3f F%d' % (self.z_final, FEED_PASS1))
        self._run('M400')
        if save:
            self._refresh_toolchange(gcmd)
            gcmd.respond_info(
                "The SAVE_CONFIG command will update the printer config file"
                " with the new nozzle position(s) and restart the printer.")
        # Probing zeroed the G-code offsets to work in raw coordinates. Put
        # the frame back before handing control to the operator: RELEASE
        # defaults to 0, so this usually ends with a tool still on the
        # carriage, and leaving Z=0 at the eddy plane means the next jog to
        # Z0 -- or the next toolchange, which would carry the zeroing -- puts
        # the nozzle into the plate.
        self._restore_offset_frame(gcmd)
        self._report_diffs(gcmd, results)

    cmd_STATION_CALIBRATE_help = (
        "Measure the station position with an EMPTY carriage "
        "(station_x/y/z) (PLATE_REMOVED=1 [PARK=1] [SAVE=1] [PLATE_CHECK=1])")

    def cmd_STATION_CALIBRATE(self, gcmd):
        park = gcmd.get_int('PARK', 1, minval=0, maxval=1)
        save = gcmd.get_int('SAVE', 1, minval=0, maxval=1)
        self._require_plate_removed(gcmd)
        self._check_homed(gcmd)
        if self.toolchange is not None:
            if park:
                # releaseFourExtruder: the carriage must be empty for TS.
                self._run('TOOLCHANGE_PARK')
                self._wait_moves()
            cur = self.toolchange.get_status(self.reactor.monotonic())
            if cur.get('current_tool', -1) != -1 or not cur.get('state_ok'):
                raise gcmd.error(
                    "%s: carriage is not verifiably empty (%s) -- the station"
                    " pass must run with no tool mounted"
                    % (self.name, cur.get('state_reason')))
        elif park:
            raise gcmd.error("%s: [ff_toolchange] not loaded -- park the tool"
                             " by hand and pass PARK=0." % self.name)
        self._run_plate_check(gcmd)
        cyl_x, cyl_y = self._cylinder()
        gcmd.respond_info("station calibration, start %.3f, %.3f"
                          % (cyl_x, cyl_y))

        expected_z = self.station[2] if self.station is not None else None

        def body():
            return self._two_pass(gcmd, cyl_x, cyl_y, self.z_target_station_2,
                                  expected_z)
        cx, cy, zp = self._with_accel_guard(gcmd, body)
        self.last['station'] = (cx, cy, zp)
        gcmd.respond_info("station = (%.4f, %.4f, %.4f)" % (cx, cy, zp))
        if save:
            self.set_station(cx, cy, zp)
            self._refresh_toolchange(gcmd)
            gcmd.respond_info(
                "The SAVE_CONFIG command will update the printer config file"
                " with the new station position and restart the printer.")
        # Runs with an empty carriage, so there is usually no tool to re-apply
        # -- but the probing zeroed the offsets all the same, and the stale
        # _z_tool_term it leaves behind would be carried into the next grab.
        self._restore_offset_frame(gcmd)

    cmd_TOOL_OFFSET_STATUS_help = "Show the configured nozzle/station positions"

    def cmd_TOOL_OFFSET_STATUS(self, gcmd):
        cyl_x, cyl_y = self._cylinder()
        lines = ["station start (cylinder_x/y): %.3f, %.3f" % (cyl_x, cyl_y)]
        for t in self.tools:
            if t.calibrated():
                lines.append("[ff_tool %d] nozzle %.4f, %.4f, %.4f"
                             % (t.index, t.nozzle[0], t.nozzle[1],
                                t.nozzle[2]))
            else:
                lines.append("[ff_tool %d] nozzle NOT CALIBRATED" % t.index)
        if self.station is not None:
            lines.append("[%s] station %.4f, %.4f, %.4f"
                         % ((self.name,) + self.station))
        else:
            lines.append("[%s] station NOT CALIBRATED" % self.name)
        configfile = self.printer.lookup_object('configfile')
        st = configfile.get_status(self.reactor.monotonic())
        if st.get('save_config_pending'):
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
        for tool, (cx, cy, zp) in sorted(results.items()):
            lines.append("T%d measured: nozzle centre %.4f, %.4f"
                         "  Z trigger %.4f" % (tool, cx, cy, zp))
        base = None
        if base_tool in results:
            base = results[base_tool]
        elif self.tools[base_tool].calibrated():
            base = self.tools[base_tool].nozzle
        z_station = self.station[2] if self.station is not None else None
        if base is not None:
            lines.append("offsets a toolchange applies (X/Y vs T%d; Z %s):"
                         % (base_tool,
                            "absolute: nozzle_z - station_z + z_adjust"
                            if z_station is not None
                            else "vs T%d, + z_adjust" % base_tool))
            for tool, (cx, cy, zp) in sorted(results.items()):
                za = self.tools[tool].z_adjust
                if z_station is not None:
                    z_applied = za + (zp - z_station)
                else:
                    z_applied = za + (zp - base[2])
                lines.append("  T%d: dX %+.4f  dY %+.4f  Z %+.4f"
                             % (tool, cx - base[0], cy - base[1], z_applied))
        gcmd.respond_info("\n".join(lines))

    def get_status(self, eventtime):
        out = {}
        for k, v in self.last.items():
            out[k] = {'x': v[0], 'y': v[1], 'z': v[2]}
        sx, sy, sz = self.station if self.station else (None, None, None)
        return {'last': out, 'station_x': sx, 'station_y': sy,
                'station_z': sz}


def load_config(config):
    return FFToolOffset(config)
