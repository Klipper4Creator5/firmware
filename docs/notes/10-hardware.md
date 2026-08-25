# Hardware & MCU topology

## MCUs (Klipper multi-MCU)

| Klipper MCU | Serial | Role |
|---|---|---|
| `mcu` | (main board, see printer.base.cfg on device) | X/Y/Z steppers, bed heater `PD2`, bed thermistor `PC3` |
| `eboard` | `/dev/ttyS5` | Carriage extruder board — ONE stepper driver shared by whichever head is mounted (`PB14/PB15/PB12`) |
| `eheaterboard` | `/dev/ttyS4` | 4 hotend heaters `PC6..PC9`, 4 thermistors `PC0/PA4/PA5/PA7`, 24V rail `PA3` |
| `levelboard` | `/dev/ttyS7` | The fixed inductive "cylinder" under the bed — all three `[e_stop X/Y/Z]` sit on `levelboard:PD0` and drive the nozzle-offset calibration. The *carriage* eddy used for G28 Z and bed mesh is `[probe]` on `eboard:PG0` — see `25-app-vs-klipper-ownership.md` |

The app pokes ttyS4/S5/S7 (sends a char, waits for "Ready") before starting Klipper.
Other serial: `/dev/ttyS3` = drying box (own protocol, not a Klipper MCU).

### The bootloader handshake, as decompiled

Not reconstructed from behaviour — this is `_Z17bootSerialHeatMcuv`,
`_Z23bootSerialMainEboardMcuv` and `_Z23bootSerialLevelBoardMcuv` disassembled out
of `usr/prog/PROGRAM/software/firmwareExe` (1.9.7). The three are the same function
with a different device path and different printf strings; `usr/prog/klipper/checkEboard`
is a separate, older `-O2` build of the eboard one.

```
open(dev, O_RDWR)                  # no O_NOCTTY, no O_NONBLOCK
fcntl(fd, F_SETFL, 0)
tcgetattr; cfmakeraw
c_cc[VMIN]=0; c_cc[VTIME]=1        # MIPS: VMIN=4, VTIME=5
cfsetispeed/cfsetospeed(B115200)   # 0x1002 on MIPS
c_iflag &= ~(IGNBRK|ICRNL|IXON)    # &= ~0x501
c_oflag &= ~OPOST
c_cflag  = (c_cflag & ~(CRTSCTS|PARODD|CSTOPB|CSIZE)) | CLOCAL|CREAD|CS8
c_lflag &= ~(ISIG|ICANON|ECHO|ECHOE)
tcsetattr(fd, 0x540E, &tio)        # see below

isReady = 0; isAck = 1
for (i = 0; i < 50; i++) {         # ~5s ceiling at VTIME=1
    n = read(fd, buf, 50)
    if (n == 0) continue
    if (find(buf, "Ready") != npos) { isReady = 1; break }
    else                           { isReady = 1 }      # ttyS5/ttyS7 only
}
send = 'A'
if (isReady)
    for (j = 0; j < 50; j++) {
        write(fd, &send, 1)
        read(fd, &recv, 1)
        if (recv == 6) { isAck = 1; break }
    }
close(fd)
return (isReady == 1 && isAck == 1) ? 0 : -1
```

Four things worth keeping in mind, all of which bit us:

- **`'A'` goes out fifty times, not once.** The board gets fifty chances.
- **A non-0x06 reply is ignored.** `isAck` is initialised to 1 and is never assigned
  0 anywhere in the function, so the ack byte cannot fail the handshake — it only
  decides whether the loop stops early. The level board answers `0x01` every time.
  Refusing the handshake over that byte is what stranded ttyS7.
- **The ready phase differs by board.** On `ttyS4` only a literal `"Ready"` sets
  `isReady`. On `ttyS5` and `ttyS7` *any* byte does, banner or not — which is why
  `checkEboard` happily sends 'A' at an eboard that is already running Klipper and
  is just returning garbage at the wrong baud. `ff-mcu-bringup.py` deliberately does
  not copy that: only a banner earns a write. **Since 2026-08-25 `checkEboard` is no
  longer called at all** — `ff-mcu-bringup.py` covers `ttyS5` too. Dropping it loses
  nothing: the binary is 9KB holding one function (`_Z23bootSerialMainEboardMcuv`),
  hard-wired to `/dev/ttyS5`, importing only the tty calls and `printf`. It flashes
  no firmware and opens no other device. It is still on the firmware partition;
  nothing runs it.
- **`tcsetattr(fd, 0x540E, ...)`** — that is `TCSETS`, where POSIX wants
  `TCSANOW`/`TCSADRAIN`/`TCSAFLUSH`. Both binaries do it, so it is in FlashForge's
  source, not a build artefact. It evidently does not fail on the printer (the
  routines go on to print their read loop), but `ff-mcu-bringup.py` passes
  `TCSANOW`, which is correct either way.

The ready phase is only ~5s and it does **not** wait for a second banner, so stock
only ever worked when it ran immediately after the board powered up. The bootloader
re-sends its banner on a period longer than that, which is why a bring-up run later
in the boot can see nothing at all and still be looking at a board in its bootloader.

## Extruder config (embedded default printer.cfg)

All four `[extruderN]` sections share the same step/dir/enable pins — only the mounted
head is electrically active; the fork tolerates the duplicate pin claims (vanilla
Klipper would refuse). Gear ratio 6.5:1, rotation_distance 19.15, Generic 3950
sensors, max_temp 350.

## Klipper objects the UI expects (all present in the stock config)

- Heaters/sensors: `extruder..extruder3`, `heater_bed`, `heater_generic
  chamber_heater` (Pro only — it lives in `printer.chamber.cfg`, and the plain
  Creator 5 gets `[temperature_sensor chamber]` instead),
  `temperature_sensor ptcTemp`, `temperature_sensor extruder_servo_value`
  (`eboard:PA0`), `temperature_sensor adc_current_value` (`eheaterboard:PC1`).
  `temperature_sensor motor_value` (`sensor_type: motor_current_sensor`,
  `eboard:PA1`) is real and ships, but in `printer.motor.cfg`, not
  `printer.base.cfg` — so `printer.base.cfg` does not include it and the
  machine's own `printer.cfg` must. `MOTOR_STOP`, `MOTOR_GRAB` and the rest of
  the lock macros live in that same file, which is why `ff-toolchange.cfg` can
  name them.
- Fans: `fan_generic fanM106` (part fan, via custom `SET_FAN_M106`), `chamber_fan`,
  `chamber_cool_fan`, `chamber_heat_fan`, `chamber_loop_fan`.
- Buttons (`gcode_button`): `extruder_pos1..4` (head present in dock N),
  `extruder_grab1..4` (head on carriage), `frontDoor`, `topDoor`. That is the
  whole family — confirmed against this printer's `printer.base.cfg` (see
  `ff-toolchange.cfg`'s sensor note): there is no bare `extruder_grab`, no
  `extruder_check_pos`, no `servo_min`/`servo_max`, and `motor_pin` is
  commented out in `printer.motor.cfg`.
- Filament: `filament_switch_sensor fd_ex0..3` (presence), custom motion sensors
  `fm_ex0..3`.
- Steppers: `manual_stepper gear_stepper` (the tool LOCK motor, not a feeder; its
  endstop doubles as the lock status signal — see `30-toolchange.md`).
- Fork's `virtual_sdcard` extra status fields: `channel`, `refuelling`,
  `after_channel_g1`, `doingChangeEx`.
