# XYZ tool calibration

How to calibrate nozzle offsets on a Creator 5 / 5 Pro running Reforge, what
each command prints, and what every refusal means.

Measuring one tool does not disturb the others: if T2 drifts, recalibrate T2
and leave the rest alone. What the machine is measuring while it does this,
and how those numbers reach a first layer, is
[How calibration works](how-calibration-works.md).

---

## Before you start

1. **Take the PEI build plate off.** The station is below the bed plane; with
   the sheet on, the Z probe stops on the sheet. You are not asked to promise
   this — the plate check measures it, and refuses.
2. **Clean every nozzle.** The calibration is exactly as good as the nozzles
   are clean. A blob of filament on a nozzle is measured as part of the
   nozzle.
3. Tools cold and docked. Nothing here heats; there is no purge.
4. Klipper up, no print running.

---

## The sequence

```gcode
CALIBRATE_TOOL_OFFSETS   ; the whole thing -- homes first if it has to
SAVE_CONFIG              ; persists it, restarts Klipper
```

`CALIBRATE_TOOL_OFFSETS` is klipper-toolchanger's documented entry point, so
it is the name HelixScreen's wizard and other UIs look for. It expands to:

```gcode
TOOL_LOCATE_SENSOR                ; the reference, empty carriage
{% for tool in printer.toolchanger.tool_numbers %}
    SELECT_TOOL T={tool}
    TOOL_CALIBRATE_TOOL_OFFSET    ; measures whatever is mounted
{% endfor %}
```

Run those by hand instead when you only want one tool:

```gcode
TOOL_LOCATE_SENSOR       ; only if the station or bed was disturbed
SELECT_TOOL T=2
TOOL_CALIBRATE_TOOL_OFFSET
SAVE_CONFIG
```

**Order is not optional.** `TOOL_LOCATE_SENSOR` must have run at least once
(now or in an earlier session) before a tool pass can be sanity-checked: the
gap guard that catches a mis-triggered Z needs `station_z` to compare
against. Without it the tool pass still runs, with one fewer guard.

The last tool stays mounted when `CALIBRATE_TOOL_OFFSETS` finishes, so a
`SHAPER_CALIBRATE` afterwards has mass on the carriage.

---

## Verifying

Calibration writes numbers; this is how you check they are the numbers you
meant. Run it straight after `SAVE_CONFIG`, and again any time a tool starts
printing at a different height from the others.

`TOOL_OFFSET_STATUS` lists what is saved for each tool and warns if anything
was measured but not yet saved:

```gcode
TOOL_OFFSET_STATUS
```

```
station start (cylinder_x/y): 28.500, 214.500
[ff_tool 0] nozzle 16.5051, 212.7750, 1.4726
[ff_tool 1] nozzle 16.2104, 212.8399, 1.5013
[ff_tool 2] nozzle NOT CALIBRATED
[ff_tool 3] nozzle 16.4415, 212.6902, 1.4488
[ff_tool_offset] station 28.7918, 212.6393, -1.6788
! unsaved calibration pending -- run SAVE_CONFIG
```

Every tool should show a nozzle triple, and nothing should say
`NOT CALIBRATED`. `TOOLCHANGE_STATUS` covers the same ground from the
toolchanger's side.

Then put the plate back and print a first layer.

---

## Errors

Every refusal below happens **before** anything is saved, and most before any
nozzle descends. A failed run leaves the previous calibration intact.

### You are holding it wrong

| Message | What happened |
|---|---|
| `G28 left the axes unhomed (homed: '<axes>')` | Homing was auto-started and did not finish — an endstop or the toolchanger refused. Fix that first; nothing was measured. |
| `no tool is mounted. SELECT_TOOL T=<0..3> first` | You ran the tool pass with an empty carriage. It would have measured the bare carriage and saved it as a nozzle — ~3.2 mm out, in the direction that crashes. `TOOL_LOCATE_SENSOR` is the one that wants an empty carriage. |
| `carriage is not verifiably empty (<reason>) -- the station pass must run with no tool mounted` | `TOOL_LOCATE_SENSOR` with a tool still on, or the dock and grab sensors disagree. `<reason>` names which. |
| `[ff_toolchange] not loaded` | Config problem, not an operator one: `ff-toolchange.cfg` is not included. |

### The build plate is still on

| Message | What happened |
|---|---|
| `plate check: station Z probe failed (...) -- is the build plate still on?` | The Z probe never triggered. Nothing has moved with a nozzle. |
| `plate check: station Z <z> is <d> mm above the calibrated <z0>` | The probe stopped high — on the sheet. The check is one-sided on purpose: a plate can only hold the probe high, so a *low* reading is never a plate. |
| `plate check: no circle edge within 14 mm of the start point` | The sideways probe found no bore. Either the plate is on, or the start point is far enough off that the bore is out of reach. |

All three mean the same thing in practice: take the plate off and run it
again.

### The probe misbehaved

| Message | What happened |
|---|---|
| `ESTOP <axis> ... : Probe triggered prior to movement` | The station read as triggered before the move started. Usually a dirty or shorted sensor; `QUERY_ESTOP <axis>` shows the pin state. |
| `ESTOP <axis> ... : No trigger on probe after full movement` | Travelled the full distance without touching. The start point is off, or the tool is not where the toolchanger thinks. |
| `ESTOP <axis> ...: sample spread <s> over samples_tolerance <t> after <n> retries (...)` | Repeated touches at one point disagreed. The individual samples are printed — read them: a slow drift is a loose tool, alternating values are backlash. |
| `ESTOP <axis> ...: probe move failed` | The move itself was rejected. Check `printer.log`. |

### The result was implausible

Nothing is saved in any of these.

| Message | What happened |
|---|---|
| `fit residual <r> exceeds max_residual 0.5 -- a probe mis-triggered` | One of the four points is off the fitted circle. With four symmetric points, one bad point of error *e* shows up as a residual of only ~*e*/4 while moving the centre by *e*/2 — so this threshold catches centre errors of about 1 mm. It is there to catch a mis-trigger, not to grade precision: a residual of a couple of tenths is ordinary probe scatter and passes. |
| `circle fit failed: circle fit is singular (points collinear?)` | The four points do not describe a circle at all. Usually two probes returned the same value. |
| `fitted radius <r> below min_radius` / `above max_radius` | Off by default; set them if you want a hard window on the bore size. |
| `T<n> nozzle_z <z> is <g> above station_z <s>, outside gap_min/gap_max [1.50, 5.00] -- probe mis-trigger suspected` | The last guard before a bad `nozzle_z` becomes a first layer driven into the plate. Checked only once `station_z` exists — another reason to run `TOOL_LOCATE_SENSOR` first. |

## When to re-run

| Event | Re-run |
|---|---|
| Nozzle changed or removed on one tool | that tool only |
| Tool disassembled or re-seated | that tool only |
| Station, bed or bed mounts disturbed | `TOOL_LOCATE_SENSOR`, then every tool |
| Firmware reinstall | nothing — the values live in `printer.cfg` |
| First install from stock | `FF_IMPORT_FIRMWARE_CONFIG` copies the factory numbers; calibrate when you want better ones |

Because every value is absolute, a single tool can be recalibrated on its own
at any time without touching the others.
