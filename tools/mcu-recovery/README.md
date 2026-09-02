# Recovering the MCU firmware source

The Creator 5 Pro has four motion-control MCUs behind the MIPS host, and
all four run **Klipper MCU firmware** -- FlashForge says so themselves, in
the `license: GNU GPLv3` field their own images carry.  FlashForge ships
the images but not the source.

This directory reconstructs that source for the **levelBoard**, and gives
you the tools to do the same for the other three.

Everything here reads the images `bin/unpack.sh` already extracts; nothing
here talks to a printer.

## Why this is tractable

Klipper stores its data dictionary -- every command, response, config
constant and pin enumeration -- zlib-compressed inside the firmware image.
So the wire protocol comes out without disassembling anything:

    ./tools/mcu-recovery/extract-dict.py work/stock/mcu/levelBoard.bin

Against that dictionary the FlashForge delta is small.  Of levelBoard's 54
commands, **47 are stock upstream Klipper**.  Only seven are FlashForge's,
and the same seven appear on all three STM32 boards (the GD32 main board
carries five of them):

| command | what it does |
|---|---|
| `get_mcu_version` | reports three hard-coded constants |
| `set_trigger_threshold threshold=%i` | eddy trigger threshold |
| `get_basic_param num=%u` | re-baselines the eddy sensor, reports value and drift |
| `remove_peel action=%u` | snapshots the live reading, reports the last peel value |
| `get_emcu_pa_value` | pressure-advance reading -- **eBoard only** |
| `pa_action action=%u pc=%u` | drives the PA pickup -- **eBoard only** |
| `endstop_recover_state oid=%c` | re-arms an endstop after homing |

The host side of the first four is in FlashForge's own klippy tree
(`klippy/extras/ff_eddy.py`), which independently confirms the argument
and reply shapes read out of the machine code.

## The base

| | |
|---|---|
| upstream commit | `6d70050261ec3290f3c2e4015438e4910fd430d0` (v0.12.0-256, 2024-06-18) |
| toolchain | GCC ARM Embedded 10.3-2021.10 |
| target | `MACH_N32G452` -- Nations N32G45x, which is why the image says `stm32f103xe` at 128 MHz |

`6d70050` is not a guess, but it is not proven to be the exact commit
FlashForge compiled either. Two things support it:

- **It reproduces the stock dictionary exactly.** Every one of levelBoard's
  47 upstream commands, all 24 responses, all 16 config constants, all four
  enumerations and all 44 static strings come out identical. That is a tight
  fit; a tree of a different vintage drifts on at least one of them.
- **It sits inside the bracket.** `MACH_N32G45x` did not exist before
  2023-04-07, and levelBoard emits `STEPPER_BOTH_EDGE`, which upstream
  replaced with `STEPPER_OPTIMIZED_EDGE` on 2025-03-09. It is also the commit
  FlashForge forked their *host* tree from (see the vendored fork's
  `README-creator5.md`), which makes it a natural choice for their MCU tree.

Any commit that reproduces the dictionary is equally usable here, so this is
a working base rather than an identification.

Note that the four boards are **not** all on one base. eBoard carries the
multi-bus `config_lis2dw oid=%c bus_oid=%c bus_oid_type=%c lis_chip_type=%c`
that upstream introduced on 2024-10-17; heaterBoard still has the two-argument
form that predates it, despite being built three weeks earlier. Evidence from
one board does not transfer to another.

The toolchain is not a guess at all -- the images name it in `build_versions`.

## Building

    ./tools/mcu-recovery/build.sh

Fetches the pinned toolchain and Klipper at the base commit, applies
`klipper-6d70050-flashforge.patch`, builds with `levelBoard.config`, and
gates on the data dictionary.  It needs `work/stock/mcu/levelBoard.dict.json`
(see `extract-dict.py` above); point `STOCK_DICT` elsewhere to override.

## How close it gets

The goal is a byte-identical image. Not there yet, but the fundamentals are
pinned and the gap is measured rather than guessed.

**Byte-identical already:**

- **The data dictionary** -- all 5,663 bytes, including every message id.
  Ids are not cosmetic: they are baked into the image, so this only fell
  into place once the FlashForge commands were positioned correctly in the
  source (see below).
- **The compressed identify blob** -- all 2,281 bytes as stored in flash.
- The memory map: load address `0x08004000` behind a 16 KiB bootloader,
  initial SP `0x20004000`.

**Measured progress on code.**

| | count | note |
|---|---:|---|
| command handlers instruction-identical | **49 of 54** | was 7, then 34 |
| all functions instruction-exact somewhere in stock | **179 of 233** | 63.8 % of instructions |
| vector-table slots disagreeing with stock | **0 of 69** | was 31 |
| handler ordering: inverted pairs | **9 of 1431** | was 344 |

The five handlers still differing are `endstop_home`, `endstop_query_state`,
`neopixel_send`, `get_basic_param` and `remove_peel`.

**The toolchain is settled, and it was settled by libgcc.** `__udivmoddi4`
is prebuilt: no source edit and no `-f` flag can change it, so if it does
not match stock, the toolchain is wrong -- and that can be tested without
building the firmware at all, by scoring each libgcc multilib in the
toolchain against the stock image:

| multilib | `__udivmoddi4` vs stock |
|---|---|
| `thumb/v7e-m+fp/softfp` | 196/250 (78 %) |
| `thumb/v7e-m/nofp` | 39/248 (16 %) |
| `thumb/v7-m/nofp` | 29/251 (12 %) |

Stock links the FPU multilib. **The N32G45x is a Cortex-M4F and we had been
building it as a Cortex-M3** -- the tree reconstructs the part from
Klipper's STM32F103 headers, which pull in CMSIS `core_cm3.h`, and that
header refuses to compile the moment VFP instructions appear. With
`-mfpu=fpv4-sp-d16 -mfloat-abi=softfp` and `core_cm4.h`, handlers went from
41 to 49 and `__udivmoddi4` became **250 of 250 exact**. GCC 10.3-2021.10 is
confirmed correct; no version hunt is needed.

**Layout.** Byte-identity needs every function at stock's address, not just
matching instructions. Three layout facts have been recovered:

- the objects are linked in **sorted** order, not `src-y` order -- top-level
  `src/*.c` alphabetically, then the subdirectory files;
- `.text` starts at 0x08004120, aligned to 16, with gaps filled `0xff`;
- stock links **GCC's startup files**: `__do_global_dtors_aux` at 0x08004120
  and `frame_dummy` at 0x08004144, ahead of libgcc. Klipper links
  `-nostdlib`, so we had neither.

That last one produced the first code in this image to land byte-correct at
stock's own address: 0x08004120-0x08004160 agrees in 58 of 64 bytes, the six
exceptions being literal-pool entries that hold data addresses.

**The vendor library is not downloadable.** It spans 0x08008924-0x08009043
(1,824 B) and covers RCC, GPIO, USART, NVIC, DMA and TIM. Klipper vendors
only `n32g45x_adc.c`, so FlashForge added the rest -- but not from any
published tree. `RCC_GetClocksFreqValue` is now **byte-exact (71/71)**, and
getting there required one change no published revision has: stock tests a
register at RCC+0x40 bit 0 to decide whether to halve HSI before multiplying
by PLLMUL, where every revision from 2.0.0 to 2.6.0 halves it
unconditionally. Six distinct SDK trees were compiled and compared before
that became clear; the fix had to be derived from the image, not found.

An earlier revision of this note put the block at 0x08008ACC and called it
1,344 bytes, with a DMA1 channel-base table at 0x08008F40. All three were
wrong: 0x08008ACC is a 4-byte `GPIO_SetBits` and 0x08008F40 is
`DMA_DeInit`'s literal pool.

**What byte-identity still needs.** No handler yet sits at stock's exact
address. The drifts cluster by file (+1108 for twelve of them, -188 for
eleven, +1448 for five), which is the signature of each object being
slightly the wrong size rather than in the wrong place -- the ordering is
right, the sizes are not. Whole-image byte agreement stays near 4 % and will
remain there until those sizes match, because one extra byte early shifts
everything after it. Handler address drift, not byte percentage, is the
metric that tracks progress from here.

One concrete lead: stock's 48-byte routine at 0x08004160 is the *unsigned*
64-bit division helper, where we link the 160-byte signed `__aeabi_ldivmod`.
Somewhere our source divides signed where FlashForge's divides unsigned.

### What had to be pinned first

The build was not reproducible against *itself*: Klipper stamps
`?-<timestamp>-<hostname>` into the dictionary it embeds, so two builds a
second apart differ. Nothing can be matched until that is fixed. Likewise
the deflate: Fedora's Python links zlib-ng, which produces different bytes
from classic zlib at the same level, for identical input.

The compiler configuration was then established by measurement, not
assumption -- each row is the count of instruction-identical handlers:

| | | |
|---|---|---|
| `-O2` | **32** | vs 10 (-Os), 3 (-O1), 28 (-O3), 3 (-Og) |
| `-mcpu=cortex-m4` | **32** | vs 8 for cortex-m3 |
| no LTO | **32** | vs 5 with Klipper's default `-flto -fwhole-program` |

Upstream Klipper builds with LTO; the stock image does not, which is
visible directly -- it *calls* `oid_lookup` where an LTO build inlines it.

### Three systematic FlashForge changes

Each one is a small edit repeated across the tree, and each unlocked many
functions at once.

1. **`shutdown()` latches an error code.** Every site writes a per-site
   constant to a global before shutting down, so the host can name the
   fault. All 30 sites recovered; the codes run sequentially in source
   order within each file, which is how the mapping was confirmed rather
   than guessed (gpiocmds.c lines 62/89/137/160/183 -> 29/30/31/32/33).
2. **`sched_add_timer()` takes a call-site tag.** On a "timer scheduled in
   the past" fault the tag is latched and reported as the `close` field of
   the board telemetry, naming which call site was late. All 13 sites
   recovered.
3. **The FlashForge commands live in `basecmd.c`,** between
   `clear_shutdown` and `identify`, and `ff_report_close()` sits at the end
   of the file. This is not a style choice: Klipper assigns message ids
   from the concatenated per-object `.ctr` files in `src-y` order, and in
   *reverse* declaration order within a file. Stock's ids put the six
   commands at 2-7, between identify (1) and clear_shutdown (8), which is
   only reachable from that one arrangement. Getting it right is what made
   the dictionary byte-identical.

### What is still missing

The remaining ~1 KB is mostly FlashForge's DMA-driven serial path (DMA1
channels 4 and 5 plus a USART1 handler for errors and idle) and a
StdPeriph-style driver library that upstream Klipper does not use.

### Next, in order of tractability

Everything on the previous version of this list is done: the vector table,
the vendor library, the serial path and the register-allocation puzzle. What
follows is what is actually left.

1. **Make each object the right size.** This is the whole remaining problem.
   The link order is right and the handlers are in stock's order, but no
   handler is yet at stock's address because the objects ahead of it are the
   wrong size. Since the drift is per-file, it can be attacked file by file:
   fix every function in `adccmds.c`, and that file's handlers snap to their
   stock addresses and stay there.
2. **The signed/unsigned 64-bit division.** Stock's 48-byte routine at
   0x08004160 is the unsigned helper; we link the 160-byte signed
   `__aeabi_ldivmod`. Finding where our source divides signed and stock's
   divides unsigned removes 112 bytes and shifts everything after it.
3. **The five remaining handlers** -- `endstop_home`, `endstop_query_state`,
   `neopixel_send`, `get_basic_param` and `remove_peel`. `get_basic_param`
   is closest: identical instruction counts, differing only in how the
   absolute value is written (stock if-converts a comparison; we get GCC's
   branchless `eor`/`sub` idiom).
4. **The 54 functions not yet matched anywhere**, led by
   `ff_eddy_timer_event` (277 instructions), `gpio_peripheral` (231) and
   `command_encode_and_frame` (133).
5. **`.bss` and `.rodata` layout.** Even byte-identical code carries literal
   pools holding data addresses, so the first matching region still differs
   in six bytes purely because our `completed.0` is at 0x20000038 where
   stock's is at 0x20000044.

### What the vector table turned out to be

Stock's table is exactly 69 words -- external IRQs 0..52 -- followed by
three `0xffffffff` fill words to 0x120. Only four slots hold a real handler:

| slot | line | what |
|---|---|---|
| irq11 | DMA1_Channel1 | the eddy sensor's TIM1 latch |
| irq14 | DMA1_Channel4 | dead -- an abandoned DMA serial design |
| irq15 | DMA1_Channel5 | dead, likewise |
| irq36 | SPI2 | the USART1 handler -- see below |

Everything else is `DefaultHandler`, and all 69 words now agree with stock.
One thing about it is still unexplained: nothing in the image accounts for
the table running out to slot 52. IRQ 52 is UART4 and the UART4 base address
0x40004C00 appears nowhere in the image, so the tail is padding whose
mechanism is inferred from its length alone.

## Two things worth knowing about

**The USART handler sits on vector 36, and that should not work.**
Stock puts a handler that services USART1 -- it reads the status register
at 0x40013800 and tests ORE/RXNE -- at vector slot 36, and unmasks NVIC
line 36 through `NVIC_Init`. On the published numbering that is the wrong
line: the N32G45x CMSIS header numbers this part exactly like an F103, a
contiguous enum in which 35 is SPI1, **36 is SPI2 and 37 is USART1**, with
the N32-only interrupts appended from 53 upward. Two independent SDK
mirrors agree, and there is no gap anywhere in 11..37 that could absorb an
off-by-one.

The obvious reading is a one-line bug in FlashForge's source. But it does
not survive contact with the rest of the image:

- the console is **not** DMA-driven. It is upstream Klipper's
  byte-at-a-time RXNE/TXE interrupt path, so it needs that interrupt;
- the DMA1 channel 4 and 5 handlers at 0x080083B4/0x080083F4 are real code
  but dead -- those channels are never configured or enabled and their
  NVIC lines are never unmasked (`NVIC_Init` has exactly three call sites:
  IRQ 11, IRQ 36 and SysTick);
- neither the SPI2 base address nor UART4's appears anywhere in the image;
- and the printer ships and works.

If the handler really were on SPI2's line, this board's console could not
receive a byte. So either the shipped silicon numbers USART1 at 36,
contradicting two published copies of the vendor header, or this image has
a defect that ought to be fatal. **The binary cannot settle it** -- that
needs the part's reference manual or a live board. An earlier revision of
this note asserted the bug as fact; that was premature.

Either way, reproducing the image requires the handler on slot 36, which
is what the tree now does.

### endstop_recover_state cannot reply


`endstop_recover_state` replies by calling `ctr_lookup_encoder()` directly
with a string literal instead of going through Klipper's `sendf()` macro.
That skips the `DECL_CTR` marker, so `endstop_recover_state oid=%c ok=%c`
is never registered as a response: the string sits in flash, the lookup
returns NULL at run time, and the reply goes to `command_sendf(NULL, ...)`.

It is not theoretical -- FlashForge's own klippy sends this command
(`klippy/mcu.py`, `MCU_endstop._recover_cmd`).  All three boards carrying
the command have it.  The patch reproduces the fault verbatim so that the
generated dictionary still matches; a fix is a one-line change to use
`sendf()`.

## The tools

| | |
|---|---|
| `extract-dict.py` | pull the Klipper data dictionary out of a raw image |
| `compare-dict.py` | gate a rebuilt dictionary against a stock one |
| `compare-blob.py` | gate the compressed identify blob as stored in flash |
| `cmpfuncs.py` | count command handlers that are instruction-identical to stock |
| `shutdownmap2.py` | recover the shutdown error code of every instrumented site |
| `timertags.py` | recover the call-site tag passed to every sched_add_timer |
| `permute.py` | try source variants of one function against stock's instructions |
| `coverage.py` | how many of our functions appear instruction-exact anywhere in stock |
| `vtcmp.py` | gate the vector table: slot by slot, and its length |
| `addrdelta.py` | how far each handler is from stock's address, and the drift pattern |
| `linkorder.py` | derive stock's link order from the handler addresses |
| `classify2.py` | bucket the differing handlers by cause (allocation vs source) |
| `objalign.py` | score a symbol from any `.o` against the stock image |
| `fncmp.py` | compare one of our functions against a stock address |
| `sbs2.py` | side-by-side disassembly of one handler, ours against stock |
| `imgdiff.py` | whole-image positional byte comparison |

`objalign.py` is the toolchain oracle: pointed at `__udivmoddi4` from a
candidate `libgcc.a`, it settles which toolchain and multilib built the
stock image without compiling the firmware at all. That is how the FPU was
found.

`eddy-sensor.md` is the full recovered description of the inductive sensor:
every claim cites the flash address of the instruction that justifies it.
| `klip_cmdtab.py` | find `command_index[]` and map every command to its handler address |
| `armdis.py` | Thumb-2 disassembly of one function, literals and strings resolved |
| `xref.py` | literal-pool cross-references, to find what touches a global |

`klip_cmdtab.py` resolves all 54 handlers on levelBoard and works on the
other three images too:

    ./tools/mcu-recovery/klip_cmdtab.py \
        work/stock/mcu/levelBoard.bin work/stock/mcu/levelBoard.dict.json 0x08004000

## The other three boards

Same seven commands, same base, same method -- only the config and the
board-specific drivers differ.

| board | MCU | clock | load addr | extra commands |
|---|---|---|---|---|
| levelBoard | N32G45x (`stm32f103xe`) | 128 MHz | `0x08004000` | -- |
| eBoard | `stm32f103xe` | 144 MHz | `0x08010000` | real `pa_action` / `get_emcu_pa_value` |
| heaterBoard | `stm32f103xe` | 144 MHz | `0x08010000` | I2C and the sensor modules left enabled |
| mainBoardGD | `gd32h757zg` | 600 MHz | `0x08000000` | seven `mclib_*` closed-loop stepper commands; lacks `set_trigger_threshold` and `endstop_recover_state` |

The 144 MHz boards need a clock option upstream does not offer for this
family, and `mainBoardGD` needs a GD32H7 port that upstream does not have
at all -- both are larger jobs than the levelBoard was.
