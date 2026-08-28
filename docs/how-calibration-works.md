# How calibration works

This machine has several calibrations, and they are not the same kind of
thing: some you run once and forget, one runs itself on every print, and one
imported itself the first time the mod booted. This page is what each of them
actually measures. The procedures are elsewhere and are linked from each
section.

| Calibration | Run it | Procedure |
|---|---|---|
| **XYZ tool offsets** | after flashing, and whenever a tool or the station is disturbed | [XYZ tool calibration](calibration.md) |
| **Bed mesh** | automatically, at every print start | [Bed mesh](bed-mesh.md) |
| **Input shaping** | once, and after mechanical changes | — |

---

## XYZ tool offsets

Where each nozzle is, relative to a fixed feature under the bed. This is the
one that stops a nozzle being driven into the plate, and the one the print
gate refuses to start without.


### What is being measured

The calibration station is a fixed bore **under the bed plane**, near the back
left. Two different things can reach into it:

| Reaching body | When | Trigger height |
|---|---|---|
| the **bare carriage** | nothing mounted | `station_z` |
| a tool's **nozzle** | that tool mounted | `nozzle_z` for that tool |

The carriage's own probe element sits *above* where a tool mounts, so it can
only reach the station when the carriage is empty. That is the whole reason
the order below is what it is: **the reference is measured first, with no
tool**, and every tool is then measured against it.

This is why upstream's "run `TOOL_LOCATE_SENSOR` with tool 0" becomes "run it
with *no* tool" here — and why our baseline cannot be spoiled by a badly
seated T0. Each tool's numbers are absolute and independent: recalibrating T2
leaves T0, T1 and T3 valid.

---

### From a measurement to a print

The measurements above are just numbers about a hole under the bed. Three
things turn them into a first layer.

**A reference the tools are compared against.** Probing the station with the
bare carriage fixes where the station is in the machine's own coordinates.
Everything else is expressed against that, which is why the reference is
measured first and why a badly seated tool cannot spoil it.

**One absolute number per tool.** Probing the station again with a tool
mounted gives that nozzle's own position. The difference between the two —
nozzle against reference — is the gap between where Z homing thinks zero is
and where that particular nozzle actually is. It comes out around 3.2 mm,
and it is different for every tool.

Because each tool is measured against the same fixed reference rather than
against another tool, the numbers are independent. Recalibrating one leaves
the others exactly as they were.

**A coordinate shift on every toolchange.** This is the part that differs
from the stock firmware. When a tool is grabbed, the toolchanger shifts the
coordinate system by that tool's own numbers: the Z gap, plus any per-tool
trim, plus the XY difference between this tool and the base tool. From that
moment Z0 is the plate for *this* nozzle, and the file's coordinates need no
adjustment at all.

The stock application did this once per print, as a single absolute offset
computed at print start. Doing it per grab is what lets a file that changes
tools mid-print stay correct after every change.

At print start a few smaller terms are added on top — the thermal expansion
of a hot nozzle, the bed at temperature, and a correction for very thin first
layers. They are small, a few hundredths of a millimetre, but they are the
difference between a first layer that sticks and one that does not.

---

### What each command does

#### `TOOL_LOCATE_SENSOR` — the reference

`[PARK=1] [SAVE=1]`

1. Parks the mounted tool (`PARK=0` if you docked it by hand) and verifies
   the carriage really is empty, from the dock and grab sensors.
2. Plate check: probes station Z with the bare carriage, then sideways for
   the bore edge.
3. Moves to the station start point (`cylinder_x`, `cylinder_y`, 28.5 /
   214.5 stock) and probes Z.
4. **Pass 1** — four sideways probes outward at Z + 0.6 (+X, +Y, −X, −Y,
   14 mm each), least-squares circle fit.
5. **Pass 2** — the same four probes re-centred on that fit, with Z
   re-probed there.
6. Stages `station_x`, `station_y`, `station_z` into `[ff_tool_offset]`.

#### `TOOL_CALIBRATE_TOOL_OFFSET` — one tool

No arguments, exactly as upstream. It measures **whatever is on the
carriage** — select the tool first.

`[SAVE=1]`

1. Plate check. It needs an empty carriage, so it parks your tool and picks
   it straight back up — that is expected, not a fault.
2. Zeroes the G-code offset and works in raw machine coordinates.
3. Same two passes as above, from `cylinder_x − 12.5` (16.0 stock), with the
   nozzle doing the touching.
4. Checks `nozzle_z − station_z` lands in `gap_min`…`gap_max` (1.5–5.0 mm;
   ~3.2 mm is right on a healthy machine).
5. Stages `nozzle_x`, `nozzle_y`, `nozzle_z` into `[ff_tool <n>]`.
6. Heater off for that tool, lifts to Z15, restores the offset frame.

#### `SAVE_CONFIG`

Writes the staged values into `printer.cfg`'s `#*#` block and restarts
Klipper. **Nothing persists until you run it.** `SAVE=0` on either command
measures and reports without staging anything.

---

### Where the numbers live

Autosaved into `printer.cfg`'s `SAVE_CONFIG` block. Never write these in an
included file — `SAVE_CONFIG` refuses to autosave an option an include
already sets.

```
#*# [ff_tool_offset]
#*# station_x = 28.791826
#*# station_y = 212.639328
#*# station_z = -1.678819
#*#
#*# [ff_tool 0]
#*# nozzle_x = 16.505066
#*# nozzle_y = 212.775040
#*# nozzle_z = 1.472569
#*# z_adjust = -0.020
```

On every grab of a tool, the toolchanger applies:

```
X = nozzle_x[tool] - nozzle_x[base]              difference vs the base tool
Y = nozzle_y[tool] - nozzle_y[base]
Z = nozzle_z[tool] - station_z + z_adjust[tool]  absolute
```

X and Y are differences, so the base tool's are zero. Z is absolute, which is
what makes Z0 the bed plane whenever a tool is mounted — not only after
`TOOLCHANGE_SET_PRINT_OFFSET` at print start.

Those go into a move transform **below** Klipper's own G-code offset, so
these stack without ever sharing a number:

| Layer | Set by | Scope | Read it as |
|---|---|---|---|
| `SET_GCODE_OFFSET` / `homing_origin` | you, and nothing else | every tool | `printer.gcode_move.homing_origin.z` |
| transform, job Z | `TOOLCHANGE_SET_PRINT_OFFSET`'s thermal/bed/layer terms | this print | `printer.toolchanger.print_z_offset` |
| transform, XYZ | `TOOL_CALIBRATE_TOOL_OFFSET` | the mounted tool | `printer["tool T<n>"].gcode_z_offset` |

Selecting a tool swaps the lower two and moves nothing. Ending a print calls
`TOOLCHANGE_SET_PRINT_OFFSET CLEAR=1`, which drops the job term and leaves
both the calibration and your babystep alone — so the number a UI shows as
"Z offset" or "baby stepping" really is just yours.

The flip side: `printer.gcode_move.position` is no longer the machine
position, because it is read *above* the transform. `gcode_position` and
`M114` are unchanged. A macro that wants the true machine Z of a G-code Z
has to subtract all three columns above.

See [`toolchange.md`](toolchange.md) for the toolchanger as a whole, and
[`notes/45-tool-offset-calibration.md`](notes/45-tool-offset-calibration.md)
for how the sequence was recovered from the stock firmware.

---

## Bed mesh

The shape of the plate, measured by probing a grid of points across it, so
the first layer can follow a bed that is not perfectly flat. 10×10 points,
bicubic interpolation, probed with the eddy sensor on the carriage — the same
sensor `G28 Z` homes on, which is why it can measure the plate but sits about
3.2 mm below the nozzle tip and cannot measure a nozzle.

**A mesh is always active for a print.** That was true of the stock firmware
too, and the mechanism is the same one, because it was always Klipper doing
the probing — the application only decided when.

There are two named profiles, and knowing which is which explains most
surprises:

| Profile | What it is |
|---|---|
| `MESH_DATA` | the factory mesh, probed before the printer shipped. This is what a print loads unless told otherwise |
| `default` | the working profile `BED_MESH_CALIBRATE` writes into |

`START_PRINT` loads `MESH_DATA` on every print. Given `LEVEL=1` it instead
probes a fresh mesh — dropping acceleration to 2000 for the probing run and
putting it back afterwards — and loads `default`.

The consequence catches people out: probing a mesh by hand leaves it in
`default`, which the automatic path never loads. To make your own mesh the
one prints use, it has to be saved over `MESH_DATA` — see
[Bed mesh](bed-mesh.md).

## Input shaping

How much the machine rings when it accelerates, so Klipper can shape moves to
avoid exciting that ringing. It is Klipper's own calibration
(`SHAPER_CALIBRATE`, `TEST_RESONANCES`, `MEASURE_AXES_NOISE`), and it works
the way it does on any Klipper printer.

One thing is specific to a toolchanger: the commands are wrapped so that they
home if needed and **grab a head first** when the carriage is empty. A bare
carriage weighs less than a loaded one, and resonance measured on the wrong
mass describes a machine you do not own. Which head it picks is configurable,
and it stays mounted afterwards.

The stock application did the same thing for the same reason.
