# FlashForge Klipper-fork delta

Custom commands/objects that do not exist in vanilla Klipper. Authoritative source:
`/usr/prog/klipper/klippy/extras/*.py` on the printer (plain Python).

## The `Tn` interception (why prints from Mainsail need this repo)

`klippy/extras/virtual_sdcard.py:566-579` — the fork consumes toolchange lines from
the SD stream before they reach the G-code engine:

```python
if line.startswith("T") and line in VALID_GCODE_T:
    self.print_channel = int(line[1:])
    if self.print_channel != self.load_channel:
        self.gcode.run_script("M400")
        self.change_filament = True        # exposed as 'refuelling'
        self.doingChangeEx = True
        while self.change_filament:        # BUSY-WAITS for the UI app!
            self.reactor.pause(...)
```

The fork does **no motion at all** — it raises `doingChangeEx`/`refuelling` and waits
for firmwareExe to perform the physical change and send `SDCARD_CLEAR_REFUELLING`.
For a Mainsail-started print nobody services that state, so a bare `Tn` freezes the
print. `line` is taken from `data.split('\n')` and never stripped, so any trailing
comment (`T2 ; anything`) does NOT match and falls through to `gcode.run_script()`.
Earlier releases of this repo exploited exactly that with a `; ff-toolchange` marker
in the slicer's change-filament G-code. **We no longer ship this fork**: the
`creator5` Klipper branch carries upstream `virtual_sdcard`, so bare `Tn` reaches
`ff_toolchange.py` directly and the marker is gone. This section stays as a record of
stock behaviour.

Couplings to `load_channel` worth knowing: bare `M104`/`M109` get ` T<print_channel>`
appended (543-547), and `SET_PRESSURE_ADVANCE` is rewritten to the per-channel value
when `pa_enable == 1` (479-487). `ff_toolchange.py` used to issue
`SDCARD_SET_CHANNEL` to keep that channel in sync; it was dropped in `764af2a`
("upstream needs no channel") and appears nowhere in `payload/` now — the upstream
`virtual_sdcard` we ship does neither rewrite, so there is no channel to sync.

### `c_helper.so` is no longer checked against its klippy

When a fork tree is shipped (`BUILD_KLIPPER=fork`), `patch.sh` still refuses a
`c_helper.so` that is not MIPS32r2/nan2008/o32, but nothing compares its
exported symbols against the klippy tree travelling with it. cffi resolves
symbols lazily, so a .so built from older sources imports cleanly, passes the
ABI check, installs and boots, then dies at `Unhandled exception during
connect` pointing at cffi rather than at the stale build — which is how it
shipped once before. The `test-chelper` check and its `ALLOW_STALE_CHELPER`
escape hatch were dropped on 2026-08-24 as the fork path winds down. Rebuild
the .so first if klippy ever fails at connect.

## Custom commands (by area)

Toolchanger/motion: `MOTOR_GRAB`, `MOTOR_GRAB2`, `MOTOR_RELEASE`, `MOTOR_STOP`,
`MOTOR_LOCK_TEST`; `HDHOME AXES=.. TARGET=..` (drive-into-stop homing, reports
distance), `TMCHOME_X_CY`/`TMCHOME_Y_CY` (stallguard homing cycle, reports position);
`ESTOP`/`QUERY_ESTOP AXES=..`; `MUTE_MODE_ENABLE/DISABLE`; `GET_MCU_VERSION`.

Virtual SD / print pipeline: `SDCARD_SET_CHANNEL CHANNEL=n`,
`SDCARD_SET_GCODE_EX_USED_BASE/CHANGED INDEX=i EXTRUDER=Tn` (slicer-tool→physical-tool
remap), `SDCARD_SET_NEED_CHECK_EX`, `SDCARD_NO_FILAMENT_CHECK_EX`,
`SDCARD_SET_PAUSE_STATE`, `SDCARD_CLEAR_REFUELLING`.

Fans/PA: `SET_FAN_M106[P2] ADJUSTED=.. FACTOR=..` (UI fan override scaling),
multi-fan `M106 P../T..`; `SET_PA_ADVANCE T0=.. T1=.. .. ENABLE=..` (per-tool PA
table), `PA_ACTION`/`PA_GET` (automatic PA measurement),
`STEPPER_RESONANCE_FACTORY_CALIBRATE`.

Filament: `RESET_FILAMENT_SENSOR SENSOR=fm_exN` (motion-sensor reset).

Probe: eddy bed mesh with profiles `MESH_DATA` (factory) and `default` (per-print);
custom webhooks endpoint `bed_mesh/abort_probe_mesh`.

## API usage by the UI

Socket `/tmp/uds`, stock Klipper webhooks protocol; subscribes to `print_stats`,
`virtual_sdcard`, `pause_resume`, `gcode_move`, `toolhead`, heaters, buttons, fans.
On a modded printer the app is gone entirely — `firmwareExe` is replaced — so the only
clients on that socket are Moonraker and HelixScreen.
