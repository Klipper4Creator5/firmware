#!/bin/sh
# Compile the s6-rc boot database from the service definitions, and point
# `current` at the result.
#
# THE DATABASE IS GENERATED, NOT SHIPPED. anvil-core carries
# etc/s6-rc/source/ as text -- see its build.sh for why the recipe does not
# compile it -- so something has to run s6-rc-compile over that tree before a
# boot can use it. On the .tgz path that something is the payload build; on a
# printer it is the postinst of each package that can change the answer:
#
#   anvil-core    owns the definitions
#   anvil-s6-rc   owns the compiler, whose execline shebang and oneshot runner
#                 every database it writes bakes in
#
# All three call this file, so there is one implementation of the compile
# rather than one per caller.
#
#     anvil-s6-rc-compile.sh [db-name]
#
# WITH A NAME the compile is deterministic and every other database is removed:
# that is the payload build, whose output has to be byte-identical between two
# builds of one commit. WITHOUT ONE the name is a timestamp and the database
# that was current is kept, so a printer that will not boot the new one still
# has the old one on disk to point `current` back at.
#
# A NEW DATABASE REACHES THE PRINTER AT THE NEXT BOOT, not when this runs.
# Nothing running is stopped or started; the cost is that `s6-rc` itself is
# unusable in between, which the tail of this script explains.
set -e

MODDIR=${MODDIR:-/usr/data/anvil}
SRC=$MODDIR/etc/s6-rc/source
COMPILED=$MODDIR/etc/s6-rc/compiled
COMPILE=$MODDIR/bin/s6-rc-compile

WANT=${1:-}

# Not an error, and not a guess about install order: opkg runs the two
# postinsts in whichever order the dependency graph gives it, and the first of
# them has only half of what a compile needs. The second does the work.
if [ ! -d "$SRC" ]; then
    echo "s6-rc-compile: no $SRC yet -- nothing to compile"
    exit 0
fi
if [ ! -x "$COMPILE" ]; then
    echo "s6-rc-compile: no $COMPILE yet -- nothing to compile with"
    exit 0
fi

if [ -n "$WANT" ]; then
    DB=$WANT
else
    DB=db-$(date +%Y%m%d%H%M%S)
fi

PREV=$(readlink "$COMPILED/current" 2>/dev/null || true)

mkdir -p "$COMPILED"
rm -rf "$COMPILED/$DB"

# Compile into its final name. Nothing points at it yet, so a half-written
# database is one the next boot ignores.
"$COMPILE" "$COMPILED/$DB" "$SRC"
echo "s6-rc-compile: $DB -- $(ls "$SRC" | wc -l) definitions"

ln -sfn "$DB" "$COMPILED/current"

# THE LIVE STATE IS NOT MIGRATED, AND THIS IS NOT AN OVERSIGHT. Moving
# `current` under a running system leaves /run/s6-rc/state -- one byte per
# service in the database that booted -- the wrong size for the database
# /run/s6-rc/compiled now resolves to, so `s6-rc` reports "unable to read
# valid state" until the next boot. Supervision is a separate mechanism and
# keeps every service running, so the printer is fine; only s6-rc itself is
# unusable in the window.
#
# s6-rc-update exists to close that window and IS SHIPPED, for a hand at a
# prompt. It is not called from here because on this machine it does not work:
# from a state that had just booted cleanly it failed with
#
#     s6-rc-update: fatal: unable to manage new service directories
#                   in /run/s6-rc: Value too large for defined data type
#
# having ALREADY emptied the scandir -- every symlink under $MODDIR/etc/s6
# gone, while the supervisors it had started were still running. The next
# s6-svscan rescan would have taken down klipper, the UI and wifi together.
# An upgrade that can do that is worse than an s6-rc you cannot drive until
# you reboot. (Measured 2026-08-31; EOVERFLOW despite -D_FILE_OFFSET_BITS=64
# through skalibs, s6, execline and s6-rc, so the cause is not the obvious
# one and wants finding before this is wired up again.)
if [ -d /run/s6-rc ]; then
    echo "s6-rc-compile: reboot to come up on $DB"
fi

# Prune. `continue` is written as a full if rather than `[ x ] && continue`,
# which under set -e exits the script the first time the test is false.
for _d in "$COMPILED"/db-*; do
    [ -d "$_d" ] || continue
    _n=$(basename "$_d")
    if [ "$_n" = "$DB" ]; then
        continue
    fi
    if [ -z "$WANT" ] && [ "$_n" = "$PREV" ]; then
        continue
    fi
    rm -rf "$_d"
done

exit 0
