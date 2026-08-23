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
    skip "no $PY in this replica -- set PROG_DUMP to a factory image"
    exit 0
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

# 4. it must name BOTH orphaned boards, not just the first
if grep -q "mcu-bringup: /dev/ttyS7" /tmp/run.out; then
    ok "covers /dev/ttyS7 as well"
else
    bad "never mentioned /dev/ttyS7: `cat /tmp/run.out`"
fi

# 5. negative control: without LD_LIBRARY_PATH the interpreter must fail.
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
