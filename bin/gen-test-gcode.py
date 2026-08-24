#!/usr/bin/env python3
"""Generate a feature-verification print for the Creator 5 / Creator 5 Pro.

The point is not the object. The point is that one file, started from Mainsail
the way any print is, drives every macro this firmware adds and leaves
something on the plate you can measure afterwards:

    ff_print        the wrapper takes SDCARD_PRINT_FILE over and reads this
                    file's own M140 / M104 / Tn / ;HEIGHT: -- all four are in
                    the preamble on purpose, so the derived path has real
                    values to work with if FF_BEFORE_PRINT_START.prepare is 1.
    START_PRINT     called by the machine start block with TOOLS=, so the
                    preflight gate checks every tool the file uses, not just
                    the first, and every one of them gets purged and wiped.
    T<n>            a tool change per layer in the tower, mid-print, hot.
    tool offsets    the nested squares are drawn one tool per ring: a uniform
                    gap means the XY offsets agree, a lopsided one measures
                    the error directly.
    print Z offset  the solid patch is a single first layer -- squish is the
                    whole verdict on TOOLCHANGE_SET_PRINT_OFFSET.
    M106 P<n>       the fan map of printer.macro.cfg, one state at a time with
                    a dwell so you can hear which one spins.
    M141            the chamber gate: heats on a Pro, says so and carries on
                    on a plain Creator 5.
    END_PRINT       the exit sequence, via the machine end block.

PAUSE / RESUME and the runout sensors are deliberately NOT in the file: both
want a human at the machine, and a resume that fails should not be indented
inside a print you are also trying to measure. Press Pause in Mainsail during
the tower instead -- the header printed into the file says so.

Nothing here is calibration. TOOL_OFFSET_CALIBRATE and STATION_CALIBRATE need
the build plate off, which a print by definition does not have, so the file
only ever READS the geometry (TOOLCHANGE_STATUS, TOOL_OFFSET_STATUS) into the
console log.
"""
import argparse
import math
import re
import os
import sys

FILAMENT_AREA = math.pi * (1.75 ** 2) / 4.0      # 2.4053, the start block's divisor

# Kept well inside stepper_x/stepper_y position_max (310 / 260) and clear of
# the docks at X~297 and the purge chute at (275, 254).
BED_MIN, BED_MAX = 20.0, 230.0

# The machine start block from the OrcaSlicer profile, verbatim. Substitution
# is Orca's own, so what ships in the profile and what this generator emits
# stay one text.
START_GCODE = """;start_gcode
M106 P101 S0 ; L+R_PLA_Turbo_Fan_0-255 -- NO-OP: printer.macro.cfg's M106 has
             ; the P101 branch commented out (there is no [fan_generic internal_fan])
M106 P2 S0 ; chamber_loop_fan + chamber_cool_fan
;M191 S0 -- chamber temp: NOT a klipper command in this fork (the app intercepts M191); harmless but noisy, left commented
M106 S0 ; part cooling fan (fan_generic fanM106) -- P1 and bare M106 both land here
M106 P3 S0 ; chamber_fan
M104 S[nozzle_temperature_initial_layer] T[initial_extruder] ; preheat in parallel
START_PRINT BED=[bed_temperature_initial_layer_single] TOOL=[initial_extruder] NOZZLE=[nozzle_temperature_initial_layer] LAYER=[layer_height] LEVEL=0 TOOLS=[tools]
G90
M83
M109 S[nozzle_temperature_initial_layer] T[initial_extruder]
G1 Z5 F2400
G1 X256 Y0 Z0.2 F6000
G1 E5 F[prime_feed]
G1 X216 E10 F[prime_feed]
;start_gcode end
"""

END_GCODE = """;end_gcode
END_PRINT
;end_gcode end
"""


class Writer:
    """Tracks position so travels can retract and extrusions can be measured."""

    def __init__(self, out, opts):
        self.out = out
        self.o = opts
        self.x = 216.0          # where the start block's prime line ends
        self.y = 0.0
        self.z = 0.2
        self.retracted = False
        self.tool = opts.tools[0]
        # The machine start block primes the tool it starts on, and no other.
        self.primed = {opts.tools[0]}
        self.filament = 0.0

    def w(self, line=""):
        self.out.write(line + "\n")

    def comment(self, text):
        self.w("; " + text)

    def banner(self, text):
        self.w()
        self.w("; " + "-" * 70)
        self.comment(text)
        self.w("; " + "-" * 70)
        self.w("M117 %s" % text[:60])

    # -- primitives ---------------------------------------------------------
    def retract(self):
        if not self.retracted:
            self.w("G1 E-%.4f F%d" % (self.o.retract, self.o.retract_feed))
            self.retracted = True

    def unretract(self):
        if self.retracted:
            self.w("G1 E%.4f F%d" % (self.o.retract, self.o.retract_feed))
            self.retracted = False

    def travel(self, x, y, z=None):
        """Move without printing. Z last when it descends, first when it rises.

        The order is load-bearing after a tool change: T<n> leaves the carriage
        at the dock, out past X250, so descending to layer height before the
        cross-bed move would drag the nozzle over everything already printed.
        """
        if (abs(x - self.x) < 1e-6 and abs(y - self.y) < 1e-6
                and (z is None or abs(z - self.z) < 1e-6)):
            return                      # square() re-enters at its own corner
        self.retract()
        rise = z is not None and z > self.z
        if rise:
            self.w("G1 Z%.3f F%d" % (z, self.o.z_feed))
            self.z = z
        self.w("G1 X%.3f Y%.3f F%d" % (x, y, self.o.travel_feed))
        self.x, self.y = x, y
        if z is not None and abs(z - self.z) > 1e-6:
            self.w("G1 Z%.3f F%d" % (z, self.o.z_feed))
            self.z = z

    def extrude_to(self, x, y, width):
        self.unretract()
        length = math.hypot(x - self.x, y - self.y)
        e = length * width * self.o.layer / FILAMENT_AREA
        self.filament += e
        self.w("G1 X%.3f Y%.3f E%.5f F%d" % (x, y, e, self.o.print_feed))
        self.x, self.y = x, y

    def square(self, cx, cy, half, width):
        """One closed square ring, entered from its own first corner."""
        pts = [(cx - half, cy - half), (cx + half, cy - half),
               (cx + half, cy + half), (cx - half, cy + half),
               (cx - half, cy - half)]
        self.travel(pts[0][0], pts[0][1])
        for px, py in pts[1:]:
            self.extrude_to(px, py, width)

    def patch(self, cx, cy, half, width):
        """A perimeter plus a zigzag fill -- a first layer you can judge."""
        self.square(cx, cy, half, width)
        x0, x1 = cx - half + width, cx + half - width
        y = cy - half + width
        self.travel(x0, y)
        left = True
        while y <= cy + half - width + 1e-6:
            self.extrude_to(x1 if left else x0, y, width)
            ny = y + width
            if ny > cy + half - width + 1e-6:
                break
            self.extrude_to(self.x, ny, width)
            y = ny
            left = not left

    # -- machine ------------------------------------------------------------
    def prime(self, tool):
        """A prime line at the front edge, once per tool, on its first use.

        Not decoration. START_PRINT's clean leaves every tool retracted by
        _FF_FILAMENT.purge_retract (5 mm), and the machine start block primes
        only the tool it starts on. Without this the first ring a tool draws
        would be the one that recovers those 5 mm, which is exactly the ring
        the offsets are measured from.
        """
        if tool in self.primed:
            return
        y = self.o.prime_y + self.o.prime_pitch * len(self.primed)
        self.comment("T%d prime line at Y%.1f (the start block primed T%d only)"
                     % (tool, y, self.o.tools[0]))
        self.travel(256.0, y, self.o.layer)
        self.w("G1 E5 F%d" % self.o.prime_feed)
        self.w("G1 X216.000 E10 F%d" % self.o.prime_feed)
        self.x, self.y = 216.0, y
        self.filament += 15.0
        self.retracted = False
        self.primed.add(tool)

    def select_tool(self, tool):
        """A mid-print tool change.

        [ff_toolchange] ships restore_axis unset, so T<n> restores NOTHING --
        the position after a change is wherever the dock run left the carriage.
        Every caller here therefore re-states X, Y and Z itself rather than
        assuming it came back.

        The outgoing tool drops to a standby temperature before it is docked.
        A test print is twenty minutes of a parked tool sitting at full
        temperature otherwise, oozing into its own dock.
        """
        if tool == self.tool:
            return
        self.retract()
        standby = self.o.nozzle - self.o.standby_delta
        z_park = min(self.z + 5.0, 250.0)
        self.w("G1 Z%.3f F%d" % (z_park, self.o.z_feed))
        self.z = z_park
        if self.o.standby_delta > 0:
            self.w("M104 S%.0f T%d" % (standby, self.tool))
        self.w("M104 S%.0f T%d" % (self.o.nozzle, tool))
        self.w("T%d" % tool)
        self.w("M109 S%.0f T%d" % (self.o.nozzle, tool))
        self.tool = tool
        self.prime(tool)

    def dwell(self, seconds):
        self.w("G4 P%d" % int(seconds * 1000))


def preamble(w, opts):
    o = opts
    w.comment("=" * 68)
    w.comment("Creator 5 / Creator 5 Pro feature-verification print")
    w.comment("generated by bin/gen-test-gcode.py -- do not hand-edit, re-run it")
    w.comment("")
    w.comment("tools %s   nozzle %.0f C   bed %.0f C   layer %.2f mm"
              % (",".join("T%d" % t for t in o.tools), o.nozzle, o.bed, o.layer))
    w.comment("")
    w.comment("BEFORE YOU START THIS FILE")
    w.comment("  * every tool listed above must be docked or mounted, and")
    w.comment("    calibrated -- START_PRINT refuses the job otherwise, before")
    w.comment("    it heats or homes anything. That refusal is itself the first")
    w.comment("    thing this file verifies.")
    w.comment("  * the machine start block below calls START_PRINT itself, so")
    w.comment("    set the implicit prepare off or the machine homes, purges and")
    w.comment("    grabs twice:")
    w.comment("      SET_GCODE_VARIABLE MACRO=FF_BEFORE_PRINT_START VARIABLE=prepare VALUE=0")
    w.comment("    (persist it by editing variable_prepare in ff-print-macros.cfg)")
    w.comment("  * filament loaded in every listed tool. LOAD_FILAMENT TOOL=<n>")
    w.comment("    is not called from here -- it releases the tool when it")
    w.comment("    finishes, which is wrong in the middle of a print.")
    w.comment("")
    w.comment("WHAT TO WATCH, IN ORDER")
    w.comment("  1  START_PRINT: homing, then one purge+wipe per tool at the")
    w.comment("     chute while the bed heats. A tool that is skipped here was")
    w.comment("     not in TOOLS=.")
    w.comment("  2  prime line at Y0, then the console dump: TOOLCHANGE_STATUS")
    w.comment("     and TOOL_OFFSET_STATUS record the live geometry into")
    w.comment("     /usr/data/logs/printer.log next to the print itself.")
    w.comment("  3  nested squares: one ring per tool, %.2f mm apart by design."
              % o.ring_gap)
    w.comment("     Measure the gap on all four sides when it is cold. Left vs")
    w.comment("     right is that tool's X offset error, front vs back its Y.")
    w.comment("  4  solid patch: a single first layer. Squish is the verdict on")
    w.comment("     the print Z offset -- see docs/toolchange.md before you")
    w.comment("     change anything, and correct it with TOOL_Z_ADJUST, not by")
    w.comment("     editing nozzle_z.")
    w.comment("  5  fan sweep: each M106 target on its own for %d s. P101 is a"
              % o.dwell)
    w.comment("     no-op by design; bare M106 and P1 are the part fan; P2 is")
    w.comment("     the chamber loop + cool pair; P3 is the chamber fan.")
    w.comment("  6  chamber: M141 S%.0f. A Pro heats. A plain Creator 5 answers"
              % o.chamber)
    w.comment("     'no chamber heater on this model' and prints on -- an abort")
    w.comment("     here is a real failure.")
    w.comment("  7  tower: one tool change per layer, hot, mid-print. Layer")
    w.comment("     shift between rings is a tool-to-tool offset error; a step")
    w.comment("     in Z is nozzle_z. THIS is where to press Pause in Mainsail")
    w.comment("     and then Resume: hotends off, park lift, reheat, and the")
    w.comment("     print carries on from the same spot.")
    w.comment("  8  END_PRINT: heaters off, bed drops to present the part, the")
    w.comment("     mounted tool goes back to its dock, motors off.")
    w.comment("=" * 68)
    w.w()
    # ff_print reads these four out of the file's own commands. They are here
    # so the derived path (prepare=1, no START_PRINT in the profile) still gets
    # real values; the start block's explicit START_PRINT wins either way.
    w.w("M140 S%.0f" % o.bed)
    w.w(";HEIGHT:%.2f" % o.layer)
    w.w()


def body(w, opts):
    o = opts
    first = o.tools[0]

    w.banner("Phase 0: report the geometry this print is about to trust")
    w.w("T%d" % first)          # the file's own initial extruder, for ff_print
    w.w("TOOLCHANGE_STATUS")
    w.w("TOOL_OFFSET_STATUS")
    w.w("M204 S%d" % o.accel)
    w.w("M220 S100")
    w.w("M221 S100")
    w.w("SET_PRESSURE_ADVANCE ADVANCE=%.4f" % o.pressure_advance)
    w.comment("the tools this file will need later, warmed to standby now so a")
    w.comment("mid-print change waits for a short reheat and not a cold start")
    for t in o.tools[1:]:
        w.w("M104 S%.0f T%d" % (o.nozzle - o.standby_delta, t))

    # ---- Phase 1: nested squares, one ring per tool ------------------------
    w.banner("Phase 1: tool offsets -- one square per tool, %.2f mm apart"
             % o.ring_gap)
    cx, cy = o.rings_at
    for i, t in enumerate(o.tools):
        half = o.ring_half + i * o.ring_gap
        w.comment("T%d ring: %.1f x %.1f mm" % (t, 2 * half, 2 * half))
        w.select_tool(t)
        w.travel(cx - half, cy - half, o.layer)
        w.square(cx, cy, half, o.first_width)

    # ---- Phase 2: one solid first layer ------------------------------------
    w.banner("Phase 2: first layer -- squish is the print Z offset")
    w.select_tool(first)
    px, py = o.patch_at
    w.travel(px - o.patch_half, py - o.patch_half, o.layer)
    w.patch(px, py, o.patch_half, o.first_width)

    # ---- Phase 3: fans, one at a time --------------------------------------
    w.banner("Phase 3: fan map -- one target at a time, %d s each" % o.dwell)
    # Off the work and well clear of it: this phase stands still for most of a
    # minute with a hot nozzle, and the patch that was just laid down is the
    # thing the Z offset gets judged on.
    w.travel(BED_MAX, o.prime_y, 15.0)
    for cmd, what in (("M106 P101 S255", "P101: nothing should spin (no-op)"),
                      ("M106 S255", "bare M106: part fan, full"),
                      ("M106 S128", "bare M106: part fan, half"),
                      ("M106 S0", "part fan off"),
                      ("M106 P2 S255", "P2: chamber loop + cool fans"),
                      ("M106 P2 S0", "P2 off"),
                      ("M106 P3 S255", "P3: chamber fan"),
                      ("M106 P3 S0", "P3 off")):
        w.comment(what)
        w.w("M117 %s" % what[:60])
        w.w(cmd)
        w.dwell(o.dwell)

    # ---- Phase 4: the chamber gate -----------------------------------------
    w.banner("Phase 4: M141 -- heats on a Pro, is refused politely otherwise")
    w.w("M141 S%.0f" % o.chamber)

    # ---- Phase 5: the tower, a tool change per layer ------------------------
    w.banner("Phase 5: tower -- one tool change per layer. Pause/Resume here.")
    tx, ty = o.tower_at
    for layer in range(1, o.tower_layers + 1):
        z = o.layer * layer
        t = o.tools[(layer - 1) % len(o.tools)]
        width = o.first_width if layer == 1 else o.width
        w.w()
        w.w(";LAYER_CHANGE")
        w.w(";HEIGHT:%.2f" % o.layer)
        w.comment("tower layer %d/%d, Z%.2f, T%d"
                  % (layer, o.tower_layers, z, t))
        w.select_tool(t)
        w.w("M106 S%d" % (0 if layer == 1 else 255))
        for ring in range(o.tower_walls):
            half = o.tower_half - ring * width
            w.travel(tx - half, ty - half, z)
            w.square(tx, ty, half, width)

    w.banner("Phase 6: hand back to the machine end block")
    w.retract()
    w.w("M141 S0")
    w.w("M106 S0")
    w.w("TOOLCHANGE_STATUS")
    w.w()


def substitute(text, opts):
    tools = ",".join("%d:%.0f" % (t, opts.nozzle) for t in opts.tools)
    prime_feed = opts.volumetric / FILAMENT_AREA * 60.0
    for key, value in (
            ("[nozzle_temperature_initial_layer]", "%.0f" % opts.nozzle),
            ("[bed_temperature_initial_layer_single]", "%.0f" % opts.bed),
            ("[initial_extruder]", "%d" % opts.tools[0]),
            ("[layer_height]", "%.2f" % opts.layer),
            ("[tools]", tools),
            ("[prime_feed]", "%.0f" % prime_feed)):
        text = text.replace(key, value)
    # An Orca placeholder is [word]; the prose in the comments contains
    # bracketed Klipper section names, which have a space in them.
    left = re.findall(r"\[[a-z0-9_]+\]|\{[^}]*\}", text)
    if left:
        raise SystemExit("unsubstituted placeholder in the start block: %s"
                         % ", ".join(left))
    return text


def parse_tools(text):
    tools = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        n = int(part)
        if not 0 <= n <= 3:
            raise argparse.ArgumentTypeError("tool %d out of range 0..3" % n)
        if n not in tools:
            tools.append(n)
    if not tools:
        raise argparse.ArgumentTypeError("name at least one tool")
    return tools


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("-o", "--out", help="output file (default dist/<name>.gcode)")
    p.add_argument("--tools", type=parse_tools, default=[0, 1],
                   help="tools to exercise, in print order (default 0,1)")
    p.add_argument("--nozzle", type=float, default=220.0)
    p.add_argument("--bed", type=float, default=60.0)
    p.add_argument("--chamber", type=float, default=40.0,
                   help="M141 target for the chamber gate check")
    p.add_argument("--layer", type=float, default=0.2)
    p.add_argument("--width", type=float, default=0.45)
    p.add_argument("--first-width", type=float, default=0.50)
    p.add_argument("--volumetric", type=float, default=12.0,
                   help="filament_max_volumetric_speed, for the prime feed")
    p.add_argument("--tower-layers", type=int, default=12)
    p.add_argument("--standby-delta", type=float, default=40.0,
                   help="how far below --nozzle a docked tool waits "
                        "(0 keeps every tool at full temperature)")
    p.add_argument("--dwell", type=int, default=3,
                   help="seconds to hold each fan state")
    o = p.parse_args(argv)

    # Fixed geometry. Bed centre is ~(125, 125); everything stays inside
    # BED_MIN..BED_MAX, which test_gcode.py re-checks against the real
    # stepper limits in printer.base.cfg.
    o.ring_half = 12.0
    o.ring_gap = 2.0
    o.rings_at = (70.0, 175.0)
    o.patch_half = 12.5
    o.patch_at = (175.0, 175.0)
    o.tower_half = 12.0
    o.tower_walls = 2
    o.tower_at = (125.0, 85.0)
    o.prime_y = 2.0          # the start block primes at Y0; these sit beside it
    o.prime_pitch = 3.0
    o.prime_feed = int(o.volumetric / FILAMENT_AREA * 60.0)
    o.retract = 0.8
    o.retract_feed = 2400
    o.travel_feed = 12000
    o.print_feed = 1800
    o.z_feed = 1200
    o.accel = 5000
    o.pressure_advance = 0.03

    name = "creator5-feature-test-%s.gcode" % "".join("T%d" % t for t in o.tools)
    out_path = o.out or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "dist", name)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)

    with open(out_path, "w", encoding="utf-8") as fh:
        w = Writer(fh, o)
        preamble(w, o)
        fh.write(substitute(START_GCODE, o))
        body(w, o)
        fh.write(substitute(END_GCODE, o))
        w.comment("filament extruded by the body: %.1f mm (~%.1f g of PLA)"
                  % (w.filament, w.filament * FILAMENT_AREA * 1.24 / 1000.0))

    sys.stderr.write("wrote %s\n" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
