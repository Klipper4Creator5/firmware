# Your first print

**Prints refuse to start on an uncalibrated toolchanger — by design.** The
gate runs before anything heats, homes or grabs, and it is there because a
toolchanger that does not know where its nozzles are drives one of them into
the plate.

This page is the order of the first run: calibrate, prove the offset is
really being applied, then two files that exercise the machine before a real
model does.

---

## 1. Calibrate

Your unit's factory numbers imported themselves on the first boot. That is a
starting point, not a calibration: measure the nozzles.

**Take the PEI sheet off first** — the calibration station sits below the bed
plane — then home and calibrate:

```gcode
G28
CALIBRATE_TOOL_OFFSETS
SAVE_CONFIG
```

Step by step, with every message it can refuse with, and what each refusal
means: [Nozzle-offset calibration](calibration.md).

Afterwards, `TOOLCHANGE_STATUS` and `TOOL_OFFSET_STATUS` should show a nozzle
triple and a dock position for every tool, and nothing should say
`NOT CALIBRATED`.

---

## 2. Prove the offset is applied

Before moving anything:

* `TOOLCHANGE_STATUS` — current tool as derived from the dock sensors, every
  sensor's state, each tool's nozzle position and `z_adjust`, `station_z`,
  dock coordinates and the derived offsets (`offset_z` is each tool's
  absolute bed-frame gap, ~3.2). Check the `dock_x`/`dock_y` rows are
  numbers, not `nan`.
* `TOOL_OFFSET_STATUS` — saved calibration per tool and for the station,
  and a warning if anything is staged but not yet `SAVE_CONFIG`'d.
* Physical Z check (clean bed, nothing on it):

  ```gcode
  G28
  T0
  TOOLCHANGE_SET_PRINT_OFFSET NOZZLE=220 BED=80 LAYER=0.25 TOOL=0
  G1 X150 Y150 F6000
  G1 Z0.1 F600
  ```

  `T0` already applies the ~+3.2 mm gap (watch the gcode Z offset in the
  UI); the offset command reports the full Z with a term-by-term breakdown,
  and the nozzle should end up a paper-thickness above the bed at the
  center. If it presses into the plate instead, STOP — the offset is not
  being applied; do not print until `TOOLCHANGE_STATUS` and
  `TOOL_OFFSET_STATUS` are clean. Afterwards restore the idle state:

  ```gcode
  G1 Z10 F1200
  TOOLCHANGE_PARK                       ; drops the per-tool frame
  TOOLCHANGE_SET_PRINT_OFFSET CLEAR=1   ; and this the job term
  ```

  `SET_GCODE_OFFSET Z=0` is *not* the way to clear the job term any more:
  it cannot tell that term from your babystep, so it would take both.

A touchscreen recalibration no longer affects this module. Recalibrate from
Klipper instead — [Nozzle-offset calibration](calibration.md) — or repeat the
import step if you really want the touchscreen's numbers.

---

## 3. The two verification files

`gcode/` holds them. They are hand-maintained G-code, not generated: send them
to the printer the way you send any print — Mainsail's upload, or OrcaSlicer's
Klipper/Moonraker target. Each one's own header repeats everything below, so
whoever is standing at the machine has it in front of them.

### First: `creator5-safe-moves.gcode`

The feature print with the heat and the filament taken out. Once homed, no move
in it goes below Z50; nothing extrudes and no heater is given a target. It
answers three questions — does the `G28` wrapper home safely, docking a mounted
tool first; does a tool change latch and release; do the fans, the chamber gate
and `END_PRINT` do what they claim — and it answers them before a nozzle can
reach the plate.

It names no tool as a bare `Tn` and carries no `M104`/`M140`, so `ff_print`
derives nothing from it and the implicit prepare has nothing to heat or purge.
That makes it safe whether `FF_BEFORE_PRINT_START.prepare` is 0 or 1.

Two refusals it may produce are the gates working, not faults: the calibration
refusal from Mainsail's print entry point (override deliberately with
`SET_GCODE_VARIABLE MACRO=_FF_JOB VARIABLE=allow_uncalibrated VALUE=1`), and
"Refusing to home Z: cannot tell whether a tool is mounted", which means the
dock switches disagree — run `TOOLCHANGE_STATUS` and find the one that is lying.

### Then: `creator5-feature-test.gcode`

Not a model. One file that drives every macro the mod adds, in the order a real
print drives them, and leaves something on the plate you can measure:

| Phase | What it proves |
|---|---|
| start block | `START_PRINT` with `TOOLS=`: the preflight gate, then one purge + wipe per tool at the chute while the bed heats |
| 0 | `TOOLCHANGE_STATUS` / `TOOL_OFFSET_STATUS` dumped into `printer.log` alongside the print itself |
| 1 | nested squares, one ring per tool, 2 mm apart. Cold, the gap on left vs right is that tool's X offset error; front vs back its Y |
| 2 | a solid single first layer — squish is the verdict on `TOOLCHANGE_SET_PRINT_OFFSET` |
| 3 | the `M106 P<n>` fan map, one target at a time with a dwell |
| 4 | `M141`: a Pro heats, a plain Creator 5 says so and prints on. An abort here is a real failure |
| 5 | a tower with one tool change per layer, hot, mid-print |
| 6 | `END_PRINT` via the machine end block |

Two things it deliberately does **not** do. It never calibrates —
`TOOL_CALIBRATE_TOOL_OFFSET` and `TOOL_LOCATE_SENSOR` need the build plate
off, which a print does not have, so the file only reads the geometry.
And it contains no
`PAUSE`: press Pause in Mainsail during the tower and then Resume, which is the
one check that wants a human at the machine.

Unlike the safe file, this one **needs** the implicit prepare turned off — it
is the deliberate exception, because it carries its own `START_PRINT` with the
`TOOLS=` list the automatic path cannot derive. For this print only:

```
SET_GCODE_VARIABLE MACRO=FF_BEFORE_PRINT_START VARIABLE=prepare VALUE=0
```

and put it back afterwards, with `VALUE=1` or simply a `RESTART`.

Preparing twice misplaces nothing, but it re-homes and re-purges every tool for
no reason.

**Do not persist the 0** by editing `variable_prepare`. Every ordinary file
printed here relies on the automatic path: the stock Orca profile calls no
`START_PRINT` and carries no `G28`, so with prepare off nothing homes or heats
the bed and the profile's first move — `G1 Z5 F2400` — runs on unhomed axes.

It is set up for T0 and T1 at 220 °C on a 60 °C bed. To exercise different
tools, edit the `TOOLS=` list in `START_PRINT` and the `T<n>` lines in the body
to match — `make test-py` will tell you if the two disagree, which is the one
mistake that costs a print.

---

## 4. A real print

Now slice something small and print it the way you will print everything
else — see [Printing](printing.md) for the slicer side. Stay at the machine
for the first one.
