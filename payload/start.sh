#!/bin/sh
# /usr/prog/klipper/start.sh
#
# Kept as close to stock as possible. The web stack is NOT started here even
# though stock has the (commented-out) lines for it -- that is the job of
# /usr/data/anvil/init.d/S60web, so there is exactly one place that starts
# nginx and moonraker and one place to restart them from over ssh.
#
# Two changes from stock:
#   * klipper_pri.sh is actually invoked. FlashForge ships that script but
#     never calls it, so klippy runs at normal priority.
#   * ff-mcu-bringup.py hands the heat and level boards over from their
#     bootloaders. Stock never needed it here because firmwareExe did all
#     three boards itself; replacing firmwareExe left two of them stranded.

cmd_mcu write_firmware /usr/prog/libmcu-bare.bin
cmd_mcu bootup
sleep 2

export PATH=$PATH:/usr/prog/Python-3.8.2/bin
export LD_LIBRARY_PATH=/usr/prog/Python-3.8.2/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/prog/libffi-3.4.4/lib:$LD_LIBRARY_PATH

# Idempotence guard: firmwareExe runs this script, and so does
# init.d/S70klipper when the stock UI is not present. Running it twice would
# start a second klippy against the same MCU.
if [ -S /tmp/uds ]; then
    echo "start.sh: klippy already running, nothing to do"
    exit 0
fi

# MCU bring-up. Each of these boards answers Klipper only after its
# bootloader is told to start the application:
#
#   /dev/ttyS2  mcu           cmd_mcu bootup, above
#   /dev/ttyS4  eheaterboard  ff-mcu-bringup.py   <- was nobody's job
#   /dev/ttyS5  eboard        checkEboard
#   /dev/ttyS7  levelboard    ff-mcu-bringup.py   <- was nobody's job
#
# This runs on every klippy start, including the restarts S70klipper issues
# when a board missed its window. python3 is on PATH from the export above.
if [ -x /usr/data/anvil/bin/ff-mcu-bringup.py ]; then
    python3 /usr/data/anvil/bin/ff-mcu-bringup.py
fi
/usr/prog/klipper/checkEboard
/usr/prog/klipper/klipperDaemon start

# Real-time priority for klippy (stock ships this but never runs it).
sh /usr/prog/klipper/klipper_pri.sh >/dev/null 2>&1 &
