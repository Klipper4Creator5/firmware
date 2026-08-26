#!/bin/sh
# Do our init.d services all behave like the same kind of thing?
#
# WHY THIS EXISTS -- the five services used to be five one-off scripts. Each
# had grown its own way of asking "is it running" (a pidfile and kill -0, a
# `ps | grep`, a `pgrep -f` with a ps fallback, a socket test), its own
# spelling of the log lines, and its own `case "$1"` block with subtly
# different verbs and exit codes. Two real bugs lived in that drift: a stop
# that returned before the process was gone, so the restart that followed saw
# it still in the process table and declined to start anything; and a status
# that read a socket klippy does not unlink on exit, so a dead klippy reported
# itself running and `restart` did nothing at all.
#
# anvil-service.sh exists to make those one decision each instead of five.
# This gate is what stops them drifting apart again. It is deliberately NOT a
# grep over the scripts -- that would pass on a service that cannot start
# anything and fail on a rename. It installs the payload and RUNS every
# service, on the printer's own busybox, and asserts on what came back.
#
# What it does NOT do is start real daemons: that is case-moonraker.sh's job
# for the web stack, and wifi/camera/klipper need hardware the replica has
# none of. What is checked here is the contract every service shares --
# it loads its library, it answers `status` without blowing up, it names
# itself in what it prints, and it rejects a verb it does not know with a
# usage line and exit 1.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
SERVICES="S50wifi S60nginx S62moonraker S65camera S70klipper S80ui"

[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }

# ---- install the payload, as run-append.sh does ----------------------------
mkdir -p $MODDIR/init.d
cp -f $PAYLOAD/anvil-env.sh $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/anvil-service.sh $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/init.d/S* $MODDIR/init.d/ 2>/dev/null
chmod +x $MODDIR/init.d/S* 2>/dev/null

# The library is sourced, never executed, so bin/patch.sh stages it with a
# plain cp and no chmod +x. It once did not stage it at all, which would have
# made every service below abort at boot -- hence checking for it by itself,
# before anything tries to use it.
[ -f $MODDIR/anvil-service.sh ] \
    && ok "the payload ships anvil-service.sh" \
    || { bad "the payload ships no anvil-service.sh -- every service aborts"; exit 1; }

for s in $SERVICES; do
    [ -x $MODDIR/init.d/$s ] || { bad "$s is missing or not executable"; continue; }

    out=`$MODDIR/init.d/$s status 2>&1`
    rc=$?
    case "$out" in
        *"no /usr/data/anvil/anvil-service.sh"*)
            bad "$s cannot find its library at runtime" ;;
        "")
            bad "$s status printed nothing (rc=$rc) -- a service must always answer" ;;
        *)
            ok "$s status -> `echo "$out" | head -1`" ;;
    esac

    # One dispatcher means one answer to a verb nobody implements. Getting
    # this wrong is how a typo in a boot script becomes a silent no-op.
    uout=`$MODDIR/init.d/$s bogusverb 2>&1`
    urc=$?
    if [ $urc -eq 1 ] && echo "$uout" | grep -q "usage:"; then
        ok "$s rejects an unknown verb with a usage line and exit 1"
    else
        bad "$s: unknown verb gave rc=$urc, output: $uout"
    fi
done

# S70klipper is the one service with a verb of its own. force-start exists
# because start() normally stands aside for bin/ff-startup.py, and the
# firmwareExe wrapper needs a way to say "no, actually start it" when that
# program returned and left no klippy behind. If the shared dispatcher ever
# swallows it, the printer loses its last-resort path to a running Klipper.
$MODDIR/init.d/S70klipper bogusverb 2>&1 | grep -q "force-start" \
    && ok "S70klipper still advertises its extra force-start verb" \
    || bad "S70klipper lost force-start from its usage line"

# Every line a service prints is "name: something". It is what makes a boot
# log readable when five services are interleaving their output -- and the
# services background their slow work precisely so that they DO interleave.
for s in $SERVICES; do
    first=`$MODDIR/init.d/$s status 2>&1 | head -1`
    echo "$first" | grep -qE "^(wifi|nginx|moonraker|camera|klipper|ui)" \
        && ok "$s names itself in its output" \
        || bad "$s output is unprefixed: $first"
done

echo
[ $FAIL -eq 0 ] && echo "  init.d services: all checks passed"
exit $FAIL
