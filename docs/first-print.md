# Your first print

**If your printer was printing before you flashed, it will print now.** The
factory numbers came across on the first boot, a bed mesh is loaded at the
start of every print, and the mod is built to run the same files the stock
firmware ran. There is nothing you have to set up first.

What follows is what is worth doing anyway, the first time, before you leave
a long print unattended. None of it is mandatory. All of it is quicker than
scraping a failed first layer off the plate.

---

## Where everything is

Everything is on the printer's own address:

| | |
|---|---|
| `http://<printer-ip>/` | Mainsail |
| `http://<printer-ip>:7125` | Moonraker's API — what slicers upload to |
| `http://<printer-ip>/webcam/` | the camera stream (mjpg-streamer on `:8080`) |
| `ssh root@<printer-ip>` | the shell — password from `anvil-password.txt` |

```
/usr/data/anvil-install.log      what the installer did
/usr/data/logs/anvil-boot.log    services + UI choice at each boot
/usr/data/logs/printer.log       klipper
/usr/data/logs/helixscreen.log   helixscreen
```

They are the first thing to read when something is wrong, and the first thing
to quote when you ask on [the Discord](https://discord.gg/ggJyfgVA4v).

---

## Check the offsets are applied

**Recommended.** Not because it is likely to be wrong, but because this is
the one thing that damages the machine when it is, and it costs two minutes.

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
Klipper instead — [XYZ tool calibration](calibration.md) — or repeat the
import step if you really want the touchscreen's numbers.

---

## If something looks off, calibrate

Only if you need it — a machine that measures correctly above does not need
this. Run it when the check disagrees with reality, when a tool has been
refitted or dropped, or when one tool prints at a different height from the
rest.

Re-measuring replaces the factory numbers with your own; it does not repair
anything else, and it is not a routine step. Background:
[Calibration](calibration-overview.md).

**Take the PEI sheet off first** — the calibration station sits below the bed
plane — then home and calibrate:

```gcode
G28
CALIBRATE_TOOL_OFFSETS
SAVE_CONFIG
```

Step by step, with every message it can refuse with, and what each refusal
means: [XYZ tool calibration](calibration.md).

Afterwards, `TOOLCHANGE_STATUS` and `TOOL_OFFSET_STATUS` should show a nozzle
triple and a dock position for every tool, and nothing should say
`NOT CALIBRATED`.

---

## The two verification files

Two G-code files live in [`gcode/`](../gcode/) in the repository. They are
not models: they exercise the things a real print depends on, in the order a
real print uses them, so a mistake shows up on a bare plate rather than
halfway through a job.

Send them the way you send any print — Mainsail's upload, or your slicer's
Moonraker target.

| File | What it does |
|---|---|
| [`creator5-safe-moves.gcode`](../gcode/creator5-safe-moves.gcode) | The whole sequence with the heat and the filament taken out. Nothing extrudes, no heater is given a target, and after homing nothing moves below Z50. It answers whether homing, tool changes and the end sequence behave — before a nozzle can reach the plate. |
| [`creator5-feature-test.gcode`](../gcode/creator5-feature-test.gcode) | The real thing, hot, with two tools: one ring per tool to read XY offsets off the plate, a solid first layer to judge squish, the fan map, a chamber-heater check, and a tower with a tool change on every layer. |

Run the safe one first. Each file's own header repeats what it does, so
whoever is standing at the machine has it in front of them.

Two refusals are the gates working rather than faults: a complaint that the
machine is not calibrated, and "Refusing to home Z: cannot tell whether a
tool is mounted", which means the dock switches disagree — run
`TOOLCHANGE_STATUS` and find the one that is lying.

---

## A real print

Now slice something small and print it the way you will print everything
else: the stock FlashForge profile, uploaded through Mainsail or your
slicer's Moonraker target. Stay at the machine for the first one.
