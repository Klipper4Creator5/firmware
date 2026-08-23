# Print lifecycle, address-verified

Everything below lives in the APP, not in Klipper: the fork ships only bare
`[pause_resume]` and `[virtual_sdcard]`. `config/ff-print-macros.cfg` reproduces the
sequences for Mainsail-started prints.

## Flow map (touchscreen print)

```
BuildPage::doPreparetion @0x9f0fbc
   -> prepareForEddy @0x9f1068          (this unit: generalFirmware=false)
BuildPage::startPrint @0x9fc148        -> absolute print Z offset (40-offsets.md),
                                          then spawns the print engine thread
CommMgr::serialPrint @0x79c8e0         -> the 37 KB engine thread
```

## Preparation (prepareForEddy) — reproduced by START_PRINT

1. `G90`, `M82`, `BED_MESH_CLEAR`, `M400`
2. `G28` (full home); abort on failure
3. `SET_GCODE_OFFSET X=0 Y=0 MOVE=1 MOVE_SPEED=600`
4. two probe touch checks (app-internal `checkProbeZValue`)
5. heat bed + chamber; dock whatever tool is held; presence check of the file's first
   tool (E0165) — ported as `_FF_REQUIRE_TOOLS` for every tool in `TOOLS=`
6. `SET_IDLE_TIMEOUT TIMEOUT=1800000`; eddy probe at (265, 4.8); nozzle clean of every tool
   the file uses (purge at the chute, wipe at (266.5, 13.8), cool by 100 °C, release) —
   ported as `_FF_NOZZLE_CLEAN`, see [`50a`](50a-nozzle-clean-recovered.md) /
   [`50b`](50b-nozzle-clean-port.md)
7. bed+chamber soak wait (keepBedTempPrint = 5 min), then **`G28 Z` re-home**
8. per-print leveling toggle: ON → `BED_MESH_CALIBRATE` at ACCEL=2000 then
   `BED_MESH_PROFILE LOAD=default`; OFF → `BED_MESH_PROFILE LOAD=MESH_DATA`
   (a mesh is ALWAYS active for a print)
9. heat + grab the first tool; `G1 Z10 F1200` clearance

## serialPrint preamble (fresh print)

`G1 X250 F2400` (clear of docks), `SDCARD_SET_CHANNEL CHANNEL=<tool>`, then
`M21 → M23 /<name> → M26 S0 → M24`, `SET_IDLE_TIMEOUT TIMEOUT=864000`. The app sends
NO heating for a fresh print — temps come from preparation + the sliced file itself.

## Pause (inline in serialPrint; UI buttons send no gcode themselves)

1. `SET_IDLE_TIMEOUT TIMEOUT=864000`, `M400`, **`M25`**, wait for sd state "paused"
2. save all tool target temps
3. `SAVE_GCODE_STATE NAME=PAUSE_state`
4. **all hotends OFF** (bed and chamber stay on)
5. park lift `G1 Z<park> F500` (thresholds 50/100; exact clamp formula unrecovered)
6. write power-loss recovery record

## Resume

1. staged reheat from saved targets: e1+e2 → wait → e3+e4 → wait
2. re-grab head if needed
3. `SET_IDLE_TIMEOUT TIMEOUT=600000` (sic — the app's odd value)
4. `RESTORE_GCODE_STATE NAME=PAUSE_state MOVE=1`, `CLEAR_PAUSE`, **`M24`**

## Cancel and normal completion share ONE exit block @0x7a25f0

Cancel additionally sends `CANCEL_PRINT` first; then, in order: heaters off (hotends,
bed, chamber), fans off; `ACCEL=5000`, `G92 E0`, `G1 E-1 F300`, `G92 E0`, `M400`;
bed presentation drop `G1 Z150/200/256.8 F1800` by current-Z thresholds 100/150;
`SET_FAN_M106[P2]` reset, `SET_PA_ADVANCE .. ENABLE=0`, `MUTE_MODE_DISABLE`,
`M220 S100`, `SET_VELOCITY_LIMIT VELOCITY=500 ACCEL=20000`, `BED_MESH_CLEAR`,
`CLEAR_PAUSE`; **dock the mounted tool**; `SET_GCODE_OFFSET Z=0 MOVE=1`; `M18`;
`SET_IDLE_TIMEOUT TIMEOUT=600`.

## Divergences in ff-print-macros.cfg (deliberate)

- resume reheats all tools in parallel, not e1+e2-then-e3+e4 staged
- no dmesg/meminfo dumps, no drop_caches shell calls
- idle timeout after resume back to 864000, not 600000
- pause park: +10 mm clamped to 256 (app's exact formula unrecovered)
- tool gate covers all of TOOLS, not just the first tool; nozzle clean uses slicer
  temperatures (TEMPS=) and the fixed purge_z instead of a fresh eddy probe
- CANCEL_PRINT override adds our cleanup only for Mainsail-started jobs (tracked by
  the SDCARD_PRINT_FILE wrapper) — the touchscreen's own cancel does its own cleanup
  and must not be doubled.
