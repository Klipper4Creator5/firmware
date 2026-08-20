# FlashForge Creator 5 Pro — native toolchanger for Klipper/Mainsail

<a href="https://buymeacoffee.com/monstrofil"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-monstrofil-FFDD00?logo=buymeacoffee&logoColor=black" alt="Buy me a coffee"></a>

Makes the Creator 5 Pro's 4-tool toolchanger and print lifecycle work for
prints started from Mainsail/Moonraker (e.g. sliced in OrcaSlicer), without
the stock touchscreen app in the loop. Based on reverse-engineering the
stock `firmwareExe` binary (addresses referenced in the source comments),
with some behaviour improved along the way — deliberate divergences are
documented in the file headers.

## What's in here

| File | Goes to (on the printer) | What it does |
|---|---|---|
| [`klippy-extras/ff_toolchange.py`](klippy-extras/ff_toolchange.py) | `/usr/prog/klipper/klippy/extras/` | The toolchanger: `T0..T3`, dock/grab state machine with sensor polling and retries, per-tool G-code offsets, `TOOLCHANGE_SET_PRINT_OFFSET` (the absolute print-start Z offset), `TOOLCHANGE_STATUS`, `TOOLCHANGE_RELOAD`, `TOOLCHANGE_PARK` |
| [`config/ff-toolchange.cfg`](config/ff-toolchange.cfg) | `/usr/data/config/` | Configuration + `SDCARD_PRINT_FILE` wrapper. Carries **no per-unit numbers** — calibration is read live from firmwareExe's own JSON |
| [`config/ff-print-macros.cfg`](config/ff-print-macros.cfg) | `/usr/data/config/` | `START_PRINT` / `END_PRINT` / `PAUSE` / `RESUME` / `CANCEL_PRINT`, reconstructed from the app's sequences |
| [`orca/`](orca/) | OrcaSlicer printer profile | Machine start/end G-code, change-filament G-code, example project |

## ⚠️ Use at your own risk

This is unofficial, reverse-engineered firmware modification. It is not
endorsed by FlashForge, it voids whatever warranty you had, and **you alone
are responsible for what happens to your printer**. Mistakes here are not
hypothetical — a wrong Z offset drives the nozzle through the build plate,
and a failed grab or missing check can end like this:

<img src="docs/molten-toolhead.jpg" alt="molten toolhead with a blob of melted plastic" width="450">

Read the warnings below, run the Verify section before the first print,
and stay next to the machine until you trust it.

## ⚠️ Before you start

* **The eddy probe's Z home is ~3.2 mm below the real bed plane.** The stock
  app compensates with an absolute `SET_GCODE_OFFSET Z=+3.2xx` at print
  start; `START_PRINT` calls `TOOLCHANGE_SET_PRINT_OFFSET` to do the same.
  Printing without these macros (or with a stale copy of them) drives the
  nozzle into the plate.
* **Never edit the JSON under `/usr/data/firmwareRes/config/`.** It holds
  per-unit factory/touchscreen calibration; the app rewrites those files
  wholesale. This module only reads them.
* **Klipper lives on the firmware partition.** A FlashForge OTA update will
  overwrite `/usr/prog/klipper/`, deleting `ff_toolchange.py`. Keep this
  repo and re-run step 1 after every firmware update.

## Install

On the printer (ssh as `pwned`):

```sh
# 1. the klippy extra (firmware partition — may need remount rw)
scp klippy-extras/ff_toolchange.py pwned@PRINTER:/usr/prog/klipper/klippy/extras/

# 2. the config files (data partition — survives OTA)
scp config/ff-toolchange.cfg config/ff-print-macros.cfg pwned@PRINTER:/usr/data/config/
```

3. Append to `/usr/data/config/printer.cfg` (order matters — must come
   AFTER `[virtual_sdcard]` is defined; do **not** put these in
   `printer.override.cfg`, which is included first):

```ini
[include ff-toolchange.cfg]
[include /usr/data/config/ff-print-macros.cfg]
```

4. Reboot the printer.

## Verify

Before moving anything:

* `TOOLCHANGE_STATUS` — every dock coordinate, feedrate and offset with
  its provenance; flags disagreement with the app's `now_extruder`.
* Physical Z check (clean bed, nothing on it):

  ```gcode
  G28
  T0
  TOOLCHANGE_SET_PRINT_OFFSET NOZZLE=220 BED=80 LAYER=0.25 TOOL=0
  G1 X150 Y150 F6000
  G1 Z0.1 F600
  ```

  The offset command reports a Z around +3.2 with a term-by-term
  breakdown, and the nozzle should end up a paper-thickness above the
  bed at the center. If it presses into the plate instead, STOP — the
  offset is not being applied; do not print until `TOOLCHANGE_STATUS`
  is clean. Afterwards restore the idle state:

  ```gcode
  G1 Z10 F1200
  TOOLCHANGE_PARK
  SET_GCODE_OFFSET X=0 Y=0 Z=0 MOVE=1
  ```

After a touchscreen recalibration, run `TOOLCHANGE_RELOAD` (or reboot) to
pick up the new JSON.

## OrcaSlicer setup

In the printer profile:

* **Machine start G-code**: contents of
  [`orca/machine-start-gcode.txt`](orca/machine-start-gcode.txt)
* **Machine end G-code**: contents of
  [`orca/machine-end-gcode.txt`](orca/machine-end-gcode.txt)
* **Change filament G-code**: contents of
  [`orca/change-filament-gcode.txt`](orca/change-filament-gcode.txt) —
  `T[next_extruder] ; ff-toolchange`, where the trailing comment is
  load-bearing (see below)

Or skip the copy-pasting: open
[`orca/creator-mainsail.3mf`](orca/creator-mainsail.3mf) in OrcaSlicer —
an example project with the "Mainsail - Flashforge Creator 5 Pro 0.4
nozzle" printer profile already carrying all three G-code blocks above.

Re-slice anything sliced with older start G-code — old files won't call
`TOOLCHANGE_SET_PRINT_OFFSET` and will print ~3.2 mm low.

`START_PRINT` options: `LEVEL=1` probes a fresh mesh (recommended for the
first print), `SOAK=<seconds>` overrides the bed heat soak (default 30,
`SOAK=0` skips; progress is reported in the console).

### Why `T[next_extruder] ; ff-toolchange` and not just `T[next_extruder]`

The comment satisfies two different parsers at once:

* **OrcaSlicer** reads the change-filament block with a real G-code parser.
  It sees an actual `T<n>` command in there, decides the custom G-code
  already changes the tool (`custom_gcode_changes_tool()`), and stops
  emitting its own bare `Tn` after the block — so the tool change happens
  exactly once.
* **FlashForge's Klipper fork** traps toolchange lines *before* they reach
  the G-code interpreter: `virtual_sdcard.py` (line 566) checks
  `line.startswith("T") and line in VALID_GCODE_T`, where `line` comes
  straight from `data.split('\n')` and is **never stripped or normalized**.
  A bare `T2` matches the exact string in `VALID_GCODE_T`, gets swallowed
  by the fork, and is handed to the touchscreen app, which then blocks the
  print on its own `doingChangeEx`/`refuelling` state — state that only the
  touchscreen UI advances. `T2 ; ff-toolchange` is not the exact string
  `T2`, so the trap does not fire; the line falls through to
  `gcode.run_script()`, where `ff_toolchange.py`'s `T2` handler services it.

This is also why touchscreen-started prints are untouched: FF-sliced files
carry bare `Tn` lines, which the fork still intercepts and the app still
services exactly as before. Only lines with the marker comment reach this
module.

## Design notes

* Per-tool offsets are **differences vs a base tool (T0)**, applied on each
  grab the way `CommMgr::setGrabGcodeOffsetMgr` computes them; the
  once-per-print **absolute** Z base (`BuildPage::startPrint`) is set by
  `TOOLCHANGE_SET_PRINT_OFFSET` after the first grab and carried through
  toolchanges. The base-tool term cancels algebraically, so a print may
  start on any tool. Babysteps made mid-print are carried across
  toolchanges, as in the app. Note this split (absolute base at print
  start + differences on grab) is a rewrite of how the original
  `firmwareExe` structures it, kept for fidelity — it would arguably be
  cleaner to apply the absolute offset on the *first toolchange* rather
  than as a `START_PRINT` step, and that change is being considered (see
  Roadmap).
* Everything is a Python extra (not gcode_macro) because the grab sequence
  polls the grab sensor and retries up to 3 times — a macro renders its
  whole template before executing and cannot poll.

## Roadmap

Fool-proofing, in rough priority order:

* **Forbid `G28` while a tool is mounted.** Homing Z runs on the eddy
  probe's frame; with a tool in the head the nozzle rams into the plate.
  The module should refuse (or auto-park first) instead of trusting the
  operator.
* **Z-height / clearance check after picking a tool**, before leaving the
  dock area — catch a bad grab early instead of dragging or breaking the
  tool on the way out.
* **Move the absolute print Z offset from `START_PRINT` to the first
  toolchange of a job**, removing the ordering dependency between the
  macro and the slicer's start G-code.

Reverse-engineering notes (recovered sequences, addresses, JSON semantics)
live in the parent project's `OKF/` directory.

## Support

If this saved your build plate (or your sanity), you can
[buy me a ~~coffee~~ new hotend](https://buymeacoffee.com/monstrofil).
