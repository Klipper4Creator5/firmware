# Filament LOAD / UNLOAD -- recovered from firmwareExe (MIPS32 LE, -O0)

Klipper port: [`48-filament-load-port.md`](48-filament-load-port.md).

Source: machine-code reading with a custom MIPS disassembler (Ghidra bodies stop at the first `ErrorBak`
ctor); the annotated `.asm` listing is not in this repo. Cross-checked against `live/printer.motor.cfg`,
`live/printer.filament.cfg`, `live/firmwareRes-config/{filament,extruder}.json` and
[`30-toolchange.md`](30-toolchange.md) for the grab/release sub-steps.
Everything marked **confirmed** is read from instructions; **inferred** is stated as such.

## 0. Headline facts (replace the guesses in (earlier guesswork notes, superseded))

1. **The live page is `FilamentLoad`** (`MainWindow::doFilament` / `barAppearDryingBox` ask
   `PageManager::newPage("12FilamentLoad")`). `FilamentMgr` is only reachable through the same factory by
   class name `"11FilamentMgr"` and **nobody requests it** -- dead code (its `G1 E300 F300 / G1 E298 F300` are
   never sent). `LoadFilamentPrint` is the runout-during-print variant (created by `BuildPage::initDialog`,
   shown by `BuildPage::showFilamentRunout`).
2. **UNLOAD runs exactly the LOAD sequence.** `doLoad` stores `FilamentEnumMgr=1`, `doUnload` stores `2`
   into `this+0x158`; that field is read only by the `LoadGuide` constructor (picks guide text LANG 0xd9
   vs 0xd8). `LoadGuide "Next" -> doGuideNext -> startPrepareLoad` is the same path for both, and neither
   `prepareProbe` nor `doLoadingOperation` ever reads `+0x158` (verified: no `0x158($..)` access in either
   body). There is **no retract / tip-forming / reverse-feed** anywhere in the user-facing flow: on this
   machine "unload" means "push the next filament through and purge" (the feed goes forward only).
3. **`[manual_stepper gear_stepper]` is the tool-lock motor, not a feeder** (coordinator fact 1 confirmed):
   the string `MANUAL_STEPPER` does not exist in the binary at all; `"manual_stepper gear_stepper"` is only
   parsed in `CommMgr::doApiResponse` (endstop triggered/not triggered) for the grab/release path which runs
   the `MOTOR_GRAB / MOTOR_RELEASE / MOTOR_STOP` macros from `printer.motor.cfg`.
4. **No `SET_FILAMENT_SENSOR` / `RESET_FILAMENT_SENSOR` / `M119` / `QUERY_FILAMENT_SENSOR` in the load
   path.** Those live in `CommMgr::setFilamentWheelManager` lambda @0x79a8bc, whose callers are
   `serialPrint` (print start), `settingOpenWheel`, `changeExtruderChannel`, `autoFeedChangeExtruder` and the
   `BuildPage` ctor -- print-time only. The load page never touches them. Sensor state is only used to gate
   the UI (tool button enabled only when `fd_ex<n>` says filament present, section 1).
5. **The tool is grabbed onto the carriage first**, driven to the purge position, filament is pushed with
   the tool's own extruder (`G1 E...` with the active extruder selected by the grab), the tool is parked
   again. Purge position: `X = 275 (+xoff)`, `Y = 254 (+yoff)`, `Z = probeZ + 8` where `probeZ` is a
   `PROBE_ACCURACY` result taken at `(X265, Y4.8)` with the **empty** carriage before the grab.
6. **Load temperature = material table in the binary + 30 C** during the feed, then `M104 S0`.
   Speed `F240` (`F80` with a `0.25mm` nozzle). Feed = `G1 E150` + `G1 E145` = **295 mm** relative (G92 E0
   first), both `M400`-waited.

## 1. Entry and gating (UI thread)

`FilamentLoad::doFilamentIndex(tool)` @0xa7473c (tool button): for each tool it checks, in order,
`CommMgr::checkInstallExtruder(tool, ExtruderGrabInfo)` (dialog LANG 0x1b6 if the tool is not docked
properly), the filament-present byte `this[0x16e+tool]` (= `fd_ex<tool>` `filament_detected` from
`doQueryResponse`; dialog LANG 0x1b7 if no filament), then `CommMgr::checkTempError(tool, true)`; only then
`m_selectIndex (+0x130) = tool`. The 4 bytes come from `CommMgr::getFilamentDetectionInfo` (switch sensors
`fd_ex0..3`, pins `!eheaterboard:PC13/PC14/PC3/PA2`); the motion sensors `fm_ex0..3` are not consulted.

`doLoad` / `doUnload` @0xa77348/@0xa774c4: set `+0x158 = 1 / 2`, create `LoadGuide(mode, lv_scr_act())`,
wire its Next/Back/Close buttons. `doGuideNext` @0xa76f78: destroys the guide, `slotSetMainEnable(false)`,
`setExtruderEnable(false)`, `startPrepareLoad()`.

`startPrepareLoad` @0xa77118 (confirmed):
```
cancel(+0x16c) = 0 ; hide top container, show step container ; arrive1()        (UI)
+0x13c = MainWindow::getMainMachineStatus() ; setMainMachineStatus(3)
state(+0x138) = 1
T = CommMgr::getFilamentOperationTemp(tool)            (section 3)
CommMgr::heatManager(tool, T + 30)        -> "M104 S<T+30> T<tool>"         (@0x770114, case 0..3)
pthread_create(pthreadFilamentLoad) ; (on failure: +0x16d=1, slotSetMainEnable(true)) ; pthread_detach
```
`pthreadFilamentLoad` @0xa79ec0: `err = prepareProbe(); if (!err) err = doLoadingOperation(); doLoadingResult(err)`.

## 2. prepareProbe @0xa7a730 (worker thread) -- Z reference for the purge height

Skipped entirely (returns 0) if `BuildPage::instBuildPage != 0` (a print page exists) or if
`this+0x124 needProbe == 0` (set to 1 by the ctor, cleared after one successful probe -> once per page life).
```
CommMgr::homeManager(true, true, true)             G28 X Y / G28 Z / G28 / MOTOR_RELEASE as required (toolchange.c)
[cancel?] -> G1 Z10 F1200 ; M400 ; return 0
SET_GCODE_OFFSET X=0 Y=0 MOVE=1 MOVE_SPEED=600 ; M400
G1 X250.000 F12000
G1 Y4.800                       (no F)            constants @f008f4 250.0, @f008f0 4.8, @f008ec 265.0
G1 X265.000                     (no F)
M400
[cancel?] -> G1 Z10 F1200 ; M400 ; return 0
CommMgr::checkProbeZValue(&z) @0x78b32c : up to 3 x { setApiResponse(""); cmdProbeCalibration() = setEddyZero();
        "PROBE_ACCURACY SAMPLES=3"; sleep; parse "maximum/minimum/average" from the reply; error if
        errorMessageIndex(reply) != 0 } ; accepted when max-min <= 0.1 (double @db6b00) ; then "G1 Z10 F1200"
   err -> G1 Z10 F1200 ; M400 ; return err
G1 Z10 F1200 ; M400
probeZ(+0x128) = z ; needProbe(+0x124) = 0
```
So `probeZ` is the Z at which the carriage's eddy probe fires over the front-right purge/wipe station with
**no tool mounted**, gcode offset zeroed; the same (265, 4.8, 250) triple is used by `clearNozzleManager` /
`clearNozzlePrint`. Which of max/min/avg is stored (`fp+0x1c0`) was not traced -- likely the average.

## 3. Temperature and speed tables (coordinator fact 2)

`CommMgr::getFilamentOperationTemp(int tool)` @0x79b764 (confirmed):
`type = Config::filamentConfig()[+0 / +8 / +0x10 / +0x18]` = `ex<tool>_filament_type` from
`/usr/data/firmwareRes/config/filament.json`; out-of-range tool -> 999 -> **220**; otherwise
`g_mapFilamentTempDefault[type]` (std::map<FILAMENT_TYPE,int> @0x12ed028, built by
`__static_initialization_and_destruction_0` @0x675dc4 from 22 `{type,temp}` pairs at **`.rodata 0xd61d44`**).
Names from `g_mapFilamentTypeText` (same initializer, `_global.part02.c:12140..`).

| type | name | temp | type | name | temp |
|---|---|---|---|---|---|
| 0 | PLA | 220 | 11 | PA-CF | 270 |
| 1 | PETG | 240 | 12 | HIPS | 250 |
| 2 | PLA-CF | 220 | 13 | PVA | 220 |
| 3 | PETG-CF | 240 | 14 | TPU-90A | 220 |
| 4 | ABS | 250 | 15 | TPU-95A | 220 |
| 5 | ASA | 250 | 16 | TPU-64D | 220 |
| 6 | SILK | 220 | 17 | PC | 260 |
| 7 | PET-CF | 270 | 18 | PA | 260 |
| 8 | PAHT-CF | 280 | 19 | PC-ABS | 260 |
| 9 | S-PAHT | 280 | 20 | PPS-CF | 290 |
| 10 | S-Multi | 270 | 21 | "" (custom) | 220 |

The page heats to **table + 30** (`addiu $v0,$v0,0x1e` @0xa77270) -- e.g. PLA loads at 250 C, PETG at 270 C.
(`LoadFilamentPrint::doOk` uses the table value *without* +30; `clearNozzle*` and the calibration purge use
their own `int temp` argument.) This unit's `filament.json`: ex0/ex1/ex3 type 0 (PLA), ex2 type 1 (PETG).

`CommMgr::getFilamentOperationSpeed(int tool)` @0x79bae8 (confirmed): `nozzle = filamentConfig()[+0x20 /
+0x38 / +0x50 / +0x68]` = `ex<tool>_diameter` string; `"0.25mm"` -> **80**, anything else -> **240**
(mm/min; emitted as `F240` / `F80`). The filament type is read but unused.

## 4. doLoadingOperation @0xa7b6c8 -- the machine sequence (tool n = m_selectIndex)

Structure (confirmed): mutex `+0x140`; if already cancelled -> `heatManager(n,0)`, return 0. `sleep(2)`.
`speed = getFilamentOperationSpeed(n)`; `setApiResponse("")`. Then a loop, **one iteration per second**
(`sleep(1)` at the tail), each iteration re-reading `getTemperatureListMgr()` (13 ints, see asm) ->
`cur = temps[n]`, `target = temps[n+6]`, `chamberTarget = temps[11]`, posting the "cur/target C" label
(lambda #1), and dispatching on `state` (jump table @0xefe298):

```
state 1  CommMgr::changeExtruderManager(n, true, false)      home if not homed, release any other tool,
                                                             doGrabExtruderMgr(n): dock approach, MOTOR_GRAB,
                                                             SET_GCODE_OFFSET X=<t n off> Y=.. MOVE=1 (31-/35- docs)
         error -> state 6 (err kept)
         M400
         CommMgr::moveLoadLocation(false):                    G1 X250 F12000
                                                             G1 Y<254 + yoff> F24000
                                                             G1 X<275 + xoff> F2400
                                                             M400
              (xoff,yoff) from Config::extruderConfig()+0x5c = "now_extruder":
               0:(0,0)  1:(-2,0)  2:(-2,+1.5)  3:(-2,-8)  other:(0,0)      consts @db6b20 -2, @db6a88 1.5, @db6b24 -8, @db6b28 254, @db6b2c 275
         if BuildPage::instBuildPage == 0:   G1 Z<probeZ + 8.000> F3000          (8.0 @f008f8; no Z move at all while a print page exists)
         setApiResponse("") ; state = 2
state 2  if -3 <= cur - target <= 3  -> state 3            (temperature reached; polled once a second, no timeout)
         else if errorMessageIndex(getApiResponse()) != 0 -> state 6 with that error
state 3  UI arrive2 ; setApiResponse("") ; state = 4 ; MainWindow::setMainMachineStatus(0x11)
state 4  getVirSdInfoFilament(&info)                         (snapshot of fan speeds from virtual_sdcard status)
         changeFilamentControlFan(true, chamberTarget, 0):  [chamberTarget != 0: SET_FAN_SPEED FAN=chamber_heat_fan SPEED=0.000
                                                                                 SET_FAN_SPEED FAN=chamber_loop_fan SPEED=0.000]
                                                             SET_FAN_SPEED FAN=chamber_fan SPEED=0.000
         G92 E0
         G1 E150 F<speed>                                    (speed = 240 | 80)
         M400
         G1 E145 F<speed>
         M400
         changeFilamentControlFan(false, chamberTarget, info.chamber_fan):
                                                             [chamberTarget != 0: chamber_heat_fan 0.900 ; chamber_loop_fan 0.300]
                                                             SET_FAN_SPEED FAN=chamber_fan SPEED=<saved>
         CommMgr::doReleaseExtruderMgr(n, false, false)      park tool (dock approach, MOTOR_RELEASE, MOTOR_STOP; 35-release-path-fidelity.md)
                                                             -- its ErrorBak is assigned but NOT tested: always -> state 5
         state = 5
state 5  UI arrive3 ; state = 6
         for i in 0..3: if getNoFilamentFlag(i) && i == n:
              sendGcodeCmd("SDCARD_SET_GCODE_EX_USED_CHANGED INDEX=<i> EXTRUDER=T<n>")      (clears a pending runout remap)
         setNoFilamentFlag(n, 0)
state 6  done = 1
tail     if (!done && !cancel) { sleep(1); continue }
exit     heatManager(n, 0)  -> "M104 S0 T<n>" ; unlock ; return err
```
Cancel (`doCancel` @0xa71ee4 sets `+0x16c`) is only honoured at the loop tail and at the two checkpoints in
`prepareProbe`; a cancel during state 4 lets the whole feed finish first, then heat-off.

There is **no M109/M190**, no `M83`, no `T<n>` (the grab selects the extruder via the tool-change macros),
no `SDCARD_SET_CHANNEL`, no wheel/channel command, and **no sensor check after feeding** -- success is
simply "both E moves completed". `fd_ex<n>` is not re-read.

`doLoadingResult(err)` @0xa79f78: `+0x134 = err`; `sendGcodeCmd("", true, APIType=3)` + `usleep(200 ms)`,
twice (status poll / flush, no G-code); posts `setLoadComplete` -> `showResultWidget` (error dialog text if
`err != 0`, re-enables the page, refreshes tool buttons from `getFilamentDetectionInfo`/`getExtruderGrabStatus`).
Error codes are whatever `changeExtruderManager` / `errorMessageIndex` return (endstop / probe / timeout
/ tool-change E-codes, see [`70-error-codes.md`](70-error-codes.md)); the load page adds no E0xxx of its own.

**Post-load state writes: none to filament.json / extruder.json.** Only `setNoFilamentFlag(n,0)` (RAM) and the
optional `SDCARD_SET_GCODE_EX_USED_CHANGED` gcode. Material type/colour are edited separately by the page's
edit dialogs (`doSelectFilamentType/Color` -> `Config::syncFilamentConfig`), independent of the motion.

## 5. UNLOAD

Identical to section 4 (see headline fact 2). The only differences are UI strings. For the Klipper port an
"unload" on this machine is therefore: grab tool, go to purge position, heat to table+30, push 295 mm, park,
heat off. If a true retract-unload is wanted it has to be designed, not copied -- the only reverse extruder
moves in the binary are `G1 E-5` (post-purge retract in `LoadFilamentPrint` / `clearNozzle*`), `G1 E-2 F300`
(`clearNozzleManager`), `G1 E-50 F150` (ManualPage "retract" button) and `G1 E-1 F300` (`serialPrint`).

## 6. Variants

**Runout during print -- `LoadFilamentPrint`** (`BuildPage::showFilamentRunout -> setPrepareWidget(tool,..)`):
`doOk` @0x8721e8: `heatManager(tool, getFilamentOperationTemp(tool))` (no +30), `doGrabExtruderMgr(tool,false,false)`,
`moveLoadLocation(false)`, then a 1 s `lv_timer` -> `doUpdateProcess` @0x872400: wait `|cur-target| <= 3`,
`getVirSdInfoFilament`, `changeFilamentControlFan(true, temps[11], 0)`, `speed = getFilamentOperationSpeed(tool)`,
```
G92 E0 ; G1 E100 F<speed> ; M400 ; G92 E0 ; G1 E-5 F<speed> ; M400 ; G92 E0
```
`changeFilamentControlFan(false, ..)`, `setNoFilamentFlag(..)`. No Z probe / Z move. `pthreadReleaseExtruder`
@0x86ef84: if the tool is in the dock zone and the grab sensor agrees -> `doReleaseExtruderMgr`, then
`G1 X100 Y2 F12000`. Heat-off happens in `~LoadFilamentPrint` (`heatManager` caller list).

**Manual page extrude/retract -- `ManualPage::pthreadFilamentOperation`** @0x980b78: mode 1 (load):
`moveLoadLocation(false); G92 E0; G1 E50 F150; M400; G92 E0`; mode 2 (unload): `G92 E0; G1 E-50 F150; M400;
G92 E0` (no move). Heating is done by the page's temperature dialog beforehand.

**SystemTest::startLoadTest** @0x85e0f4 (factory test, T0 only): `homeManager`, `doGrabExtruderMgr(T0)`,
`G1 X130 Y130 F6000; G1 Z250 F600; M400; G92 E0; M109 S<dialog temp> T0;` then up to 1e6 times until stopped:
`G92 E0; G1 E200 F<dialog F>; M400`. `OfflineWidget::doLoadTest` only hides the offline dialog.

**Purge used by print prep (for reference)** -- `clearNozzlePrint` @0x9f46f4 / `clearNozzleManager` @0x7938d8:
same (265, 4.8, 250) approach, `G1 Z<probeZ+8> F3000`, heat + wait, then `G92 E0; G1 E50 F<speed>; M400;
M106 P1 S153; G92 E0; G1 E-5 F<speed>; M400` (print) or `G92 E0; G1 E90 F300; M400; M106 P1 S153; G92 E0;
G1 E-2 F300` + 8 wipe strokes `G1 X16 / G1 X7 F6000` + `G1 Z.. F600` (manager), `M106 P1 S0`, `G1 Z10 F1200`, release.

**Dead:** `FilamentMgr::doLoadingOperation` @0x994e34 (`G92 E0; G1 E300 F300; M400; G1 E298 F300` after the same
grab + `moveLoadLocation`); `FilamentMgr::doUnload` only runs `arriveStep1` (UI).

## 7. App-only UI steps vs real machine commands

App-only (skip in a port): LoadGuide pages, `arrive1/2/3` step icons, `showLoadMsg` temperature label,
`setMainMachineStatus(3 / 0x11 / restore)`, `slotSetMainEnable`, `setExtruderEnable`, the two
`sendGcodeCmd("",..,3)` polls, `doLoadingResult`/`setLoadComplete`/`showResultWidget`, language ids
(0x4f temp label, 0xd8/0xd9 guide, 0xcd "load?" dialog, 0xb1 cancel dialog, 0x1b6/0x1b7 gating dialogs --
no language file in the repo to resolve them).
Machine: everything in sections 2 and 4 that is a quoted G-code line, plus the grab/release macros inside
`changeExtruderManager` / `doReleaseExtruderMgr` (already recovered in `toolchange.c`).

## 8. Constants

| value | where | use |
|---|---|---|
| 30 | `addiu 0x1e` @0xa77270 | added to table temp for the load |
| 220 / 999 | imm @0x79b77c / @0x79b860 | default temp / "no type" |
| 240 / 80 | imm @0x79bb0c / @0x79bd2c; `"0.25mm"` @db4334, `"0.4mm"` @db432c | feed F |
| 22 pairs | `.rodata 0xd61d44` (`g_mapFilamentTempDefault`) | type -> temp table (section 3) |
| 2 s / 1 s / 200 ms | `sleep` PLT @0x1258920 (a0=2, 1), `usleep` PLT @0x1256a70 (0x30d40) | pacing |
| +-3 | `slti -3` / `slti 4` @0xa7c0ac/@0xa7c0c4 | temperature-reached window |
| 8.0f | @f008f8 | Z lift above probeZ for the purge |
| 265.0f / 4.8f / 250.0f | @f008ec / @f008f0 / @f008f4 | probe position |
| 254.0f / 275.0f | @db6b28 / @db6b2c | purge Y / X base (moveLoadLocation) |
| -2.0f / 1.5f / -8.0f | @db6b20 / @db6a88 / @db6b24 | per-`now_extruder` XY correction |
| 0.9f / 0.3f | @db6ac0 / @db6ac4 | chamber_heat_fan / chamber_loop_fan after feed |
| 0.1 (double) | @db6b00 | PROBE_ACCURACY max-min tolerance |
| strings | `"G92 E0"` @efe224, `"G1 E150 F"` @efe22c, `"G1 E145 F"` @efe238, `"M400"` @efe1b8, `"G1 Z"` @efe214, `" F3000"` @efe21c, `"SET_GCODE_OFFSET X=0 Y=0 MOVE=1 MOVE_SPEED=600"` @efe1c0, `"G1 Z10 F1200"` @efe1a8, `"G1 X"` @efe1f0, `" F12000"` @efe1f8, `"G1 Y"` @efe200, `"SDCARD_SET_GCODE_EX_USED_CHANGED INDEX="` @efe244, `" EXTRUDER=T"` @efe26c, `"G1 X250 F12000"` @db4128, `"G1 X250 F4800"` @db4108, `" F24000"` @db3b94, `" F2400"` @db20a8, `"M104 S"` @db29cc, `"PROBE_ACCURACY SAMPLES=3"` @db37f8, `"SET_FAN_SPEED FAN=chamber_fan SPEED="` @db2ab8, LFP `"G1 E100 F"` @e2d600, `"G1 E-5 F"` @e2d614, ManualPage `"G1 E50 F150"` @ea2890, `"G1 E-50 F150"` @ea28a4, SystemTest `"G1 E200 F"` @e19078, FilamentMgr `"G1 E300 F300"` @eae634 | |
| jump tables | doLoadingOperation states @efe298; fanControlMgr @db2b88 (1 chamber_fan, 2 chamber_cool_fan, 3 chamber_heat_fan, 4 chamber_loop_fan, 5 fanM106); sendGcodeCmd APIType @db2944 | |

Temperature list layout (`setTemperatureListMgr` @0x76fdf4 from `doQueryResponse`): `[0..3]` extruder..extruder3
`temperature`, `[4]` heater_bed, `[5]` chamber_heater, `[6..9]` extruder targets, `[10]` bed target,
`[11]` chamber target, `[12]` `temperature_sensor ptcTemp`. `VirtualSdcardInfo+0x34` = `fan_generic chamber_fan speed`.

## 9. Confirmed vs inferred / open

- Confirmed from code: every G-code literal and its order above, temps/speeds tables, the +30, the +-3 window,
  the 1 s polling, unload == load, FilamentMgr dead, no sensor commands, grab-before-feed, release-after-feed,
  fan handling, the `SDCARD_SET_GCODE_EX_USED_CHANGED` tail, the `BuildPage` gating of probe and Z-lift.
- Inferred: `extruderConfig()+0x5c` == `now_extruder` (offset arithmetic over `extruder.json` key order, also
  stated in `30-toolchange.md`); that `now_extruder` equals the just-grabbed tool when `moveLoadLocation` runs (so the
  correction table is per mounted tool); `checkProbeZValue` stores the average.
- Not traced: bodies of `changeExtruderManager`/`doGrabExtruderMgr`/`doReleaseExtruderMgr` (use toolchange.c,
  31-/35- docs), `homeManager` branch selection, `errorMessageIndex` full string->code table,
  `sendGcodeCmd` APIType 1/2/4-6 variants, exact `setNoFilamentFlag` args in `LoadFilamentPrint`.
- Open for the port: whether Klipper's active extruder after the stock grab macro is `extruder<n>` (the app
  relies on it -- `G1 E` is issued with no `T<n>` / `ACTIVATE_EXTRUDER`), and whether a real retract-unload
  is wanted since the stock firmware has none.
