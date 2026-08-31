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
# THE LIVE STATE HAS TO BE RECONCILED, not left alone. s6-rc-init writes
# /run/s6-rc/state as one byte per service in the database it booted, and
# /run/s6-rc/compiled is a symlink to compiled/current -- so moving `current`
# under a running system leaves a state file whose size no longer matches the
# database, and every `s6-rc` command fails with "unable to read valid state"
# until the next boot. Supervision itself survives (s6-svscan and s6-supervise
# are a separate mechanism, and s6-svstat/s6-svc keep working), which is what
# makes the breakage quiet enough to ship without noticing. It shipped once,
# 2026-08-31.
#
# s6-rc-update is the supported answer: it migrates the live state onto the new
# database, leaving services whose definitions did not change running. Ones
# that DID change are restarted, which is the honest cost of applying an
# upgrade to a running machine -- and is why an upgrade is not a thing to do
# mid-print.
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

# Reconcile a running system BEFORE `current` moves. s6-rc-update reads the
# database the live directory is on to know what it is migrating FROM, and
# /run/s6-rc/compiled is a symlink to compiled/current -- so flipping first
# leaves it comparing the new database against itself. Ask the migration to
# happen while the old database is still the current one.
#
# LIVE's absence is the ordinary case: the payload build, and a printer that
# has not booted this far. A failure is reported and not fatal -- the database
# on disk is right either way, and a reboot applies it.
LIVE=/run/s6-rc
UPDATE=$MODDIR/bin/s6-rc-update
if [ -d "$LIVE" ] && [ -x "$UPDATE" ]; then
    if "$UPDATE" -l "$LIVE" "$COMPILED/$DB"; then
        echo "s6-rc-compile: live state migrated to $DB"
    else
        echo "s6-rc-compile: !! could not migrate the live state to $DB" >&2
        echo "s6-rc-compile:    reboot to come up on it" >&2
    fi
elif [ -d "$LIVE" ]; then
    echo "s6-rc-compile: no $UPDATE -- reboot to come up on $DB"
fi

# Now the next boot's database, whatever the migration did.
ln -sfn "$DB" "$COMPILED/current"

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
