# Nozzle XY/Z offset calibration -- recovered from firmwareExe (MIPS32 LE, -O0)

Source: a custom MIPS disassembler (float/double constant resolution, COP1 fallback for odd-numbered
double regs that capstone rejects, skipdata). Annotated `.asm` listing and tool are not in this repo.
Klipper port: [`45-tool-offset-calibration.md`](45-tool-offset-calibration.md).
Ghidra bodies were useless past the first `ErrorBak` ctor; everything below is from machine code.

## 1. Which variant the touchscreen runs

`CalibrationDialog::doExtruderOffset` (button for the selected T0..T3, `this[0]` = TypeManager) snapshots the
check-boxes into `this[0x1d..0x24]` and spawns `pthreadExtruderOffset` @0x7fcfe4:

```
if Config::testConfig()->generalFirmware (byte +0x10)   -> testExtruderOffsetChangeDirection   (default 0)
elif this[0x21]  "Four-point"  (+0x7c)                   -> testEddyExtruderOffsetForwardTwoCheck  @0x806490  <== SHIPPED
elif this[0x22]  "maker-point" (+0x80):
       this[0x23] "maker-movex" -> ...TwoCheckMakerMoveX ; else this[0x24] -> ...TwoCheckMakerMoveY
```
`initCheckBox` (@0x7ec008, line 331 of CalibrationDialog.c) does `lv_obj_add_state(+0x7c, CHECKED)` -> "Four-point"
is on by default and `doTestWithFF` clears the maker boxes when it is on. `testConfig` comes from
`/usr/data/config/test.json` (keys `grabSpeed, grabSpeedSlow, grabOffset, tempOffset, generalFirmware, cylinder_x,
cylinder_y, impact_loop_count, ...`); `initTestConfig` defaults: generalFirmware=0, cylinder_x=28.5, cylinder_y=214.5.
`testEddyExtruderOffsetForwardTest` / `...Forward` (no TwoCheck) are **not reachable** from the thread.
`testAllExtruderOffset` @0x82fe64 ("All" button, `pthreadAllExtruderOffset`) just loops `for t in 0..3: this[0]=t;`
and calls the same variant selection, then `G1 Z15 F1200; M400`; it sets `this[0x1c]` ("All-T" log prefix).
Other check-boxes: "Loop" (+0x74 -> `this[0x1d]`, 1000 iterations instead of 1), "Release" (+0x70 -> `this[0x1e]`,
release tool after each run), "Clear Ex" (+0x78 -> `this[0x1f]`, heats to `this+0x114` (temp +/- buttons) and purges via
`clearNozzleEddy` instead of a plain tool grab). All default off.

## 2. Exact sequence of testEddyExtruderOffsetForwardTwoCheck (per selected tool `ext`)

No heating anywhere in the default path (only `M104 S0 T<ext>` via `heatManager(ext,0)` on exit). Constants are
IEEE values resolved from .rodata (`@dfdb8c -5.0f, @dfdba8 12.5f, @dfdb90 0.6, @dfdb98 7.0, @dfdba0 3.0f, @dfdbac 10.0f`).
Helper semantics: `estopManager(axis, from, target, &result)` @0x788738 = `setEstopStatus(1); usleep(20ms);
setEddyZero(); SET_VELOCITY_LIMIT ACCEL=100; "ESTOP AXES=<X|Y|Z> TARGET=<target %.3f>"; poll getEstopStatus()
every 100 ms until the `{"module":"estop"}` reply clears it; result = reply "data"; if not ok: G1 Z10 F1200; M400;
SET_VELOCITY_LIMIT ACCEL=20000`. **The `from` argument is never read** -- the caller positions the carriage itself,
and the ESTOP move starts from wherever the nozzle is.

```
 0  releaseFourExtruder(ext, true, false)            park every tool (G28 X / G28 Y / homeManager as needed)
 1  changeExtruderManager(ext, true, false)          -> doGrabExtruderMgr(ext): pick up tool ext
                                                       (setGrabGcodeOffsetMgr applies SET_GCODE_OFFSET X= Y= MOVE=1 for it)
 2  moveCylinderPos(&zP, ext, isStation=0, probeZ=1, useStationEx=0, zTarget=-5.0)  @0x789a1c :
      x0 = cylinder_x - 12.5 ; y0 = cylinder_y                     (28.5-12.5 = 16.0 , 214.5 by default)
      SET_GCODE_OFFSET X=0 Y=0 Z=0 MOVE=0 MOVE_SPEED=600 ; M400 ; G1 Z10 F1200
      G1 X{x0} Y{y0} F12000 ; SET_VELOCITY_LIMIT ACCEL=100 ; M400 ; G1 Z10 F1200
      estopManager(Z, 10.0, -5.0, &zP)        => zP = Z where the station fires under the nozzle ("Z Probe pos")
      G1 F6000 ; SET_VELOCITY_LIMIT ACCEL=20000
 3  G1 X{x0} Y{y0} F1200 ;  G1 Z{zP + 0.6} F1200 ; M400         (nozzle stays at this Z for all 4 points)
 4  ESTOP X  TARGET = x0 + 14   -> px1       Point1 = (px1, y0)
    G1 X{x0} Y{y0} F1200 ; M400                                  (straight back through the centre, same Z)
    ESTOP Y  TARGET = y0 + 14   -> py2       Point2 = (x0, py2)
    G1 X{x0} Y{y0} F1200 ; M400
    ESTOP X  TARGET = x0 - 14   -> px3       Point3 = (px3, y0)
    G1 X{x0} Y{y0} F1200 ; M400 ; M400
    ESTOP Y  TARGET = y0 - 14   -> py4       Point4 = (x0, py4)
 5  (cx, cy, r) = fitCircleByLeastSquares({P1..P4})   @0x645b10  (plain algebraic LS; fitCircleStable is NOT used)
    log "<ext>: <loop>: Center (cx, cy, zP) radius: r"          -- no tolerance / retry check at all
 6  x0 = cx ; y0 = cy
    SET_VELOCITY_LIMIT ACCEL=100 ; G1 Z{zP + 3} F1200 ; G1 Y{cy} F2400 ; G1 X{cx} F2400 ; M400
    [generalFirmware only: checkProbeZValue -> cmdProbeCalibration, needs max-min <= 0.1]
    ESTOP Z  TARGET = -5.0  (from Z = zP+3)  -> zP2            "double Z Probe pos" (Z re-probed at fitted centre)
    G1 Z{zP2 + 0.6} F1200 ; M400
 7  second ("check") pass, same 4 directions, +/-14, around (cx,cy); between points the return is
    G1 Y{cy} F2400 ; G1 X{cx} F2400 ; M400   (Y first, then X)
 8  G1 Y{cy} F2400 ; G1 X{cx} F2400 ; M400 ; G1 Z15 F1200 ; M400
    (cx2, cy2, r2) = fitCircleByLeastSquares({check P1..P4});  log "check Center (...)"
 9  this+4 = cx2 ; this+8 = cy2 ; this+0xc = zP2 ;  doExtruderOffsetSave()
10  optional: "Release" -> doReleaseExtruderMgr(ext, false, false); PNG via drawCalibrationImg; loop
11  exit: heatManager(ext, 0) ; G1 Z15 F1200 ; M400 ; SET_VELOCITY_LIMIT ACCEL=20000
```
Summary of numbers: 4 points per circle, probe radius/travel 14 mm (target = centre +/- 14, i.e. `7.0+7.0`),
approach always from the centre outward (one side per axis, not both), probe Z = `zProbe + 0.6`, lift between
passes `zProbe + 3`, final lift Z15, XY approach feed F1200 (pass 1) / F2400 (pass 2), positioning F12000,
ESTOP runs at ACCEL=100 (restored to 20000). Two passes: pass 2 is centred on the pass-1 fit and re-probes Z
there; pass-2 result is what is stored. No residual check, no retries; any ESTOP error aborts the whole run.

## 3. What is stored

`doExtruderOffsetSave` @0x7fbef0: `OffsetMgr::setXyzOffsetValue(ext, {cx2, cy2, zP2})` and
`extruderConfig()[ext*3 + {0,1,2}] = cx2, cy2, zP2` (Config+0x14c.. = `t<ext>_offset_x/y/z`), then
`syncExtruderConfig()` -> `/usr/data/config/extruder.json`. **Raw machine coordinates of the fitted circle centre
with gcode offset zeroed; nothing is subtracted** (no probe x_offset/y_offset, no station position).

`TS` / `x,y,z_station_pos` come from `testStationPosFourPointTwoCheck` @0x7edf10 (`pthreadStationPos`, the
"station" button): `releaseFourExtruder` (carriage EMPTY), then
`moveCylinderPos(&z, TypeManager=6, isStation=1, probeZ=1, useStationEx=0, -5.0)` -> carriage to
`(cylinder_x, cylinder_y)` (no -12.5), ESTOP Z 10 -> -5; identical 4-point/+-14/F1200 pass at `z+0.6`, LS fit;
then `G1 Z{z+3}; G1 X{cx} Y{cy} F1200; moveCylinderPos(&z2, cx, cy, probeZ=1, -3.0)` (@0x78a610, ESTOP Z to -3),
check pass at `z2+0.6`, LS fit -> `x_station_pos = cx2 (+0x50), y_station_pos = cy2 (+0x54), z_station_pos = z2 (+0x58)`.
So TS is the station-detected feature of the *empty carriage* (on this unit 12.4 mm +X of the nozzle, trigger Z
3.2 mm lower), not an eddy measurement. `CommMgr::getStationExOffset(ext)` @0x79a508 returns
`(x_station_pos - t<ext>_offset_x, y_station_pos - t<ext>_offset_y)` and is only used by `moveCylinderPos(useStationEx=1)`
(other variants) to pre-position a tool over the station. The CSV `calibration-mgr-test-*.txt` lines are exactly
these stored triples (TS = station pass, T<n>-<loop> = tool pass).

## 4. Tool pickup / gcode offset

Pickup is `CommMgr::changeExtruderManager(ext, true, false)` @0x782600 (home check -> `homeManager`, release current
tool via `doReleaseExtruderMgr` if different, `doGrabExtruderMgr(ext, ..)` @0x77ed0c which wraps
`doGrabExtruderLatest(ext,..)` @0x7a8190 and then `setGrabGcodeOffsetMgr`), called once per run before any probing
(step 1). The grab applies the tool's `SET_GCODE_OFFSET X= Y= MOVE=1 MOVE_SPEED=100`;
`moveCylinderPos` then sends `SET_GCODE_OFFSET X=0 Y=0 Z=0 MOVE=0 MOVE_SPEED=600` **before** probing, so all
ESTOP results are raw machine coordinates. The tool is left attached afterwards unless "Release" is checked.

## 5. Not determined / caveats

- `fitCircleByLeastSquares` @0x645b10 body (372 B) was not traced instruction-by-instruction; it is a 3+-point
  algebraic LS fit returning centre+radius (size<3 -> returns 0). With 4 symmetric points it is effectively
  `cx=(px1+px3)/2, cy=(py2+py4)/2`.
- `estopManager` local `0x30` (1.0 for X/Y, 3.0 for Z @0x788898/0x788930) is computed but never used.
- `TypeManager` value 6 passed by the station variant was not resolved to its enum name.
- What physical sensor/feature fires for the empty carriage (TS) is inferred from the numbers only.
- `test.json` contents on this unit unknown; defaults (cylinder_x/y = 28.5/214.5) assumed. If present it
  overrides the start point only -- the stored result does not depend on it beyond convergence.
- `releaseFourExtruder`, `changeExtruderManager`, `clearNozzleEddy` were only skimmed (call/string skeleton).
