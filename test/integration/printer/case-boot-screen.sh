#!/bin/sh
# Does the first-boot screen actually draw, on the printer's own userland?
#
# ffscreen.py packs pixels by hand into a framebuffer. Nothing about that is
# provable by reading it, and the two things most likely to be wrong are
# exactly the two a Debian container would never catch:
#
#   * whether /usr/prog/Python-3.8.2/bin/python3 -- a 3.8 built by FlashForge,
#     running here under qemu-mipsel -- executes this code at all. That is the
#     moonrakerDaemon lesson: reasoning about compatibility was not enough.
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
PY=/usr/prog/Python-3.8.2/bin/python3
FB=/dev/fb0
W=480
H=800
BPP=32

mkdir -p $MOD/bin
for f in ffscreen.py ff-startup.py; do
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
    bad "$PY is not executable -- the replica has no usable interpreter"
    exit 1
fi

# Exactly what start.sh and the firmwareExe wrapper export, in the same order.
export PATH=$PATH:/usr/prog/Python-3.8.2/bin
export LD_LIBRARY_PATH=/usr/prog/Python-3.8.2/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/prog/libffi-3.4.4/lib:$LD_LIBRARY_PATH

# 1. the interpreter runs the importer at all. --help exits before any I/O,
#    so this is purely "does this 3.8 accept the syntax and the imports".
if "$PY" $MOD/bin/ff-startup.py --help >/tmp/help.out 2>&1; then
    ok "ff-startup.py runs under the printer's python"
else
    bad "ff-startup.py does not run: `cat /tmp/help.out`"
fi

# 2. it found ffscreen.py beside itself. The import is optional by design, so
#    a missing sibling would silently mean "no screen" forever.
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
