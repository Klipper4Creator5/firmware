# Error code table (English strings, complete)

Useful as a behavioral spec — every hardware fault the stock system distinguishes.

## Toolchanger
- E0127–E0130: T1–T4 not in dock. Cannot pick up extruder.
- E0051–E0054: T1–T4 pickup failed.
- E0131–E0134: T1–T4 already in dock. Cannot release extruder.
- E0135–E0138: T1–T4 release failed.
- E0139: Extruder mount sensor not triggered
- E0140: Extruder dock sensor not triggered
- E0141: Extruder mount sensor still triggered
- E0142: Extruder dock sensor still triggered
- E0143: State error after extruder pickup
- E0144: State error after extruder release
- E0145: Lock motor current abnormal
- E0146: Unlock sensor not triggered.
- E0160: Cannot release extruder. Homing failed.
- E0165: extruder not installed, can not print.

## Leveling / probe (eddy)
- E0041: Leveling sensor cannot reset.
- E0147: Build plate not removed. Please check.
- E0148: The leveling extreme values are out of range. Please clean the platform or adjust its flatness, then try again.
- E0149: Sensor not triggered at max travel.
- E0150: Homing timeout.
- E0151: Eddy current probe triggered before move.
- E0152: During leveling, the values measured multiple times are out of range. Please clean the platform and nozzle, then try again.
- E0153: During nozzle offset calibration, the values measured multiple times are out of range. Please clean the eddy-current sensor and nozzle, then try again.
- E0161: Bed eddy current position abnormal. Please check.
- E0167/E0168: The platform is not installed. Please install it and try again.

## Heating
- E0063–E0066: Extruder 1–4 heating error.
- E0123: Bed heating error.
- E0077: Chamber heating error.
- E0154: Drive motor temp abnormal. Please check if PCB fan is on.

## Axes / homing
- E0012/E0013/E0014: X/Y/Z-axis signal not triggered.
- E0155/E0156/E0157: X/Y/Z-axis limit still triggered after retract.
- E0158: Sensor error.  E0159: Homing error.

## Communication
- E0002: MCU communication lost.
- E0124: Extruder mount MCU communication lost.  (eboard)
- E0125: Heater board MCU communication lost.    (eheaterboard)
- E0126: Leveling board MCU communication lost.  (levelboard)
- E0170–E0173: Lost communication with main/extruder/heater/level mcu
- E0005: Printer is not ready. Please check if the wiring is correct.

## Print-time
- E0162: Paused. Filament runout.
- E0163: Paused. Clog detected.
- E0164: Paused. Spaghetti detected. (camera AI)
- E0166: Print file error.  E0169: Printer model mismatch. Please re-slice.
- E0175: Internal error on command.  E0176: The gcode move out of range.
- E0021: Cannot open camera. / Camera not recognized.
- E0174: Copy log error.  E0999: Unknown error.
