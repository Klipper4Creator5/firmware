# The toolchanger mod

FlashForge Creator 5 Pro — native toolchanger for Klipper/Mainsail.

<a href="https://buymeacoffee.com/monstrofil"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-monstrofil-FFDD00?logo=buymeacoffee&logoColor=black" alt="Buy me a coffee"></a>

Makes the Creator 5 Pro's 4-tool toolchanger and print lifecycle work for
prints started from Mainsail/Moonraker (e.g. sliced in OrcaSlicer), without
the stock touchscreen app in the loop. Based on reverse-engineering the
stock `firmwareExe` binary (addresses referenced in the source comments),
with some behaviour improved along the way — deliberate divergences are
documented in the file headers.

> **This is the design side.** The checks to run before a first print are in
> [Your first print](first-print.md). What is on this page is what the extras
> do and why, for someone changing them.

## What's in here

| File | Goes to (on the printer) | What it does |
|---|---|---|
| [`pkgs/klipper/payload/klipper/klippy/extras/ff_toolchange.py`](../pkgs/klipper/payload/klipper/klippy/extras/ff_toolchange.py) | `/usr/data/anvil/klipper/klippy/extras/` | The toolchanger: `T0..T3`, dock/grab state machine with sensor polling and retries, per-tool G-code offsets (the absolute ~3.2 mm bed-frame Z is applied at every grab), `TOOLCHANGE_SET_PRINT_OFFSET` (the print-start thermal/bed/layer Z terms), `TOOL_Z_ADJUST` (per-tool babystep, live, saved on request), `TOOLCHANGE_STATUS`, `TOOLCHANGE_PARK` |
| [`pkgs/helixscreen/payload/helixscreen/config/printer_database.d/flashforge_creator5.json`](../pkgs/helixscreen/payload/helixscreen/config/printer_database.d/flashforge_creator5.json) | HelixScreen `config/printer_database.d/` | Printer-database entry so HelixScreen auto-detects both Creator 5 models as tool changers (the Pro and the non-Pro differ only by the chamber heater) |
| [`pkgs/klipper/payload/klipper/klippy/extras/ff_print.py`](../pkgs/klipper/payload/klipper/klippy/extras/ff_print.py) | `/usr/data/anvil/klipper/klippy/extras/` | `[ff_print]` — takes over `SDCARD_PRINT_FILE` and `M23`, reads bed/nozzle/initial tool/first-layer height out of the file itself, and calls `FF_BEFORE_PRINT_START` before the file's first line and `FF_AFTER_PRINT_END` once the job leaves the printing state. Declared in `ff-print-macros.cfg`; holds no policy of its own |
| [`pkgs/klipper/payload/klipper/klippy/extras/ff_tool.py`](../pkgs/klipper/payload/klipper/klippy/extras/ff_tool.py) | `/usr/data/anvil/klipper/klippy/extras/` | `[ff_tool n]` — one section per tool; `dock_x/dock_y`, `nozzle_x/y/z` and `z_adjust` are all autosaved (import or calibration + `SAVE_CONFIG`) |
| [`pkgs/klipper/payload/klipper/klippy/extras/ff_tool_offset.py`](../pkgs/klipper/payload/klipper/klippy/extras/ff_tool_offset.py) | `/usr/data/anvil/klipper/klippy/extras/` | `TOOL_CALIBRATE_TOOL_OFFSET` / `TOOL_LOCATE_SENSOR` / `TOOL_OFFSET_STATUS` — the touchscreen's nozzle XY/Z offset calibration, recovered from the binary and reimplemented in Klipper |
| [`pkgs/klipper/payload/klipper/klippy/extras/ff_legacy.py`](../pkgs/klipper/payload/klipper/klippy/extras/ff_legacy.py) | `/usr/data/anvil/klipper/klippy/extras/` | `FF_IMPORT_FIRMWARE_CONFIG` — one-shot import of the factory/touchscreen JSON into Klipper config. The command and nothing else: no startup behaviour. `bin/ff-startup.py` is what runs it on the first boot |
| [`pkgs/klipper-config/payload/config/ff-toolchange.cfg`](../pkgs/klipper-config/payload/config/ff-toolchange.cfg) | `/usr/data/config/` | empty `[ff_tool 0..3]` sections (the per-unit dock/nozzle data is autosaved, nothing unit-specific ships), `[ff_toolchange]` feeds/geometry, the `G28` dock-first wrapper |
| [`pkgs/klipper-config/payload/config/ff-tool-offset.cfg`](../pkgs/klipper-config/payload/config/ff-tool-offset.cfg) | `/usr/data/config/` | `[ff_tool_offset]` — probe geometry and guards for the calibration commands |
| [`pkgs/klipper-config/payload/config/ff-legacy.cfg`](../pkgs/klipper-config/payload/config/ff-legacy.cfg) | `/usr/data/config/` | `[ff_legacy]` — stays included permanently; declares the section and, optionally, `firmware_config_dir` |
| [`pkgs/anvil-core/payload/bin/ffscreen.py`](../pkgs/anvil-core/payload/bin/ffscreen.py) | `/usr/data/anvil/bin/` | A few lines of text and a progress bar drawn straight onto `/dev/fb0`, geometry read from sysfs. The framebuffer is **portrait 480×800@32** and the panel is that buffer turned 90° clockwise (landscape 800×480) — established from FlashForge's own `/usr/prog/start.img`, 1536000 bytes, which only decodes into a picture read that way. Drawing is done in landscape coordinates and each rectangle is rotated on the way into the buffer, so it costs arithmetic per rectangle and nothing per pixel. All of the first boot happens before HelixScreen starts, so without it the panel is black for the longest wait of the install — which reads as a brick and invites a power cut mid-`SAVE_CONFIG`. `make boot-screen` renders every frame to PNG on the host; `make boot-screen-sim` renders the same frames inside the replica using FlashForge's own python3 on MIPS (they come out byte-identical); `qa/replica/test_boot_screen.py` is the gate |
| [`pkgs/anvil-core/payload/bin/ff-startup.py`](../pkgs/anvil-core/payload/bin/ff-startup.py) | `/usr/data/anvil/bin/` | Everything before HelixScreen. **Every boot** it hands the toolhead boards over from their bootloaders (calling `ff_mcu_bringup.py` directly — it owns when klippy opens the ports, so it owns doing this first), starts klipper, and waits for klipper + moonraker to be ready, naming the board or service holding things up and re-handing the boards over on each retry. It runs as two s6-rc oneshots (`mcu-bringup`, then `ff-startup`), and the UI depends on the second — starting the UI before that is what produces a screen reporting a disconnected printer with no clue which board is missing. **First boot only**, once that has happened, it sends `FF_IMPORT_FIRMWARE_CONFIG` and `SAVE_CONFIG` over the moonraker API and stamps `/usr/data/anvil/.firmware-config-imported`. Only a verified save stamps, so a slow boot retries. It always runs and always waits — the `MOD_STARTUP` and `MOD_IMPORT` switches went with `anvil.conf` |
| [`pkgs/klipper-config/payload/config/ff-print-macros.cfg`](../pkgs/klipper-config/payload/config/ff-print-macros.cfg) | `/usr/data/config/` | `START_PRINT` / `END_PRINT` / `PAUSE` / `RESUME` / `CANCEL_PRINT`, reconstructed from the app's sequences, plus the `_FF_PREFLIGHT` calibration and tool-presence gate; declares `[ff_print]` and the `FF_BEFORE_PRINT_START` / `FF_AFTER_PRINT_END` entry points it calls |
| [`pkgs/klipper-config/payload/config/ff-filament.cfg`](../pkgs/klipper-config/payload/config/ff-filament.cfg) | `/usr/data/config/` | `LOAD_FILAMENT` / `UNLOAD_FILAMENT` / `PURGE` — the touchscreen's filament-load sequence (grab tool, purge chute, feed) recovered from the binary; unload is a designed retract (the stock app has none) |
| [`pkgs/klipper-config/payload/config/ff-runout.cfg`](../pkgs/klipper-config/payload/config/ff-runout.cfg) | `/usr/data/config/` | Runout / clog handling: gives the stock `fd_ex*` / `fm_ex*` sensors a `runout_gcode` that pauses a Mainsail print when the **mounted** tool runs out or clogs (the app's E0162 / E0163, reported here in plain words); `ff_toolchange` arms only the mounted tool's sensors |
| [`pkgs/klipper-config/payload/config/printer.base.cfg`](../pkgs/klipper-config/payload/config/printer.base.cfg) | `$MODDIR/config/` -> symlinked to `/usr/data/config/printer.base.cfg` | FlashForge's `printer.base.cfg` with the chamber block replaced by `[include printer.chamber.cfg]`. Klipper can override an option but cannot un-declare a section, and the plain Creator 5 has no chamber heating element, so its heater must be **absent** rather than neutralised. `bin/unpack.sh` compares this against each stock package it unpacks and warns if FlashForge's has changed |
| [`Creator5.cfg`](../pkgs/klipper-config/payload/config/chamber/Creator5.cfg) · [`Creator5Pro.cfg`](../pkgs/klipper-config/payload/config/chamber/Creator5Pro.cfg) | `$MODDIR/config/chamber/<Machine>.cfg` -> symlinked to `/usr/data/config/printer.chamber.cfg` | The one per-model difference: the Pro gets `[heater_generic chamber_heater]` + `[verify_heater]` verbatim from FlashForge, the Creator 5 gets only `[temperature_sensor chamber]` on the same pin. **Both ship in `anvil-klipper-config`** and `anvil-link-prog.sh` links whichever the printer asks for, reading `MACHINE=` out of FlashForge's own `app_startup.sh`. They used to be a package per model, which Conflicted — each owned `config/printer.chamber.cfg`, so the package manager refused the pair and the build had to choose. Nothing is edited at build time, and the payload is no longer model-specific |
| [`pkgs/klipper-config/payload/config/ff-chamber.cfg`](../pkgs/klipper-config/payload/config/ff-chamber.cfg) | `/usr/data/config/` | `M141` / `M191` for the chamber heater (Klipper has neither, and the stock app drove the chamber only from its own UI), plus the gate: the macros ask Klipper whether `heater_generic chamber_heater` exists, so a non-zero chamber target is refused on a machine that does not declare one. Nothing to keep in sync; identical in every package |
| [`docs/notes/`](notes/) | (reference only) | Condensed reverse-engineering notes: what the stock app actually does, with binary addresses |

## ⚠️ Before you start

* **The eddy probe's Z home is ~3.2 mm below the real bed plane.** The stock
  app compensates with an absolute `SET_GCODE_OFFSET Z=+3.2xx` at print
  start. Here every `T<n>` grab applies that tool's gap
  (`nozzle_z − station_z + z_adjust`) as the Z offset, so Z=0 is the bed
  whenever a tool is mounted; `START_PRINT`'s `TOOLCHANGE_SET_PRINT_OFFSET`
  only adds the thermal/bed/thin-layer terms — small, but not negligible:
  `NOZZLE=220 BED=80` (the example below) gives 0.045 mm, and a bed at 100 °C
  or above adds a further 0.08 mm. With no tool
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
* **Klipper lives on the data partition.** The extras install under
  `/usr/data/anvil/klipper/klippy/extras/`, which a FlashForge OTA cannot
  delete — but an OTA rewrites the software component the mod boots from, so
  re-flash the mod after one. The `#*#` block in `printer.cfg` survives either
  way.

## Install

A package built from this repo needs no config editing at all. It ships:

* the `ff_*.py` extras, inside the klippy tree `anvil-klipper` installs
* the `ff-*.cfg`, to `/usr/data/config/` (`runFirmwareExe.sh`, keeping any you
  edited and leaving the new one as `.mod-new`)
* the `[include]` lines for all seven, at the end of `printer.base.cfg` —
  which the stock `run.sh` force-copies to `/usr/data/config/` on every flash

`printer.cfg` is never touched by any of that, by design: it is the user's
file. That is also why the includes live in `printer.base.cfg` and not there
— and it makes the undo button work, since flashing the stock FlashForge
package restores its own `printer.base.cfg` and the includes go with it.

Flash, and your unit's calibration imports itself on the first boot — step 5
below says how, and step 6 how to check it.

### By hand

For dropping a single edited file onto a printer that is already modded. On
the printer (ssh as `pwned` — this assumes a jailbroken printer; how to get
root/ssh access is covered in the community
[Discord](https://discord.gg/tYs3eNEDq)):

```sh
# 1. the klippy extras (data partition — the tree the klipper service runs)
scp pkgs/klipper/payload/klipper/klippy/extras/ff_*.py \
    pwned@PRINTER:/usr/data/anvil/klipper/klippy/extras/

# 2. the config files (data partition — survives OTA)
scp pkgs/klipper-config/payload/config/ff-*.cfg \
    pwned@PRINTER:/usr/data/config/
```

3. Make sure something includes them. A flashed printer already does, at the
   end of `printer.base.cfg`. **All seven are required** — they are not
   optional drop-ins, and without them Klipper comes up as a plain printer
   with no toolchanger:

```ini
[include ff-toolchange.cfg]
[include ff-tool-offset.cfg]
[include ff-filament.cfg]
[include ff-print-macros.cfg]
[include ff-runout.cfg]        ; after printer.base.cfg (overrides its sensor sections)
[include ff-chamber.cfg]       ; M141/M191; follows whatever printer.chamber.cfg declared
[include ff-legacy.cfg]        ; harmless to leave in — see step 7
```

   > **If you put these in `printer.cfg` instead, they must go ABOVE the
   > `#*# <---------------------- SAVE_CONFIG ---------------------->`
   > marker.** Klipper treats any non-`#*#` line below that marker as
   > corruption, discards the entire autosave block, and every calibrated
   > value — PID, mesh, shaper, nozzle and dock positions — stops being read.

   Only two ordering rules are real, and both are about one file overriding
   another's values, which Klipper applies in include order: `ff-runout.cfg`
   after the sensor sections in `printer.base.cfg`, and `ff-chamber.cfg`
   after `printer.chamber.cfg`. Placement relative to `[virtual_sdcard]` does
   **not** matter — `ff_print` takes `SDCARD_PRINT_FILE`/`M23` over at
   `klippy:connect`, once every section is loaded — and neither does
   placement relative to the commands the `G28` and `SHAPER_CALIBRATE`
   wrappers rename, since `gcode_macro` defers its rename to `klippy:connect`
   as well.

4. `RESTART` (or reboot).

5. The factory/touchscreen calibration imports itself on the first boot after
   the flash — driven from outside Klipper by
   [`bin/ff-startup.py`](../pkgs/anvil-core/payload/bin/ff-startup.py),
   which the `firmwareExe` wrapper runs ahead of HelixScreen. It waits until
   klipper and moonraker are up — those two and nothing else, since that is
   what it talks to; the browser UI gets a short grace period and is then
   ignored, so a Fluidd build or one with no browser UI at all still
   migrates — then sends the
   two commands below over the moonraker API: `[ff_legacy]` reads `extruder.json` /
   `test.json` / `zoffset.json` and stages **your unit's** dock coordinates,
   nozzle and station values, station start point and any per-tool Z tune,
   and `SAVE_CONFIG` persists them into `printer.cfg`'s `#*#` block. That
   save restarts Klipper once, before the UI is up: the wizard never meets an
   uncalibrated machine. Then it stamps
   `/usr/data/anvil/.firmware-config-imported` and never runs again — delete
   the stamp to redo it. To skip the migration entirely, create the stamp
   before the first boot; there is no longer a switch for it. The manual form,
   for inspecting or after a `RESTORE`:

   ```gcode
   FF_IMPORT_FIRMWARE_CONFIG            ; APPLY=0 to only print, stage nothing
   SAVE_CONFIG
   ```

   Only a save it can verify writes the stamp. A boot where the heater board
   needed several klippy restarts simply times out and tries
   again next boot; `/usr/data/logs/anvil-boot.log` says which service it was
   waiting on.

   Nothing to paste either way; the import only prints an `[ff_toolchange]`
   snippet if a feed in the JSON differs from the running config (it does not
   on a stock unit).

6. `TOOLCHANGE_STATUS` and `TOOL_OFFSET_STATUS` — every tool should show a
   nozzle triple and a dock position, the station `z` must be present;
   nothing should say `NOT CALIBRATED`, "no dock position" or "unsaved
   calibration pending".

7. Optionally remove the `[include ff-legacy.cfg]` line and `RESTART`. Not
   required: the import returns early as soon as any tool has a nozzle
   position, so the section is inert once the import has been saved. A
   flashed printer keeps it included.

## Calibration

The nozzle XY/Z offset calibration is the touchscreen's own sequence
(`testEddyExtruderOffsetForwardTwoCheck`, recovered from the binary — see
[`docs/notes/45-tool-offset-calibration.md`](notes/45-tool-offset-calibration.md)
and [`46-offset-calibration-recovered.md`](notes/46-offset-calibration-recovered.md)),
constants included. **Take the PEI sheet off first** — the calibration
station sits below the bed plane. Nothing asks you to promise that: both
commands park the carriage and *measure* it, probing the station Z with the
bare carriage (it must not land more than 0.8 mm **above** the calibrated
`station_z` — the check is one-sided, since a plate can only hold the probe
high) and sweeping sideways for the circle's edge. A plate left on lands
the Z probe high and has no edge, so the command refuses before any nozzle
descends (`PLATE_CHECK=0` or `plate_check: False` skips it). Home, then:

```gcode
CALIBRATE_TOOL_OFFSETS   ; or, by hand:
TOOL_LOCATE_SENSOR       ; empty carriage, parks the mounted tool for you
SELECT_TOOL T=0
TOOL_CALIBRATE_TOOL_OFFSET   ; measures whatever is on the carriage
SAVE_CONFIG
```

`TOOL_LOCATE_SENSOR` probes the fixed under-bed station with the empty
carriage (eddy frame) and stores `station_x/y/z`; `TOOL_CALIBRATE_TOOL_OFFSET`
touches the station's cylinder in four directions with the mounted tool's
nozzle, fits a circle, repeats the pass centred on that fit and
stores the nozzle's absolute `nozzle_x/y/z`. Results are station-frame
absolutes per tool, so recalibrating one tool leaves the others valid;
`nozzle_z − station_z` is the ~3.2 mm gap the print-start Z offset uses.
Re-run `TOOL_LOCATE_SENSOR` whenever the station or bed is disturbed.

`CALIBRATE_TOOL_OFFSETS` runs both passes in one command. It is
klipper-toolchanger's documented entry point, so it is the name HelixScreen's
setup wizard and other UIs look for — the two commands above are what it calls.
[`calibration.md`](calibration.md) is the operator's walkthrough: the order,
the expected output, and every refusal the commands can raise.

**Probe sampling.** Both commands take klipper-toolchanger's parameters —
`SAMPLES`, `SAMPLES_TOLERANCE`, `SAMPLES_TOLERANCE_RETRIES`,
`SAMPLES_RESULT` (`average` or `median`), `SAMPLE_RETRACT_DIST`,
`PROBE_SPEED` — applied to every probe of the run, or set once in
`[ff_tool_offset]`. Left alone they follow the fork's own `[e_stop <axis>]`
settings, which already sample: three touches, spread rejected above
`error_v` (0.02 mm), retried up to `main_cycle_cnt` times, `back_v` retract
between them, averaged. So the defaults probe exactly as before this was
reachable; the parameters widen or narrow that, and add the median upstream
offers and the fork does not. Upstream's `LIFT_SPEED` has no counterpart:
the retract between touches runs along the probe axis, at `PROBE_SPEED`.

```gcode
TOOL_CALIBRATE_TOOL_OFFSET SAMPLES=5 SAMPLES_RESULT=median
```

Note on the word "gap": `station_z` is where the *empty carriage* trips the
station, and the feature it trips sits about 12.4 mm +X of the nozzle and lower
(see `notes/46-offset-calibration-recovered.md`). So `nozzle_z − station_z` is
a nozzle-to-station-trigger distance, not a nozzle-to-eddy-coil one — the
number is right, the mental picture of an eddy measurement is not.

Per-tool first-layer tuning: Klipper's `SET_GCODE_OFFSET Z_ADJUST=` babystep
is one global number. Use

```gcode
TOOL_Z_ADJUST TOOL=2 ADJUST=-0.02          ; live, saves nothing
TOOL_Z_ADJUST TOOL=2 ADJUST=-0.02 SAVE=1   ; and stage it
SAVE_CONFIG                                ; when you are happy with it
```

instead: it edits `[ff_tool 2] z_adjust`, re-applies immediately if that
tool is mounted, is added on every later grab of that tool, and persists.

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

## Input shaper

`SHAPER_CALIBRATE`, `TEST_RESONANCES` and `MEASURE_AXES_NOISE` are wrapped
(`ff-toolchange.cfg`): they home if needed and grab a head first when the
carriage is empty, so the measured moving mass is the real one (the app's
`grabVibration`). Works the same from Mainsail, HelixScreen or the console;
the original parameters pass through. Which head: `variable_shaper_tool`
in `[gcode_macro _FF_SHAPER_PREP]` (default T0). The tool stays mounted
afterwards; `TOOLCHANGE_PARK` docks it.

## Roadmap

Fool-proofing, in rough priority order:

* **Run this branch on hardware.** Calibration sequence, import and the
  safety gates are mock-tested only.
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
for — `toolchanger` (`name`, `status`, `tool`, `tool_number`, `tool_numbers`,
`tool_names`, `detected_tool`, `detected_tool_number`, `has_detection`) and
`tool T0..T3` (`active`, `mounted`, `detect_state` = `mounted|absent` from the
tool's grab sensor, `extruder`, `heater`, `fan`, `gcode_x/y/z_offset`) — and the
commands they send: `SELECT_TOOL T=<n>` (= `T<n>`), `UNSELECT_TOOL [T=<n>]`
(= `TOOLCHANGE_PARK`), `INITIALIZE_TOOLCHANGER` (state check, no motion),
`SET_TOOL_TEMPERATURE [T=<n>] TARGET=<t> [WAIT=1]`,
`VERIFY_TOOL_DETECTED [T=<n>] [ASYNC=…]` and `SELECT_TOOL_ERROR [MESSAGE=…]`.
`status` is `changing` from before the first move of a **toolchange** until the
sensors confirm the swap, `error` when the dock sensors disagree, else `ready`.
A bare park (`TOOLCHANGE_PARK` / `UNSELECT_TOOL`) never sets it, so it reports
`ready` throughout one.
We keep no commanded tool state, so `detected_tool*` always equals `tool*`:
both are derived from the dock and grab sensors.

`SELECT_TOOL`, `UNSELECT_TOOL` and `TOOLCHANGE_PARK` accept upstream's
`RESTORE_AXIS=<xyz>`: the G-code position is captured before the change and
replayed after it, X/Y first and Z last so the nozzle is never dragged across
the part. A G-code position is replayed, not a machine one, so it is read back
through the offsets in force *after* the change — the new tool's nozzle lands
where the old one was. The default is `restore_axis` in `[ff_toolchange]`,
itself empty: nothing is restored unless asked, which is how this machine has
always behaved. Restoring Z after an `UNSELECT_TOOL` is the sharp edge, since
parking zeroes the tool offsets and the same G-code Z becomes a different
machine Z (~3.2 mm, this tool's nozzle-to-station-trigger gap -- the station,
not the eddy coil; see the note under Calibration).

`SET_TOOL_TEMPERATURE` addresses the extruder behind the tool; `WAIT=1` waits
only for heat-up, as Klipper's own `TEMPERATURE_WAIT MINIMUM` does.
`VERIFY_TOOL_DETECTED` accepts `ASYNC` and ignores it — we read switches after
a `wait_moves`, which costs nothing to do inline. `SELECT_TOOL_ERROR` aborts
the running script; we hold no error latch to set, because status is derived
from the sensors every time it is asked for.
Upstream's docking-mode and tool-parameter commands (`TEST_TOOL_DOCKING`,
`ENTER_DOCKING_MODE`, `SET_TOOL_PARAMETER` and friends) are deliberately
absent: calibration here is `TOOL_CALIBRATE_TOOL_OFFSET` /
`TOOL_LOCATE_SENSOR` / `TOOL_Z_ADJUST`, already tied to the factory numbers.
`ASSIGN_TOOL` is refused — remap tools in the slicer. Nothing to enable; it is
always on. `part_fan` in `[ff_toolchange]` is what gets reported as each
tool's fan (shared `fan_generic fanM106` on this machine). `ff_toolchange`
itself stays (the printer-database fingerprint keys on it); the new objects
sit alongside.

Verify from any machine that can reach Moonraker (port 7125):

```sh
curl -s http://PRINTER:7125/printer/objects/list | grep -o '"toolchanger"\|"tool T[0-3]"'
# expect all five names
curl -s 'http://PRINTER:7125/printer/objects/query?toolchanger&tool%20T0'
# toolchanger.status "ready", tool_number -1 (parked) or 0..3;
# tool T0: mounted/active false, detect_state "absent" while docked
```

Then `SELECT_TOOL T=0` from the console and poll the query again: `status`
goes `changing`, then `ready` with `tool_number: 0` and `tool T0`
`detect_state: "mounted"`. HelixScreen's log on connect should read
`[Moonraker Client] Subscribing to toolchanger + 4 tool objects`, and its
tool panel shows the mounted head and Park/Select per tool. The resonance
commands are wrapped so they grab a head first (see [Input shaper](#input-shaper)).

[HelixScreen](https://github.com/prestonbrown/helixscreen) then runs its Tool
Changer backend: tool slots in the sidebar and print status, per-tool
temperatures and offsets, Spoolman per tool, the plain single-extruder runout
dialog. Drop `pkgs/helixscreen/payload/helixscreen/config/printer_database.d/flashforge_creator5.json` into HelixScreen's
`config/printer_database.d/` for auto-detection (`ams_type: tool_changer`,
`z_offset_calibration_strategy: firmware_managed`). Its default Load/Unload buttons only mount/unmount the tool (`SELECT_TOOL` /
`UNSELECT_TOOL`); to actually feed or pull filament assign `LOAD_FILAMENT`,
`UNLOAD_FILAMENT` and `PURGE` from [`pkgs/klipper-config/payload/config/ff-filament.cfg`](../pkgs/klipper-config/payload/config/ff-filament.cfg)
in Settings → Macro Buttons — a user-assigned macro outranks the backend, and
the parameter dialog picks up `TOOL` / `TEMP` / `PURGE_TEMP` from the macros.

## Reverse-engineering notes

Condensed notes from the `firmwareExe` analysis — recovered sequences, binary
addresses, JSON semantics — live in [`docs/notes/`](notes/):
architecture overview, the Klipper-fork delta (including the `Tn` interception),
[who decides what — app vs Klipper](notes/25-app-vs-klipper-ownership.md)
(heaters, runout, doors, calibration; which "features" are dead code),
the verified grab/release sequences, the offset model, the recovered
nozzle-offset calibration and its Klipper port, and the full print
lifecycle with the deliberate divergences listed.

## Support

If this saved your build plate (or your sanity), you can
[buy me a ~~coffee~~ new hotend](https://buymeacoffee.com/monstrofil).
