#!/bin/sh
# Is every directory in ANVIL_LIBS actually load-bearing, and is every one
# that was taken out actually dead?
#
# WHY THIS EXISTS. ANVIL_LIBS is a measured list, not the union of what
# FlashForge exports, and a measurement has to be re-checked or it rots. Of the
# seven entries dropped, the only consumer of ffmpeg, x264, opencv, nim and
# libzip between them was FlashForge's own firmwareExe, which this mod replaces
# with a shell script; curl is reachable only through pycurl, which does not
# import on this firmware at all; and libsodium existed only for 3.8's libnacl,
# which nothing under $FF_PYTHON imports.
#
# WHO STILL USES THIS PATH AT ALL. Not Moonraker: it runs on our 3.13 now,
# proven mapping zero /usr/prog libraries in
# test/integration/printer/case-moonraker313-s6.sh. What is left on
# Python-3.8.2 is Klipper -- started by FlashForge's own
# /usr/prog/klipper/klipperDaemon, via start.sh, which sources this file and
# so hands its environment (LD_LIBRARY_PATH included) down to klippy as an
# inherited child-process variable, not a sourced one. So the three that
# remain are read as "what klippy's process tree needs", not "what every mod
# process needs" -- the premise this file measures changed with the switch,
# and says so rather than quietly keeping the old framing.
#
# So the list is three now, and a shorter list is only an improvement if it is
# still correct. Both halves of that are questions about behaviour, and both
# are answered here by running the printer's own interpreter rather than by
# reading anything:
#
#   THE THREE ARE REQUIRED. Each is removed from LD_LIBRARY_PATH one at a time
#   and something is made to fail: for Python-3.8.2 and openssl-1.0.2d the
#   interpreter does not start at all (openssl because libpython3.8.so.1.0
#   itself has DT_NEEDED on libssl.so.1.0.0 -- _ssl and zlib are BUILTIN and
#   statically linked in, so this has nothing to do with `import ssl`), for
#   libffi-3.4.4 it is `import ctypes`. These are the negative controls and
#   they carry the weight: without them this case would pass just as happily
#   against a list of forty directories.
#
#   THE SEVEN ARE DEAD. The strongest available check is not "nothing greps
#   for them" but that a process running on the three-entry path maps none of
#   the seven -- and then, so that this is a statement about the LIBRARIES
#   rather than about the path, that the same process handed the OLD
#   ten-entry path still maps none of them. /proc/PID/maps is the authority
#   on what a running process has loaded, so that is what is read. libsodium
#   gets its own check too: `import libnacl` must now FAIL on the three-entry
#   path, because a leftover working path would mean the removal did not
#   actually take.
#
# And that the printer still works on three: the interpreter runs and ctypes
# imports. Moonraker's own component set belongs to Moonraker's own
# interpreter, checked in case-moonraker313-s6.sh -- the printer never runs
# Moonraker on Python-3.8.2.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
skip() { echo "  SKIP  $*"; }
note() { echo "  ..    $*"; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
PY=/usr/prog/Python-3.8.2/bin/python3

# THE SEVEN THAT WENT, written down here because they are deliberately absent
# from the shipped file and so cannot be read out of it. If one is ever put
# back, this list and the check at section 6 are what make somebody say out
# loud which process maps it.
GONE="/usr/prog/curl-7.55.1/lib
/usr/prog/ffmpeg-402/lib
/usr/prog/x264/lib
/usr/prog/opencv-4.2/lib
/usr/prog/nim/lib
/usr/prog/libzip-1.10.1/lib
/usr/prog/libsodium/lib"

[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }
[ -x "$PY" ] || { bad "no interpreter at $PY"; exit 1; }

# ---- install the payload, as run-append.sh does ----------------------------
mkdir -p $MODDIR/init.d
cp -f $PAYLOAD/anvil-env.sh $MODDIR/ 2>/dev/null
[ -f $MODDIR/anvil-env.sh ] || { bad "the payload ships no anvil-env.sh"; exit 1; }
ok "payload installed to $MODDIR"

# ---- 1. the environment is load-bearing at all -----------------------------
# If the interpreter runs with no LD_LIBRARY_PATH whatsoever then this whole
# file measures nothing: every "it failed without X" below would have to be
# read as "it failed for some other reason".
if env -u LD_LIBRARY_PATH "$PY" -c 'pass' >/dev/null 2>&1; then
    bad "the interpreter runs with NO LD_LIBRARY_PATH -- nothing below is a real negative control"
else
    ok "without LD_LIBRARY_PATH the interpreter does not start -- the path is load-bearing"
fi

# ---- 2. what the shipped file actually exports -----------------------------
# Read out of the installed file by SOURCING it, not by grepping it: the
# question is what a caller gets, and a caller sources it.
. $MODDIR/anvil-env.sh
THREE="$LD_LIBRARY_PATH"
note "LD_LIBRARY_PATH after sourcing anvil-env.sh: $THREE"

for d in /usr/prog/Python-3.8.2/lib /usr/prog/openssl-1.0.2d/lib \
         /usr/prog/libffi-3.4.4/lib; do
    if [ ! -d "$d" ]; then
        skip "$d does not exist on this printer"
        continue
    fi
    case ":$THREE:" in
        *":$d:"*) ok "$d is exported" ;;
        *)        bad "$d is NOT exported -- something the mod runs will not start" ;;
    esac
done

# And none of the seven. This is the cheap half of the claim -- section 6 is
# the half that means something -- but a path that still carries them would
# make section 6 pass for the wrong reason, so it is asked first.
for d in $GONE; do
    case ":$THREE:" in
        *":$d:"*) bad "$d is back on the path with nothing shown to map it" ;;
        *)        ok "$d is not on the path" ;;
    esac
done

# ---- 3. the three, taken away one at a time --------------------------------
# The point of each entry, stated as the failure that happens without it. Each
# probe is chosen to be the FIRST thing that breaks, so that a pass here means
# the entry is required and not merely present:
#
#   Python-3.8.2    the interpreter cannot load libpython3.8.so.1.0
#   openssl-1.0.2d  the interpreter cannot load libssl.so.1.0.0, which
#                   libpython itself needs -- so it dies before running code
#   libffi-3.4.4    the interpreter is fine and `import ctypes` is not
#
# A "without it, still fine" result is not a harness problem to route around:
# it is this gate saying the entry is cargo and should go the way the seven did.
without() {
    echo "$THREE" | tr ':' '\n' | grep -v "^$1\$" | tr '\n' ':' | sed 's/:*$//'
}

drop_check() {
    _dir=$1; _probe=$2; _what=$3
    if [ ! -d "$_dir" ]; then
        skip "$_dir is not installed here -- cannot take it away"
        return
    fi
    _path=`without "$_dir"`
    if [ "$_path" = "$THREE" ]; then
        bad "removing $_dir from the path changed nothing -- this control is broken"
        return
    fi
    if LD_LIBRARY_PATH="$_path" "$PY" -c "$_probe" >/tmp/drop.out 2>&1; then
        bad "WITHOUT $_dir, $_what still worked -- that entry is cargo"
    else
        ok "without $_dir, $_what fails -- \"`tail -1 /tmp/drop.out | cut -c1-90`\""
    fi
}

echo
echo "--- 3. negative controls: each entry removed on its own ---"
drop_check /usr/prog/Python-3.8.2/lib   'pass'            "starting the interpreter"
drop_check /usr/prog/openssl-1.0.2d/lib 'pass'            "starting the interpreter"
drop_check /usr/prog/libffi-3.4.4/lib   'import ctypes'   "import ctypes"

# The two interpreter-does-not-start controls above are the same observation
# twice unless openssl fails for its OWN reason, so the reason is asked for
# directly: libpython3.8.so.1.0 has DT_NEEDED on libssl.so.1.0.0, and the
# rootfs has only libssl.so.1.1, which is a different soname and cannot
# satisfy it. readelf is not on every busybox, so this degrades to strings and
# then skips -- it is corroboration, and section 3 is the measurement.
LIBPY=/usr/prog/Python-3.8.2/lib/libpython3.8.so.1.0
if [ -f "$LIBPY" ]; then
    if command -v readelf >/dev/null 2>&1; then
        if readelf -d "$LIBPY" 2>/dev/null | grep -q 'libssl\.so\.1\.0\.0'; then
            ok "readelf: libpython3.8.so.1.0 has DT_NEEDED on libssl.so.1.0.0 -- the interpreter itself needs it, nothing to do with import ssl"
        else
            bad "readelf: libpython3.8.so.1.0 does NOT need libssl.so.1.0.0 -- then why did the openssl control fail?"
        fi
    elif command -v strings >/dev/null 2>&1; then
        strings "$LIBPY" 2>/dev/null | grep -q '^libssl\.so\.1\.0\.0$' \
            && ok "strings: libpython3.8.so.1.0 names libssl.so.1.0.0" \
            || skip "strings found no libssl.so.1.0.0 in libpython -- section 3 is the measurement either way"
    else
        skip "no readelf or strings here -- section 3 stands on its own"
    fi
fi

# ---- 4. on the three-entry path, the things klippy needs still work -------
echo
echo "--- 4. and the three-entry path is enough ---"
"$PY" -c 'print("interpreter ok")' >/tmp/three.out 2>&1
grep -q '^interpreter ok' /tmp/three.out \
    && ok "the interpreter starts on the three-entry path" \
    || bad "the interpreter does not start on the shipped path: `tail -1 /tmp/three.out`"

"$PY" -c 'import ctypes; print("ctypes ok")' >/tmp/three-ctypes.out 2>&1
grep -q '^ctypes ok' /tmp/three-ctypes.out \
    && ok "import ctypes works -- libffi.so.8 was found" \
    || bad "import ctypes failed on the shipped path: `tail -1 /tmp/three-ctypes.out`"

# The negative control for the removal itself: libsodium came off ANVIL_LIBS
# in the same commit that moved FF_PYTHON to 3.13, on the strength of the
# claim that nothing left running on 3.8.2 imports libnacl. If that claim were
# wrong, this would still pass -- FlashForge's own libsodium.so.18 might be
# reachable some other way -- so this is what makes the claim fall over if it
# is false, rather than just not being contradicted.
"$PY" -c 'import libnacl' >/tmp/three-nacl.out 2>&1
if [ $? -ne 0 ]; then
    ok "import libnacl fails on the three-entry path -- the libsodium removal took: `tail -1 /tmp/three-nacl.out | cut -c1-70`"
else
    bad "import libnacl still WORKS on the three-entry path -- libsodium is reachable from somewhere and the removal did not take"
fi

# ---- 6. the seven, proved dead by /proc/PID/maps ---------------------------
# A running python is asked what it has actually loaded. The probe imports the
# thing klippy's process tree still needs -- ctypes -- and then sits still so
# its maps can be read.
#
# TWICE, and the second run is the one that matters. On the three-entry path,
# "none of the seven is mapped" is nearly a tautology: they are not on the
# path, so of course nothing found them. So the same probe is run again with
# the OLD TEN-ENTRY path -- every directory available to it, exactly as before
# this change -- and if it still maps none of the seven, then removing them
# took nothing away from any process this mod starts. That is the claim.
echo
echo "--- 6. /proc/PID/maps: what a real process loads ---"
cat > /tmp/libprobe.py <<'EOPROBE'
# Import what klippy's process tree still needs, then hold still.
import sys, time
import ctypes                                        # noqa: F401
sys.stdout.write("probe up\n")
sys.stdout.flush()
time.sleep(300)
EOPROBE

OLDTEN="/usr/prog/Python-3.8.2/lib:/usr/prog/openssl-1.0.2d/lib:/usr/prog/curl-7.55.1/lib:/usr/prog/ffmpeg-402/lib:/usr/prog/x264/lib:/usr/prog/libffi-3.4.4/lib:/usr/prog/libsodium/lib:/usr/prog/opencv-4.2/lib:/usr/prog/nim/lib:/usr/prog/libzip-1.10.1/lib"

maps_of() {
    # Start the probe on the given LD_LIBRARY_PATH, wait for it to say it is
    # up, and leave its maps in /tmp/probe.maps. Echoes the pid, or nothing.
    _out=/tmp/probe.$$.out
    rm -f $_out /tmp/probe.maps
    LD_LIBRARY_PATH="$1" "$PY" /tmp/libprobe.py > $_out 2>&1 &
    _pid=$!
    _w=0
    while [ $_w -lt 90 ]; do
        grep -q '^probe up' $_out 2>/dev/null && break
        kill -0 $_pid 2>/dev/null || break
        sleep 2
        _w=$((_w + 2))
    done
    if ! grep -q '^probe up' $_out 2>/dev/null; then
        kill -9 $_pid 2>/dev/null
        return 1
    fi
    cp /proc/$_pid/maps /tmp/probe.maps 2>/dev/null
    kill -9 $_pid 2>/dev/null
    [ -s /tmp/probe.maps ]
}

check_maps() {
    _label=$1
    # POSITIVE CONTROL FOR THE METHOD. If /proc/PID/maps carried no /usr/prog
    # library at all -- an unreadable maps, a probe that died, a kernel that
    # reports nothing -- then "none of the seven is mapped" would be true of a
    # file that says nothing about anything. libpython is the one library this
    # process cannot be running without.
    if grep -q '/usr/prog/Python-3.8.2/lib/libpython3\.8\.so' /tmp/probe.maps; then
        ok "$_label: the probe maps libpython3.8.so.1.0 -- maps is telling us what is loaded"
    else
        bad "$_label: the probe's maps has no libpython in it -- this measurement is worthless"
        return
    fi
    note "$_label: `grep -c /usr/prog /tmp/probe.maps` mapped regions under /usr/prog"
    _hits=""
    for d in $GONE; do
        grep -qF "$d/" /tmp/probe.maps && _hits="$_hits $d"
    done
    if [ -z "$_hits" ]; then
        ok "$_label: none of the seven removed directories is mapped"
    else
        bad "$_label: still mapped, so they were NOT dead:$_hits"
    fi
}

if maps_of "$THREE"; then
    check_maps "on the three shipped entries"
else
    bad "the probe never came up on the shipped path -- see /tmp/probe.$$.out"
fi

# The one that means something: everything on the path, and still nothing
# reaches for the seven.
if maps_of "$OLDTEN"; then
    check_maps "with the OLD ten-entry path"
    # And the same process, on the same path, does map libffi -- so the seven
    # were not skipped because the loader gave up early.
    _miss=""
    for d in /usr/prog/libffi-3.4.4/lib; do
        [ -d "$d" ] || continue
        grep -qF "$d/" /tmp/probe.maps || _miss="$_miss $d"
    done
    [ -z "$_miss" ] \
        && ok "with the OLD ten-entry path the probe does map libffi -- it was loading libraries, it just never wanted the seven" \
        || note "not mapped by this probe:$_miss (this tree may not import the component that needs them)"
else
    bad "the probe never came up on the old ten-entry path -- the interesting half of section 6 did not run"
fi

echo
[ $FAIL = 0 ] && echo "libpath: all checks passed" || echo "libpath: FAILURES"
exit $FAIL
