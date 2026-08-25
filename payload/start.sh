#!/bin/sh
# /usr/prog/klipper/start.sh
#
# Kept as close to stock as possible. The web stack is NOT started here even
# though stock has the (commented-out) lines for it -- that is the job of
# /usr/data/anvil/init.d/S60web, so there is exactly one place that starts
# nginx and moonraker and one place to restart them from over ssh.
#
# Three changes from stock:
#   * klipper_pri.sh is actually invoked. FlashForge ships that script but
#     never calls it, so klippy runs at normal priority.
#   * ff_mcu_bringup.py hands the heat, eboard and level boards over from
#     their bootloaders. Stock never needed it here because firmwareExe did
#     all three itself; replacing firmwareExe left two of them stranded, and
#     the third was covered by checkEboard.
#   * checkEboard is no longer called. It is one function, hard wired to
#     /dev/ttyS5, and an older build of the routine ff_mcu_bringup.py already
#     reimplements -- one that treats ANY byte from that port as a bootloader
#     banner and so sends 'A' at an eboard already running Klipper. The
#     binary is still on the firmware partition; nothing runs it.
#   * the /tmp/uds idempotence guard below, so S70klipper's retry loop cannot
#     start a second klippy against the same MCU.

cmd_mcu write_firmware /usr/prog/libmcu-bare.bin
cmd_mcu bootup
sleep 2

export PATH=$PATH:/usr/prog/Python-3.8.2/bin
export LD_LIBRARY_PATH=/usr/prog/Python-3.8.2/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/prog/libffi-3.4.4/lib:$LD_LIBRARY_PATH

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
# Call the interpreter by absolute path. PATH is exported above and the base
# rootfs ships no other python3, so a bare `python3` would resolve -- but this
# is the one step Klipper cannot start without, so do not depend on a lookup.
# LD_LIBRARY_PATH still matters: this interpreter does not start without it,
# which is exactly how moonrakerDaemon used to fail.
FF_PYTHON=/usr/prog/Python-3.8.2/bin/python3
[ -x "$FF_PYTHON" ] || FF_PYTHON=python3
#
# Test -f, not -x. The script is handed to the interpreter by path, so its
# execute bit is irrelevant -- and it is not always set: the payload carries
# mode 644 in git, and the +x only happens if the file arrived through
# patch.sh or run-append.sh. A hand-copied file is perfectly runnable and
# used to be skipped with a "missing" message while sitting right there.
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
