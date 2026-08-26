# Who decides what: firmwareExe vs Klipper

Mapped 2026-08-21 from the Ghidra decompile of firmwareExe, the fork's `klippy/extras`, and the
stock config (binary addresses given for cross-reference). Rule of thumb: Klipper executes primitives and keeps
thermal runaway; every *policy* lives in the app. Anything in the left column is absent when a
print is driven from Mainsail unless `ff_*` re-provides it.

| Subsystem | App decides | Klipper side | Evidence |
|---|---|---|---|
| Heaters | `M104 S.. T0..T3`, `M140`, `SET_HEATER_TEMPERATURE HEATER=chamber_heater`; **never M109/M190** — waiting is app-side polling; staged heating e1+e2 then e3+e4; 5-min bed soak; chamber heater coupled to `chamber_heat_fan` 0.9 / `chamber_loop_fan` 0.3 in the app only | `[verify_heater]` (fork hardcodes gain times, caps concurrent extruder heating at 2, loosens PID settle so M109 returns early); `min_extrude_temp: -200` on all extruders = cold-extrude guard effectively off. The chamber is **ported**: `ff-chamber.cfg` wraps `SET_HEATER_TEMPERATURE` and adds `M141`/`M191`, gated on the model that actually has an element | `CommMgr::heatManager` @0x76… (CommMgr.c:2576-2700) |
| Material temps | from `filament.json` via `getFilamentOperationTemp` | none | CommMgr.c, LoadFilamentPrint.c |
| Runout / clog | app state machine on `filament_switch_sensor fd_ex*` `filament_detected` + `"wheel runout:Tn"` text; arms/disarms with `SET_FILAMENT_SENSOR … ENABLE=0/1`; endless-spool auto-swap (E0162/E0163) | all eight sensors `pause_on_runout: False`; motion sensors' `runout_gcode` only `action_respond_info` — **ported** (mounted-tool arming in `ff_toolchange.py`, pause via `payload/klipper/config/ff-runout.cfg`; no endless spool), see `49-runout-recovered.md` | `printer.filament.cfg`, `dealFilamentWheelStatus`, `checkAndAutoFeed` |
| Doors | `openDoorPause` toggle in general.json | `[gcode_button topDoor/frontDoor]` with **empty** `press_gcode` | `printer.base.cfg:278-287` |
| Load / unload / purge | app sequences (`FilamentLoad::doLoad/doUnload`, `clearNozzlePrint`) — grab tool, purge chute X275 Y254, material+30 °C, `G1 E150`+`E145`; "unload" is the same push | nothing (extruders are direct drive; `gear_stepper` is the tool lock) — **ported** to `payload/klipper/config/ff-filament.cfg`, see `48-filament-load-port.md` | `47-filament-load-recovered.md` |
| Print lifecycle | prepare (14 steps), preamble, pause (**all hotends off**), resume (staged reheat + re-grab), exit block | no START/END/PAUSE/RESUME macros in stock config | 50-print-lifecycle.md |
| Z frame | absolute print-start Z offset (~+3.2 mm) computed in `BuildPage::startPrint`; per-tool XY/Z diffs applied on every grab | nothing; eddy `G28 Z` is **not** nozzle zero | 40-offsets.md |
| Mesh / leveling | app triggers `BED_MESH_CALIBRATE` / `BED_MESH_PROFILE LOAD=…` | executes | 50-print-lifecycle.md |
| Tool remap | `SDCARD_SET_GCODE_EX_USED_BASE`, `SDCARD_SET_CHANNEL`; fork's `virtual_sdcard` swallows bare `Tn` | executes blindly | 20-klipper-fork.md |
| LEDs / fans | `SET_LED LED=chamber_led`, `SET_FAN_SPEED FAN=…` enum mapping | bare sections — the chamber light is **ported**: `ff-chamber.cfg` sets `initial_WHITE: 1.0` so it comes up lit without a UI to switch it | `ledControlMgr`, `fanControlMgr` |
| PLR, timelapse, camera, MQTT/REST, OTA, drying box | app only | none | 60-background.md |

## Four items looked at in depth (and what turned out to be true)

### Lock-motor "current judgement" — does not exist
The app subscribes to `temperature_sensor motor_value` (A4988 sense, stock `adc_temperature`
0–3.3 V → 0–1000 on `eboard:PA1`) and stores the float, but the **only** use in the binary is a
log line (toolchange.c:419 in the recovered sources, `"extruderGrab/motorValue: %d / %f"`). Every grab /
release decision is made on the grab micro-switches: 3 attempts × 30 polls @100 ms, grab = OR of
`extruder_grab1..4` (`getGrabSensorStatus` @0x76f294 ignores the tool index), post-verify = dock
switch released AND grab switch pressed. `MOTOR_STOP` is a no-op in `printer.motor.cfg`.
`E0145 "Lock motor current abnormal"`: this note says it exists only in the language tables
with no code raising it, while `ff_toolchange.py`'s header says it is raised Klipper/MCU-side.
Both are claims about the stock side and neither is decidable from this repo — but they cannot
both be right, so treat E0145 as unresolved.
→ `ff_toolchange.py` reproduces the switch logic; real current supervision would be a new
feature (sample `motor_value` during the grab inside the extra; thresholds unknown).

### Tool presence
`checkInstallExtruder` @0x781a34: `installed = extruder_pos[tool] PRESSED || (any grab && now_extruder == tool)`.
`now_extruder` lives in `extruder.json`, is reset to −1 by every home, so the app cannot recover
tool identity from sensors after G28. `doCheckM119` is an `M119` poll; `getPrinterReady` a cached
byte; `QUERY_ESTOP` (`e_stop.py:360`) is probe-endstop diagnostics, unrelated.
`checkPlatformInstall/Remove` (E0147/E0167/E0168) are stubs called from the *leveling* page; no
platform switch exists in the config — input signal not found (probably eddy-derived).
→ `ff_toolchange.py` derives the tool from the dock switches (survives power cycle and G28).
Ported: `_FF_PREFLIGHT` (`ff-print-macros.cfg`) refuses before any heating or motion when a
requested tool is not docked or mounted, and again when the machine is uncalibrated.
`FF_BEFORE_PRINT_START` calls it first, before the file is fed, and then chains to
START_PRINT, which calls it again. Note that `[ff_print]`'s call is inside
`{% if origin == 'SDCARD_PRINT_FILE' %}`, so an M23-started print gets only
START_PRINT's -- and with `prepare_on_m23: 0`, the shipped default, not even that.

### Calibration
| Item | App math | Klipper-native |
|---|---|---|
| PID | none — `PID_CALIBRATE` + `SAVE_CONFIG` | upstream |
| Shaper | none — park + `SHAPER_CALIBRATE` / `STEPPER_RESONANCE_FACTORY_CALIBRATE` (a fork **macro** in `printer.vibration.cfg:45-66` over `stepper_resonance_tester.py`) | already Klipper |
| PA | `stof(PA_GET)` only; scoring lives in **closed eboard firmware** (`pa_adjust.py` forwards `pa_action` / `get_emcu_pa_value` to `mcu eboard`) | callable, not reproducible; PA tower as fallback |
| XY/Z nozzle offsets | 4-point `ESTOP` probes + LS circle fit, two passes | **ported** — see `45-tool-offset-calibration.md` |
| Dock auto-cal | parses `HDHOME` / `TMCHOME_*_CY` "Result is …", subtracts nominal | portable; exact arithmetic is in stubs |

### AI spaghetti detection (E0164) — inert
No ML runtime linked (no ncnn/tflite/onnx; OpenCV only for capture), no upload endpoint, no
MQTT verdict topic. The feature is one boolean `aiCheck` in general.json that boots to `false`
(`MainWindow.c:275`); `SettingInfo::doAiDetected()` hard-writes 0. `E0164` is a dead string.
→ nothing to port; Obico off-box (host is MIPS X2000, 128–256 MB, no NPU) with a `[webcam]`
entry in moonraker.conf -- see "What is lost with firmwareExe" below for how the stream is
served now.

## Corrections to earlier notes
- The "station" used for nozzle offsets is **not** the eddy probe. `[e_stop X|Y|Z]` all sit on
  `levelboard:PD0`, a fixed inductive "cylinder" under the bed that detects the nozzle;
  `x/y/z_station_pos` ("TS") is the same 4-point pass with an **empty carriage**
  (`testStationPosFourPointTwoCheck`). `[probe]` (`eboard:PG0`) is the carriage eddy used only
  for G28 Z / mesh. The gap `t<n>_offset_z − z_station_pos` (~3.19 mm) is still the print-start
  Z term; only its provenance was wrong.

## What is lost with firmwareExe (2026-08-23)

The mod replaces firmwareExe outright -- HelixScreen is the only UI and there is no fallback.
Everything in the "app only" row of the table above therefore stops existing on the printer,
not just stops being used. Two of them were load-bearing for users:

### The HTTP REST API on :8898 -- gone
FlashForge's AD5M-style API (`/detail`, `/gcodeList`, `/uploadGcode`, `/printGcode`, and the
`materialMappings` multi-tool start) was served by firmwareExe. Nothing else on the box
implements it, so FlashPrint, Orca's FlashForge profile, the mobile app and any script written
against it stop working the moment the mod is installed. Moonraker's API replaces it
(`/server/files/upload`, `/printer/print/start`); tool-to-slot mapping stops being a request
field and becomes the slicer's job, baked into the gcode.

### The camera stream on :8080 -- lost with the app, but restored from the disk
Easy to get wrong in both directions, so both halves matter.

On stock, the stream *is* firmwareExe's: `strings firmwareExe` shows `GET /?action=stream`,
`multipart/x-mixed-replace;boundary=boundarydonotcross`, `:8080`, its own accept/bind/
pthread_create error strings, `cameraOpen` and `/usr/data/firmwareRes/camera/*` -- an HTTP
server compiled into the app over its OpenCV capture, right down to announcing
`Server: MJPG-Streamer/0.2`. Kill firmwareExe and that server goes with it.

But the real thing is also on the box and merely unused. `/usr/prog/mjpg-streamer/` holds
`mjpg_streamer`, `input_uvc.so`, `output_http.so`, its own `libjpeg.so.9` and a `www/` dir, and
`app_startup.sh:159` exports `LD_LIBRARY_PATH=/usr/prog/mjpg-streamer` for it -- and then never
launches it. So nothing has to be cross-compiled or shipped: start FlashForge's own binary.

`payload/init.d/S65camera` does exactly that, on the S50wifi pattern (the wait for `/dev/video0`
and the respawn loop are backgrounded so a printer with no camera never delays the boot):

```sh
export LD_LIBRARY_PATH=/usr/prog/mjpg-streamer:$LD_LIBRARY_PATH
cd /usr/prog/mjpg-streamer
./mjpg_streamer -i "input_uvc.so -d /dev/video0 -r 1280x720 -f 30" \
                -o "output_http.so -p 8080 -w www"
```

Two details that bite: `libjpeg.so.9` lives in that directory, so without the LD_LIBRARY_PATH the
binary dies on a missing shared object (the same failure moonrakerDaemon had, which is why
`anvil-env.sh` is the one place the library path is written down); and the
plugin `.so` names resolve against the working directory, hence the `cd`. nginx proxies it at
`/webcam/` and `assets/moonraker.conf` carries the matching `[webcam]` entry with relative URLs,
so one forwarded port is enough.
