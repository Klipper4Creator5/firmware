# XYZ tool calibration

How to calibrate nozzle offsets on a Creator 5 / 5 Pro running Reforge, what
each command prints, and what every refusal means.

The command names are klipper-toolchanger's. What they do underneath is this
machine's, because the sensor is not upstream's.

---

## What is being measured

The calibration station is a fixed bore **under the bed plane**, near the back
left. Two different things can reach into it:

| Reaching body | When | Trigger height |
|---|---|---|
| the **bare carriage** | nothing mounted | `station_z` |
| a tool's **nozzle** | that tool mounted | `nozzle_z` for that tool |

The carriage's own probe element sits *above* where a tool mounts, so it can
only reach the station when the carriage is empty. That is the whole reason
the order below is what it is: **the reference is measured first, with no
tool**, and every tool is then measured against it.

This is why upstream's "run `TOOL_LOCATE_SENSOR` with tool 0" becomes "run it
with *no* tool" here — and why our baseline cannot be spoiled by a badly
seated T0. Each tool's numbers are absolute and independent: recalibrating T2
leaves T0, T1 and T3 valid.

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
G28                      ; all three axes
CALIBRATE_TOOL_OFFSETS   ; the whole thing
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
G28
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

## What each command does

### `TOOL_LOCATE_SENSOR` — the reference

`[PARK=1] [SAVE=1] [PLATE_CHECK=1]` plus the sampling parameters below.

1. Parks the mounted tool (`PARK=0` if you docked it by hand) and verifies
   the carriage really is empty, from the dock and grab sensors.
2. Plate check: probes station Z with the bare carriage, then sideways for
   the bore edge.
3. Moves to the station start point (`cylinder_x`, `cylinder_y`, 28.5 /
   214.5 stock) and probes Z.
4. **Pass 1** — four sideways probes outward at Z + 0.6 (+X, +Y, −X, −Y,
   14 mm each), least-squares circle fit.
5. **Pass 2** — the same four probes re-centred on that fit, with Z
   re-probed there.
6. Stages `station_x`, `station_y`, `station_z` into `[ff_tool_offset]`.

### `TOOL_CALIBRATE_TOOL_OFFSET` — one tool

No arguments, exactly as upstream. It measures **whatever is on the
carriage** — select the tool first.

`[SAVE=1] [PLATE_CHECK=1]` plus the sampling parameters below.

1. Plate check. It needs an empty carriage, so it parks your tool and picks
   it straight back up — that is expected, not a fault.
2. Zeroes the G-code offset and works in raw machine coordinates.
3. Same two passes as above, from `cylinder_x − 12.5` (16.0 stock), with the
   nozzle doing the touching.
4. Checks `nozzle_z − station_z` lands in `gap_min`…`gap_max` (1.5–5.0 mm;
   ~3.2 mm is right on a healthy machine).
5. Stages `nozzle_x`, `nozzle_y`, `nozzle_z` into `[ff_tool <n>]`.
6. Heater off for that tool, lifts to Z15, restores the offset frame.

### `SAVE_CONFIG`

Writes the staged values into `printer.cfg`'s `#*#` block and restarts
Klipper. **Nothing persists until you run it.** `SAVE=0` on either command
measures and reports without staging anything.

---

## Expected output

`TOOL_LOCATE_SENSOR`:

```
  plate check: station Z -1.679
  plate check: circle edge at X 34.210 (+5.71 from the start point) -- plate is off
station calibration, start 28.500, 214.500
  Z probe to -3.000
  Z probe pos: -1.6788
 pass 1 around 28.500, 214.500 at Z -1.079
  Point1: 33.7936, 214.5000
  Point2: 28.5000, 217.6421
  Point3: 23.7900, 214.5000
  Point4: 28.5000, 207.6365
  centre 28.7918, 212.6393  radius 5.0021  max residual 0.0032
  double Z probe pos: -1.6788
 pass 2 around 28.792, 212.639 at Z -1.079
  ...
station = (28.7918, 212.6393, -1.6788)
The SAVE_CONFIG command will update the printer config file with the new
station position and restart the printer.
```

`TOOL_CALIBRATE_TOOL_OFFSET` after `SELECT_TOOL T=0`:

```
T0: offset calibration, start 16.000, 214.500
  Z probe to -3.000
  Z probe pos: 1.5160
 pass 1 around 16.000, 214.500 at Z 2.116
  ...
  centre 16.5051, 212.7750  radius 4.9987  max residual 0.0041
  double Z probe pos: 1.4726
 pass 2 around 16.505, 212.775 at Z 2.073
  ...
T0: offset = (16.5051, 212.7750, 1.4726)
The SAVE_CONFIG command will update the printer config file with the new
nozzle position and restart the printer.
T0 measured: nozzle centre 16.5051, 212.7750  Z trigger 1.4726
offsets a toolchange applies (X/Y vs T0; Z absolute: nozzle_z - station_z + z_adjust):
  T0: dX +0.0000  dY +0.0000  Z +3.1514
```

The last block is the useful one. `dX`/`dY` are differences against the base
tool (T0 by default), so T0's own are zero by definition. `Z` is absolute —
`nozzle_z − station_z + z_adjust`, the nozzle-to-station-trigger gap — and is
**not** zero for the base tool.

**Sanity check the numbers as they come out.** `max residual` should be a few
hundredths; `radius` should be the same to within a few hundredths on every
pass and every tool. The `dX`/`dY` spread across four tools is a real
mechanical property of your machine, usually well under a millimetre. A `Z`
far from ~3.2 mm means something is wrong even if no guard fired.

---

## Verifying

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

`TOOLCHANGE_STATUS` covers the same ground from the toolchanger's side. Then
put the plate back and print a first layer; tune per tool with:

```gcode
TOOL_Z_ADJUST TOOL=2 ADJUST=-0.02          ; live, nothing saved
TOOL_Z_ADJUST TOOL=2 ADJUST=-0.02 SAVE=1   ; and stage it for SAVE_CONFIG
```

Klipper's own babystep is one global number and moves every tool together.
`TOOL_Z_ADJUST` edits `[ff_tool 2] z_adjust`, which only that tool's frame
carries.

**It takes effect immediately and saves nothing.** That is what lets you
dial a first layer in *during* a print — `SAVE_CONFIG` is a restart, so a
change that needed one could never be made while printing. Add `SAVE=1`
when you are happy with the number and want it to survive a reboot, then
`SAVE_CONFIG` at a convenient moment.

Nothing moves when you run it: the frame shifts and the next move lands in
it, the same as `SET_GCODE_OFFSET Z_ADJUST` without `MOVE=1`.

---

## Errors

Every refusal below happens **before** anything is saved, and most before any
nozzle descends. A failed run leaves the previous calibration intact.

### You are holding it wrong

| Message | What happened |
|---|---|
| `home all axes first (homed: '')` | Run `G28`. |
| `no tool is mounted. SELECT_TOOL T=<0..3> first` | You ran the tool pass with an empty carriage. It would have measured the bare carriage and saved it as a nozzle — ~3.2 mm out, in the direction that crashes. `TOOL_LOCATE_SENSOR` is the one that wants an empty carriage. |
| `carriage is not verifiably empty (<reason>) -- the station pass must run with no tool mounted` | `TOOL_LOCATE_SENSOR` with a tool still on, or the dock and grab sensors disagree. `<reason>` names which. |
| `[ff_toolchange] not loaded` | Config problem, not an operator one: `ff-toolchange.cfg` is not included. |

### The build plate is still on

| Message | What happened |
|---|---|
| `plate check: station Z probe failed (...) -- is the build plate still on?` | The Z probe never triggered. Nothing has moved with a nozzle. |
| `plate check: station Z <z> is <d> mm above the calibrated <z0>` | The probe stopped high — on the sheet. The check is one-sided on purpose: a plate can only hold the probe high, so a *low* reading is never a plate. |
| `plate check: no circle edge within 14 mm of the start point` | The sideways probe found no bore. Either the plate is on, or the start point is far enough off that the bore is out of reach. |

All three end in the same hint. `PLATE_CHECK=0` skips the check for one
command, `plate_check: False` disables it permanently — do that only if you
have some other reason to be certain.

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
| `fit residual <r> exceeds max_residual 0.05 -- a probe mis-triggered` | One of the four points is off the fitted circle. With four symmetric points, one bad point of error *e* shows up as a residual of only ~*e*/4 while moving the centre by *e*/2 — so this threshold catches centre errors of about 0.1 mm. |
| `circle fit failed: circle fit is singular (points collinear?)` | The four points do not describe a circle at all. Usually two probes returned the same value. |
| `fitted radius <r> below min_radius` / `above max_radius` | Off by default; set them if you want a hard window on the bore size. |
| `T<n> nozzle_z <z> is <g> above station_z <s>, outside gap_min/gap_max [1.50, 5.00] -- probe mis-trigger suspected` | The last guard before a bad `nozzle_z` becomes a first layer driven into the plate. Checked only once `station_z` exists — another reason to run `TOOL_LOCATE_SENSOR` first. |

### Later, at print start

```
Not calibrated: station_z=None, calibrated tools [0, 1], needed [0, 1, 2].
Run TOOL_LOCATE_SENSOR / TOOL_CALIBRATE_TOOL_OFFSET (or
FF_IMPORT_FIRMWARE_CONFIG) and SAVE_CONFIG.
```

`START_PRINT` refuses before heating, homing or grabbing anything when a tool
the file uses has no `nozzle_z`, or `station_z` is missing. Without those the
print Z offset cannot be computed and the nozzle would go ~3 mm into the
plate. For bench tests only:
`SET_GCODE_VARIABLE MACRO=_FF_JOB VARIABLE=allow_uncalibrated VALUE=1`.

---

## Probe sampling

Both commands accept klipper-toolchanger's sampling parameters, applied to
every probe of the run:

```gcode
TOOL_CALIBRATE_TOOL_OFFSET SAMPLES=5 SAMPLES_RESULT=median
```

`SAMPLES`, `SAMPLES_TOLERANCE`, `SAMPLES_TOLERANCE_RETRIES`, `SAMPLES_RESULT`
(`average` or `median`), `SAMPLE_RETRACT_DIST`, `PROBE_SPEED`. Set them once
in `[ff_tool_offset]` instead if you want them every time.

Left alone, each follows the fork's own `[e_stop <axis>]`: three touches,
spread rejected above `error_v` (0.02 mm), retried up to `main_cycle_cnt`
(10) times, `back_v` (3 mm) retract between them, averaged. **The defaults
probe exactly as this extra always has** — the parameters only widen or
narrow that, and add the median the fork does not offer.

Upstream's `LIFT_SPEED` has no counterpart: the retract between touches runs
along the probe axis, at `PROBE_SPEED`.

---

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

---

## Where the numbers live

Autosaved into `printer.cfg`'s `SAVE_CONFIG` block. Never write these in an
included file — `SAVE_CONFIG` refuses to autosave an option an include
already sets.

```
#*# [ff_tool_offset]
#*# station_x = 28.791826
#*# station_y = 212.639328
#*# station_z = -1.678819
#*#
#*# [ff_tool 0]
#*# nozzle_x = 16.505066
#*# nozzle_y = 212.775040
#*# nozzle_z = 1.472569
#*# z_adjust = -0.020
```

On every grab of a tool, the toolchanger applies:

```
X = nozzle_x[tool] - nozzle_x[base]              difference vs the base tool
Y = nozzle_y[tool] - nozzle_y[base]
Z = nozzle_z[tool] - station_z + z_adjust[tool]  absolute
```

X and Y are differences, so the base tool's are zero. Z is absolute, which is
what makes Z0 the bed plane whenever a tool is mounted — not only after
`TOOLCHANGE_SET_PRINT_OFFSET` at print start.

Those go into a move transform **below** Klipper's own G-code offset, so
three things stack without ever sharing a number:

| Layer | Set by | Scope |
|---|---|---|
| `SET_GCODE_OFFSET` / `homing_origin` | you, and `TOOLCHANGE_SET_PRINT_OFFSET`'s thermal/bed/layer terms | every tool |
| transform, XYZ | `TOOL_CALIBRATE_TOOL_OFFSET` | the mounted tool |
| transform, Z | `TOOL_Z_ADJUST` | the mounted tool |

Selecting a tool swaps the lower two and moves nothing. `SET_GCODE_OFFSET
Z=0` clears the job terms and leaves the calibration alone — so the number a
UI shows as "Z offset" or "baby stepping" really is just yours.

See [`toolchange.md`](toolchange.md) for the toolchanger as a whole, and
[`notes/45-tool-offset-calibration.md`](notes/45-tool-offset-calibration.md)
for how the sequence was recovered from the stock firmware.
