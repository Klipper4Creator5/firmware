#!/bin/sh
# Install the mod the way a user installs it, and stop.
#
# NOTHING HERE RE-IMPLEMENTS THE UPDATE. The package is on a genuine FAT
# filesystem exposed as /dev/sda1, and the thing that finds it, mounts it,
# decrypts it and installs it is the machine's OWN /usr/prog/app_startup.sh,
# run verbatim, exactly as /etc/init.d runs it at boot. This script starts that
# and waits for it to finish; it makes no decisions and asserts nothing.
#
# That distinction is the whole reason this file replaced an earlier
# install-payload.sh, which copied payload/*.sh and payload/init.d/S* into
# place by hand. Hand-placing is a SECOND implementation of the install, so the
# tests downstream of it asserted against a layout the harness had built rather
# than one the installer produced -- and the real installer could have broken
# without a single test noticing. case-install.sh's header records the same
# lesson being learned once already:
#
#     An earlier version of this file replayed app_startup.sh by hand -- which
#     meant a bug in our reading of it could never be caught.
#
# Installing for real also means the payload under test is the built package:
# the cross-compiled s6, the CPython 3.13, the Klipper extras, staged by
# bin/patch.sh exactly as they ship. Nothing has to be stood in for.
#
# On the printer a successful install ends in `sleep 100000`, waiting for the
# user to power-cycle. That is the signal this waits for.
set -e

APP=/usr/prog/app_startup.sh

[ -b /dev/sda1 ] || { echo "install: no /dev/sda1 -- no stick was attached" >&2; exit 1; }
[ -f "$APP" ]    || { echo "install: no $APP -- is there a stock baseline?" >&2; exit 1; }

# busybox 1.31.1 here has no `timeout` applet, so the wait is bounded by hand.
wait_for() {            # wait_for <seconds> <command...>
    limit=$1; shift
    n=0
    while [ "$n" -lt "$limit" ]; do
        "$@" && return 0
        sleep 2; n=$((n+2))
    done
    return 1
}

# NOT `ps | grep`: busybox ps truncates COMMAND to 80 columns when there is no
# tty, and under qemu every command line is prefixed with
# "/usr/bin/qemu-mipsel-static ", which pushes the interesting part off the
# end. `ps | grep 'sleep 100000'` therefore never matches and the wait sits
# there until it times out on an install that actually succeeded. /proc is
# exact, and `case` is a builtin so this cannot match itself.
running() {
    for _p in /proc/[0-9]*; do
        _c=$( { tr '\0' ' ' < "$_p/cmdline"; } 2>/dev/null )   # may exit mid-scan
        case "$_c" in *"$1"*) return 0 ;; esac
    done
    return 1
}
installed() { running 'sleep 100000'; }
exited()    { ! kill -0 "$BOOTPID" 2>/dev/null; }
settled()   { installed || exited; }

echo "install: booting $APP with the package on /dev/sda1"
sh "$APP" > /tmp/install.log 2>&1 &
BOOTPID=$!

if ! wait_for "${INSTALL_TIMEOUT:-900}" settled; then
    echo "install: app_startup.sh never settled -- last 40 lines:" >&2
    tail -40 /tmp/install.log >&2
    kill "$BOOTPID" 2>/dev/null
    exit 1
fi

if installed; then
    RESULT=installed
else
    RESULT=completed
fi

kill "$BOOTPID" 2>/dev/null || true
killall sleep 2>/dev/null || true

# `completed` means app_startup.sh fell through to a normal boot instead of
# reaching the post-install wait -- it did not find or did not accept the
# package. Baking an image from that would produce a "machine with the mod
# installed" that has no mod on it, and every test downstream would then be
# asserting against the stock firmware while believing otherwise.
if [ "$RESULT" != installed ]; then
    echo "install: app_startup.sh did not install the package (it fell through" >&2
    echo "         to a normal boot). Last 40 lines:" >&2
    tail -40 /tmp/install.log >&2
    exit 1
fi

echo "install: the machine's own updater installed the package"
