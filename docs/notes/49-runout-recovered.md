# Filament runout / clog handling — recovered, and the port

Everything below was app-side. The stock config ships all eight sensors with
`pause_on_runout: False`; the motion sensors' `runout_gcode` only prints
`wheel runout:Tn` / `wheel insert:Tn` and the switch sensors have no gcode at all.

## Sensors (live `printer.filament.cfg`)

| tool | switch (`filament_switch_sensor`) | motion (`filament_motion_sensor`, `detection_length 50`) |
|---|---|---|
| 0 | `fd_ex0` `!eheaterboard:PC13` | `fm_ex0` `!eheaterboard:PA15` |
| 1 | `fd_ex1` `!eheaterboard:PC14` | `fm_ex1` `!eheaterboard:PB13` |
| 2 | `fd_ex2` `!eheaterboard:PC3`  | `fm_ex2` `!eheaterboard:PB11` |
| 3 | `fd_ex3` `!eheaterboard:PA2`  | `fm_ex3` `!eheaterboard:PB12` |

Switch `event_delay 1.0`, motion `event_delay 3.0`. The fork adds
`RESET_FILAMENT_SENSOR SENSOR=<motion>` (filament_motion_sensor.py, "chenhe"): moves the
runout position to `extruder_pos + detection_length`.

## Switch sensors (runout, E0162): polled, never enabled/disabled

No `SET_FILAMENT_SENSOR … fd_ex*` exists in the binary. The app subscribes to the four
`filament_switch_sensor fd_exN` objects (`CommMgr::queryStateString` @0x75c26c…) and reads
`filament_detected` (`doQueryResponse` @0x77815c…).

* `BuildPage::checkFilamentDetection` @0x9fe70c (UI timer): if print status == 4 (printing)
  and the **mounted** tool's (`extruder.json now_extruder`) `filament_detected` != 1 → log
  `"extruderN filament runout"` — nothing else (the rest of the function updates the
  temperature display).
* The pause is in the print engine thread, `CommMgr::serialPrint` @0x7a0d28-0x7a10e8:
  `checkFilamentUsedOut(channel)` @0x7a64c8 + `getNoFilamentFlag(channel)` @0x7a6418
  ("3 - runout nowChannel: %d, noFlag: %d"), `printfFilamentDetectInfo`, then
  `isFilamentSame` ("is same changeExt") → either the endless-spool path
  (`changeExtruderChannel` @0x796354, `checkAndAutoFeed` @0x7a6af4) or the plain pause:
  `M25`, wait for sd state `paused` ("no filament pause stats: %s"), `M400`,
  `SAVE_GCODE_STATE NAME=PAUSE_state`, hotends off, park — the normal pause block
  (50-print-lifecycle.md), with E0162 "Paused. Filament runout." on screen.
* Only the channel being printed is checked. Other heads' sensors are ignored.

## Motion sensors (clog, E0163): only the mounted tool's is ever enabled

`CommMgr::setFilamentWheelManager(TypeManager tool, bool enable)` @0x79b060 (Ghidra showed
only its first statement):

1. lock; `wheelEnable = false`; clear the per-tool wheel flags;
2. `SET_FILAMENT_SENSOR SENSOR=fm_ex0 ENABLE=0` … `fm_ex3 ENABLE=0` — **all four, always**;
3. if `enable`: detached thread (lambda @0x79a8bc): `sleep 3 s`; if general.json
   `plugCheck` is false → `wheelEnable = false`, done; else
   `RESET_FILAMENT_SENSOR SENSOR=fm_ex<tool>`, `SET_FILAMENT_SENSOR SENSOR=fm_ex<tool>
   ENABLE=1`, `wheelEnable = true`.

Call sites (tool, enable):

| where | args | meaning |
|---|---|---|
| `serialPrint` @0x79f048 | (channel, 1) | arm at print start |
| `serialPrint` @0x7a0854 | (channel, 1) | re-arm after resume / channel change |
| `serialPrint` exit block @0x7a25fc | (6, 0) | disarm at cancel/complete (6 = none) |
| `changeExtruderChannel` @0x79750c / @0x797dcc | (old, 0) … (new, 1) | disarm before the head swap, arm after |
| `autoFeedChangeExtruder` @0x7a794c / @0x7a7f60 | same pair | endless-spool variant |
| `BuildPage` ctor @0x9cfc10 | (6, 0) | disarm when the print page opens |
| `settingOpenWheel` @0x79a7ac | (now_extruder, 1) or (0, 0) | settings toggle `plugCheck` |

Event path: Klipper runs the sensor's `runout_gcode` → `wheel runout:Tn` →
`CommMgr::doApiResponse` @0x77794c (only if `wheelEnable`) → `dealFilamentWheelStatus`
@0x77b2bc parses `runout` / `insert` + `T<n>` and sets/clears that tool's flag.
`BuildPage::checkFilamentWheel` @0x9fea30 (UI timer): `plugCheck` && printing &&
`wheelEnable` && flag[now_extruder] → `doPopupPause(2)` @0x9ef938 → `setPrintPause`, E0163
"Paused. Clog detected.". `insert` only clears the flag.

The load pages (`FilamentLoad`, `LoadFilamentPrint`) never touch the sensors.

## Port

`pkg/klipper/prog/klippy/extras/ff_toolchange.py` (`[ff_toolchange] runout_switch_prefix: fd_ex`,
`runout_motion_prefix: fm_ex`; empty or absent sections = that kind off, partial = config
error):

* grab verified → every sensor off, motion sensor of the new tool reset (the app's
  `RESET_FILAMENT_SENSOR` — a sensor that sat disabled while its extruder moved would fire
  the moment it is enabled), then that tool's switch + motion sensor on. The app does this
  3 s later from a thread; here the grab moves are already complete. Same-tool re-select
  re-arms.
* release (and so `TOOLCHANGE_PARK` / `UNSELECT_TOOL` / print end) → everything off,
  before any motion — as `changeExtruderChannel` does.
* `klippy:ready` mirrors whatever the dock switches say is mounted.
* `FF_RUNOUT_ARM [TOOL=]` / `FF_RUNOUT_DISARM`; status `runout_armed` (tool or −1),
  `runout_sensors` (object names); `TOOLCHANGE_STATUS` prints the same.

`pkg/anvil-core/payload/config/ff-runout.cfg` (include after `printer.base.cfg`; Klipper merges repeated sections,
later options win — the stock `printer.filament.cfg` is left untouched):

* the eight sections get `runout_gcode: _FF_RUNOUT TOOL=n KIND=switch|motion` and
  `insert_gcode: _FF_INSERT …`, `pause_on_runout` stays `False`.
* `_FF_RUNOUT`: ignores the event unless `print_stats.state == printing`, not paused, and
  `TOOL` is `ff_toolchange.current_tool`; then `PAUSE`, `M117 T<n> clog` or
  `M117 T<n> out of filament` (the app's E0162/E0163 codes are not emitted) and a console
  line telling the user to `LOAD_FILAMENT TOOL=n` (its paused path is the app's in-print
  feed: `E100`, `E-5`) and `RESUME`. `_FF_RUNOUT_CFG` `clog_pause` is the app's `plugCheck`
  (0 = report a clog, don't pause); `switch_pause` has no app equivalent.
* `_FF_INSERT`: a hint only (`LOAD_FILAMENT TOOL=n`, plus `RESUME` when paused on that
  tool). Klipper fires insert events only while idle, so it never interrupts a print.

Divergences, deliberate:

* switch sensors are also disabled for the non-mounted tools (the app polled them instead);
  `filament_detected` keeps updating in the status regardless of `enabled`, so UIs still
  show presence for all four.
* no endless spool / `changeExtruderChannel` — another tool is another head.
* the app re-arms the motion sensor after every resume (@0x7a0854). Nothing does that
  here unless `RESUME` calls `FF_RUNOUT_ARM` (recommended in `ff-print-macros.cfg`): after
  a clog pause the sensor only re-arms by itself once the encoder sees motion again.
* Klipper's own gate is `idle_timeout == Printing`, which any motion satisfies (a manual
  `UNLOAD_FILAMENT` pulls filament through the switch); the SD-state check in
  `_FF_RUNOUT` is what keeps that from pausing nothing.
