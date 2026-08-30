# The MCU firmware is Klipper

`20-klipper-fork.md` describes the FlashForge fork as host-side only, with
"closed prebuilt MCU firmware on the main/e/eheater/level boards". The first
half is right; the second half is worth restating. The boards are not a black
box — **all four run Klipper MCU firmware**, and their own images say so:

```
$ ./tools/mcu-recovery/extract-dict.py work/stock/mcu/levelBoard.bin
  app       Klipper (GNU GPLv3)
  version   ?-20260609_102247-zhengxiaomming
  built     gcc: (GNU Arm Embedded Toolchain 10.3-2021.10) 10.3.1 20210824
  mcu       stm32f103xe @ 128000000 Hz, 230400 baud
  54 commands, 24 responses
```

## Where the firmware lives

Not in `firmwareExe`. The MCU images ship in the **control** component
(`control-1.2.9.tar.xz`), which `bin/unpack.sh` extracts but nothing else
looks at. Its `run.sh` burns them over the same serial ports the app
handshakes on in `10-hardware.md`:

| image | board | flashed by | port | load addr |
|---|---|---|---|---|
| `mainBoardGD.hex` | main board | `ISPCommand` | — | `0x08000000` |
| `eBoard.hex` | carriage extruder | `IAPCommand` | `/dev/ttyS5` | `0x08010000` |
| `heaterBoard.hex` | hotend heaters | `IAPCommand` | `/dev/ttyS4` | `0x08010000` |
| `levelBoard.hex` | under-bed cylinder | `IAPCommand` | `/dev/ttyS7` | `0x08004000` |
| `VDS_V1.0.1_0.hex` | VDS accessory | `firmwareExe`, from `/media/` | — | `0x08005000` |

`IAPCommand` and `ISPCommand` ship alongside them, so the flashing protocol is
in hand too. The `*_fail.img` and `mcu.img` files are 800×480 framebuffer
splash screens, not firmware. VDS is the only one that is not Klipper.

## Why this matters

Klipper stores its data dictionary — every command, response, config constant
and pin enumeration — zlib-compressed inside the image. Nothing has to be
disassembled to learn the wire protocol; it decompresses straight out.

| board | MCU | clock | commands | of those, upstream |
|---|---|---|---|---|
| levelBoard | N32G45x (reports `stm32f103xe`) | 128 MHz | 54 | 47 |
| eBoard | `stm32f103xe` | 144 MHz | 77 | 69 |
| heaterBoard | `stm32f103xe` | 144 MHz | 78 | 71 |
| mainBoardGD | `gd32h757zg` | 600 MHz | 49 | 37 |

The FlashForge delta is seven commands on the three STM32 boards —
`get_mcu_version`, `set_trigger_threshold`, `get_basic_param`, `remove_peel`,
`get_emcu_pa_value`, `pa_action`, `endstop_recover_state` — and their host
side is already in the fork we ship (`extras/ff_eddy.py`,
`extras/pa_adjust.py`). The GD32 main board has five of the seven plus seven
`mclib_*` commands of its own, for closed-loop steppers.

The FlashForge additions come from one shared source file with a board
selector: `get_emcu_pa_value` is a real function on the eBoard and a bare
`bx lr` on the levelBoard, while its reply stays in both dictionaries.

The *upstream* underneath that file is not shared, though. eBoard carries a
`config_lis2dw` that upstream only introduced in October 2024; heaterBoard
still has the form that predates it, despite being built three weeks earlier.
Each board is rebased on its own schedule, so a version fingerprint from one
board says nothing about another.

`tools/mcu-recovery/` reconstructs the levelBoard source from upstream Klipper
`6d70050` plus a 318-line patch, and `build.sh` gates the rebuild on producing
the stock dictionary. It does; the machine code is ~8.8 KiB smaller, because
the eddy front end (ADC1 over DMA1 ch1, SPI2 side channel), the DMA serial
path and the board telemetry counters were not reconstructed. See that
directory's README for the full accounting.

## Two things found on the way

**`endstop_recover_state` cannot reply.** The handler calls
`ctr_lookup_encoder()` directly with a string literal instead of going through
Klipper's `sendf()` macro. That skips the `DECL_CTR` marker, so the reply
format is never registered as a response: the lookup returns NULL at run time
and the reply goes to `command_sendf(NULL, ...)`. FlashForge's own klippy
sends this command — `MCU_endstop._recover_cmd` in `klippy/mcu.py` — and all
three boards that carry it are affected.

**`RESERVE_PINS_serial` is `PH10,PH9`.** Upstream says `PA10,PA9` for USART1.
Port H does not exist on this family and does not appear in the image's own
pin enumeration, so the reservation silently matches nothing and PA9/PA10 stay
allocatable from `printer.cfg`. Deliberate, as far as anyone can tell from the
image.
