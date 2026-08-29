# Filament load / unload / purge — Klipper port

Source of truth: [`47-filament-load-recovered.md`](47-filament-load-recovered.md), recovered 2026-08-21
from MIPS code (Ghidra bodies were 36-byte stubs).
Port: `pkgs/klipper-config/payload/config/ff-filament.cfg` — `LOAD_FILAMENT`, `UNLOAD_FILAMENT`, `PURGE`, tunables in
`[gcode_macro _FF_FILAMENT]`.

## What the app really does 

- Live page is `FilamentLoad` (`PageManager::newPage("12FilamentLoad")`). `FilamentMgr` (the
  `G1 E300/E298 F300` one) is unreachable dead code.
- `[manual_stepper gear_stepper]` is the **tool lock motor**; `MANUAL_STEPPER` does not occur in the
  binary. Loading = the tool's own direct-drive extruder after the tool is grabbed.
- Load on tool n: `M104 S<material+30> T<n>` → home if needed → `SET_GCODE_OFFSET X=0 Y=0 MOVE=1` →
  eddy `PROBE_ACCURACY` at (265, 4.8) with an empty carriage (once per page life) → grab tool n →
  `G1 X250 F12000; G1 Y<254+dy> F24000; G1 X<275+dx> F2400`, dx/dy by tool 0:(0,0) 1:(−2,0)
  2:(−2,1.5) 3:(−2,−8) → `G1 Z<probeZ+8> F3000` → wait |T−target| ≤ 3 (1 s poll, no timeout) →
  chamber_fan 0 (+heat/loop fans 0 if chamber heating) → `G92 E0; G1 E150 F240; M400; G1 E145 F240;
  M400` (F80 for a 0.25 mm nozzle) → fans back (heat 0.9 / loop 0.3) → release tool → `M104 S0`.
- **Unload is the same forward push** (`+0x158` only selects guide text). No retract exists in the
  user flow; the only reverse moves in the binary are E−5 (post-purge), E−2, E−50 (manual page).
- Temperature table `g_mapFilamentTempDefault` (.rodata 0xd61d44): PLA/PLA-CF/SILK/PVA/TPU 220,
  PETG/PETG-CF 240, ABS/ASA/HIPS 250, PC/PA/PC-ABS 260, PET-CF/S-Multi/PA-CF 270, PAHT-CF/S-PAHT 280,
  PPS-CF 290, custom 220; indexed by `ex<n>_filament_type` in filament.json.
- No `M109`, no `SET_FILAMENT_SENSOR`/`RESET_FILAMENT_SENSOR`, no sensor check after the feed, no
  JSON writes (except `SDCARD_SET_GCODE_EX_USED_CHANGED` when clearing a no-filament flag).
- Runout-during-print variant `LoadFilamentPrint`: table temp (no +30), grab, same location,
  `G92 E0; G1 E100; M400; G92 E0; G1 E-5; M400`, release, `G1 X100 Y2 F12000`.
- Purge `clearNozzlePrint`: `G1 E50; M400; M106 P1 S153; G1 E-5; M400` at the same spot.

## Port decisions

| | app | macro |
|---|---|---|
| Z at the chute | probeZ+8 via PROBE_ACCURACY | `purge_z` 8 nominal (probe z_offset 0.0); Z only raised |
| temp | table by filament.json type, +30 | `TEMP=` (HelixScreen pre-fills) or `MATERIAL=PLA` → same table; `BOOST=30` |
| wait | 1 s poll ±3 | `TEMPERATURE_WAIT MIN/MAX ±3` |
| tool | grab, release at end | `SELECT_TOOL`, `UNSELECT_TOOL` (`RELEASE=0` keeps it) |
| paused print | LoadFilamentPrint path | mounted tool only (else refuse), E100/E−5, no Z, tool and heater left for RESUME |
| printing | UI disabled | refuse |
| unload | same as load | **designed**: E+10 prime, E−20 F1200, remainder of `unload_length` (80) F600 |
| PURGE | clearNozzlePrint | same, plus the app's cold wipe: `WIPE=1` by default runs `_FF_NOZZLE_WIPE` (travel to 266.5/13.8, cool by `clean_cool_delta` 100 °C, `G1 Z10 F1200`). `PURGE_TEMP=` is HelixScreen's name |

HelixScreen: its tool-changer backend maps Load/Unload to SELECT/UNSELECT_TOOL; assigning
`LOAD_FILAMENT`/`UNLOAD_FILAMENT`/`PURGE` in Settings → Macro Buttons outranks that. Parameter modal
reads `params.X|default()` from the template.

## Verified (mock render harness, 23 checks — harness since deleted)

The harness was `test/test-macros.py`, removed in `91604c2` when the suite was cut down
and the Python half rewritten as pytest. Nothing renders these macros today, so the
checks below are a record of what was true then, not a gate that still runs:

Emitted order for idle load matches the recovered list; per-tool nudges; thin-nozzle F80; material
table; chamber fan off/restore; refusals (printing, paused + other tool, no tool); paused path;
unload stages; purge sequence; G28 when unhomed. **Not run on the printer.** `unload_length` 80 mm
is a guess — measure nozzle→above-gears path and shorten.
