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

**The data dictionary matches the stock levelBoard firmware** -- 54/54
commands, 24/24 responses, and every config constant and enumeration
identical.  The rebuilt firmware speaks precisely what the stock board
speaks.

The one difference is numbering: 17 of the 54 commands are assigned a
different message id.  Klipper hands ids out in the order the
compile-time-request entries land in the image, and the host reads them
back out of the dictionary at run time, so two builds that disagree only
on numbering are both correct.  `compare-dict.py` reports the count and
does not gate on it.  The memory map matches too: load address `0x08004000` behind a
16 KiB bootloader, initial SP `0x20004000`.

The **machine code is not identical**, and is not meant to be.  The rebuild
is 17,920 bytes against the stock 26,704.  The ~8.8 KiB difference is the
part that the dictionary cannot describe and that was not reconstructed:

- the eddy front end that produces the live reading -- ADC1 sampled over
  DMA1 channel 1, with an SPI2 side channel;
- FlashForge's DMA-driven serial path (DMA1 channels 4 and 5).  Upstream's
  `serial_irq.c` is interrupt-driven a byte at a time; the stock image is
  not, which is why it can carry a 384-byte receive window;
- the three `Levelboard close= / Close_num= / Temp_waketime=` counters,
  whose meaning is not recoverable from the image;
- `pa_action`, whose eBoard implementation reconfigures TIM4, TIM8 and a
  DMA stream.

Treat the result as a faithful reconstruction of the **protocol layer**,
not as a drop-in replacement image.  Do not flash it.

## A bug worth knowing about

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
