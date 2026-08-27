#!/bin/sh
# Does the first-boot screen actually draw, on the printer's own userland?
#
# ffscreen.py packs pixels by hand into a framebuffer. Nothing about that is
# provable by reading it, and the two things most likely to be wrong are
# exactly the two a Debian container would never catch:
#
#   * whether $MODDIR/bin/python3.13 -- our own cross-built interpreter,
#     running here under qemu-mipsel -- executes this code at all. FF_PYTHON
#     named FlashForge's 3.8.2 for this file's whole earlier life, so this
#     used to test THAT interpreter; the moonrakerDaemon lesson (reasoning
#     about compatibility was not enough) is why it still runs the real
#     interpreter rather than trusting that ffscreen.py's stdlib-only imports
#     are obviously fine on the new one.
#   * whether the bytes land where the arithmetic says. A stride or bpp error
#     produces a diagonally sheared screen, not an exception, so the check has
#     to be on the buffer itself.
#
# The replica's /dev/fb0 is a regular file, which is exactly what a
# framebuffer is from a writer's point of view, so this is the real code path.
# Geometry is passed EXPLICITLY: the replica mounts the host's /sys read-only,
# so a sysfs probe here would describe the developer's monitor. The numbers
# are the machine's real ones -- a PORTRAIT 480x800 framebuffer at 32bpp,
# shown on a landscape 800x480 panel turned 90 degrees clockwise. Both come
# from FlashForge's own /usr/prog/start.img, which is 1536000 bytes and only
# decodes into a picture when read that way.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }

MOD=/usr/data/anvil
# anvil-env.sh's own FF_PYTHON line reads $MODDIR, not $MOD -- this file's own
# variable name predates that and nothing here renames it, so without this
# alias FF_PYTHON resolves to the empty-prefix "/bin/python3.13" instead of
# $MOD/bin/python3.13.
MODDIR=$MOD
PY=$MOD/bin/python3.13
FB=/dev/fb0
W=480
H=800
BPP=32

mkdir -p $MOD/bin
# The interpreter FF_PYTHON resolves to -- a BUILD OUTPUT (work/.py313), not
# part of /tmp/payload, handed over as py.tgz. gates.py's boot_screen() Skips
# the whole case when nothing has built it, so reaching here without one is a
# harness bug, not an absent feature.
[ -f /mnt/py.tgz ] || { bad "no py.tgz mounted -- gates.py should have Skipped this case instead"; exit 1; }
gzip -dc /mnt/py.tgz | tar -x -C $MOD || { bad "cannot unpack py.tgz"; exit 1; }
for f in ffscreen.py ff-startup.py ff_mcu_bringup.py; do
    cp /tmp/payload/bin/$f $MOD/bin/$f 2>/dev/null
    if [ -f "$MOD/bin/$f" ]; then
        ok "payload ships bin/$f"
    else
        bad "payload does not carry bin/$f"
        exit 1
    fi
done
chmod +x $MOD/bin/ff-startup.py 2>/dev/null

if [ ! -x "$PY" ]; then
    bad "$PY is not executable after unpacking py.tgz -- the replica has no usable interpreter"
    exit 1
fi

# Exactly what start.sh and the firmwareExe wrapper get, by sourcing the same
# shipped file -- not retyped here, which is what let this drift from the real
# exports before. $MODDIR/bin/python3.13 needs no LD_LIBRARY_PATH entry at all
# (measured in case-python.sh and case-moonraker313-s6.sh), so an empty result
# here is the expected one, not a sign the file failed to source.
cp -f /tmp/payload/anvil-env.sh $MOD/ 2>/dev/null
[ -f $MOD/anvil-env.sh ] || { bad "the payload ships no anvil-env.sh"; exit 1; }
. $MOD/anvil-env.sh
[ "$FF_PYTHON" = "$PY" ] \
    && ok "anvil-env.sh resolves FF_PYTHON to $PY" \
    || bad "FF_PYTHON is '$FF_PYTHON', expected $PY"

# 1. the interpreter runs the importer at all. --help exits before any I/O,
#    so this is purely "does this 3.8 accept the syntax and the imports".
if "$PY" $MOD/bin/ff-startup.py --help >/tmp/help.out 2>&1; then
    ok "ff-startup.py runs under the printer's python"
else
    bad "ff-startup.py does not run: `cat /tmp/help.out`"
fi

# 2. it found BOTH siblings beside itself. Each import is optional by design,
#    so a missing one silently means "no screen" or "no bring-up" forever --
#    and the bring-up one would mean klippy opening ports at boards still
#    sitting in their bootloaders.
"$PY" -c "
import sys
sys.path.insert(0, '$MOD/bin')
import ffscreen
print('glyphs', len(ffscreen.FONT))
" >/tmp/imp.out 2>&1
if grep -q "^glyphs" /tmp/imp.out; then
    ok "ffscreen imports (`cat /tmp/imp.out`)"
else
    bad "ffscreen does not import: `cat /tmp/imp.out`"
fi

# 2b. ff-startup.py imports its two siblings by plain name, which resolves
#     ONLY because python puts a script's own directory on sys.path. That is
#     true when the wrapper runs it by path and false the moment anything
#     loads it some other way -- so the check has to be the script running
#     itself, which is what --selftest is. If the bring-up import silently
#     returned None the boards would never be handed over and klippy would
#     open the ports at bootloaders.
"$PY" $MOD/bin/ff-startup.py --selftest >/tmp/self.out 2>&1
if grep -q "^selftest: ok" /tmp/self.out && grep -q "^ports: 3" /tmp/self.out; then
    ok "ff-startup.py reaches both siblings and names all 3 boards"
else
    bad "selftest failed: `cat /tmp/self.out`"
fi

# 3. draw a real frame onto the replica's /dev/fb0.
: > $FB
"$PY" -c "
import sys
sys.path.insert(0, '$MOD/bin')
import ffscreen
s = ffscreen.Screen('$FB', geometry=($W, $H, $BPP))
if not s.ok:
    print('screen refused the geometry'); raise SystemExit(1)
s.show('SETTING UP YOUR PRINTER', 'READING FACTORY CALIBRATION',
       'DO NOT TURN THE PRINTER OFF', 0.5)
print('stride', s.stride)
" >/tmp/draw.out 2>&1
if grep -q "^stride" /tmp/draw.out; then
    ok "drew a frame (`cat /tmp/draw.out`)"
else
    bad "drawing failed: `cat /tmp/draw.out`"
fi

# 4. the frame is EXACTLY one screen. A stride or bpp mistake shows up here
#    as a short or long file long before anyone sees a sheared panel.
WANT=`expr $W \* $H \* $BPP / 8`
GOT=`wc -c < $FB 2>/dev/null || echo 0`
if [ "$GOT" = "$WANT" ]; then
    ok "frame is exactly one screen ($GOT bytes)"
else
    bad "frame is $GOT bytes, expected $WANT"
fi

# 5. it is a picture, not a blank buffer: the background must be painted (the
#    file started empty) and the title's white must appear somewhere.
"$PY" -c "
import sys
sys.path.insert(0, '$MOD/bin')
import ffscreen
s = ffscreen.Screen('$FB', geometry=($W, $H, $BPP))
buf = open('$FB', 'rb').read()
bg = s._pixel(ffscreen.BACKGROUND)
fg = s._pixel(ffscreen.TITLE)
bar = s._pixel(ffscreen.BAR_FG)
print('corner', buf[:len(bg)] == bg)
print('rotated', s.rotate == 90 and (s.width, s.height) == (800, 480))
print('title', buf.count(fg) > 0)
print('bar', buf.count(bar) > 0)
" >/tmp/check.out 2>&1
if grep -q "^rotated True" /tmp/check.out; then
    ok "drawing is rotated for the panel (800x480 seen, 480x800 stored)"
else
    bad "rotation is not in effect: `cat /tmp/check.out`"
fi
for what in corner title bar; do
    if grep -q "^$what True" /tmp/check.out; then
        ok "frame has its $what"
    else
        bad "frame has no $what: `cat /tmp/check.out`"
    fi
done

# 6. clear() must leave the panel black, or HelixScreen starts on top of our
#    text instead of its own splash.
"$PY" -c "
import sys
sys.path.insert(0, '$MOD/bin')
import ffscreen
ffscreen.Screen('$FB', geometry=($W, $H, $BPP)).clear()
" >/tmp/clear.out 2>&1
if [ -s /tmp/clear.out ]; then
    bad "clear() complained: `cat /tmp/clear.out`"
elif [ -n "`tr -d '\000' < $FB`" ]; then
    bad "clear() left something on the panel"
else
    ok "clear() leaves the panel black"
fi

# 7. no framebuffer at all must be silent, not fatal: this runs on every first
#    boot and a missing panel is not an install failure.
"$PY" -c "
import sys
sys.path.insert(0, '$MOD/bin')
import ffscreen
s = ffscreen.Screen('/dev/does-not-exist', geometry=($W, $H, $BPP))
print('ok', s.ok)
s.show('T', 'S', 'N', 0.5)
s.clear()
print('survived')
" >/tmp/absent.out 2>&1
if grep -q "^ok False" /tmp/absent.out && grep -q "^survived" /tmp/absent.out; then
    ok "a missing framebuffer is a no-op, not an error"
else
    bad "a missing framebuffer misbehaved: `cat /tmp/absent.out`"
fi

echo
[ $FAIL = 0 ] && echo "boot screen: all checks passed" || echo "boot screen: FAILURES"
exit $FAIL
