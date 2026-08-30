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
 │                            └─ levelboard    /dev/ttyS7 fixed under-bed cylinder
 ├─ DryingService ──/dev/ttyS3──► filament drying box (own MCU, not Klipper)
 ├─ OrcaServer / MQTT cloud / camera
 └─ /usr/data/firmwareRes/config/*.json — per-unit calibration + state
```

## Printer facts

- 4-tool toolchanger: docked heads T0–T3 at X≈297 (250/280 are the staging and
  approach waypoints, not the docks), picked up by the X carriage
  with a lock motor. `temperature_sensor motor_value` exists (printer.motor.cfg)
  but the app only ever logged it -- no grab/release decision reads it; see
  `25-app-vs-klipper-ownership.md`.
- Bed ~250×250, 10×10 bed mesh from the carriage eddy (`[probe]`, `eboard:PG0`).
  Nozzle XY/Z offset calibration uses a different sensor: the fixed inductive
  cylinder under the bed (`[e_stop X/Y/Z]` on `levelboard:PD0`).
- 4 filament channels, each a direct-drive extruder on its own head — there is no
  feed hub; `manual_stepper gear_stepper` is the tool LOCK motor (see
  `47-filament-load-recovered.md`). Presence sensors `fd_ex0..3`, motion sensors
  `fm_ex0..3`.
- Chamber heater + 4 fans + LED, front/top door switches.

## Method

The binary is not stripped, so targeted questions are answered by reading symbols and
disassembling straight from the file (capstone), rather than a full Ghidra project —
Ghidra's auto-analysis wrongly marked the logging helpers noreturn and truncated ~916
functions (29k bogus CALL_RETURN overrides), so its decompile of exactly the
interesting `CommMgr` methods was misleading until repaired. Addresses cited in these
notes are verified against the live binary.

## Notes map

Files ending `-recovered` are reconstructions of the stock app's behaviour; the matching
`-port` note says what this repo actually shipped.

- `10-hardware.md` — MCUs, serial ports, Klipper objects the UI expects
- `20-klipper-fork.md` — fork delta: custom commands, the `Tn` interception
- `25-app-vs-klipper-ownership.md` — which side owns which behaviour, and what is ported
- `30-toolchange.md` — dock/grab/release sequences, sensors, mounted-tool state
- `40-offsets.md` — where per-unit numbers live; per-tool offsets; the absolute print Z offset
- `44-vfa-calibration.md` — VFA (motor torque-ripple) compensation: the stock chain, and the numpy gap that blocks it
- `45-tool-offset-calibration.md` — the Klipper port: storage layout, commands, guards
- `46-offset-calibration-recovered.md` — the app's calibration sequence it was ported from
- `47-filament-load-recovered.md` / `48-filament-load-port.md` — load/unload/purge
- `49-runout-recovered.md` — runout and clog handling (ported: `ff-runout.cfg`)
- `50-print-lifecycle.md` — start/pause/resume/cancel/complete, address-verified
- `50a-nozzle-clean-recovered.md` / `50b-nozzle-clean-port.md` — the pre-print nozzle clean
- `51-pa-calibration-recovered.md` — automatic pressure advance: the sweep, and how to port it
- `60-background.md` — filament system, calibration flows, config keys (background context)
- `70-error-codes.md` — full E-code table (behavioral spec)
- `80-s6-migration.md` — the prefix root and s6 supervision plan
- `85-packaging.md` — apk vs opkg, why opkg won, and the .ipk proof of concept
