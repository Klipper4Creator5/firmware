#!/bin/sh
# Check the prog partition is real, and create the few directories the stock
# installer expects to already exist.
#
# There is deliberately no fallback here. An earlier version stubbed out
# python3, nginx, the klipper daemons and OpenSSL when a real /usr/prog was
# missing, which meant a green test run could come from mocks -- exactly the
# kind of reassurance that is worse than no test at all. If the partition is
# not there, this fails.
set -e
R=/printer
ROOTFS=${ROOTFS:-/rootfs}

for f in klipper/klippy nginx/sbin/nginx Python-3.8.2/bin/python3 \
         openssl-1.0.2d/bin/openssl app_startup.sh; do
    [ -e "$R/usr/prog/$f" ] && continue
    echo "seed-prog: /usr/prog/$f is missing -- this is not a real prog partition." >&2
    echo "           Set PROG_DUMP to a factory image, or use a printer image that" >&2
    echo "           has one baked in. See docs/printer-replica.md." >&2
    exit 1
done

# Version directories the installer writes into. A factory image has the ones
# it shipped with, not necessarily all four.
mkdir -p $R/usr/prog/PROGRAM/software $R/usr/prog/PROGRAM/library \
         $R/usr/prog/PROGRAM/kernel $R/usr/prog/PROGRAM/control \
         $R/usr/data/config $R/usr/data/logs/NIM $R/usr/data/update

# /etc on the running printer is a bind mount of /usr/prog/etc, set up by
# app_startup.sh.
[ -f $R/usr/prog/etc/passwd ] || cp -a "$ROOTFS/etc/." $R/usr/prog/etc/ 2>/dev/null || true

[ -f $R/usr/prog/.SIMULATED ] || : > $R/usr/prog/.SIMULATED
if [ -z "${PROG_MB:-}" ] || [ -z "${DATA_MB:-}" ]; then
    echo '/usr/prog and /usr/data sizes (unbounded: set PROG_MB/DATA_MB from df -h on the printer)' \
        >> $R/usr/prog/.SIMULATED
fi

# A marker that must survive every install. Appended rather than written, so
# it works whether printer.cfg came from the factory image or not.
grep -q USER-CONFIG-MUST-SURVIVE $R/usr/data/config/printer.cfg 2>/dev/null \
    || echo '# USER-CONFIG-MUST-SURVIVE' >> $R/usr/data/config/printer.cfg

exit 0
