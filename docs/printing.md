# Printing

Day-to-day use once the machine is calibrated: how to set the slicer up, the
rules that keep a toolchanger from damaging itself, and what happens when
filament runs out or clogs.

---

## Slicer setup

**Leave the profile stock.** An untouched FlashForge Orca profile works as
shipped: nothing to paste into Machine start or end G-code, and files sliced
before the mod keep printing. `[ff_print]` wraps `SDCARD_PRINT_FILE`/`M23`,
reads the bed, nozzle, initial tool and first-layer height out of the file
itself, and runs `START_PRINT` before the file's first line -- which the stock
block needs, because it has no `G28` (its first motion, `G1 Z5 F2400`, assumes
a homed machine) and no `M190` (nothing waits for the bed). At the other end
its `;end_gcode` is a single move that turns nothing off, so
`FF_AFTER_PRINT_END` runs the exit sequence when the job leaves the printing
state.

To drive the sequence from the slicer instead, put an explicit `START_PRINT`
call in Machine start G-code and set
`SET_GCODE_VARIABLE MACRO=FF_BEFORE_PRINT_START VARIABLE=prepare VALUE=0`
so the machine is not prepared twice.

Leave **Change filament G-code** empty. With no custom block Orca emits its
own bare `Tn` at each tool change, which reaches `ff_toolchange.py` directly.
Older instructions here asked for a `T[next_extruder] ; ff-toolchange` line to
dodge a trap in FlashForge's Klipper fork; we ship upstream `virtual_sdcard`
now and that trap is gone, so **clear the field** if it still holds anything.
Files already sliced with the old marker keep printing correctly — the G-code
parser discards the comment and `T2` arrives either way, so no re-slice is
needed for that.

No re-slicing is needed: `[ff_print]` applies the print Z offset for any file,
including ones sliced before the mod existed.

`START_PRINT` options, for the explicit path: `TOOLS=0:220,2:240` every tool
the file uses with its clean temperature (Orca: `is_extruder_used[n]`; a bare
`TOOLS=0,2` also works and falls back to `NOZZLE=`) — presence gate and
pre-print
nozzle clean; without explicit temperatures each tool is cleaned at the
temperature its `_FF_FILAMENT.tool_material` maps to; `CLEAN=0` skips the clean (default on: each used tool is grabbed,
heated, purged 50 mm at the chute with the part fan on, wiped at the
station, cooled by 100 °C and docked while the bed heats — the app's
`clearNozzlePrint`); `LEVEL=1` probes a fresh mesh (recommended for the
first print); `SOAK=<seconds>` dwells after the bed reaches target (the app
waits 5 min; default 0).

---

## The rules that matter

These are the gates the mod puts between a bad command and your build plate.
Knowing they exist explains most of what looks like the printer refusing to
cooperate.

* **`G28` docks a mounted tool before homing Z.** Z homes on the
  carriage's eddy sensor, whose trigger height is ~3.2 mm below the nozzle
  tip — with a head on, the nozzle hits the plate first. The `G28`
  wrapper in `ff-toolchange.cfg` homes X/Y (endstops at 0, away from the
  docks), runs `TOOLCHANGE_PARK`, then homes as asked; `G28 X`/`G28 Y`
  alone are untouched. If the dock sensors can't say whether a head is on,
  Z homing is refused.
* **Prints refuse to start while uncalibrated.** `START_PRINT` runs
  `_FF_PREFLIGHT` first, and `[ff_print]` runs it again through
  `FF_BEFORE_PRINT_START` before the file is even loaded:
  if any tool's `nozzle_z` or the `station_z` is missing, the job is refused
  before anything heats, homes or grabs, with the fix spelled out. Override
  only for bench tests:
  `SET_GCODE_VARIABLE MACRO=_FF_JOB VARIABLE=allow_uncalibrated VALUE=1`.
* **Calibration moves are bounded.** The plate check gates both
  calibration commands; the Z probe targets −3 by default (the app's own
  station value) and, once a trigger height is known, stops 2 mm below it
  instead of driving on.
* **Implausible results are not saved.** A circle-fit residual above
  0.05 mm, or a nozzle-to-station gap (`nozzle_z − station_z`) outside
  1.5–5 mm, aborts the command with nothing staged. Thresholds are in
  `ff-tool-offset.cfg`.
* A `T<n>` on an unhomed machine aborts instead of homing silently
  (`auto_home: False`) — a remote G28 with a tool mounted rams the nozzle
  into whatever is on the bed.
* **Missing tools are caught before anything moves.** `START_PRINT TOOLS=…`
  passes them to the same `_FF_PREFLIGHT`: every tool the file uses must be sitting in its
  dock (switch pressed) or be the mounted one, else the job is refused with
  the list of what is missing (the app's E0165 — which only checked the
  first tool and let the others fail mid-print at their grab).
* **Runout and clogs pause the print.** See [Runout and clogs](#runout-and-clogs).

---

## Filament: load, unload, purge

`payload/klipper/config/ff-filament.cfg` reproduces the touchscreen's FilamentLoad page
(recovered from the binary — [`docs/notes/47-filament-load-recovered.md`](notes/47-filament-load-recovered.md)):
each tool has its own direct-drive extruder, so loading means *grab the tool,
drive it to the purge chute at the back right (X275 Y254), heat to material
temperature + 30, push 150 + 145 mm at F240, park the tool, heater off*.

```gcode
LOAD_FILAMENT TOOL=1 TEMP=220          ; or MATERIAL=PETG (app's temperature table)
UNLOAD_FILAMENT TOOL=1 TEMP=220        ; prime 10 mm, then pull 80 mm out (LENGTH= to tune)
PURGE TOOL=1 PURGE_TEMP=220 LENGTH=50  ; app's clearNozzlePrint purge + cold wipe (WIPE=0 to skip)
```

* `TOOL` defaults to the mounted tool; `RELEASE=0` keeps the tool on the
  carriage afterwards, `HEAT_OFF=0` leaves the heater on.
* `PURGE` ends the way the app's pre-print clean does: the nozzle rests on
  the front-right wipe spot (266.5, 13.8) 1 mm above the eddy trigger height
  while the hotend cools by 100 °C, then lifts — the purge string freezes
  and tears off instead of riding back to the dock. `WIPE=0` skips it.
  `LOAD_FILAMENT` has no wipe, as in the app (its guide tells you to pull
  the string off).
* While a print is **paused** the macros only act on the mounted tool, use
  the app's in-print lengths (100 mm then −5), and leave tool and heater for
  `RESUME`. While **printing** they refuse.
* The stock app has **no retract-unload** — its "unload" is the same forward
  push and the on-screen guide tells you to cut and pull. `UNLOAD_FILAMENT`
  is therefore designed, not ported; `unload_length` (80 mm) in
  `[gcode_macro _FF_FILAMENT]` is a first guess — shorten it once you have
  measured the nozzle-to-above-gears path.
* All geometry, feeds, the temperature table and the per-tool chute nudges
  are variables of `[gcode_macro _FF_FILAMENT]`.

---

## Runout and clogs

The stock config ships all eight filament sensors with `pause_on_runout:
False` and a `runout_gcode` that only prints `wheel runout:Tn` — the
touchscreen app did the rest (polled the mounted channel's switch sensor
from its print loop, kept only the mounted tool's motion sensor enabled).
Without the app nothing would happen. `payload/klipper/config/ff-runout.cfg` restates the
sensor sections (Klipper merges repeated sections, later options win — the
stock `printer.filament.cfg` stays untouched and OTA-safe) so that
`runout_gcode` calls `_FF_RUNOUT`, and `ff_toolchange` arms the mounted
tool's two sensors on every grab, disarms everything on release, and
re-arms on `RESUME` (the app's `setFilamentWheelManager`).

Flow: sensor fires while an SD print is running and the sensor belongs to
the mounted tool → `PAUSE`, `T<n> out of filament` / `T<n> clog` on the
display and console → fix the filament → `LOAD_FILAMENT TOOL=n` (its paused
path is the app's in-print feed: 100 mm, then 5 mm back) → `RESUME`.
Sensors of tools that are not mounted never fire, and nothing fires
outside a print. `TOOLCHANGE_STATUS` shows which sensors are armed;
`FF_RUNOUT_ARM [TOOL=n]` / `FF_RUNOUT_DISARM` do it by hand. Clog pausing
can be made report-only, as the app's `plugCheck` toggle did:
`SET_GCODE_VARIABLE MACRO=_FF_RUNOUT_CFG VARIABLE=clog_pause VALUE=0`.

The pause is immediate, as the app's was. Note that the runout switch is
upstream of the extruder gear with a long PTFE run in between (~600 mm
here), so the head still holds that much printable filament when the print
stops — it is lost. Printing on and pausing once that length has been
extruded is a real improvement, but it needs a per-machine measurement and
a watcher counting extrusion; it is not built in.
No endless-spool: another tool is another head, not another spool of the
same material. Untested on hardware: whether the motion sensors
(`detection_length 50`, `event_delay 3`) stay quiet through `LOAD_FILAMENT`.
