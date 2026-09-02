# FlashForge levelBoard — eddy sensor module, recovered

Source: `work/stock/mcu/levelBoard.bin`, load address `0x08004000`,
Cortex-M4 Thumb-2, 26704 bytes (`0x08004000`–`0x0800A850`), no symbols.
Reconstructed C: `recovered_eddy.c`.

Every claim below cites the flash address of the instruction that
justifies it. Anything not established by the image is marked
**UNCERTAIN**.

---

## 1. Headline finding: it is not an ADC sensor

The task brief describes `0x08007894` as "the DMA1 channel 1 (ADC)
interrupt handler". It is a DMA1 channel 1 handler (vector 27,
`0x0800406C = 0x08007895`, IRQ 11 = `DMA1_Channel1_IRQn`), but **no ADC
is involved anywhere in this module**. `ADC1` (`0x40012400`) never
appears as a literal in the image at all — the only literals in the
`0x4001xxxx` range are `0x40012C00`/`0x40012C24` (TIM1, TIM1->CNT),
`0x40013400` (TIM8) and `0x40013800` (USART1, klipper's serial).

The sensor is a **frequency (period) counter** on an LC oscillator:

```
  LC oscillator ──► PA0 = TIM8_ETR ──► TIM8 (ext clock mode 2, ARR=500)
                                          │ update event every 501 edges
                                          ▼ DMA request
  TIM1 (free run, PSC=0, ARR=0xFFFF) ──► DMA1_CH1 ──► ff_eddy_dma_capture
                                                          │ TC interrupt
                                          value = (uint16)(cnt - prev_cnt)
```

`value` is therefore **the number of TIM1 ticks that elapsed while the
oscillator produced 501 edges** — a reciprocal-frequency measurement.
At `CLOCK_FREQ = 128000000` one tick is 7.8125 ns. Metal approaching
the coil lowers the oscillator frequency, so `value` rises.

Sanity check on the numbers: the polling timer consumes one sample every
500 us (`0x08006008`, `timer_from_us(500)`), which is only sustainable if
501 oscillator edges take roughly 500 us, i.e. an oscillator around
1 MHz. 500 us at 128 MHz is 64000 ticks, which fits the 16-bit
`uxth` truncation at `0x080078BA` with room to spare. The
auto-calibrated trigger threshold of 20–60 ticks is then a frequency
shift of roughly 0.03 %–0.1 %.

---

## 2. Function inventory

Addresses are the function entry; "size" is entry to the last
instruction before the literal pool / next function.

| Address | Size | Name given | Role |
|---|---|---|---|
| `0x080076AC` | 0x2A | `ff_eddy_pin_init` | PA1 as push-pull output, latched high |
| `0x080076DC` | 0x60 | `ff_eddy_median` | copy 11-sample ring, insertion sort, return `[5]` |
| `0x08007740` | 0x28 | `ff_eddy_home_reset` | reset detector state at homing start |
| `0x08007780` | 0x7C | `ff_eddy_dma_init` | DMA1_CH1: TIM1->CNT → RAM, circular, TC irq |
| `0x08007808` | 0x82 | `ff_eddy_counter_init` | TIM8 ext-clock gate + TIM1 tick counter, tail-calls the above |
| `0x08007894` | 0x3C | `DMA1_Channel1_IRQHandler` | capture → `value`, `sample_ready = 1`, wake task |
| `0x080078EC` | 0x2B2 | `ff_eddy_update` | ring buffer, MAD/sigma statistics, auto-calibration |
| `0x08007BF4` | 0x5C | `ff_eddy_rebaseline` | re-zero everything against the current reading |
| `0x08007C98` | 0xDE | `ff_eddy_check_trigger` | IIR + debounce → virtual endstop pin level |
| `0x08005FF8` | 0x3C | `ff_eddy_timer_event` | 500 us `struct timer` callback, calls `ff_eddy_update` |
| `0x0800630C` | 0x2A | `ff_eddy_timer_init` | register the 500 us timer (caller id `0x62`) |
| `0x08004D00` | 0x1C | `command_set_trigger_threshold` | msgid 2 |
| `0x08004CCC` | 0x26 | `command_get_basic_param` | msgid 4 |
| `0x08004C78` | 0x22 | `command_remove_peel` | msgid 7 |

Patched stock klipper functions that belong to the same subsystem:

| Address | Function | FlashForge change |
|---|---|---|
| `0x0800819C` | `gpio_in_read` | returns `ff_eddy_pin_state` for one specific pin (§6) |
| `0x080054E0` | `command_endstop_home` | calls `ff_eddy_home_reset` (`0x08005514`), sets/clears `0x2000009F`, forces pin high when disarming (`0x08005510`) |
| `0x080055C8` | `command_endstop_recover_state` | calls `ff_eddy_home_reset` (`0x080055EE`) |
| `0x08005568` | `command_endstop_query_state` | sets/clears `0x2000009F` around the query |
| `0x08006340` | `sched_main` | three extra init calls before `sendf("starting")`: `0x080076AC`, `0x08007808`, `0x0800630C` |
| `0x080063BA` | `run_tasks` | inlined `if (sched_check_wake(&ff_eddy_wake)) ff_eddy_check_trigger();` at the bottom of the loop |
| `0x0800626C` | `sched_add_timer` | gained a second argument (caller id) recorded for the "Levelboard close=…" report (§8) |

Vendor SPL routines the module calls (standard STM32F1 StdPeriph,
identified from their register writes, listed for completeness):
`0x08008A3C` GPIO_Init, `0x08008AB4` GPIO_StructInit, `0x08008ACC`
GPIO_SetBits, `0x08008938` NVIC_Init, `0x08008CB0` RCC_AHBPeriphClockCmd,
`0x08008CC0` RCC_APB2PeriphClockCmd, `0x08008CD4` TIM_TimeBaseInit,
`0x08008DFC` TIM_TimeBaseStructInit, `0x08008E14` TIM_Cmd,
`0x08008E20` TIM_ETRClockMode2Config, `0x08008E6C` TIM_DMACmd,
`0x08008EA4` DMA_DeInit, `0x08008F6C` DMA_Init, `0x08009000` DMA_Cmd,
`0x08009018` DMA_ITConfig, `0x08009030` DMA_GetITStatus,
`0x0800903C` DMA_ClearITPendingBit.

---

## 3. ADC/DMA question, answered precisely

**Which ADC channel** — none. See §1.

**DMA setup** (`0x08007780`, struct built on the stack and passed to
`DMA_Init` at `0x080077C4`; the field offsets below are proved by
`0x08008F6C`, which is the stock F1 SPL `DMA_Init`):

| `DMA_InitTypeDef` field | offset | value | instruction |
|---|---|---|---|
| `PeripheralBaseAddr` | +0x00 | `0x40012C24` = `TIM1->CNT` | `0x08007794` |
| `MemoryBaseAddr` | +0x04 | `0x20000130` | `0x08007798` |
| `DIR` | +0x08 | `0` peripheral → memory | `0x080077BA` |
| `BufferSize` | +0x0C | `1` | `0x080077BA` |
| `PeripheralInc` | +0x10 | `0` disabled | `0x080077BE` |
| `MemoryInc` | +0x14 | `0` disabled | `0x080077BE` |
| `PeripheralDataSize` | +0x18 | `0x100` halfword | `0x080077A2` |
| `MemoryDataSize` | +0x1C | `0x400` halfword | `0x080077A2` |
| `Mode` | +0x20 | `0x20` circular | `0x080077B6` |
| `Priority` | +0x24 | `0x2000` high | `0x080077B6` |
| `M2M` | +0x28 | `0` disabled | `0x080077C2` |

Then `DMA_ITConfig(TCIE)` (`0x080077EE`, flag `0x2`) and `DMA_Cmd(ENABLE)`
(`0x080077F4`). NVIC: `{IRQChannel = 11, PreemptionPriority = 0,
SubPriority = 7, Cmd = ENABLE}` (`0x080077D0`–`0x080077E6`).

**Sample buffer size** — one halfword. There is no DMA ring; the DMA
overwrites a single word (`0x20000130`) circularly and the interrupt
reads it. The 11-entry ring buffer at `0x20000164` is filled in
software, one entry per 500 us tick.

**How the live value is derived** — `0x080078B0`–`0x080078C6`:

```
delta         = (uint16_t)(capture - prev_capture);
prev_capture  = capture;
ff_eddy_sample = delta;      // 0x20000154
ff_eddy_value  = delta;      // 0x20000158  (the host-visible "value")
sample_ready   = 1;          // 0x2000015C
sched_wake_task(&ff_eddy_wake);
```

No averaging or filtering happens in the interrupt. Two independent
filters run downstream:

* **Baseline filter** (`ff_eddy_update`, `0x08007950`) — a 4×-scaled
  first-order IIR, `acc = x + 3*acc/4`, so `acc/4` is a low pass with
  α = 1/4. It feeds the baseline, not the trigger.
* **Trigger filter** (`ff_eddy_check_trigger`, `0x08007CF2`) — a
  16×-scaled first-order IIR on the *absolute* deviation,
  `acc += (16*|value-baseline| - acc)/4`, and `filtered = acc/16`.

**Unexplained write.** `0x080077CC` stores `0x32` (50) at
`DMA1_Channel1 + 0x10`. On a stock STM32F103 that is the reserved word
between channel 1 and channel 2 and the write is a no-op — but a stock
F103 also cannot route `TIM8_UP` to DMA1 channel 1 (`TIM8_UP` is a DMA2
request; DMA1 channel 1 accepts only `ADC1`, `TIM2_CH3`, `TIM4_CH1`).
The most plausible reading is that this silicon has a per-channel
request selector there and 50 is the `TIM8_UP` request id. **UNCERTAIN.**
Corroborating evidence that this is not a genuine STM32F103 despite
`MCU=stm32f103xe` in the data dictionary: `digital_regs[]` at
`0x0800A788` holds only four GPIO ports, at `0x40023400`, `0x40023800`,
`0x40023C00`, `0x40024000` (not `0x40010800…`), and `GPIO_Init`
(`0x08008A3C`, `0x080089A8`, `0x080089F0`) writes an F4/L4-style
register file — 2-bit MODER at `+0x00`, OTYPER at `+0x04`, a 1-bit
register at `+0x08`, 2-bit PUPDR at `+0x0C`, IDR `+0x10`, BSRR `+0x18`,
AFRL/AFRH `+0x20`/`+0x24`, and a further 2-bit register at `+0x2C`.
RCC (`0x40021000`, AHBENR at `+0x14`, APB2ENR at `+0x18`), FLASH
(`0x40022000`), DMA1 (`0x40020000`, seven channels at `0x40020008` +
0x14 stride), IWDG (`0x40003000`) and the timer map are all F1. I could
not identify the exact part. **UNCERTAIN.**

---

## 4. Pins

| Pin | Direction | Evidence |
|---|---|---|
| **PA0** | alternate function 8, "speed" field 2 → TIM8 external trigger input | `0x0800781C`–`0x0800782E`; port = `digital_regs[0]` = `0x40023400`, pin mask `1` |
| **PA1** | push-pull output, set high at init and never cleared | `0x080076BA`–`0x080076CE` (pin mask `2`, mode `1`, then a BSRR write of `2`) |
| **PD0** | *virtual* — the eddy endstop the host homes against | `0x080081A4`–`0x080081C8`, see §6 |

PA1's meaning (oscillator power / enable / LED) is not determined by the
image — only that it is an output latched high at startup. **UNCERTAIN.**

---

## 5. The algorithm

### 5.1 Sampling loop (`ff_eddy_update`, `0x080078EC`)

Runs from the 500 us timer, returns immediately unless
`sample_ready` is set.

**Before the first calibration** (`ff_eddy_armed == 0`, `0x080078FA`):
the raw sample is pushed into the ring.

**After arming** (`0x080079D0`): let `dev = value - sample_ref` and
`thr = |ff_eddy_threshold|`.

| condition | ring gets | side effect |
|---|---|---|
| `|dev| <= thr` | raw value | both run counters cleared (`0x08007B44`) |
| `thr < |dev| <= 150` | **the baseline**, so a probe touch does not pollute the noise estimate (`0x08007A04`) | `inrange_count++`; at 100 (`0x08007A0C`) the baseline and `sample_ref` are dragged to the current value — drift adaptation |
| `|dev| > 150` | raw value | `outrange_count++`; at 15 (`0x08007B6C`) sets `ff_eddy_hard_trigger` |

Common tail (`0x08007912`): store into `ring[pos]`, `pos = (pos+1) % 11`,
`count` saturates at 11.

Once 11 samples are in (`0x08007A28`), the baseline IIR is seeded with
`4 * median(ring)` and a quiet-window start timestamp is taken. From
then on, every sample:

1. `filter_acc = sample + 3*filter_acc/4` (`0x08007950`)
2. `center = median(ring)` (`0x0800795C` → `0x080076DC`)
3. `mad = median(|ring[i] - center|)` over all 11 (`0x0800796E`–`0x080079BA`)
4. if `mad > mad_limit` (2) → reset the quiet-window timer, done
5. else, if the window has been quiet for **2000 ms** (`0x08007A6A`) →
   recalibrate.

### 5.2 Recalibration (`0x08007A70`–`0x08007B3A`)

```
variance = Σ (ring[i] - center)² / 11         (64-bit accumulate, /11 at 0x08007A92)
sigma    = isqrt(variance)                     (Newton, 0x08007A9A..0x08007AB6)
sigma    = max(sigma, max(1, mad + mad/2))     (0x08007AB8..0x08007ACA)
threshold = clamp((int16)(3*sigma), 20, 60)    (0x08007AF2..0x08007B14)
baseline = sample_ref = offset + filter_acc/4  (0x08007B08, 0x08007B1A/0x08007B1E)
ring_count = ring_pos = 0; have_filter = 0; calibrated = 1
```

There is also an outlier scrub just before this — entries further than
`3*mad` (saturating; `mad_limit` if `mad == 0`) from `center` are
replaced by `center` (`0x08007AD6`–`0x08007AF0`). **It has no observable
effect**, because `ring_count`/`ring_pos` are reset immediately
afterwards and every slot is overwritten before it is read again.

**Consequence worth flagging:** the trigger threshold the host sets with
`set_trigger_threshold` (`ff_eddy.py` defaults it to −15) lands in
`0x2000003E` but is overwritten by `0x08007B14` at the next quiet
recalibration, which happens within a couple of seconds of any idle
period. In practice the firmware runs on its own 3σ estimate, clamped
to 20–60 ticks, and the host value only survives until the next quiet
window. The int32 copy at `0x20000000` is written and echoed back but
never used for anything.

### 5.3 Trigger detection (`ff_eddy_check_trigger`, `0x08007C98`)

Woken once per DMA capture. Guard: samples with `value == 0` are
discarded (`(value-1) > 0xFFFE`, `0x08007CB6`/`0x08007CD0`).

```
peel      = value - baseline                       (signed, 0x08007CE0)
adiff     = (uint16)|peel|
trig_acc += (16*adiff - trig_acc) / 4              (0x08007CF2)
filtered  = trig_acc / 16                          (0x08007D00)
```

| condition | action |
|---|---|
| `filtered >= threshold` | `trig_count++`; on the 4th consecutive (`0x08007D12`) set `pin_state = 0` (**triggered**) |
| `filtered < threshold - 2` | `untrig_count++`; on the 3rd consecutive (`0x08007D4A`) set `pin_state = 1` (released) |
| in between (2-tick hysteresis band) | hold state, clear the opposing counter (`0x08007D60`) |

`ff_eddy_hard_trigger` (set by the ">150 for 15 samples" rule) short
circuits all of this and drops `pin_state` to 0 immediately
(`0x08007D26`).

---

## 6. How the trigger reaches trsync

There is no `trsync` call anywhere in this module. The eddy detector
drives a **virtual GPIO pin** and the host homes against it with the
ordinary `config_endstop` / `endstop_home` commands; stock `endstop.c`
polls `gpio_in_read()` and does the `trsync_do_trigger()` itself.

`gpio_in_read` at `0x0800819C` is patched:

```
  080081A4  ldr  r1, =0x40024000        ; digital_regs[3], i.e. port "PD"
  080081A8  cmp  r0, r1
  080081AC  beq  0x80081bc
  080081AE  ldr  r3, [r3, #0x10]        ; normal path: regs->IDR
  ...
  080081BC  cmp  r2, #1                 ; bit mask == 1 -> pin 0
  080081BE  bne  0x80081ae
  080081C0  ldr  r3, =0x2000003C
  080081C2  ldrb r0, [r3]               ; return ff_eddy_pin_state
```

`digital_regs[]` is the 4-entry table at `0x0800A788`; index 3 with bit
mask 1 is klipper pin id 48, which the data dictionary names **PD0**.
So a `[ff_eddy]`-equipped printer.cfg configures its probe endstop on
`PD0` of this MCU and the whole detector is invisible to klipper's
endstop code.

`pin_state` semantics: `1` = not triggered (its `.data` initialiser at
`0x0800A848` is `0x01`), `0` = triggered.

Homing hooks:

* `command_endstop_home` with `sample_count != 0` calls
  `ff_eddy_home_reset` (`0x08005514`) which sets `pin_state = 1` and
  zeroes `trig_acc`, both debounce counters, `hard_trigger` and `peel`.
* `command_endstop_home` with `sample_count == 0` (disable) forces
  `pin_state = 1` directly (`0x08005510`).
* `command_endstop_recover_state` calls `ff_eddy_home_reset`
  (`0x080055EE`).
* `0x2000009F` is set to 1 while homing is armed and while
  `endstop_query_state` runs, and cleared afterwards — but **nothing in
  the image ever reads it**. Dead in this build.

---

## 7. RAM map

`.data` is `0x20000000`–`0x20000044`, copied from flash `0x0800A80C`
(`0x080088D4`). `.bss` is `0x20000044`–`0x200003A8` (`0x080088EA`).
So every eddy variable at or above `0x20000044` starts at zero.

| Address | Width | Init | Name | Justification |
|---|---|---|---|---|
| `0x20000000` | i32 | 25 | `ff_trigger_threshold` (host echo, unused) | `0x08004D0A` |
| `0x20000038` | u32 | 2 | `ff_eddy_mad_limit` | `0x080079C0`, `0x08007AD2`; flash `0x0800A844` |
| `0x2000003C` | u8 | 1 | `ff_eddy_pin_state` | `0x080081C2`, `0x08007D28` |
| `0x2000003E` | i16 | 25 | `ff_eddy_threshold` (working) | `0x080079DC`, `0x08007B14`, `0x08007CC8` |
| `0x200000AC` | u8 | 0 | `ff_eddy_wake` (`struct task_wake`) | `0x080078C4` → `0x08006160`; `0x080063BA` |
| `0x200000AD` | u8 | 0 | `ff_eddy_armed` | `0x080078FA`, `0x0800601C` |
| `0x20000110` | 12 | 0 | `ff_eddy_timer` (`struct timer`: next/func/waketime) | `0x0800630E`–`0x08006326` |
| `0x2000012C` | u32 | 0 | `ff_eddy_prev_cnt` | `0x080078AC` |
| `0x20000130` | u32 | 0 | `ff_eddy_dma_capture` (DMA writes only the low halfword) | `0x08007798`, `0x080078AE` |
| `0x20000134` | u32 | 0 | `|value - baseline|`, **write only** | `0x08007CEC` |
| `0x20000138` | u32 | 0 | baseline copy, **write only** | `0x08006030` |
| `0x2000013C` | u8 | 0 | `ff_eddy_have_filter` | `0x0800793E`, `0x08007A3E`, `0x08007B22` |
| `0x2000013D` | u8 | 0 | `ff_eddy_hard_trigger` | `0x08007B7A`, `0x08007CA6` |
| `0x20000140` | u32 | 0 | `ff_eddy_mad` | `0x080079BA` |
| `0x20000144` | u32 | 0 | `ff_eddy_baseline` | `0x08004CD2`, `0x08007B1A` |
| `0x20000148` | i32 | 0 | `ff_eddy_trig_acc` (16× scaled) | `0x08007CFE` |
| `0x2000014C` | u32 | 0 | `ff_eddy_filter_acc` (4× scaled) | `0x08007958`, `0x08007C1E` |
| `0x20000150` | u32 | 0 | `ff_eddy_sample_ref` | `0x080079D6`, `0x08007B1E` |
| `0x20000154` | u32 | 0 | `ff_eddy_sample` (last raw delta) | `0x080078BE` |
| `0x20000158` | u32 | 0 | `ff_eddy_value` (host-visible) | `0x080078C6`, `0x08004CD4` |
| `0x2000015C` | u32 | 0 | `ff_eddy_sample_ready` | `0x080078C2`, `0x080078F2` |
| `0x20000160` | u8 | 0 | `ff_eddy_calibrated` | `0x08007B38`, `0x08006002` |
| `0x20000162` | u16 | 0 | `ff_eddy_outrange_count` | `0x08007B68` |
| `0x20000164` | 11×u32 | 0 | `ff_eddy_ring[11]` | `0x08007920`, extent from `0x08007966` (`+0x2c`) |
| `0x20000190` | u8 | 0 | `ff_eddy_ring_count` (saturates at 11) | `0x0800792C`–`0x0800793A` |
| `0x20000191` | u8 | 0 | `ff_eddy_ring_pos` (wraps at 11) | `0x08007918`–`0x08007932` |
| `0x20000192` | u16 | 0 | `ff_eddy_inrange_count` | `0x08007A0E` |
| `0x20000194` | u32 | 0 | `ff_eddy_quiet_start_ms` | `0x08007A4E`, `0x080079C8` |
| `0x20000198` | u8 | 0 | `ff_eddy_untrig_count` | `0x08007D4E` |
| `0x2000019C` | u32 | 0 | `ff_eddy_offset` — read at `0x08007AF6`/`0x08007BFC`, **never written**, so a constant 0 | — |
| `0x200001A0` | u8 | 0 | `ff_eddy_trig_count` | `0x08007D16` |
| `0x200001A4` | i32 | 0 | `ff_eddy_peel` | `0x08007CE0`, `0x08004C80` |
| `0x2000009F` | u8 | 0 | homing-in-progress flag, write only | `0x0800553C`, `0x080055B4` |
| `0x20000398` | 16 | 0 | shared `TIM_TimeBaseInitTypeDef` scratch | `0x08008E7A` |

`0x2000012C`–`0x200001A8` is contiguous, which is consistent with a
single `struct` but equally with plain file-scope statics laid out in
declaration order; the image cannot distinguish the two, so
`recovered_eddy.c` uses statics.

---

## 8. Command-layer corrections

Small differences from the existing `src/ff_flashforge.c` reconstruction,
all verifiable in the disassembly:

* `command_get_basic_param` (`0x08004CCC`) does **not** wrap its
  snapshot in `irq_disable()/irq_enable()` — the two loads at
  `0x08004CD2`/`0x08004CD4` are plain. Likewise `command_remove_peel`
  (`0x08004C78`).
* `command_get_basic_param` reports `value = baseline` and
  `reserve = |value - baseline|`, both taken **before** the rebaseline.
* `command_remove_peel` sets `baseline = value` only; it does not touch
  `sample_ref` (`0x20000150`).
* `ff_eddy_rebaseline` (`0x08007BF4`) does much more than the comment in
  `ff_flashforge.c` suggests: it also reseeds `filter_acc = 4*baseline`,
  clears the ring, sets `have_filter = 1`, `calibrated = 1`,
  `pin_state = 1`, `peel = 0` and both debounce counters.
* The `Levelboard close=%hu Close_num=%hu Temp_waketime=%hu` report is
  not eddy telemetry. It is emitted from the FlashForge-modified
  `sched_add_timer` (`0x0800626C`) on the "Timer too close" path:
  `close` = the caller id passed as the new second argument to
  `sched_add_timer` (`0x2000010C`, `0x080062E2`), `Close_num` =
  `timer_read_time()` at the failure (`0x200000A4`, `0x080062DC`),
  `Temp_waketime` = the requested `waketime` (`0x200000A8`,
  `0x080062D8`). The eddy timer registers itself with caller id `0x62`
  (`0x0800632C`).

---

## 9. What remains uncertain

1. The exact MCU. It is F1-shaped (RCC/DMA/FLASH/TIM/IWDG map, DWT-based
   `timer_read_time`, 128 MHz) but has F4-style GPIO register files at
   `0x40023400`+ and, apparently, a per-DMA-channel request selector.
   Not identified.
2. The `0x32` written to `DMA1_Channel1 + 0x10` (`0x080077CC`).
   Interpreted as a request-line selector for `TIM8_UP`; not proven.
3. What PA1 physically drives (`0x080076AC`).
4. Whether `ff_eddy_offset` (`0x2000019C`) is written on a sibling board
   from the same source tree. In this image it is a constant zero.
5. Whether `ff_eddy_pin_init`, `ff_eddy_counter_init` and
   `ff_eddy_timer_init` are `DECL_INIT` functions in FlashForge's source
   or literal edits to `sched_main`. The image calls them directly from
   `sched_main` (`0x0800634A`, `0x0800634E`, `0x08006352`), *after*
   `ctr_run_initfuncs` (`0x08007014`), which argues for the latter; the
   reconstruction uses `DECL_INIT` because it is behaviourally identical
   and idiomatic. The same applies to `ff_eddy_check_trigger`, which the
   stock `run_tasks` calls inline instead of via `ctr_run_taskfuncs`.
