# Feature list

Reforge replaces the FlashForge application layer on the Creator 5 family
with Klipper and a toolchanger-aware web and touchscreen experience.

## Printer owner features

| Area | What is included | Status |
|---|---|---|
| Installation | FlashForge-style USB installer, one package per model, model guard | ✅ Yes |
| Recovery | Matching stock package restores stock files | ✅ Yes |
| Calibration import | Factory dock, station, nozzle, and bed data imported on first boot | ✅ Yes |
| Printing | Stock slicer G-code, preparation, mesh, clean, tool checks, cancel/pause/resume | ✅ Yes |
| Toolchanger | T0–T3 selection, docking/grabbing, mounted-tool detection, safe homing | ✅ Yes |
| Tool calibration | Per-tool offsets, station calibration, bounded probes, sanity checks | ✅ Yes |
| Bed mesh | Factory mesh import, 10×10 probing, save/load through `MESH_DATA` | ✅ Yes |
| Filament | Tool-specific load, unload, purge, cold wipe, material temperatures | ✅ Yes |
| Runout and clog | Mounted-tool sensors pause prints and support load/resume recovery | ✅ Yes |
| Pressure advance | Automatic FlashForge-compatible sweep, HelixScreen integration, and slicer-oriented results | ✅ Yes* |
| VFA calibration | Klipper VFA support with required MCU library and dependency | ✅ Yes |
| Chamber | Pro heater/light configuration and heater-following fan; heater-free Creator 5 config | ✅ Yes |
| Mainsail | Mainsail over Moonraker, webcam stream, Klipper API compatibility | ✅ Yes |
| Screen | HelixScreen with tool/material-aware filament controls and persistent settings | ✅ Yes |
| SSH | Root access with per-printer first-install password on the USB stick | ✅ Yes |
| Updates | APK feed, signed packages, preserved user settings and password | ✅ Yes |

\* Pressure advance is a manual check. See the [pressure advance calibration
guide](pressure-advance.md).
