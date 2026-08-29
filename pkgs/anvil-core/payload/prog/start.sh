#!/bin/sh
# /usr/prog/klipper/start.sh
#
# Kept as close to stock as possible. The web stack is NOT started here even
# though stock has the (commented-out) lines for it -- that is the job of
# /usr/data/anvil/init.d/S60nginx and /usr/data/anvil/init.d/S62moonraker, so
# there is exactly one place that starts each of them and one place to restart
# them from over ssh. They were a single S60web until the split; nginx and
# moonraker fail independently and are now stopped and started independently.
#
# Three changes from stock:
#   * klipper_pri.sh is actually invoked. FlashForge ships that script but
#     never calls it, so klippy runs at normal priority.
#   * ff_mcu_bringup.py hands the heat, eboard and level boards over from
#     their bootloaders. Stock never needed it here because firmwareExe did
#     all three itself; replacing firmwareExe left two of them stranded, and
#     the third was covered by checkEboard.
#   * checkEboard is deliberately not called. It is one function, hard wired
#     to /dev/ttyS5, and an older build of the routine ff_mcu_bringup.py
#     reimplements -- one that treats ANY byte from that port as a bootloader
#     banner and so sends 'A' at an eboard already running Klipper. The binary
#     is still on the firmware partition; nothing runs it.
#   * the /tmp/uds idempotence guard below, so S70klipper's retry loop cannot
#     start a second klippy against the same MCU.

cmd_mcu write_firmware /usr/prog/libmcu-bare.bin
cmd_mcu bootup
sleep 2

# PATH, LD_LIBRARY_PATH and FF_PYTHON, from the one file that defines them.
# This script is on the firmware partition and the env file is on the data
# partition, which is the right way round: the list describes /usr/prog and
# the mod owns it. See anvil-env.sh.
MODDIR=/usr/data/anvil
if [ -f $MODDIR/anvil-env.sh ]; then
    . $MODDIR/anvil-env.sh
else
    echo "start.sh: !! no $MODDIR/anvil-env.sh -- klippy will not find its libraries"
fi

# Idempotence guard: init.d/S70klipper runs this script, and so does its own
# retry loop. Running it twice would start a second klippy against the same
# MCU.
if [ -S /tmp/uds ]; then
    echo "start.sh: klippy already running, nothing to do"
    exit 0
fi

# MCU bring-up. Each of these boards answers Klipper only after its
# bootloader is told to start the application:
#
#   /dev/ttyS2  mcu           cmd_mcu bootup, above
#   /dev/ttyS4  eheaterboard  ff_mcu_bringup.py   <- was nobody's job
#   /dev/ttyS5  eboard        ff_mcu_bringup.py   <- was checkEboard
#   /dev/ttyS7  levelboard    ff_mcu_bringup.py   <- was nobody's job
#
# This runs on every klippy start, including the restarts S70klipper issues
# when a board missed its window.
#
# $FF_PYTHON is the absolute path anvil-env.sh sets, with no `python3`
# fallback: the base rootfs ships no other interpreter, so a fallback would
# resolve either to the same binary or to something untested. LD_LIBRARY_PATH
# matters too -- this interpreter does not start without it.
#
# Test -f, not -x. The script is handed to the interpreter by path, so its
# execute bit is irrelevant -- and it is not always set: the payload carries
# mode 644 in git, and the +x only happens if the file arrived through
# patch.sh or run-append.sh. A hand-copied file is perfectly runnable.
#
# FF_SKIP_MCU_BRINGUP=1 says the caller has already done it. bin/ff-startup.py
# sets that: it owns the boot sequence, so it does the bring-up itself, in
# process, and then runs this script to launch klippy. Nothing else sets it,
# so a start.sh run by hand over ssh -- or by S70klipper's fallback -- still
# does the full job.
if [ "${FF_SKIP_MCU_BRINGUP:-0}" = 1 ]; then
    echo "start.sh: MCU bring-up already done by the caller"
elif [ -f /usr/data/anvil/bin/ff_mcu_bringup.py ]; then
    "$FF_PYTHON" /usr/data/anvil/bin/ff_mcu_bringup.py \
        || echo "start.sh: MCU bring-up reported a problem ($?)"
else
    echo "start.sh: ff_mcu_bringup.py missing -- the toolhead boards are not brought up"
fi
/usr/prog/klipper/klipperDaemon start

# Real-time priority for klippy (stock ships this but never runs it).
sh /usr/prog/klipper/klipper_pri.sh >/dev/null 2>&1 &
