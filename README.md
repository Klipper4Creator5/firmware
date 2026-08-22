# FlashForge Creator 5 Pro — native toolchanger for Klipper/Mainsail

<a href="https://buymeacoffee.com/monstrofil"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-monstrofil-FFDD00?logo=buymeacoffee&logoColor=black" alt="Buy me a coffee"></a>

Makes the Creator 5 Pro's 4-tool toolchanger and print lifecycle work for
prints started from Mainsail/Moonraker (e.g. sliced in OrcaSlicer), without
the stock touchscreen app in the loop. Based on reverse-engineering the
stock `firmwareExe` binary (addresses referenced in the source comments),
with some behaviour improved along the way — deliberate divergences are
documented in the file headers.

> **Branch `klipper-vanilla` — not yet run on hardware.** Everything on
> this branch has been exercised against a mock Klipper harness only. The
> `main` branch keeps the previous design, which reads calibration live
> from firmwareExe's JSON and has been used on a real printer. Here all
> per-unit numbers live in ordinary Klipper config, and the touchscreen's
> nozzle-offset calibration is reimplemented as Klipper commands.

## What's in here

| File | Goes to (on the printer) | What it does |
|---|---|---|
| [`klippy-extras/ff_toolchange.py`](klippy-extras/ff_toolchange.py) | `/usr/prog/klipper/klippy/extras/` | The toolchanger: `T0..T3`, dock/grab state machine with sensor polling and retries, per-tool G-code offsets (the absolute ~3.2 mm bed-frame Z is applied at every grab), `TOOLCHANGE_SET_PRINT_OFFSET` (the print-start thermal/bed/layer Z terms), `TOOL_Z_ADJUST` (per-tool persistent babystep), `TOOLCHANGE_STATUS`, `TOOLCHANGE_PARK` |
| [`helixscreen/flashforge_creator5_pro.json`](helixscreen/flashforge_creator5_pro.json) | HelixScreen `config/printer_database.d/` | Printer-database entry so HelixScreen auto-detects the Creator 5 Pro as a tool changer |
| [`klippy-extras/ff_tool.py`](klippy-extras/ff_tool.py) | `/usr/prog/klipper/klippy/extras/` | `[ff_tool n]` — one section per tool; `dock_x/dock_y`, `nozzle_x/y/z` and `z_adjust` are all autosaved (import or calibration + `SAVE_CONFIG`) |
| [`klippy-extras/ff_tool_offset.py`](klippy-extras/ff_tool_offset.py) | `/usr/prog/klipper/klippy/extras/` | `TOOL_OFFSET_CALIBRATE` / `STATION_CALIBRATE` / `TOOL_OFFSET_STATUS` — the touchscreen's nozzle XY/Z offset calibration, recovered from the binary and reimplemented in Klipper |
| [`klippy-extras/ff_legacy.py`](klippy-extras/ff_legacy.py) | `/usr/prog/klipper/klippy/extras/` | `FF_IMPORT_FIRMWARE_CONFIG` — one-shot import of the factory/touchscreen JSON into Klipper config. Needed once, at install |
| [`config/ff-toolchange.cfg`](config/ff-toolchange.cfg) | `/usr/data/config/` | empty `[ff_tool 0..3]` sections (the per-unit dock/nozzle data is autosaved, nothing unit-specific ships), `[ff_toolchange]` feeds/geometry, `SDCARD_PRINT_FILE` wrapper |
| [`config/ff-tool-offset.cfg`](config/ff-tool-offset.cfg) | `/usr/data/config/` | `[ff_tool_offset]` — probe geometry and guards for the calibration commands |
| [`config/ff-legacy.cfg`](config/ff-legacy.cfg) | `/usr/data/config/` | `[ff_legacy]` — include only for the import step, then remove |
| [`config/ff-print-macros.cfg`](config/ff-print-macros.cfg) | `/usr/data/config/` | `START_PRINT` / `END_PRINT` / `PAUSE` / `RESUME` / `CANCEL_PRINT`, reconstructed from the app's sequences, plus the calibration gate |
| [`config/ff-filament.cfg`](config/ff-filament.cfg) | `/usr/data/config/` | `LOAD_FILAMENT` / `UNLOAD_FILAMENT` / `PURGE` — the touchscreen's filament-load sequence (grab tool, purge chute, feed) recovered from the binary; unload is a designed retract (the stock app has none) |
| [`config/ff-runout.cfg`](config/ff-runout.cfg) | `/usr/data/config/` | Runout / clog handling: gives the stock `fd_ex*` / `fm_ex*` sensors a `runout_gcode` that pauses a Mainsail print when the **mounted** tool runs out or clogs (the app's E0162 / E0163); `ff_toolchange` arms only the mounted tool's sensors |
| [`orca/`](orca/) | OrcaSlicer printer profile | Machine start/end G-code, change-filament G-code, example project |
| [`docs/notes/`](docs/notes/) | (reference only) | Condensed reverse-engineering notes: what the stock app actually does, with binary addresses |

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
  start. Here every `T<n>` grab applies that tool's gap
  (`nozzle_z − station_z + z_adjust`) as the Z offset, so Z=0 is the bed
  whenever a tool is mounted; `START_PRINT`'s `TOOLCHANGE_SET_PRINT_OFFSET`
  only adds the thermal/bed/thin-layer terms (< 0.1 mm). With no tool
  mounted, or on an uncalibrated machine, Z=0 is still ~3.2 mm *below* the
  plate — the print gate refuses to start in that state.
* **Where the numbers live.** Nothing is read from firmwareExe's JSON at
  runtime any more. Feeds and staging positions (`[ff_toolchange]`) are
  plain config in `ff-toolchange.cfg`. Per-unit values — `dock_x/dock_y`,
  `nozzle_x/y/z` and `z_adjust` per tool, `station_x/y/z`, `cylinder_x/y` —
  are written by the import/calibration commands (`configfile.set`) and persisted with
  `SAVE_CONFIG` into the `#*#` block at the end of `printer.cfg`, exactly
  like PID or input-shaper results. **Never put those autosaved options
  into an included `.cfg`**: this Klipper fork's `SAVE_CONFIG` refuses with
  "conflicts with included value" and the calibration cannot be saved.
* **Still never edit the JSON under `/usr/data/firmwareRes/config/`.** This
  module no longer reads it, but the touchscreen app still does and rewrites
  those files wholesale — leave it alone.
* **Klipper lives on the firmware partition.** A FlashForge OTA update will
  overwrite `/usr/prog/klipper/`, deleting the extras. Keep this repo and
  re-run step 1 after every firmware update. The `#*#` block in
  `printer.cfg` is on the data partition and survives.

## Install

On the printer (ssh as `pwned` — this assumes a jailbroken printer; how to
get root/ssh access is covered in the community
[Discord](https://discord.gg/tYs3eNEDq)):

```sh
# 1. the klippy extras (firmware partition — may need remount rw)
scp klippy-extras/ff_tool.py klippy-extras/ff_toolchange.py \
    klippy-extras/ff_tool_offset.py klippy-extras/ff_legacy.py \
    pwned@PRINTER:/usr/prog/klipper/klippy/extras/

# 2. the config files (data partition — survives OTA)
scp config/ff-toolchange.cfg config/ff-tool-offset.cfg \
    config/ff-print-macros.cfg config/ff-filament.cfg config/ff-runout.cfg \
    config/ff-legacy.cfg \
    pwned@PRINTER:/usr/data/config/
```

3. Append to `/usr/data/config/printer.cfg` (order matters — must come
   AFTER `[virtual_sdcard]` is defined; do **not** put these in
   `printer.override.cfg`, which is included first):

```ini
[include ff-toolchange.cfg]
[include ff-tool-offset.cfg]
[include ff-filament.cfg]
[include ff-print-macros.cfg]  ; after ff-filament.cfg (the nozzle clean uses it)
[include ff-runout.cfg]        ; after printer.base.cfg (overrides its sensor sections)
[include ff-legacy.cfg]        ; temporary — only for step 5
```

4. `RESTART` (or reboot).

5. Import the factory/touchscreen calibration once:

   ```gcode
   FF_IMPORT_FIRMWARE_CONFIG
   ```

   This reads `extruder.json` / `test.json` / `zoffset.json` and stages
   **your unit's** dock coordinates, nozzle and station values, station
   start point and any per-tool Z tune for `SAVE_CONFIG`. Nothing to
   paste; it only prints an `[ff_toolchange]` snippet if a feed in the JSON
   differs from the running config (it does not on a stock unit).

6. `SAVE_CONFIG` — persists the imported values into `printer.cfg`'s `#*#`
   block and restarts.

7. `TOOLCHANGE_STATUS` and `TOOL_OFFSET_STATUS` — every tool should show a
   nozzle triple and a dock position, the station `z` must be present;
   nothing should say `NOT CALIBRATED`, "no dock position" or "unsaved
   calibration pending".

8. Remove the `[include ff-legacy.cfg]` line and `RESTART`. The import is
   one-shot; the touchscreen's JSON is not consulted again.

## Verify

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
  TOOLCHANGE_PARK
  SET_GCODE_OFFSET X=0 Y=0 Z=0 MOVE=1
  ```

A touchscreen recalibration no longer affects this module. Recalibrate from
Klipper instead (next section), or repeat the import step if you really
want the touchscreen's numbers.

## Calibration

The nozzle XY/Z offset calibration is the touchscreen's own sequence
(`testEddyExtruderOffsetForwardTwoCheck`, recovered from the binary — see
[`docs/notes/45-tool-offset-calibration.md`](docs/notes/45-tool-offset-calibration.md)
and [`46-offset-calibration-recovered.md`](docs/notes/46-offset-calibration-recovered.md)),
constants included. **Take the PEI sheet off first** — the calibration
station sits below the bed plane and the Z probe cannot tell a build plate
from air. Home, then:

```gcode
STATION_CALIBRATE PLATE_REMOVED=1              ; empty carriage, no tool mounted
TOOL_OFFSET_CALIBRATE TOOL=ALL PLATE_REMOVED=1 ; or TOOL=<0..3> for one tool
SAVE_CONFIG
```

`STATION_CALIBRATE` probes the fixed under-bed station with the empty
carriage (eddy frame) and stores `station_x/y/z`; `TOOL_OFFSET_CALIBRATE`
then picks up each tool, touches the station's cylinder in four directions
with the nozzle, fits a circle, repeats the pass centred on that fit and
stores the nozzle's absolute `nozzle_x/y/z`. Results are station-frame
absolutes per tool, so recalibrating one tool leaves the others valid;
`nozzle_z − station_z` is the ~3.2 mm gap the print-start Z offset uses.
Re-run `STATION_CALIBRATE` whenever the station or bed is disturbed.

Per-tool first-layer tuning: Klipper's `SET_GCODE_OFFSET Z_ADJUST=` babystep
is one global number. Use

```gcode
TOOL_Z_ADJUST TOOL=2 ADJUST=-0.02   ; relative, or VALUE=<mm> absolute
SAVE_CONFIG                         ; when you are happy with it
```

instead: it edits `[ff_tool 2] z_adjust`, re-applies immediately if that
tool is mounted, is added on every later grab of that tool, and persists.

## Safety

* **Prints refuse to start while uncalibrated.** `START_PRINT` runs
  `_FF_REQUIRE_CALIBRATION` first, and the Mainsail entry point (the
  `SDCARD_PRINT_FILE` wrapper) checks `printer.ff_toolchange.print_offset_ready`:
  if any tool's `nozzle_z` or the `station_z` is missing, the job is refused
  before anything heats, homes or grabs, with the fix spelled out. Override
  only for bench tests:
  `SET_GCODE_VARIABLE MACRO=_FF_JOB VARIABLE=allow_uncalibrated VALUE=1`.
* **Calibration moves are bounded.** Both calibration commands require
  `PLATE_REMOVED=1`; the Z probe targets −3 by default (the app's own
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
  runs `_FF_REQUIRE_TOOLS`: every tool the file uses must be sitting in its
  dock (switch pressed) or be the mounted one, else the job is refused with
  the list of what is missing (the app's E0165 — which only checked the
  first tool and let the others fail mid-print at their grab).
* **Runout and clogs pause the print.** See [Runout / clog](#runout--clog).

## Filament load / unload

`config/ff-filament.cfg` reproduces the touchscreen's FilamentLoad page
(recovered from the binary — [`docs/notes/47-filament-load-recovered.md`](docs/notes/47-filament-load-recovered.md)):
each tool has its own direct-drive extruder, so loading means *grab the tool,
drive it to the purge chute at the back right (X275 Y254), heat to material
temperature + 30, push 150 + 145 mm at F240, park the tool, heater off*.

```gcode
LOAD_FILAMENT TOOL=1 TEMP=220          ; or MATERIAL=PETG (app's temperature table)
UNLOAD_FILAMENT TOOL=1 TEMP=220        ; prime 10 mm, then pull 80 mm out (LENGTH= to tune)
PURGE TOOL=1 PURGE_TEMP=220 LENGTH=50  ; app's clearNozzlePrint purge
```

* `TOOL` defaults to the mounted tool; `RELEASE=0` keeps the tool on the
  carriage afterwards, `HEAT_OFF=0` leaves the heater on.
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

## Runout / clog

The stock config ships all eight filament sensors with `pause_on_runout:
False` and a `runout_gcode` that only prints `wheel runout:Tn` — the
touchscreen app did the rest (polled the mounted channel's switch sensor
from its print loop, kept only the mounted tool's motion sensor enabled).
Without the app nothing would happen. `config/ff-runout.cfg` restates the
sensor sections (Klipper merges repeated sections, later options win — the
stock `printer.filament.cfg` stays untouched and OTA-safe) so that
`runout_gcode` calls `_FF_RUNOUT`, and `ff_toolchange` arms the mounted
tool's two sensors on every grab, disarms everything on release, and
re-arms on `RESUME` (the app's `setFilamentWheelManager`).

Flow: sensor fires while an SD print is running and the sensor belongs to
the mounted tool → `PAUSE`, `E0162 filament runout` / `E0163 clog` on the
display and console → fix the filament → `LOAD_FILAMENT TOOL=n` (its paused
path is the app's in-print feed: 100 mm, then 5 mm back) → `RESUME`.
Sensors of tools that are not mounted never fire, and nothing fires
outside a print. `TOOLCHANGE_STATUS` shows which sensors are armed;
`FF_RUNOUT_ARM [TOOL=n]` / `FF_RUNOUT_DISARM` do it by hand. Clog pausing
can be made report-only, as the app's `plugCheck` toggle did:
`SET_GCODE_VARIABLE MACRO=_FF_RUNOUT_CFG VARIABLE=clog_pause VALUE=0`.
No endless-spool: another tool is another head, not another spool of the
same material. Untested on hardware: whether the motion sensors
(`detection_length 50`, `event_delay 3`) stay quiet through `LOAD_FILAMENT`.

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
nozzle" printer profile already carrying all three G-code blocks above
(its start G-code predates `TOOLS=`/`TEMPS=` — paste the current
`machine-start-gcode.txt` over it to get the presence gate and nozzle clean).

Re-slice anything sliced with older start G-code — old files won't call
`TOOLCHANGE_SET_PRINT_OFFSET` and will print ~3.2 mm low.

`START_PRINT` options: `TOOLS=0,2` every tool the file uses (Orca:
`is_extruder_used[n]`, as in the snippet) — presence gate and pre-print
nozzle clean; `TEMPS=220,0,240,0` per-tool clean temperature (0 = use
`NOZZLE=`); `CLEAN=0` skips the clean (default on: each used tool is grabbed,
heated, purged 50 mm at the chute with the part fan on, wiped at the
station, cooled by 100 °C and docked while the bed heats — the app's
`clearNozzlePrint`); `LEVEL=1` probes a fresh mesh (recommended for the
first print); `SOAK=<seconds>` dwells after the bed reaches target (the app
waits 5 min; default 0).

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

* Per-tool X/Y offsets are **differences vs a base tool (T0)**, applied on
  each grab the way `CommMgr::setGrabGcodeOffsetMgr` computes them. Z is
  **absolute** on every grab: `nozzle_z − station_z + z_adjust`, the
  bed-frame gap the app only sets once per print (`BuildPage::startPrint`).
  This departs from the app deliberately — with the app's scheme a tool
  picked up outside a print sits in the raw eddy frame and a manual
  `G1 Z0.1` drives it 3 mm into the plate. `TOOLCHANGE_SET_PRINT_OFFSET`
  adds only the job terms (thermal, bed ≥ 100 °C, thin first layer) and
  those, plus mid-print babysteps, are carried across toolchanges as in
  the app. A print may start on any tool.
* Calibration is stored the way Klipper's own calibrators store theirs:
  absolute `nozzle_x/y/z` per `[ff_tool n]` section (modelled on
  `[bed_mesh <profile>]` / klipper-toolchanger's `[tool Tn]`) plus
  `[ff_tool_offset] station_x/y/z`, written with `configfile.set()` and
  persisted by `SAVE_CONFIG`; dock positions and the station start point
  are imported the same way. The offsets are derived at load.
  `[save_variables]` is deliberately not used. The stock touchscreen
  cannot see Klipper-side results — it keeps using its own JSON.
* Everything is a Python extra (not gcode_macro) because the grab sequence
  polls the grab sensor and retries up to 3 times, and the calibration
  drives the fork's `e_stop` probe objects directly — a macro renders its
  whole template before executing and cannot poll.

## Roadmap

Fool-proofing, in rough priority order:

* **Run this branch on hardware.** Calibration sequence, import and the
  safety gates are mock-tested only.
* **Forbid `G28` while a tool is mounted.** Homing Z runs on the eddy
  probe's frame; with a tool in the head the nozzle rams into the plate.
  The module should refuse (or auto-park first) instead of trusting the
  operator.
* **Z-height / clearance check after picking a tool**, before leaving the
  dock area — catch a bad grab early instead of dragging or breaking the
  tool on the way out.
* **Block the stock touchscreen UI during Mainsail prints.** The app
  doesn't know a print is running (it only tracks jobs it started
  itself), so the screen stays fully live — a stray tap can home, move
  the carriage, start a filament load, or fire its own toolchange into
  the middle of a running job. The module should lock the UI out (or at
  least its motion commands) while a Mainsail-started print is active.

## HelixScreen / tool-changer-aware UIs

`ff_toolchange` also registers the Klipper objects that UIs written for
[klipper-toolchanger](https://github.com/viesturz/klipper-toolchanger) look
for — `toolchanger` (`status`, `tool_number`, `tool_numbers`, `tool_names`) and
`tool T0..T3` (`active`, `mounted`, `extruder`, `fan`, `gcode_x/y/z_offset`) —
and the commands they send: `SELECT_TOOL T=<n>` (= `T<n>`), `UNSELECT_TOOL`
(= `TOOLCHANGE_PARK`), `INITIALIZE_TOOLCHANGER` (state check, no motion).
`ASSIGN_TOOL` is refused — remap tools in the slicer. Nothing to enable; it is
always on. `part_fan` in `[ff_toolchange]` is what gets reported as each
tool's fan (shared `fan_generic fanM106` on this machine).

[HelixScreen](https://github.com/prestonbrown/helixscreen) then runs its Tool
Changer backend: tool slots in the sidebar and print status, per-tool
temperatures and offsets, Spoolman per tool, the plain single-extruder runout
dialog. Drop `helixscreen/flashforge_creator5_pro.json` into HelixScreen's
`config/printer_database.d/` for auto-detection (`ams_type: tool_changer`,
`z_offset_calibration_strategy: firmware_managed`). Its default Load/Unload buttons only mount/unmount the tool (`SELECT_TOOL` /
`UNSELECT_TOOL`); to actually feed or pull filament assign `LOAD_FILAMENT`,
`UNLOAD_FILAMENT` and `PURGE` from [`config/ff-filament.cfg`](config/ff-filament.cfg)
in Settings → Macro Buttons — a user-assigned macro outranks the backend, and
the parameter dialog picks up `TOOL` / `TEMP` / `PURGE_TEMP` from the macros.

## Reverse-engineering notes

Condensed notes from the `firmwareExe` analysis — recovered sequences, binary
addresses, JSON semantics — live in [`docs/notes/`](docs/notes/):
architecture overview, the Klipper-fork delta (including the `Tn` interception),
[who decides what — app vs Klipper](docs/notes/25-app-vs-klipper-ownership.md)
(heaters, runout, doors, calibration; which "features" are dead code),
the verified grab/release sequences, the offset model, the recovered
nozzle-offset calibration and its Klipper port, and the full print
lifecycle with the deliberate divergences listed.

## Support

If this saved your build plate (or your sanity), you can
[buy me a ~~coffee~~ new hotend](https://buymeacoffee.com/monstrofil).
