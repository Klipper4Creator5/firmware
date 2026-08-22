#!/bin/sh
# /usr/prog/klipper/start.sh
#
# Kept as close to stock as possible. The web stack is NOT started here even
# though stock has the (commented-out) lines for it -- that is the job of
# /usr/data/mod/init.d/S60web, so there is exactly one place that starts
# nginx and moonraker and one place to restart them from over ssh.
#
# The only change from stock: klipper_pri.sh is actually invoked. FlashForge
# ships that script but never calls it, so klippy runs at normal priority.

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

/usr/prog/klipper/checkEboard
/usr/prog/klipper/klipperDaemon start

# Real-time priority for klippy (stock ships this but never runs it).
sh /usr/prog/klipper/klipper_pri.sh >/dev/null 2>&1 &
