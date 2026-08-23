# Background: filament system, calibration, persistent state

Context recovered from the binary but NOT (yet) ported — the stock touchscreen still
handles all of this. Kept as reference for future work.

## Filament system

- 4 channels; per-channel presence (`fd_ex0..3`) and motion/clog (`fm_ex0..3`)
  sensors; feed hub `manual_stepper gear_stepper`. Errors: E0162 runout, E0163 clog.
- **Runout auto-swap** (the flagship app feature): on runout mid-print the app pauses,
  finds another channel with the same material/color, switches channel (possibly a
  head change), refeeds, purges, restores position and resumes. All app-side.
- Load ≈ heat, `G92 E0`, `G1 E150`/`G1 E145` long feed; unload ≈ feed assist then
  retract ramp `G1 E-50 F150` … tip forming.
- Pre-print screen parses 3MF per-tool type/color and lets the user remap slicer
  tools to physical channels (`SDCARD_SET_GCODE_EX_USED_BASE/CHANGED`).
- Drying box: separate MCU on `/dev/ttyS3`, own textual protocol (`DryingService`),
  2 chambers with temp/humidity control. Not Klipper at all.

## Calibration flows (all driven by the app)

- **Bed leveling**: eddy probe, 10×10 bicubic; factory mesh saved as profile
  `MESH_DATA`, per-print mesh as `default`; `SAVE_CONFIG` after.
- **Nozzle offset calibration** (`testEddyExtruderOffsetForward*`): heats and cleans
  each nozzle, probes the fixed under-bed sensor with the eddy, then touches it with
  each nozzle; circular probing + least-squares circle fit for XY; results →
  `tN_offset_x/y/z`, `z_station_pos` in extruder.json. Reimplemented in Klipper as
  `STATION_CALIBRATE` / `TOOL_OFFSET_CALIBRATE` (`45-tool-offset-calibration.md`,
  `46-offset-calibration-recovered.md`); the JSON is imported once with
  `FF_IMPORT_FIRMWARE_CONFIG` and not consulted afterwards.
- **Input shaper**: `STEPPER_RESONANCE_FACTORY_CALIBRATE` (fork) / `SHAPER_CALIBRATE`.
- **Auto PA**: prints slow-fast-slow line patterns per PA candidate, scores via
  `PA_ACTION`/`PA_GET` (sensor unknown), stores per-tool table via `SET_PA_ADVANCE`.

## Persistent state map (/usr/data/firmwareRes/config/)

- `extruder.json`, `test.json`, `zoffset.json` — motion-critical, see
  `40-offsets.md`. **Back these up.**
- `filament.json` — per-channel `exN_filament_type/color/diameter`.
- `general.json`/`print.json` — UI toggles: `levelOpen` (per-print leveling),
  `openDoorPause`, `filamentDetected`, `aiCheck`, camera, LED…
- `total.json` — maintenance counters/service reminders.
- `levelData` — 10×10 mesh copy the UI renders.

Also worth backing up before any experiment: `/usr/data/config/printer.cfg` (+
`printer.base/macro/motor/override.cfg`) and the whole `/usr/prog/klipper/` fork tree.
