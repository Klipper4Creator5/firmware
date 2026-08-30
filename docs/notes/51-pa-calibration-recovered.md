# Automatic pressure advance -- recovered from firmwareExe (MIPS32 LE)

Source: `work/stock/firmwareExe` (`f666ff60`, Creator 5 Pro, not stripped, no DWARF for the app
itself), disassembled with capstone; addresses below are verified against machine code, not
Ghidra. The host side is fully recovered. The *scoring* is not host code at all -- it lives in
the closed eBoard MCU image -- see [section 5](#5-what-the-eboard-actually-does).

This supersedes two earlier claims: "sensor unknown" in
[`60-background.md`](60-background.md) and "callable, not reproducible" in
[`25-app-vs-klipper-ownership.md`](25-app-vs-klipper-ownership.md). The *host* procedure is
reproducible in full; only the pass/fail verdict stays behind the MCU boundary, and that
boundary is one we keep -- we ship FlashForge's eBoard firmware unchanged.

## 1. Entry points

`CommMgr::paTestMgr(float &pa_out, bool &ok_out, std::string restore_gcode)` @0x791640 is the
whole procedure. Two callers, both inside the pre-print nozzle clean
([`50a-nozzle-clean-recovered.md`](50a-nozzle-clean-recovered.md)):

| caller | when | what it does with the result |
|---|---|---|
| `BuildPage::clearNozzlePrint(bool, float)` +2492 @0x9f50b0 | per tool, during the print-start clean, when the paTest flag is set | `PA_Vector` push per tool; after the loop `SET_PA_ADVANCE T0=.. T1=.. T2=.. T3=.. ENABLE=1` @0x9f60fc |
| `CommMgr::clearNozzleEddy(TypeManager, int, bool, bool)` +4264 @0x78f244 | single tool, from the UI clean | `SET_PA_ADVANCE PA=<%.4f> ENABLE=1` @0x78f318 |

`CalibrationDialog::doPaTest` / `testPaTest` @0x82ce40/@0x82d054 is the factory dialog. It does
**not** call `paTestMgr` -- it is a second, inlined copy of the same procedure, with the same
prologue and the same seven candidates in the same scrambled order (@0x82d5b8..0x82dc04). Two
independent copies agreeing is good evidence the constants below are the real ones.

`testPaTest` is also the only place the *preconditions* are visible, because the print-start
caller has already met them. In order: `homeManager`, `doGrabExtruderMgr(tool)`, wait for
`getTemperatureListMgr()` current to reach target (emitting `"temp:<c> target:<t>"` to the
dialog), `moveClearLocation(bool)`, then the sweep. A standalone `FF_PA_CALIBRATE` needs the
same four.

The user-facing path is the print-start one -- this is genuinely automatic, not a menu item. The
print log line `"function: %s , print path: %s , isPaTest: %d , timelapse: %d , ..."` carries the
flag.

`restore_gcode` is built by the caller as `SET_KINEMATIC_POSITION X=<x> Y=<y> Z=<z>` (@0x9f4f1c)
and is replayed by `resetTmcPa` at the end -- the sweep force-drives X/Y with the drivers
manually latched, so Klipper's idea of position has to be restored afterwards.

## 2. The Klipper side we already have

`klippy/extras/pa_adjust.py` (40 lines, ships in the stock image **and, byte-identical, in our
own tree**) is a pure forwarder to `mcu eboard`:

```python
self._pa_value_get_cmd = self.mcu.lookup_query_command(
    "get_emcu_pa_value", "pa_value value=%u")
self._pa_action_cmd = self.mcu.lookup_command("pa_action action=%u pc=%u")

def cmd_PA_ACTION(self, gcmd):      # 0:PA_close  1:PA_start   (comment is stale, see below)
    self._pa_action_cmd.send([gcmd.get_int('ACTION', 0), gcmd.get_int('PC', 0)])

def cmd_PA_GET(self, gcmd):
    result = self._pa_value_get_cmd.send()
    gcmd.respond_info("Result is value=%s" % (result["value"],))
```

`work/stock/mcu/eBoard.dict.json` confirms the current MCU still exposes them:

```
commands:  pa_action action=%u pc=%u
           get_emcu_pa_value
responses: pa_value value=%u
```

Note `lookup_command(...).send()` and `lookup_query_command(...).send()` are **immediate**, not
queued behind the move queue. So `PA_ACTION` does not synchronise with motion at all -- see the
timing caveat in [section 4](#4-timing-the-app-does-not-synchronise-and-neither-should-we).

## 3. The procedure, exactly

Prologue (once):

```
G92 E0
M83
SET_VELOCITY_LIMIT ACCEL=5000
SET_VELOCITY_LIMIT SQUARE_CORNER_VELOCITY=9
SET_PIN PIN=enable_pin_tmc_x VALUE=1.00
SET_PIN PIN=enable_pin_tmc_y VALUE=1.00
M400
```

Candidates, pushed in this order (@0x791ae0..0x791d70) -- deliberately **not** monotonic:

```
i:   0       1       2       3       4       5       6
pa:  0.0100  0.0200  0.0150  0.0350  0.0250  0.0300  0.0400
Y:   50.000  55.000  60.000  65.000  70.000  75.000  80.000     Y = 50 + 5*i, "%.3f"
```

They are kept as fixed-width **strings**, never as floats, so that the later `std::sort` sorts
them numerically by sorting them lexicographically. Then:

```
for attempt in 0..4:                       # 0x791de0, slti 5
    good = []
    for i in 0..len(candidates)-1:         # 0x791df4 resets i each pass
        PA_ACTION ACTION=11 PC=666
        SET_PRESSURE_ADVANCE ADVANCE=<candidates[i]>      # active extruder, no EXTRUDER=
        G1 X40 Y<50+5*i> F30000
        G1 F1080  ; G1 X60  E1.13573      # 20 mm @  18 mm/s
        G1 F10980 ; G1 X100 E2.27146      # 40 mm @ 183 mm/s
        G1 F1080  ; G1 X120 E1.13573      # 20 mm slow
        G1 F1080  ; G1 X140 E1.13573      # 20 mm slow
        G1 F10980 ; G1 X180 E2.27146      # 40 mm @ 183 mm/s
        G1 F1080  ; G1 X200 E1.13573      # 20 mm slow
        PA_ACTION ACTION=0 PC=666
        M400
        reply = PA_GET                     # captured, not just logged
        v = stoi(reply[reply.find("=")+1:])
        if v == 9: good.append(candidates[i])      # 9 is the ONLY accepted verdict
        if klipper reported an error, or the cancel flag is set: abort
    if good:
        sort(good); best.append(good[0]); good.clear()   # smallest passing PA wins the pass
    if len(best) >= 3: break
if len(best) >= 3:
    *pa_out = (stof(best[0]) + stof(best[1]) + stof(best[2])) / 3.0f   # 3.0f @0xdb6a80
    *ok_out = true
else:
    *pa_out = 0.0f ; *ok_out = false
resetTmcPa(restore_gcode)
```

`resetTmcPa` @0x79350c:

```
SET_PIN PIN=enable_pin_tmc_x VALUE=0.00
SET_PIN PIN=enable_pin_tmc_y VALUE=0.00
M400
<restore_gcode>            # SET_KINEMATIC_POSITION X= Y= Z=
M400
```

Things worth noticing:

- **E is constant per mm in every segment.** 1.13573 mm over 20 mm and 2.27146 mm over 40 mm are
  the same 0.0568 mm/mm. Only the *speed* changes, 18 mm/s vs 183 mm/s. The line is
  slow-fast-slow-slow-fast-slow across X40..X200, so each line contains two accel/decel pairs at
  a 10x flow step -- the only place pressure advance can show up.
- **The candidate order is scrambled** (0.010, 0.020, 0.015, 0.035, 0.025, 0.030, 0.040) while
  the Y positions are sequential. Adjacent lines on the bed are therefore never adjacent in PA,
  which keeps a slow drift (nozzle temperature, bed tilt) from biasing a contiguous band.
- **`good[0]`, not the median.** Within one pass, several candidates can score 9; the app takes
  the *smallest* passing value. It then repeats the whole 7-line sweep until three passes have
  produced a winner, and averages exactly those three. Worst case 5 sweeps = 35 lines; fewer
  than 3 winners after 5 sweeps is a hard failure (`pa=0, ok=false`), not a fallback.
- **Nothing restores pressure advance.** After the sweep the active extruder is still at the last
  candidate tried (0.0400). Only the caller's `SET_PA_ADVANCE` is meant to install the result --
  see the caveat in [section 6](#6-set_pa_advance-is-not-in-any-klipper-we-have).
- No heating, no homing, no Z move inside `paTestMgr`. The caller has already parked the tool at
  the wipe spot and set the temperature.

## 4. Timing: the app does not synchronise, and neither should we

`PA_ACTION` maps to an *immediate* MCU command. `ACTION=11` therefore fires as soon as the G-code
stream reaches it -- before the moves are executed -- and `ACTION=0` fires as soon as the last
`G1` has been *queued*, not finished. The only real barrier is `M400` after `ACTION=0`, and by
then the window has already been closed. The eBoard is not being handed a tight measurement
window; it is being told "a line is coming" and "that was the last one", and it finds the event
itself.

Consequence for the port: reproduce the sequence **verbatim, including the absence of `M400`
between the last `G1` and `PA_ACTION ACTION=0`**. Adding barriers to "make it more correct"
changes the timing the closed scorer was tuned against.

## 5. What the eBoard actually does

Not recovered, and not cheaply recoverable: the scoring is in `work/stock/mcu/eBoard.bin`, 43 KB
of Cortex-M3 for an `stm32f103xe` at 144 MHz.

What the data dictionary does tell us is what the board can sample: `config_adxl345`,
`config_lis2dw` (accelerometer -- this is also the input-shaper board), `config_spi_angle`,
`config_analog_in`, `config_tmcuart`, plus the eddy coil (`[ff_eddy eboard]`,
`set_trigger_threshold`). The toolhead accelerometer is the obvious candidate -- the extruder
motor sits on the same carriage, and a PA error shows up as an abrupt torque step at each of the
two flow transitions -- but that is inference, not a finding. Do not write it down as fact.

Two arguments the host passes and we do not understand:

- `ACTION=11`. `pa_adjust.py`'s comment says `0:PA_close 1:PA_start`; the app sends 11 to start
  and 0 to stop. The comment is from an older release (the older `firmwareExe` we have,
  `ca6f1bf1`, has no `paTestMgr` at all). 11 is presumably start-plus-mode.
- `PC=666`. The Chinese comment on the parameter is 材料, "material". The app hardcodes 666 in
  every call, so we can too.

The verdict is a small unsigned integer and **only 9 means pass** (`bne $v1, 9` @0x792878). What
the other values mean is unknown; the app does not distinguish them.

## 6. `SET_PA_ADVANCE` is not in any Klipper we have

`SET_PA_ADVANCE T0=.. T1=.. T2=.. T3=.. ENABLE=1` is how the app installs the per-tool result,
and `... T0=99.0 T1=99.0 T2=99.0 T3=99.0 ENABLE=0` (@0x7a30c4, `CommMgr::serialPrint`) is how it
disables the override at print end. Neither is implemented anywhere in
`work/software/klipper` -- `grep -rn PA_ADVANCE` over the whole stock tree is empty, and
`kinematics/extruder.py` registers only upstream's `SET_PRESSURE_ADVANCE`.

**But that tree is a different release from the binary above.** `work/software/firmwareExe` is
`ca6f1bf1` and contains neither `paTestMgr` nor `SET_PA_ADVANCE`; the binary this note is
recovered from is `f666ff60`. So the honest statement is: the Klipper that *ships with the
release that has auto-PA* is not in this repo, and whether it implements `SET_PA_ADVANCE` is
untested. Settle it on a machine with one line -- `SET_PA_ADVANCE T0=0.02 ENABLE=1` either
errors as unknown or does not.

It does not block the port either way: we have no per-tool-PA-aware `virtual_sdcard`, so there is
no override to install or reset, and stock `SET_PRESSURE_ADVANCE EXTRUDER=extruderN ADVANCE=x`
does the job.

## 7. Porting it to our Klipper

### What already works today

`pa_adjust.py` is in our tree byte-identical to FlashForge's, and
`pkgs/klipper-config/payload/config/printer.base.cfg:257` already has `[pa_adjust]` against
`[mcu eboard]`. **`PA_ACTION` and `PA_GET` should already be callable on a Reforge machine.**
That is the first thing to check, and it needs no code:

```
PA_ACTION ACTION=11 PC=666
G1 X40 Y50 F30000
G1 F1080  ; G1 X60 E1.13573
...
PA_ACTION ACTION=0 PC=666
M400
PA_GET                       -> expect "Result is value=<n>"
```

If that returns a value, everything below is host-side work with no unknowns left.

### This cannot be a G-code macro

`PA_GET` only calls `gcmd.respond_info(...)`. A Jinja macro cannot read another command's
response, so the sweep has to be Python. The clean shape is a new
`klippy/extras/ff_pa.py` that talks to the eBoard directly rather than through the `PA_GET`
text:

```python
pa = self.printer.lookup_object('pa_adjust')
value = pa._pa_value_get_cmd.send()["value"]      # skip the string round-trip entirely
```

That also removes the `find("=")`/`stoi` parsing the app needs and its failure modes.

### Suggested shape

`FF_PA_CALIBRATE [TOOL=n] [SAVE=1]`, in `ff_pa.py`, driving the loop from section 3 verbatim:
same seven candidates, same scrambled order, same Y ladder, same 5-pass / 3-winner / mean-of-3
selection, same "only 9 passes". Resist tuning any of it until a machine has produced numbers --
the constants are matched to a scorer we cannot read.

Store the result the way every other per-unit number is stored here: a `pressure_advance` key on
`[ff_tool N]`, autosaved into printer.cfg's `SAVE_CONFIG` block, applied by `ff_toolchange` on
grab next to the XY/Z offsets (see [`45-tool-offset-calibration.md`](45-tool-offset-calibration.md)).
That gives per-tool PA without needing `SET_PA_ADVANCE`, survives restarts, and stays visible to
the user.

Do **not** wire it into the print-start clean the way FlashForge does. Thirty-five 160 mm lines
is minutes of purge and a sheet of plastic on the bed before every print; the app gets away with
it because it only runs behind a flag. A user-invoked calibration that saves a number is the
right default, and matches how PID and shaper already work here
([`25-app-vs-klipper-ownership.md`](25-app-vs-klipper-ownership.md)).

### Order of work

1. On a machine: `PA_ACTION`/`PA_GET` round-trip returns a value. If it does not, stop -- the
   rest is dead.
2. One hand-run sweep of the seven candidates, recording every verdict. Confirm that the scores
   are not all-9 or all-not-9, i.e. that the eBoard actually discriminates.
3. `ff_pa.py` + `FF_PA_CALIBRATE`, `[ff_tool N] pressure_advance`, applied on grab.
4. Compare against a hand-tuned PA tower on the same filament before recommending it.

Until step 2 has real numbers the PA tower stays the documented method.

## Addresses

| address | symbol |
|---|---|
| 0x791640 | `CommMgr::paTestMgr(float&, bool&, std::string)` (7884 bytes) |
| 0x7914d4 | its `stof` lambda |
| 0x82d054 | `CalibrationDialog::testPaTest()` — the inlined second copy |
| 0x79350c | `CommMgr::resetTmcPa(std::string)` |
| 0x78f244 | `paTestMgr` call in `clearNozzleEddy` |
| 0x78f318 | `SET_PA_ADVANCE PA=` there |
| 0x9f50b0 | `paTestMgr` call in `BuildPage::clearNozzlePrint` |
| 0x9f60fc | `SET_PA_ADVANCE T0=..` there |
| 0x7a30c4 | `SET_PA_ADVANCE .. ENABLE=0` in `CommMgr::serialPrint` |
| 0x791de8 | outer bound, `slti 5` |
| 0x792878 | the verdict test, `bne $v1, 9` |
| 0xdb6a80 | `3.0f`, the divisor |
