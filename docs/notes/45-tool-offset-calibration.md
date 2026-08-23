# Nozzle XY/Z offset calibration — Klipper port

Source of truth for the sequence: [`46-offset-calibration-recovered.md`](46-offset-calibration-recovered.md),
recovered 2026-08-21 from MIPS machine code with a custom disassembler (annotated `.asm` listing not in repo).

Design decision (2026-08-21): firmwareExe's JSON is no longer a runtime source. FlashForge's UI
cannot use Klipper-side results anyway and HelixScreen is the target, so calibration is stored
the way Klipper's own calibrators store theirs — `configfile.set()` + `SAVE_CONFIG` — in
per-tool sections, modelled on `[bed_mesh <profile>]` / klipper-toolchanger's `[tool Tn]`.

## Files

| file | role |
|---|---|
| `payload/klipper/extras/ff_tool.py` | `[ff_tool n]`: `dock_x/dock_y` hand-written; `nozzle_x/y/z` (measured) and `z_adjust` (user per-tool Z correction, `TOOL_Z_ADJUST`) autosaved |
| `payload/klipper/extras/ff_tool_offset.py` | `TOOL_OFFSET_CALIBRATE`, `STATION_CALIBRATE`, `TOOL_OFFSET_STATUS`; `[ff_tool_offset]` holds `station_x/y/z` (autosaved) + probe geometry |
| `payload/klipper/extras/ff_toolchange.py` | takes docks/offsets from the `ff_tool` objects; `refresh_offsets()`; `_station_z()`; JSON reader and `TOOLCHANGE_RELOAD` removed |
| `payload/klipper/extras/ff_legacy.py` | `FF_IMPORT_FIRMWARE_CONFIG [DIR=] [APPLY=1]` — one-shot import of extruder/test/zoffset.json |
| `payload/klipper/config/ff-toolchange.cfg` | `[ff_tool 0..3]` with this unit's docks + `[ff_toolchange]` |
| `payload/klipper/config/ff-tool-offset.cfg`, `payload/klipper/config/ff-legacy.cfg` | sections for the other two extras |

## Storage layout

```
# hand-written (ff-toolchange.cfg)          # SAVE_CONFIG block of printer.cfg
[ff_tool 1]                                 #*# [ff_tool 1]
dock_x: 296.538940                          #*# nozzle_x = 16.407789
dock_y: 106.336197                          #*# nozzle_y = 211.986710
                                            #*# nozzle_z = 1.426736
[ff_tool_offset]                            #*# [ff_tool_offset]
#cylinder_x: 28.5                           #*# station_x = 28.791826
                                            #*# station_y = 212.639328
                                            #*# station_z = -1.678819
```
- Raw station-frame absolutes per tool, not T0-relative diffs: recalibrating one tool leaves
  the others valid; diffs are derived at load (`ff_toolchange._derive_offsets`).
- `nozzle_z − station_z` is the ~3.19 mm nozzle-to-eddy-trigger gap the print-start Z offset
  uses (`TOOLCHANGE_SET_PRINT_OFFSET`).
- Fork constraint (`configfile.py:385`): `SAVE_CONFIG` refuses to autosave an option an
  *included* file already sets — so `nozzle_*`/`station_*` must never be written into the
  `.cfg` includes. Autosaving new options into a section that an include defines is fine.
- Values are applied live at once; `SAVE_CONFIG` persists and restarts.
- Klipper's babystep is global; `TOOL_Z_ADJUST TOOL=n ADJUST=±mm|VALUE=mm` edits the per-tool
  `z_adjust`, re-applies immediately if that tool is mounted, and stages it for `SAVE_CONFIG`.
- `[save_variables]` is not used (Klipper core never uses it for calibration).

## Install / first run

```
cp payload/klipper/extras/ff_*.py /usr/prog/klipper/klippy/extras/
# printer.cfg, after [virtual_sdcard]:
#   [include ff-toolchange.cfg]  [include ff-tool-offset.cfg]  [include ff-legacy.cfg]
RESTART
FF_IMPORT_FIRMWARE_CONFIG        ; stages factory nozzle/station; prints dock/feed snippet
SAVE_CONFIG
TOOLCHANGE_STATUS                ; all four tools calibrated, station_z present
# later, PEI off, homed:
STATION_CALIBRATE
TOOL_OFFSET_CALIBRATE TOOL=ALL
SAVE_CONFIG
```
Remove `ff-legacy.cfg` afterwards; it is only needed once.

## Safety on an uncalibrated machine (added 2026-08-21, user request)

- `START_PRINT` calls `_FF_REQUIRE_CALIBRATION` first and the Mainsail entry point
  (`SDCARD_PRINT_FILE` wrapper) checks `printer.ff_toolchange.print_offset_ready`: no
  `nozzle_z`/`station_z` → refuse before heating/homing/grabbing, with the fix spelled out.
  Escape hatch for tests: `SET_GCODE_VARIABLE MACRO=_FF_JOB VARIABLE=allow_uncalibrated VALUE=1`.
- `TOOL_OFFSET_CALIBRATE` / `STATION_CALIBRATE` require `PLATE_REMOVED=1`; default `z_target`
  is −3 (the app's station pass-2 value) not −5; once a trigger height is known (calibrated
  `nozzle_z`/`station_z`, or `station_z + ~3.25` for a first tool pass) the Z probe stops
  `z_margin` (2 mm) below it.
- Guards on by default: `max_residual 0.05` (4 symmetric points dilute one bad point's error to
  ~1/4 in the residual while moving the centre by half), `gap_min/gap_max 1.5..5 mm` for
  `nozzle_z − station_z` (3.19 here). A failed guard saves nothing.
- `TOOL_Z_ADJUST TOOL=n ADJUST=±mm|VALUE=mm` is the per-tool babystep (Klipper's is global).

## Fidelity of the probe sequence

Identical to `testEddyExtruderOffsetForwardTwoCheck`: start `(cylinder_x-12.5, cylinder_y)`,
`ESTOP Z TARGET=-5`, probes `+X +Y -X -Y` by 14 mm at `zP+0.6` returning through the centre,
LS circle fit, lift `zP+3`, `G1 Y; G1 X F2400` to the fit, re-probe Z, second 4-point pass,
store pass 2 `(cx, cy, zP2)` raw. Station: start `(cylinder_x, cylinder_y)`, second Z to -3.
`M104 S0 T<n>` + `G1 Z15` on exit. ESTOP is driven by calling the fork's `e_stop` objects'
`run_probe()` directly (3 samples, `error_v` spread check, `back_v` retract — all the fork's).

Deliberate divergences (documented in the cfg): accel stays 100 for the whole run and is
restored to the pre-run limit; optional `max_residual`/`min_radius`/`max_radius` guards; pass-2
points use the 3-decimal-rounded centre actually commanded; `fit_circle` is the centroid-shifted
`fitCircleStable` (identical result for 4 axis-aligned points); homing is required, not done.

## Verified (mock harness, not in repo)

Emitted G-code order matches the recovered list; fitted centre = virtual centre; autosave
receives exactly `nozzle_x/y/z` for the calibrated tool and `station_x/y/z`; live offsets
update without restart; `TOOLCHANGE_SET_PRINT_OFFSET` gives 3.240 for T0/220 °C/80 °C/0.25 mm
(OKF/62's value) and refuses without `station_z`; `TOOL_Z_ADJUST` applies live and stages;
PLATE_REMOVED gate, bounded Z target, gap and residual guards all fire; `FF_IMPORT_FIRMWARE_CONFIG` against
`live/firmwareRes-config` stages 15 values and reproduces the OKF/33 offset table.
**Not yet run on the printer.**

## Not recoverable / open

`fitCircleByLeastSquares` body not traced line by line; `TypeManager=6` in the station pass
unnamed; what feature of the empty carriage the station detects (12.4 mm +X of the nozzle,
3.2 mm lower) is inferred from the numbers only.
