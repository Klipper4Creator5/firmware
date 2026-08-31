# Cancelling an object stalls the host into "Timer too close"

**Status: diagnosed, not fixed.** The measurements below are from a Creator 5 Pro
running the current mod; the fix at the end is written but unwritten to code.

Cancelling an object mid-print — `EXCLUDE_OBJECT NAME=…`, what Mainsail's and
HelixScreen's "cancel this object" buttons send — makes Klipper read the rest of the
file as fast as the SD reader can go, with no motion to pace it. On this two-core
SoC the reactor falls far enough behind that an MCU timer expires and the eboard
shuts down with `Timer too close`.

It needs a *cancel*. Merely slicing with objects defined is harmless.

## The chain

1. `EXCLUDE_OBJECT NAME=…` reaches `_exclude_object`, which calls
   `_register_transform()` and installs `ExcludeObject` as a `gcode_move` move
   transform.
2. Every move now enters `ExcludeObject.move()`. Inside a cancelled object
   `_test_in_excluded_region()` is true, so the move goes to `_ignore_move()`,
   which updates Python state and **returns without calling
   `next_transform.move()`**. Nothing is queued to the toolhead.
3. `virtual_sdcard.work_handler` is paced by that queue: normally `gcode.run_script`
   blocks once the lookahead buffer fills, and that backpressure is the reader's
   only throttle. Its own yields are one `reactor.pause(self.reactor.NOW)` per
   8192-byte read, plus a `gcode_mutex.test()` check.
4. With every move discarded there is no backpressure. At ~24.8 bytes/line for a
   typical sliced file that is **~330 lines dispatched between reactor yields**.
5. The eboard's soft-PWM output (`queue_digital_out oid=15` in the shutdown dump,
   re-queued every ~0.1–0.2 s) misses its refresh deadline. The eboard raises
   `Timer too close` and Klipper transitions to shutdown.

When the whole plate is one object — a single Benchy — cancelling it means every
remaining move is discarded, and the reader runs unthrottled to end of file.

## What the logs show

A 2.48 MB / 99,854-line Benchy, single object, cancelled from the UI:

| observation | value |
| --- | --- |
| `Excluding object 3DBENCHY.DRC_ID_0_COPY_0` | between `Stats 940.4` and `Stats 946.5` |
| `shutdown … static_string_id=Timer too close` | 979.8 s — **~37 s after the cancel** |
| status-query latency, 1 Hz poll, across that window | **1.30–1.78 s**, never 1.0 s |
| main MCU at the failure | `mcu_awake=0.000 mcu_task_avg=0.000004 gcodein=0` |
| retransmits | eboard `bytes_retransmit=9` (25 by the dump); every other MCU 0 |

The host is not starved of *work* — `gcodein=0`, the main MCU is idle. It is late,
continuously, for 37 s. The shutdown payload is FlashForge's own:
`Eboard close=15 Close_num=3519175851 Temp_waketime=3512776558`.

## What it is not

`EXCLUDE_OBJECT_DEFINE` is not the cost, despite being the line that disappears when
the symptom does. Removing it removes the *precondition* — no object defined means
no object to cancel means no transform — not the work.

Measured on the printer, for a real 9,008-byte / 502-point Benchy `POLYGON`:

| path | cost |
| --- | --- |
| the DEFINE line through the live klippy, HTTP round trip included | **115 ms** |
| the same line, `_process_commands` only | **89.6 ms**, of which `shlex.read_token` is 97% |
| each `EXCLUDE_OBJECT_START` / `_END` (480 of them) | 0.503 ms |
| parse+dispatch throughput on real move lines | 14,134 lines/s, against ~28 moves/s demanded |
| steady-state CPU with the object defined vs not | unchanged (klippy 5.6% vs 5.7%) |

Three full prints of this file with the DEFINE present and no cancel completed
normally, `bytes_retransmit=0`.

`shlex` is nonetheless quadratic in token length, because `read_token` builds tokens
with `self.token += nextchar` and CPython cannot resize an instance attribute in
place (refcount > 1). On the printer a 64,000-character token costs 2,396 ms, of
which 1,880 ms is that one `+=`. It is a real hazard for a plate of many objects or
a very high-point polygon — 129 KB of DEFINE takes 10.4 s — but it is not this bug.
`tools/gcode-bench/` holds the harnesses.

## The fix

Restore pacing on the discard path. `ExcludeObject` should yield to the reactor
while ignoring moves, the way `toolhead._check_pause` already does from inside gcode
processing:

```python
# _ignore_move, after the state update
now = self.reactor.monotonic()
if now >= self._next_yield:
    self._next_yield = now + 0.020
    self.reactor.pause(now + 0.001)   # let MCU timers be serviced
```

`exclude_object.py` is an extra, and `pkgs/klipper` already overlays extras from
`payload/klipper/klippy/extras/` — that is how the toolchanger extras ship — so this
is a supported shape and not the half-overwritten tree `pkgs/klipper/build.sh` warns
about.

Open: the yield interval is a guess against a ~0.1–0.2 s soft-PWM deadline and wants
measuring. The spin rate can be measured without moving the machine — with an object
defined *and* excluded every `G1` is discarded, so a few thousand moves can be fed to
a live klippy to time the starvation window directly.

## Reproducing

1. Slice anything as a single object with `EXCLUDE_OBJECT_DEFINE` (Orca emits it by
   default).
2. Start the print and let it reach steady printing.
3. Cancel that one object from the UI.
4. Watch `/usr/data/logs/printer.log`. Expect `Excluding object …`, then tens of
   seconds of reactor lateness, then `MCU 'eboard' shutdown: Timer too close`.
