#!/bin/sh
# Can start.sh actually run ff_mcu_bringup.py on this machine?
#
# The handshake logic is tested elsewhere against a pty. What is tested HERE
# is the boring part that has already bitten us once: whether the interpreter
# starts at all. moonrakerDaemon shipped broken for exactly this reason --
# /usr/prog/Python-3.8.2/bin/python3 does not run without LD_LIBRARY_PATH,
# and on stock it was only ever launched from a script that exported it.
#
# So this runs the command line start.sh really uses, in the environment
# start.sh really sets, against the printer's real /usr/prog. FF_PYTHON now
# names our own $MODDIR/bin/python3.13 (see payload/anvil-env.sh), so that is
# the interpreter under test here too -- ff_mcu_bringup.py's imports (os, sys,
# termios, time) are stdlib-only, checked against CPython's removed-in-3.13
# list, so nothing here needs FlashForge's 3.8.2.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
skip() { echo "  SKIP  $*"; }

MOD=/usr/data/anvil
# anvil-env.sh's own FF_PYTHON line reads $MODDIR, not $MOD -- this file's own
# variable name predates that and nothing here renames it, so without this
# alias FF_PYTHON resolves to the empty-prefix "/bin/python3.13" instead of
# $MOD/bin/python3.13. Caught by section 2 below.
MODDIR=$MOD
SCRIPT=$MOD/bin/ff_mcu_bringup.py
PY=$MOD/bin/python3.13

mkdir -p $MOD/bin
# The interpreter FF_PYTHON resolves to. Not part of /tmp/payload -- it is a
# BUILD OUTPUT (bin/patch.sh section 5c, cached under work/pkg), so gates.py
# hands it over as py.tgz the same way case-python.sh receives one, and this
# is a hard failure rather than a Skip if it is missing: gates.py's
# mcu_bringup() already Skips the whole case when nothing has built it, so
# reaching here without one is a harness bug, not an absent feature.
[ -f /mnt/py.tgz ] || { bad "no py.tgz mounted -- gates.py should have Skipped this case instead"; exit 1; }
gzip -dc /mnt/py.tgz | tar -x -C $MOD || { bad "cannot unpack py.tgz"; exit 1; }
cp /tmp/payload/bin/ff_mcu_bringup.py $SCRIPT 2>/dev/null
chmod +x $SCRIPT 2>/dev/null

if [ ! -f "$SCRIPT" ]; then
    bad "payload does not carry bin/ff_mcu_bringup.py"
    exit 1
fi
ok "payload ships bin/ff_mcu_bringup.py"

if [ ! -x "$PY" ]; then
    bad "$PY is not executable after unpacking py.tgz -- the replica has no usable interpreter"
    exit 1
fi
ok "interpreter present at $PY"

# The environment start.sh runs in -- sourced from the shipped file rather
# than retyped here. A copy would agree with start.sh right up until one of
# them changed, and testing the bring-up in an environment the printer never
# actually uses is worse than not testing it.
if [ -f /tmp/payload/anvil-env.sh ]; then
    . /tmp/payload/anvil-env.sh
    ok "sourced the shipped anvil-env.sh -- the same environment start.sh gets"
else
    bad "the payload ships no anvil-env.sh"
    exit 1
fi

# 1. the interpreter starts and can import what the script imports
if "$PY" -c 'import os, sys, termios' >/tmp/imp.out 2>&1; then
    ok "python3 starts and imports termios"
else
    bad "python3 cannot import termios: $(cat /tmp/imp.out)"
fi

# 2. the interpreter start.sh will actually invoke is this one. start.sh no
#    longer falls back to a bare `python3` -- that never helped, since the base
#    rootfs ships no other one -- so what matters now is that the shipped env
#    resolves FF_PYTHON to the interpreter this gate just proved works.
if [ "$FF_PYTHON" = "$PY" ]; then
    ok "anvil-env.sh resolves FF_PYTHON to $PY"
else
    bad "FF_PYTHON is '$FF_PYTHON', not $PY"
fi

# 3. the real command line from start.sh. No ttyS4/ttyS7 exist in the replica,
#    so the expected result is the guard path: a clean report, not a traceback.
"$PY" $SCRIPT >/tmp/run.out 2>&1
RC=$?
if grep -q "Traceback" /tmp/run.out; then
    bad "script raised: `cat /tmp/run.out`"
elif grep -qi "error while loading shared libraries\|not found" /tmp/run.out; then
    bad "interpreter/library failure: `cat /tmp/run.out`"
elif grep -q "mcu-bringup: /dev/ttyS4" /tmp/run.out; then
    ok "runs and reports on /dev/ttyS4 (rc=$RC, no devices in the replica)"
else
    bad "unexpected output: `cat /tmp/run.out`"
fi

# 4. it must name EVERY board it owns, not just the first. ttyS5 is in that
#    list because nothing else covers it -- start.sh does not call checkEboard
#    -- so a bring-up that quietly stopped covering ttyS5 would strand the
#    eboard with nothing left to notice.
for dev in /dev/ttyS5 /dev/ttyS7; do
    if grep -q "mcu-bringup: $dev" /tmp/run.out; then
        ok "covers $dev as well"
    else
        bad "never mentioned $dev: `cat /tmp/run.out`"
    fi
done

# 5. and start.sh must not still be calling the binary it replaced
if grep -q "^[^#]*checkEboard" /tmp/payload/start.sh; then
    bad "start.sh still runs checkEboard"
else
    ok "start.sh no longer runs checkEboard"
fi

# 6. negative control: without LD_LIBRARY_PATH the interpreter must fail.
#    This is what makes the export in start.sh load-bearing rather than
#    decorative -- if this ever starts passing, the comment there is stale.
if env -u LD_LIBRARY_PATH "$PY" -c 'pass' >/dev/null 2>&1; then
    skip "interpreter runs without LD_LIBRARY_PATH (fine, but start.sh's export is then belt-and-braces)"
else
    ok "interpreter needs LD_LIBRARY_PATH -- start.sh's export is load-bearing"
fi

echo
[ $FAIL -eq 0 ] && echo "  ff_mcu_bringup.py is runnable as start.sh invokes it"
exit $FAIL
