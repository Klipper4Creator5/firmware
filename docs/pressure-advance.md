# Pressure advance

Pressure advance is the correction for the lag between the extruder motor
turning and plastic actually arriving at the tip. Get it wrong and every
corner shows it — a blob where pressure had built up, or a gap where it
never did. It is a property of the whole drive train from motor to nozzle,
so each of the four tools has its own value.

Unlike your nozzle offsets and bed mesh, there is no factory pressure-advance
number waiting to be imported — this command only measures and reports one,
you decide what to do with it. Run it once per tool and filament type you
care about, and again if you see the blobbing or gapping above, or after
swapping an extruder gear or motor on one tool.

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

**It only reports — it does not save or apply anything**, and printer.cfg
is the wrong place for it anyway: pressure advance is a property of the
*filament*, not the printer, so a PLA value baked into printer.cfg is wrong
the moment you load PETG. Put the number in your slicer instead, as that
filament's own **Pressure Advance** setting (OrcaSlicer, PrusaSlicer and
SuperSlicer all have one, under the filament's Advanced settings) — it
travels with the material profile and applies automatically on every print,
correct nozzle and all.

You can also try a number for one session without touching any profile:

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
