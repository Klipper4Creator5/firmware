#!/bin/sh
# /usr/prog/klipper/start.sh
#
# Klippy is an s6-rc longrun, so this asks for the service and the graph brings
# the MCU bring-up along. It is kept rather than deleted because it is a path
# other things take -- FlashForge's own tooling knows this filename, and it is
# in every set of notes anybody has written about this printer.
#
# There is deliberately no direct launch left here. One that still ran
# klipperDaemon would be a second way to start klippy: unsupervised, invisible
# to s6-rc, and fighting the supervised copy for /dev/ttyS4.
#
# bin/payload.sh stages this as a software component and FlashForge's own run.sh
# copies it onto /usr/prog/klipper, which is why it lives on the firmware
# partition and why a stock flash replaces it.
MODDIR=/usr/data/anvil

# This script is on the firmware partition and the env file is on the data
# partition, which is the right way round: the list describes /usr/prog and the
# mod owns it.
if [ -f $MODDIR/anvil-env.sh ]; then
    . $MODDIR/anvil-env.sh
else
    echo "start.sh: !! no $MODDIR/anvil-env.sh -- klippy will not find its libraries"
fi

# /tmp/uds is klippy's API socket. The transition below would also be a no-op
# on a running klippy, but it would not say so.
if [ -S /tmp/uds ]; then
    echo "start.sh: klippy already running, nothing to do"
    exit 0
fi

if [ ! -x $MODDIR/bin/s6-rc ]; then
    echo "start.sh: !! no $MODDIR/bin/s6-rc -- the mod payload is not installed"
    echo "start.sh: !! nothing here can start Klipper; flash the stock package to get it back"
    exit 1
fi
# The transition pulls mcu-bringup in first, because klipper depends on it.
# -t for the reason firmwareExe spells out: an infinite deadline is
# EOVERFLOW on a 32-bit time_t.
exec $MODDIR/bin/s6-rc -t 300000 -u change klipper
