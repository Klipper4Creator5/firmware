# Pressure advance

Pressure advance is the correction for the lag between the extruder motor
turning and plastic actually arriving at the tip. Get it wrong and every
corner shows it — a blob where pressure had built up, or a gap where it
never did. It is a property of the whole drive train from motor to nozzle,
so each of the four tools has its own value.

**Your printer already has one per tool**, imported with the rest of your
machine's numbers on first boot. Re-run this only if you see the blobbing or
gapping above, or after swapping an extruder gear or motor on one tool.

---

## Before you start

* The tool you're calibrating is **mounted**, homed, and has filament
  **loaded**.
* Nothing else is printing.

---

## Running it

Pick the tool (`0`–`3`) and a temperature for the filament you're testing:

```gcode
FF_PA_CALIBRATE TOOL=0 TEMP=230
```

It heats, parks over the purge chute, extrudes about a gram sweeping through
candidate values, and reports a number:

```
ff_pa: T0 pressure_advance = 0.023300   (mean of 3 sweep winners: 0.0200, 0.0250, 0.0250)
  ...
  NOT saved and NOT applied. To keep it, put it in printer.cfg yourself:
      [extruder]
      pressure_advance: 0.023300
```

**It only reports — it does not save or apply anything.** To keep the
result, add it to that tool's extruder section (`[extruder]` for T0,
`[extruder1]` for T1, and so on) and run `SAVE_CONFIG`:

```gcode
SAVE_CONFIG
```

Or try it just for the current session, without saving:

```gcode
SET_PRESSURE_ADVANCE EXTRUDER=extruder ADVANCE=0.0233
```

HelixScreen's calibration screen can start the same run from the
touchscreen instead of the console.

---

## If the run refuses a number

`FF_PA_CALIBRATE` will tell you rather than guess:

* **"not discriminating between candidates"** — every line came back the
  same verdict. Check filament is actually extruding and try again; if it
  keeps happening, run `FF_PA_PROBE PA=0.02 TOOL=0` to draw one line and see
  its raw verdict before trusting a full sweep.
* **"only N of M sweeps produced a passing candidate"** — not enough clean
  results to average. Re-run it; a nozzle that's partially clogged or a
  loose extruder gear are the usual causes.

What's actually going on behind these — the eBoard verdict, why it's not
saved automatically — is in
[How calibration works](how-calibration-works.md#pressure-advance).
