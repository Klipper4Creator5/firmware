# Automatic pressure advance -- recovered from firmwareExe (MIPS32 LE)

Source: `work/stock/firmwareExe` (`f666ff60`, Creator 5 Pro, not stripped, no DWARF for the app
itself), disassembled with capstone; addresses below are verified against machine code, not
Ghidra. The host side is fully recovered. The *scoring* is not host code at all -- it lives in
the closed eBoard MCU image -- see [section 5](#5-what-the-eboard-actually-does).

The port is built -- see [section 7](#7-the-port). This supersedes two earlier claims: "sensor unknown" in
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
  the Y positions are sequential. This *looks* like a guard against a slow drift biasing a
  contiguous band of the bed, and an earlier revision of this note said so. It cannot be: as
  [section 3a](#3a-the-carriage-does-not-move) shows, the carriage never moves and there is no
  band. The scramble is kept because it is the app's, not because it buys anything here.
- **`good[0]`, not the median.** Within one pass, several candidates can score 9; the app takes
  the *smallest* passing value. It then repeats the whole 7-line sweep until three passes have
  produced a winner, and averages exactly those three. Worst case 5 sweeps = 35 lines; fewer
  than 3 winners after 5 sweeps is a hard failure (`pa=0, ok=false`), not a fallback.
- **Nothing restores pressure advance.** After the sweep the active extruder is still at the last
  candidate tried (0.0400). Only the caller's `SET_PA_ADVANCE` is meant to install the result --
  see the caveat in [section 6](#6-set_pa_advance-is-not-in-any-klipper-we-have).
- No heating, no homing, no Z move inside `paTestMgr`. The caller has already parked the tool and
  set the temperature -- see below, because *where* it parked turns out to be the whole story.

## 3a. The carriage does not move

`SET_PIN PIN=enable_pin_tmc_x VALUE=1.00` **disables the X driver**, and `..._y` the Y driver.
They are not Klipper's stepper enables -- `[stepper_x] enable_pin: !PJ6`, `[stepper_y]
enable_pin: !PJ2` -- but a second, independent latch on `PH2`/`PH3` that Klipper knows nothing
about. So for the whole sweep every `G1 X40 ... X200` is planned, step-generated and clocked out
against dead drivers. **The toolhead does not move, no lines are drawn, and the whole ~1 g of
filament falls straight down from wherever the caller parked it.**

The proof is the argument the caller hands `resetTmcPa`. Disassembling `clearNozzleEddy` just
before its `jal 0x791640`:

```
0078f030  lui   $v0, 0xdb
0078f034  lwc1  $f0, 0x6b24($v0)        ; -8.0    <- tool_dy[3]
0078f04c  lwc1  $f1, 0x30($fp)
0078f054  lwc1  $f0, 0x6b28($v0)        ; 254.0   <- purge_y
0078f058  add.s $f0, $f1, $f0           ; Y = 254 + tool_dy
0078f068  lwc1  $f0, 0x6b2c($v0)        ; 275.0   <- purge_x
0078f06c  add.s $f0, $f1, $f0           ; X = 275 + tool_dx
0078f080  ldc1  $f0, 0x6a90($v0)        ; 2.8
0078f084  add.d $f0, $f1, $f0           ; Z = <probe Z> + 2.8
0078f0b8  addiu $a1, $v0, 0x35b0        ; "SET_KINEMATIC_POSITION X="
0078f0d4  addiu $a2, $v0, 0x3240        ; " Y="
0078f13c  addiu $a2, $v0, 0x3b28        ; " Z="
0078f244  jal   0x791640                ; paTestMgr(pa, ok, restore_gcode)
```

275.0 @0xdb6b2c and 254.0 @0xdb6b28 are the **purge chute**, the same pair
[`ff-filament.cfg`](../../pkgs/klipper-config/payload/config/ff-filament.cfg) carries as
`purge_x`/`purge_y`; the -8.0 @0xdb6b24 is literally our `tool_dy[3]`. The app parks over the
chute, kills X and Y, dumps the gram down the chute, and then tells Klipper the carriage is
**still at the chute** -- which is only a sane thing to say because it never left. Had the
ladder been real motion, forcing the position back to X275 Y246 would drive the next move into
the far right limit.

`resetTmcPa` @0x79350c, disassembled in full, is exactly:

```
SET_PIN PIN=enable_pin_tmc_x VALUE=0.00
SET_PIN PIN=enable_pin_tmc_y VALUE=0.00
M400
SET_KINEMATIC_POSITION X=<275+dx> Y=<254+dy> Z=<probeZ+2.8>
M400
```

## 4. Timing: the app does not synchronise, and neither should we

`PA_ACTION` maps to an *immediate* MCU command. `ACTION=11` therefore fires as soon as the G-code
stream reaches it -- before the moves are executed -- and `ACTION=0` fires as soon as the last
`G1` has been *queued*, not finished. The only real barrier is `M400` after `ACTION=0`, and by
then the window has already been closed. The eBoard is not being handed a tight measurement
window; it is being told "a line is coming" and "that was the last one", and it finds the event
itself.

How loose, precisely: what bounds the stream is Klipper throttling G-code *input* inside
`toolhead.move()` -> `_check_pause()` once queued motion exceeds `BUFFER_TIME_HIGH` (2.0 s,
`toolhead.py:194`). One line is about 4.94 s of motion --

| segment | mm | mm/s | s |
|---|---|---|---|
| X40->X60 | 20 | 18 | 1.11 |
| X60->X100 | 40 | 183 | 0.25 |
| X100->X120 | 20 | 18 | 1.11 |
| X120->X140 | 20 | 18 | 1.11 |
| X140->X180 | 40 | 183 | 0.25 |
| X180->X200 | 20 | 18 | 1.11 |

-- so `ACTION=0` lands with roughly 2 s still queued and the capture closes partway through the
line, losing the last flow step and possibly more. The app hits the same throttle, because it
feeds G-code through the same input path, so this is not a defect we introduce by copying it.
`FF_PA_CALIBRATE VERBOSE=1` prints the unflushed figure per line; if verdicts ever look like
mush, that number is the first thing to reach for.

Consequence for the port: reproduce the sequence **verbatim, including the absence of `M400`
between the last `G1` and `PA_ACTION ACTION=0`**. Adding barriers to "make it more correct"
changes the timing the closed scorer was tuned against.

## 5. What the eBoard actually does

Recovered, contrary to what this section used to say. `work/stock/mcu/eBoard.bin` is 43 KB of
Cortex-M3 for an `stm32f103xe` at 144 MHz, and it is a stock Klipper MCU build, so the handlers
are reachable without symbols:

- `eBoard.hex`'s only extended-linear-address record is `:020000040801F1`, so the image loads at
  **0x08010000**.
- `struct command_parser` is `{uint16 encoded_msgid; uint8 num_args, flags, num_params; const
  uint8_t *param_types; void (*func)(uint32_t*);}` -- 16 bytes, and `command_index[cmdid]` is
  indexed by the id straight out of `eBoard.dict.json`. The table is at **0x0801a288** and all 77
  ids line up. `pa_action` is id 5 -> **0x080115ec**; `get_emcu_pa_value` is id 6 ->
  **0x080115d0**.

### The measurement is a serial sample stream, not an on-board sensor

`pa_action(action, pc)` @0x080115ec stores `action` at 0x20000098 and `pc` at 0x20000094, then:

| `action` | what it does |
|---|---|
| `11` (the only start value) | capture flag 0x2000009c = 1; result 0x200000a0 = 0; write index 0x2000213c = 0; `memset(0x200001fc, 0, 8000)`; enable TIM4, TIM1, TIM8 and DMA1 channel 5 |
| anything else (the app sends 0) | disable those four, tail-call 0x08016214(2, 1) |

The buffer is filled by the **USART3** (0x40004800) idle-line handler @0x08016734, draining DMA1
channel 3. It validates a fixed 11-byte frame byte for byte -- `b[0]==5, b[2]==0x41, b[3]==0xCF,
b[4]==5, b[5]==0xFF, b[6]==0x41`, and `b[1]|b[7]|b[8]` must be zero -- then takes the
**big-endian `uint16` at `b[9]`** (`rev16`), stores it as a 32-bit word at `0x200001fc[idx++]`,
and saturates `idx` at 0x7c6 = **1990 samples**. That store happens **only while the capture flag
is set** (@0x8016758), which is what makes this buffer the PA trace and not general traffic.

So the thing being measured arrives on the eBoard's *second* UART as a stream of 16-bit samples
from a separate module. It is not the accelerometer, not the eddy coil, and not an ADC channel --
those were the earlier guess and it was wrong. **Which transducer sits on that UART is still not
identified**; the frame shape is all we have.

### The verdict

A background task @0x08016c60 closes the loop:

```c
if (capture_flag != 1) return;
if (action == 11) return;          // still capturing
analyse(0x200001fc, 2000);         // -> 0x08016848, writes the result to 0x200000a0
capture_flag = 0;
```

`analyse` is double-precision and walks the trace looking for events. What is legible without
fully reversing it: a span test of **81..149 samples** (`sub #0x51; cmp #0x44` @0x8016a2c),
amplitude ratio tests against **1.2** (`0x3FF3333333333333` @0x8016a38) and **1.5**
(`0x3FF8000000000000` @0x8016c3c), a qualifying-event counter **saturated at 10** and required to
be **> 2** (@0x8016a04, @0x8016a5a), and a rising-run scan over the sample array. The value
stored to 0x200000a0 is what `get_emcu_pa_value` @0x080115d0 sends back verbatim.

That the counter saturates at 10 while the host accepts only **9** (`bne $v1, 9` @0x792878) fits
a graded score rather than a boolean, but the app does not distinguish the other values, and we
have not pinned what each means.

### Still unknown

- The transducer on USART3.
- `ACTION=11`. `pa_adjust.py`'s comment says `0:PA_close 1:PA_start`; the firmware tests only
  `== 11` for start and treats everything else as stop. The comment is from an older release (the
  older `firmwareExe` we have, `ca6f1bf1`, has no `paTestMgr` at all).
- `PC=666`. The Chinese comment on the parameter is 材料, "material". `pa_action` stores it at
  0x20000094 and the capture path never reads it back, so on this firmware it is inert -- the app
  hardcodes 666 and so can we.

### Why this matters for the port

The extrudate is a **byproduct**, not the measurement -- and since the carriage is latched still
([section 3a](#3a-the-carriage-does-not-move)) it is not even lines, just a gram of filament in
the chute. Nothing -- no camera, no probe, no later pass -- ever looks at it. They exist because you cannot produce a real pressure transient
without really extruding. The scoring happens live, during the move, from a signal the toolhead
is already streaming. That is why the port can reproduce this at all: we keep the eBoard firmware
and the sensor, so we get the same verdicts for free.

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

## 7. The port

Built: `pkgs/klipper/payload/klipper/klippy/extras/ff_pa.py` and
`pkgs/klipper-config/payload/config/ff-pa.cfg`, included from `printer.base.cfg`.

### Why it is Python and not a macro

`PA_GET` only calls `gcmd.respond_info(...)`, and a Jinja macro cannot read another command's
response — so the sweep has to be Python whatever else is decided. `ff_pa.py` borrows
`pa_adjust`'s already-bound MCU command wrappers rather than the `PA_GET` text, which drops the
`find("=")`/`stoi` parsing the app needs and its failure modes.

It **borrows** rather than declaring its own `lookup_query_command`. Declaring our own would be
safe — `MCU.lookup_query_command` builds a fresh wrapper per call and registers no lasting
handler (`SerialRetryCommand` registers per send and unregisters after), and klippy runs commands
serially so two wrappers cannot be in flight at once. But it would put a second copy of a closed
MCU's protocol strings in our tree to drift out of sync on a fork bump, and it would need a
`register_config_callback` on `[mcu eboard]`, which would let a report-only tool block startup on
a machine whose eBoard is unplugged. The wrappers are resolved on first use, not at
`klippy:connect`: `pa_adjust` binds them from its own MCU config callback, and the ordering
between the two handlers depends only on section order, which nothing enforces.

### What it does

`FF_PA_CALIBRATE [TOOL=] [TEMP=] [SWEEPS=] [WINNERS=] [CANDIDATES=] [PASS_VALUE=] [Y_START=]
[Y_STEP=] [Z=] [VERBOSE=1] [DRY_RUN=1]` runs section 3 verbatim — same seven candidates in the
same scrambled order, same Y ladder, same 5-sweep / 3-winner / mean-of-3 selection, same "only 9
passes" — and **reports**. Every constant is overridable from `[ff_pa]`, but the defaults are
FlashForge's, because they are matched to a scorer we cannot read.

`FF_PA_PROBE [PA=] [Y=]` draws one line and prints one verdict. This is the bring-up instrument:
it is how you answer "does the eBoard discriminate?" without committing to a full run.

`FF_PA_STATUS` shows the config in force, whether the eBoard commands are bound, the driver pin
state, and the last run's table.

### Deliberate divergences from the app

- **The extruder's own pressure advance is restored on exit.** The app leaves the last candidate
  (0.0400) installed — it can afford that because it immediately overrides it via
  `SET_PA_ADVANCE`, and we do not. Leaving it would mean the command silently applied something,
  and the wrong thing.
- **A run where every line returned the same verdict is refused** (`require_discrimination`).
  This is the failure that matters: if the eBoard is not discriminating and answers 9 for
  everything, the smallest passing candidate is `candidates[0]` on every sweep, and the mean is
  `0.0100` — a number that looks exactly like a measurement and is an artefact. The app accepts
  it. Related, and printed with every result: because the rule is *smallest passing wins*, this
  procedure can structurally never report below its smallest candidate.
- **Cold extruder, empty tool, out-of-range geometry are refused before anything moves**, rather
  than failing mid-line with the eBoard armed and the drivers latched.
- **The park is ours, the latch is the app's.** `[ff_pa] park` (default on) drives the nozzle to
  the chute in `_FF_FILAMENT_PREP`'s own three moves *before* the drivers are latched -- the app
  relies on its caller having already gone there, and `FF_PA_CALIBRATE` has no such caller. With
  `park: False` the gram lands wherever the nozzle happens to be, and the command says so before
  it starts.
- **`SET_KINEMATIC_POSITION` *is* replayed**, to the parked coordinates. It has to be: after the
  sweep Klipper believes the carriage is at the end of the ladder and it is over the chute, and
  the axes are still flagged homed. An earlier revision of this port deliberately skipped it on
  the reasoning that "our sweep is plain G1 under Klipper's own kinematics" -- that reasoning
  was wrong, because the latch means our G1s move nothing either.
- **Failing to unlatch is reported, not swallowed.** Both `SET_PIN`s go back to their snapshot
  value, and if that fails (a shutdown mid-run makes `run_script_from_command` raise) the command
  prints the recovery line rather than leaving a printer that silently cannot move.
- **`SAVE_GCODE_STATE`/`RESTORE_GCODE_STATE`** wrap the run; the app leaks its modal state.
- **`min()` on floats**, not the app's lexicographic sort of fixed-width strings. Identical for
  its own seven values, correct for an override with mixed decimal widths.
- **Not wired into print start.** Thirty-five 160 mm lines is minutes and about a gram of
  filament before every print; the app gets away with it only because it sits behind a flag. A
  user-invoked calibration matches how PID and shaper already work here
  ([`25-app-vs-klipper-ownership.md`](25-app-vs-klipper-ownership.md)).

The result is **not** persisted and **not** applied on a toolchange. It is printed, with the
`[extruder<n>] pressure_advance:` line to paste and the `SET_PRESSURE_ADVANCE` to try it for the
session.

### Bring-up, in order — each stage gates the next

1. **Does the round-trip answer?** Needs no new code — `[pa_adjust]` already shipped before this
   port. By hand: `PA_ACTION ACTION=11 PC=666`, a few moves, `PA_ACTION ACTION=0 PC=666`, `M400`,
   `PA_GET` -> `Result is value=<n>`. Record the value even if it is 0: a 0 that arrives is very
   different from a query that times out.
2. **Does it discriminate?** `FF_PA_PROBE` across the seven candidates, repeated two or three
   times. Looking for more than one distinct verdict, the same candidate landing the same way
   across runs, and passing candidates clustering rather than scattering. All-9 or never-9 means
   stop — `FF_PA_CALIBRATE` will refuse anyway, and it is right to.
3. **The command.** `FF_PA_CALIBRATE DRY_RUN=1` to read the emitted script and the computed Z
   without moving, then `SWEEPS=1` (~1 min), then the full run three or four times. Check
   afterwards that `pressure_advance`, both `enable_pin_tmc_*` and `max_accel` /
   `square_corner_velocity` are back where they started.
4. **Is it right?** Against a hand-tuned PA tower on the same filament.

Until stage 2 produces real numbers the PA tower stays the documented method and this is an
experiment. Nothing in the repo can load klippy off-hardware, so `pyflakes` (via `make qa-static`)
and the replica's include-wiring check are the whole automated story.

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
| 0x78f030 | the chute coordinates and `SET_KINEMATIC_POSITION` restore string, in `clearNozzleEddy` |
| 0xdb6b2c / 0xdb6b28 | `275.0` / `254.0` -- the purge chute, `purge_x` / `purge_y` |
| 0xdb6b24 | `-8.0` -- the tool dy applied to it, our `tool_dy[3]` |
| 0xdb6a90 | `2.8` (double) -- the Z added to the probe Z for the restore |
| 0x791de8 | outer bound, `slti 5` |
| 0x792878 | the verdict test, `bne $v1, 9` |
| 0xdb6a80 | `3.0f`, the divisor |

### eBoard (`work/stock/mcu/eBoard.bin`, loads at 0x08010000)

| address | what |
|---|---|
| 0x0801a288 | `command_index[]`, 16-byte entries, indexed by the dictionary's command id |
| 0x080115ec | `pa_action` (id 5) |
| 0x080115d0 | `get_emcu_pa_value` (id 6) |
| 0x08016734 | USART3 idle-line handler — frame check and sample store |
| 0x08016c60 | background task: on stop, run `analyse` and clear the flag |
| 0x08016848 | `analyse(buffer, 2000)` |
| 0x200001fc | 1990-sample capture buffer (memset 8000 bytes) |
| 0x200000a0 | the verdict `get_emcu_pa_value` returns |
| 0x2000009c | capture-armed flag |
| 0x20000098 / 0x20000094 | last `action` / `pc` |
