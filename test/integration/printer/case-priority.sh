#!/bin/sh
# Do the services actually start at the nice value anvil.conf asks for?
#
# WHY THIS EXISTS -- the mod added moonraker, nginx and the streamer to a
# two-core SoC that stock left to klippy alone (both lines are commented out in
# FlashForge's own start.sh). A host that misses Klipper's step deadlines does
# not print slowly, it stops: the MCU reports "Timer too close" and shuts down.
# NICE_MOONRAKER / NICE_CAM are the knobs that let those services yield.
#
# It is deliberately NOT a grep for "-N" in the scripts. Whether a nice level
# is really applied depends on the PRINTER's busybox accepting the option --
# this one is 1.31.1 and has no ionice applet at all, so option support here is
# a fact to be measured, not assumed. Every assertion below reads the value
# back out of /proc/<pid>/stat field 19, which is where the kernel keeps it.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
[ -d "$PAYLOAD" ] || PAYLOAD=/payload

[ -d "$PAYLOAD" ] || { bad "no payload mounted at /tmp/payload or /payload"; exit 1; }

mkdir -p $MODDIR
cp -f $PAYLOAD/anvil-service.sh $MODDIR/ || { bad "no anvil-service.sh"; exit 1; }
cp -f $PAYLOAD/anvil.conf       $MODDIR/ || { bad "no anvil.conf"; exit 1; }

SVC_NAME=priority-test
. $MODDIR/anvil-service.sh

# field 19 of /proc/<pid>/stat is the nice value
nice_of() { awk '{print $19}' /proc/$1/stat 2>/dev/null; }

# Start `sleep` through the real svc_start_daemon and report the nice value the
# kernel gave it. $1 is the SVC_NICE to use ("" = leave it unset entirely).
started_nice() {
    _pf=/tmp/prio-$$.pid
    rm -f $_pf
    if [ -z "$1" ]; then
        unset SVC_NICE
    else
        SVC_NICE="$1"
    fi
    svc_start_daemon $_pf /bin/sleep 300 >/dev/null 2>&1
    unset SVC_NICE
    # -b -m writes the pidfile after the fork; give it a moment on qemu.
    _w=0
    while [ ! -s $_pf ] && [ $_w -lt 10 ]; do sleep 1; _w=$((_w + 1)); done
    _p=$(cat $_pf 2>/dev/null)
    _n=$(nice_of $_p)
    [ -n "$_p" ] && kill $_p 2>/dev/null
    rm -f $_pf
    echo "${_n:-NONE}"
}

# ---- the knobs are shipped, with the documented defaults -------------------
for knob in NICE_MOONRAKER NICE_CAM; do
    if grep -q "^$knob=" $MODDIR/anvil.conf; then
        ok "anvil.conf ships $knob ($(grep "^$knob=" $MODDIR/anvil.conf))"
    else
        bad "anvil.conf has no $knob -- nothing can be tuned on the printer"
    fi
done

# ---- SVC_NICE unset must behave exactly as it did before it existed --------
n=$(started_nice "")
if [ "$n" = 0 ]; then
    ok "SVC_NICE unset -> nice 0 (unchanged behaviour)"
else
    bad "SVC_NICE unset -> nice $n, expected 0"
fi

# ---- 0 is the documented "disabled", and must not pass -N 0 as a level -----
n=$(started_nice 0)
if [ "$n" = 0 ]; then
    ok "SVC_NICE=0 -> nice 0 (disabled)"
else
    bad "SVC_NICE=0 -> nice $n, expected 0"
fi

# ---- and a real value has to actually reach the process --------------------
n=$(started_nice 7)
if [ "$n" = 7 ]; then
    ok "SVC_NICE=7 -> nice 7 (start-stop-daemon -N works on this busybox)"
else
    bad "SVC_NICE=7 -> nice $n, expected 7 -- -N not honoured here"
fi

# ---- the camera does not go through start-stop-daemon: it uses `nice` ------
# Same assertion, on the form S65camera's respawn loop actually runs.
NICE_CAM_TEST=$(grep "^NICE_CAM=" $MODDIR/anvil.conf | cut -d= -f2)
nice -n "${NICE_CAM_TEST:-10}" /bin/sleep 300 &
cam_pid=$!
_w=0
while [ ! -d /proc/$cam_pid ] && [ $_w -lt 10 ]; do sleep 1; _w=$((_w + 1)); done
n=$(nice_of $cam_pid)
if [ "$n" = "${NICE_CAM_TEST:-10}" ]; then
    ok "nice -n $NICE_CAM_TEST (the streamer's form) -> nice $n"
else
    bad "nice -n $NICE_CAM_TEST -> nice $n, expected $NICE_CAM_TEST"
fi
kill $cam_pid 2>/dev/null

[ $FAIL = 0 ] && echo "case-priority: OK" || echo "case-priority: FAILED"
exit $FAIL
