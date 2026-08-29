# Pre-print nozzle clean and tool-presence check, recovered

Recovered 2026-08-22 from the MIPS code of `BuildPage::clearNozzlePrint` @0x9f46f4,
`clearNozzleCheckTemp` @0x9f6ce0, `clearNozzleProbez` @0x9f4020 and the presence check in
`prepareForEddy` @0x9f1068 (the Ghidra bodies are 36-byte stubs, cut at the first `ErrorBak`
constructor). Port: `_FF_NOZZLE_CLEAN` / `_FF_PREFLIGHT` in `pkgs/klipper-config/payload/config/ff-print-macros.cfg`,
see [`50b-nozzle-clean-port.md`](50b-nozzle-clean-port.md).

## Where it sits in the prepare flow (prepareForEddy)

After `G28`, `SET_GCODE_OFFSET X=0 Y=0 MOVE=1 MOVE_SPEED=600`, the two probe touches and
`heatManager(bed)` / `heatManager(chamber)` (non-blocking `M140` / chamber set), the app:

1. `releaseFourExtruder` @0x9f1e9c — docks whatever is on the carriage.
2. **Presence check** @0x9f2084–0x9f2130: `getExtruderGrabStatus`, then
   `checkInLocation(grabInfo, this+0x410)` for **one tool only — the file's initial tool**
   (`PrintFileInfo` first field). Not in its dock → log `"T: %d, no install"`, error 0x3e
   (E0165 "extruder not installed, can not print"), abort. The other tools used by the file are
   not checked here; a missing one fails later at its grab inside the clean (or, for a
   touchscreen print, is greyed out earlier on the material-mapping page, which calls
   `checkInstallExtruder` for all four: `dock switch || (any grab && now_extruder == tool)`).
3. `SET_IDLE_TIMEOUT TIMEOUT=1800000` @0x9f2160.
4. `clearNozzleProbez(&probeZ)` @0x9f21d0: `SET_GCODE_OFFSET X=0 Y=0 MOVE=1 MOVE_SPEED=600`,
   `M400`, `G1 X265 Y4.8 F6000`, `M400`, `checkProbeZValue(&probeZ)` (eddy `PROBE_ACCURACY`,
   empty carriage), `M400`. `probeZ` is the Z reference for everything below.
5. The filament remap block (`SDCARD_NO_FILAMENT_CHECK_EX`, `SDCARD_SET_GCODE_EX_USED_CHANGED`).
6. `clearNozzlePrint(this+0x40d /* PA-test flag */, probeZ)` @0x9f2770, then `M106 P1 S0`
   @0x9f27a4.
7. Bed/chamber soak wait, `G28 Z`, leveling, heat + grab the first tool.

So the clean runs **with the bed already heating but before the soak, the Z re-home, the mesh
and the first grab**; every tool is released again at the end of its pass.

## Which tools (clearNozzlePrint @0x9f47d0–0x9f49bc)

- Multi-material flag `this+0x434` set → iterate the `Slice3mfInfo` list at `this+0x5c0`
  (fallback `this+0x5cc` when `+0x5c0` is empty); each entry's field `+8` is the 1-based
  extruder from the 3mf slice metadata, pushed as `extruder − 1`, in list order.
- Flag clear → a single entry: `PrintFileInfo` field 0 (the file's tool).
- Each entry is logged `"Func: clearNozzlePrint , print clear nozzle index: %d"` @0x9f4a20.
- Loop @0x9f4a8c: a tool equal to the previous iteration's tool is skipped
  (`beq` @0x9f4adc — consecutive duplicates only).

## Per tool (clearNozzlePrint @0x9f4ae4–0x9f5cb0)

```
temp  = getFilamentOperationTemp(tool)      ; material table value, NO +30  (@0x9f4afc)
speed = getFilamentOperationSpeed(tool)     ; 240, or 80 for a 0.25 mm nozzle (@0x9f4b18)
doGrabExtruderMgr(tool)                     ; @0x9f4b48 (error unless 0 or tool+1)
moveLoadLocation(false)                     ; G1 X250 F12000 ; G1 Y<254+dy> F24000 ; G1 X<275+dx> F2400 ; M400
G1 Z<probeZ + 8> F3000                      ; @0x9f4c14, 8.0f @0xedc998
heatManager(tool, temp)                     ; M104 S<temp> T<tool>   (@0x9f4d2c), sleep 3
clearNozzleCheckTemp(tool, 90)              ; wait |cur - target| <= 3, 1 s poll, 90 s max
changeFilamentControlFan(true, chamberFan, 0)   ; chamber fan off (@0x9f4dac)
-- PA-test flag clear (the normal case, @0x9f51fc):
G92 E0 ; G1 E50 F<speed> ; M400
M106 P1 S153
G92 E0 ; G1 E-5 F<speed> ; M400
-- PA-test flag set: SET_KINEMATIC_POSITION X= Y= Z= + paTestMgr (factory PA lines), not ported
G1 X250 F6000                               ; @0x9f56e0
G1 Y<4.8 + 9.0 = 13.8> F24000               ; @0x9f5790, 9.0f @0xedc994
G1 X<265 + 1.5 = 266.5> F6000               ; @0x9f5870, 1.5f @0xedc990
G1 Z<probeZ + 1.0> F600                     ; @0x9f5954
changeFilamentControlFan(false, ..)         ; chamber fans back (@0x9f5a34)
heatManager(tool, temp - 100)               ; @0x9f5a5c (addiu -0x64), sleep 3
clearNozzleCheckTemp(tool, 180)             ; wait until cooled to temp-100 +-3, 180 s max
M106 P1 S0                                  ; @0x9f5abc
G1 Z10 F1200 ; M400                         ; @0x9f5b48
doReleaseExtruderMgr(tool)                  ; @0x9f5c5c
```

After the loop: if the PA-test flag was set and PA values were collected,
`SET_PA_ADVANCE T0=.. T1=.. T2=.. T3=.. ENABLE=1`, else
`SET_PA_ADVANCE T0=99.0 T1=99.0 T2=99.0 T3=99.0 ENABLE=0`; then `G1 Z10 F1200`.

`clearNozzleCheckTemp(tool, n)` @0x9f6ce0: reads `getTemperatureListMgr()[tool]` (current) and
`[tool + 6]` (target), logs `"currentTemp: %d  targetTemp: %d"`, returns 0 when
`-3 <= cur - target <= 3`; otherwise checks the cancel flag (`this+0x4f4` → 0xb5), polls
`getApiResponse` for a Klipper error, sleeps 1 s, and after `n` polls returns 0x21 + tool
(the E003x "heating" family).

## What the wipe spot is

(266.5, 13.8) is 1.5 mm / 9 mm off the (265, 4.8) eddy-probe point used by the load page and
the station calibration — the front-right corner next to the inductive station. The nozzle is
lowered to 1 mm above the probe trigger height there and the hotend is **cooled by 100 °C
while resting** (part fan at 60 % from the purge helps), then lifted: the blob that oozed after
the purge freezes and is torn off. There is no brush stroke; this is a cold-pull-style wipe.
Whether a silicone pad sits there has not been checked on the machine (the app's numbers
are used verbatim in the port).

## Constants

| value | where | use |
|---|---|---|
| 265.0 / 4.8 | @0xedc988 / @0xedc98c | probe / wipe base point |
| 1.5 / 9.0 | @0xedc990 / @0xedc994 | wipe offsets → (266.5, 13.8) |
| 8.0 | @0xedc998 | purge height above probeZ |
| 1.0 | @0xedc938 | wipe height above probeZ |
| −2.0 / 1.5 / −8.0 / 254.0 / 275.0 | @0xedc99c–@0xedc9a8 | moveLoadLocation per-tool XY nudge (same table as the load page) |
| 100 | `addiu -0x64` @0x9f5a4c | cool-down delta |
| 90 / 180 | @0x9f4d60 / @0x9f5a70 | CheckTemp poll budgets (s) |
| 153 | `"M106 P1 S153"` | purge fan 60 % |
| 0x3e | @0x9f20f0 | E0165 |
