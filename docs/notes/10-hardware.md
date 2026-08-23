# Hardware & MCU topology

## MCUs (Klipper multi-MCU)

| Klipper MCU | Serial | Role |
|---|---|---|
| `mcu` | (main board, see printer.base.cfg on device) | X/Y/Z steppers, bed heater `PD2`, bed thermistor `PC3` |
| `eboard` | `/dev/ttyS5` | Carriage extruder board — ONE stepper driver shared by whichever head is mounted (`PB14/PB15/PB12`) |
| `eheaterboard` | `/dev/ttyS4` | 4 hotend heaters `PC6..PC9`, 4 thermistors `PC0/PA4/PA5/PA7`, 24V rail `PA3` |
| `levelboard` | `/dev/ttyS7` | Eddy-current probe (bed leveling + nozzle offset sensing) |

The app pokes ttyS4/S5/S7 (sends a char, waits for "Ready") before starting Klipper.
Other serial: `/dev/ttyS3` = drying box (own protocol, not a Klipper MCU).

## Extruder config (embedded default printer.cfg)

All four `[extruderN]` sections share the same step/dir/enable pins — only the mounted
head is electrically active; the fork tolerates the duplicate pin claims (vanilla
Klipper would refuse). Gear ratio 6.5:1, rotation_distance 19.15, Generic 3950
sensors, max_temp 350.

## Klipper objects the UI expects (all present in the stock config)

- Heaters/sensors: `extruder..extruder3`, `heater_bed`, `heater_generic
  chamber_heater`, `temperature_sensor motor_value` (grab-motor current),
  `temperature_sensor ptcTemp`.
- Fans: `fan_generic fanM106` (part fan, via custom `SET_FAN_M106`), `chamber_fan`,
  `chamber_cool_fan`, `chamber_heat_fan`, `chamber_loop_fan`.
- Buttons (`gcode_button`): `extruder_pos1..4` (head present in dock N),
  `extruder_grab`, `extruder_grab1..4` (head on carriage), `extruder_check_pos`,
  `servo_min`/`servo_max` (lock end positions), `frontDoor`, `topDoor`, `motor_pin`.
- Filament: `filament_switch_sensor fd_ex0..3` (presence), custom motion sensors
  `fm_ex0..3`.
- Steppers: `manual_stepper gear_stepper` (feed hub; its endstop doubles as the lock
  status signal — see `30-toolchange.md`).
- Fork's `virtual_sdcard` extra status fields: `channel`, `refuelling`,
  `after_channel_g1`, `doingChangeEx`.
