# firmwareExe analysis — overview

Analyzed binary: `firmwareExe` (20.9 MB, ELF 32-bit MIPS32r2, Ingenic XBurst2 SoC,
Linux 3.10.14, **not stripped** — full C++ symbols). Machine identifies itself as
"Creator 5 Pro", cloud backend `api.voxelshare.com`.

## The single most important finding

**The printer already runs Klipper.** `firmwareExe` is NOT the motion firmware — it is
the LVGL touchscreen UI + orchestration daemon. It:

- starts Klipper with `/usr/prog/klipper/start.sh &`
- talks to Klipper's native API socket at `/tmp/uds` (stock webhooks JSON:
  `gcode/script`, `objects/query`, `objects/subscribe`, …)
- implements everything "smart" (toolchange orchestration, print lifecycle, filament
  runout auto-swap, calibration wizards, cloud/camera/LAN APIs) **app-side**, by
  sending G-code strings.

The Klipper fork itself ships no START/END/PAUSE/RESUME/CANCEL macros and no
toolchange motion code — a print started from Mainsail/Moonraker gets none of that
behaviour unless something re-provides it. That something is this repo:
`ff_toolchange.py` + the config/macros.

## System architecture

```
firmwareExe (touchscreen app)
 ├─ LVGL UI on /dev/fb0 + touch /dev/input/event2
 ├─ KlipperAPI ──/tmp/uds──► Klipper fork (/usr/prog/klipper)
 │                            ├─ mcu           main board: X/Y/Z, bed
 │                            ├─ eboard        /dev/ttyS5 carriage extruder driver
 │                            ├─ eheaterboard  /dev/ttyS4 4 hotend heaters + 24V
 │                            └─ levelboard    /dev/ttyS7 eddy-current probe
 ├─ DryingService ──/dev/ttyS3──► filament drying box (own MCU, not Klipper)
 ├─ OrcaServer / MQTT cloud / camera
 └─ /usr/data/firmwareRes/config/*.json — per-unit calibration + state
```

## Printer facts

- 4-tool toolchanger: docked heads T0–T3 at X≈250–280, picked up by the X carriage
  with a lock motor (current sensing via `temperature_sensor motor_value`).
- Bed ~250×250, 10×10 eddy bed mesh; eddy probe also used for nozzle XY/Z offset
  calibration.
- 4 filament channels with feed hub (`manual_stepper gear_stepper`), presence sensors
  `fd_ex0..3`, motion sensors `fm_ex0..3`.
- Chamber heater + 4 fans + LED, front/top door switches.

## Method

The binary is not stripped, so targeted questions are answered by reading symbols and
disassembling straight from the file (capstone), rather than a full Ghidra project —
Ghidra's auto-analysis wrongly marked the logging helpers noreturn and truncated ~916
functions (29k bogus CALL_RETURN overrides), so its decompile of exactly the
interesting `CommMgr` methods was misleading until repaired. Addresses cited in these
notes are verified against the live binary.

## Notes map

- `10-hardware.md` — MCUs, serial ports, Klipper objects the UI expects
- `20-klipper-fork.md` — fork delta: custom commands, the `Tn` interception
- `30-toolchange.md` — dock/grab/release sequences, sensors, mounted-tool state
- `40-offsets.md` — where per-unit numbers live; per-tool offsets; the absolute print Z offset
- `50-print-lifecycle.md` — start/pause/resume/cancel/complete, address-verified
- `60-background.md` — filament system, calibration flows, config keys (unported context)
- `70-error-codes.md` — full E-code table (behavioral spec)
