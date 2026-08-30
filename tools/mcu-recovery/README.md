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

**Measured progress on code.** Over the stock image's 20,484-byte code
region, across 194 discovered functions:

| | functions | bytes | share |
|---|---:|---:|---:|
| instruction-identical or near (EXACT+CLOSE) | 104 | 9,248 | **45.1 %** |
| adding partial matches | 127 | 11,604 | 56.7 % |
| no counterpart of any kind | — | **2,244** | 11.0 % |

34 of the 54 command handlers are instruction-identical, up from 7. The
image is 25,624 bytes against the stock 26,704.

The 1,164-byte code gap is accounted for rather than estimated: 514 bytes
spread thinly across already-matched functions, and 738 bytes of net
imbalance from what is missing outright. The missing part is FlashForge's
peripheral plumbing -- 0x08008ACC (1,344 B) with its helpers (328 B), the
DMA serial interrupt handlers (268 B) and the eddy task wrapper (80 B) --
offset by the ADC and interrupt-serial code we still carry and stock does
not.

**0x08008ACC is vendor code, not FlashForge logic.** It is a standard
peripheral library subset -- `USART_Init` with the textbook
`x25/(4*baud)/100` BRR helper, `RCC_GetClocksFreq`, `DMA_Init`, and a DMA1
channel-base table at 0x08008F40. Klipper vendors only `n32g45x_adc.c` of
that library, so FlashForge added the USART, RCC and DMA drivers from the
Nations SDK. Reproducing that block means compiling the right vendor
sources, not writing anything new -- which makes it the most tractable
piece of what is left, given the SDK.

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

1. **The vector table.** Stock declares more slots than we do and fills
   three that Klipper leaves on its weak `DefaultHandler`: NMI (`bx lr`),
   HardFault (`b .`) and SVCall (`bx lr`), at 0x08007DA0/DA4/DA8. It also
   places its USART1 handler on the **SPI2 vector** -- see the bugs section
   below -- and its table runs to slot 68 (IRQ 52) where ours stops at 54
   (IRQ 37). Reproducing that means declaring the handler on IRQ 36 as
   FlashForge do, bug and all, and padding the table out.
2. **The vendor peripheral library** at 0x08008ACC (1,344 B, plus 328 B of
   helpers) -- a matter of finding the right published source, not writing
   new code. Klipper vendors only `n32g45x_adc.c`, but the rest is public:
   the N32G45x SDK ships `n32g45x_usart.c`, `n32g45x_rcc.c` and
   `n32g45x_dma.c`, exactly the three drivers that block accounts for.

   Confirmed by compiling them: the SDK's `RCC_GetClocksFreqValue` at -O2
   reproduces stock's first four instructions exactly and the next two are
   the same pair swapped, and `USART_Init`/`DMA_Init` touch the same
   registers and fields in the same order. ST's own StdPeriph
   `RCC_GetClocksFreq` does markedly worse (a 1-instruction prefix over 54
   instructions, against 4 over 70), so it is the Nations driver rather
   than the ST original.

   The family is right; the revision is not. Two published mirrors compile
   to the same code for that function, and nine flag combinations leave -O2
   the best fit, so what is needed is the particular SDK version FlashForge
   built against.
3. **The DMA serial path** (268 B of interrupt handlers plus its setup),
   which sits on top of that library.
4. **The remaining register-allocation differences** -- see below.

### The open puzzle

The 20 handlers that still differ are close: most have identical instruction
counts and diverge only in where a value is kept across a call. Stock
consistently uses one fewer callee-saved register than we do and spills to
the stack instead -- which is the *more* expensive choice, so it is not a
size or speed preference.

What makes it interesting is that it is not global:

- `command_get_clock` matches instruction for instruction, and it *does*
  keep a value in a callee-saved register across a call. So the allocator
  is not behaving differently in general.
- `command_debug_ping` does not match, and it is untouched upstream code in
  `debugcmds.c`. Same compiler, same flags, same source should give the same
  instructions -- so one of those three is not actually the same, and the
  source is the one we have least reason to trust.

Twenty-odd flags have been swept without beating the baseline, including
every register-allocator knob (`-fira-algorithm`, `-fira-region`,
`-fno-ira-share-*`, `-fsched-pressure`, `-fno-ipa-ra`, `-fno-caller-saves`)
and the obvious codegen ones. `permute.py` drives the
next step: search semantically equivalent source formulations for the one
that reproduces stock, which is how matching decompilation projects close
this kind of gap.

Do not flash any of this. It is a reconstruction for study, not a
drop-in image.

## Two bugs worth knowing about

**The USART interrupt handler is installed on the wrong vector.** Stock
puts a handler that services USART1 -- it reads the status register at
0x40013800 and tests ORE/RXNE -- at vector slot 36. On this part
`USART1_IRQn` is 37; 36 is `SPI2_IRQn`, confirmed from the N32G45x SDK's
own CMSIS header, and `USART1_BASE` really is 0x40013800 there. So the
handler is registered on an interrupt that cannot fire from USART1, and
the USART error and idle path is dead code. The serial link works anyway
because it is driven by DMA (channels 4 and 5), which is presumably why
this was never noticed.

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
