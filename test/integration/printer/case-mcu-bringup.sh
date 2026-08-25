#!/bin/sh
# Can start.sh actually run ff-mcu-bringup.py on this machine?
#
# The handshake logic is tested elsewhere against a pty. What is tested HERE
# is the boring part that has already bitten us once: whether the interpreter
# starts at all. moonrakerDaemon shipped broken for exactly this reason --
# /usr/prog/Python-3.8.2/bin/python3 does not run without LD_LIBRARY_PATH,
# and on stock it was only ever launched from a script that exported it.
#
# So this runs the command line start.sh really uses, in the environment
# start.sh really sets, against the printer's real /usr/prog.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
skip() { echo "  SKIP  $*"; }

MOD=/usr/data/anvil
SCRIPT=$MOD/bin/ff-mcu-bringup.py
PY=/usr/prog/Python-3.8.2/bin/python3

mkdir -p $MOD/bin
cp /tmp/payload/bin/ff-mcu-bringup.py $SCRIPT 2>/dev/null
chmod +x $SCRIPT 2>/dev/null

if [ ! -f "$SCRIPT" ]; then
    bad "payload does not carry bin/ff-mcu-bringup.py"
    exit 1
fi
ok "payload ships bin/ff-mcu-bringup.py"

if [ ! -x "$PY" ]; then
    # `exit 0` here reported a PASSING gate: Replica.run_case only reads the
    # exit code, so everything below -- the import test, the resolution check,
    # the actual bring-up run, the ttyS7 coverage and the LD_LIBRARY_PATH
    # negative control -- was skipped and scored as clean. That is the
    # "SKIP printed, exit 0, counted as ok" protocol ffsim was written to end.
    # seed-prog.sh already hard-fails when the interpreter is MISSING, so
    # reaching here means it is present but not executable, which is a broken
    # replica rather than an absent feature.
    bad "$PY is not executable -- the replica has no usable interpreter"
    exit 1
fi
ok "interpreter present at $PY"

# Exactly what start.sh exports, in the same order.
export PATH=$PATH:/usr/prog/Python-3.8.2/bin
export LD_LIBRARY_PATH=/usr/prog/Python-3.8.2/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib:$LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/usr/prog/libffi-3.4.4/lib:$LD_LIBRARY_PATH

# 1. the interpreter starts and can import what the script imports
if "$PY" -c 'import os, sys, termios' >/tmp/imp.out 2>&1; then
    ok "python3 starts and imports termios"
else
    bad "python3 cannot import termios: $(cat /tmp/imp.out)"
fi

# 2. a bare `python3` resolves to that same interpreter (start.sh's fallback)
WHICH=`command -v python3 2>/dev/null`
if [ "$WHICH" = "$PY" ]; then
    ok "bare 'python3' resolves to $PY"
else
    bad "bare 'python3' resolves to '$WHICH', not $PY"
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
#    list because checkEboard no longer runs: start.sh dropped it, so a
#    bring-up that quietly stopped covering ttyS5 would strand the eboard
#    with nothing left to notice.
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
[ $FAIL -eq 0 ] && echo "  ff-mcu-bringup.py is runnable as start.sh invokes it"
exit $FAIL
