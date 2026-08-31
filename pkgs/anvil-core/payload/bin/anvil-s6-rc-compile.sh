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
# NOTHING LIVE IS TOUCHED. s6-rc reads the database at boot; a running
# supervision tree keeps the one it started with until the printer is
# rebooted. That is deliberate -- switching a live tree over would restart
# services, and an `opkg upgrade` is not a thing that should stop a print.
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

# Compile first, flip second. A half-written database that `current` never
# pointed at is one the next boot ignores; the reverse loses the printer.
"$COMPILE" "$COMPILED/$DB" "$SRC"
ln -sfn "$DB" "$COMPILED/current"
echo "s6-rc-compile: $DB -- $(ls "$SRC" | wc -l) definitions"

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
