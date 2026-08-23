# Pre-print nozzle clean and tool gate — Klipper port

Source of truth: [`50a-nozzle-clean-recovered.md`](50a-nozzle-clean-recovered.md).
Port: `config/ff-print-macros.cfg` — `_FF_REQUIRE_TOOLS`, `_FF_NOZZLE_CLEAN`, and the
`TOOLS=` / `TEMPS=` / `CLEAN=` / `SOAK=` parameters of `START_PRINT`; tunables
`clean_*` in `[gcode_macro _FF_FILAMENT]` (`config/ff-filament.cfg`);
`docked_tools` in `printer.ff_toolchange` status.

## START_PRINT now

```
START_PRINT BED=60 TOOL=2 NOZZLE=240 LAYER=0.2 LEVEL=0 TOOLS=0,2 TEMPS=220,0,240,0 [CLEAN=1] [SOAK=0]
```

1. `_FF_REQUIRE_CALIBRATION` — every tool in TOOLS (plus TOOL) calibrated, station known.
2. `_FF_REQUIRE_TOOLS` — every tool in TOOLS docked or mounted (`docked_tools` /
   `current_tool`); refuses before any heating or motion. App: E0165.
3. `G90 M82 BED_MESH_CLEAR M400 G28`, offset zero, idle timeout 1800000 — unchanged.
4. `M140 S<bed>` (non-blocking, as the app's heatManager).
5. `_FF_NOZZLE_CLEAN TOOLS=.. TEMPS=.. TEMP=<NOZZLE>` then `M106 P1 S0` — the clean runs
   while the bed heats, exactly where the app runs it.
6. `M190`, optional `G4` soak, `G28 Z`, mesh, `M104 S<NOZZLE> T<TOOL>`, `T<TOOL>`,
   `TOOLCHANGE_SET_PRINT_OFFSET` — as before, plus the app's heat-before-grab of the first tool.

TOOLS defaults to TOOL; with neither, no gate and no clean (single-tool legacy call).

## _FF_NOZZLE_CLEAN, per tool

Reuses `_FF_FILAMENT_PREP` (new `ALLOW_PRINTING=1`, since `print_stats.state` is already
`printing` inside START_PRINT) for: `M104`, offset zero, `SELECT_TOOL` (or
`ACTIVATE_EXTRUDER` when already mounted), `G1 Z purge_z` if below, the chute approach with the
per-tool nudge, `TEMPERATURE_WAIT ±3`, chamber fans off. Then, verbatim from the app:
`M83 G92 E0 G1 E50 F<speed> M400 M106 P1 S153 G1 E-5 M400`, `G1 X250 F6000`,
`G1 Y13.8 F24000`, `G1 X266.5 F6000`, `G1 Z1.0 F600`, `M104 S<temp-100>`,
`TEMPERATURE_WAIT MAXIMUM=<temp-97>`, `M106 P1 S0`, `G1 Z10 F1200`, and
`_FF_FILAMENT_FINISH RELEASE=1 HEAT_OFF=0` (chamber fans back, `UNSELECT_TOOL`). The hotend
is left at temp−100 as the app leaves it; `speed` is 80 for a 0.25 mm nozzle, else 240.

Temperatures: `TEMPS` indexed by tool number (0 / missing → `TEMP`, which START_PRINT sets
to NOZZLE). The app takes the slot's material-table temperature; the slicer's first-layer
temperature per extruder is the same information from the other side.

## Deliberate divergences

- **Gate scope**: the app checks only the initial tool at prepare (the others fail at their
  grab, after the bed is already heating); we refuse up front for all of TOOLS.
- **Purge / wipe heights** are `purge_z` (8.0) and `clean_wipe_z` (1.0) in the homed frame,
  i.e. the app's `probeZ + 8` / `probeZ + 1` with probeZ taken as 0 — no fresh eddy
  `PROBE_ACCURACY` at (265, 4.8). Same assumption as LOAD_FILAMENT; unmeasured.
- **Cool-down wait** has no timeout (`TEMPERATURE_WAIT`); the app gives up after 180 s with
  E003x. `clean_cool_delta: 0` skips it (much faster, less clean).
- The PA-test variant (`paTest` flag → `SET_KINEMATIC_POSITION` + `paTestMgr`) and the
  `SET_PA_ADVANCE … ENABLE=0` reset after the loop are not reproduced (`_FF_PRINT_END`
  already resets PA).
- Consecutive-duplicate skipping became full de-duplication of TOOLS.
- Bed soak: `SOAK=<s>` is a plain dwell after `M190`; the app's 5-minute `keepBedTempPrint`
  starts when the bed first reaches target. (The previous file referenced an undefined `soak`
  inside a `;`-comment — Jinja still evaluates those — which would have failed every
  START_PRINT with BED>0.)

## OrcaSlicer

`orca/machine-start-gcode.txt` builds TOOLS/TEMPS from `is_extruder_used[n]` and
`nozzle_temperature_initial_layer[n]`. Verify once in your Orca version that
`is_extruder_used` resolves (it is a PrusaSlicer-lineage placeholder); fall back to
`TOOLS=[initial_extruder]` if the G-code export complains.

## Open

- Hardware: wipe spot geometry (is there a pad at 266.5/13.8? Z clearance with
  `clean_wipe_z` 1.0 in the eddy frame, i.e. ~−2.2 mm physical relative to the bed plane —
  the bed does not extend there).
- Whether the app's `err == tool+1` tolerance after `doGrabExtruderMgr` matters
  (probably "already holding this tool").
