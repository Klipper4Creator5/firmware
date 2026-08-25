#!/bin/sh
# Does moonraker load with the library path S60web sets -- and does it really
# need every directory in that list?
#
# A printer reported moonraker never coming up. The cause was S60web naming
# three /usr/prog/*/lib directories and inheriting the other nine from
# app_startup.sh, which exports twelve before it runs the wrapper. That
# inheritance holds on a normal boot and nowhere else.
#
# The one that mattered is libsodium: moonraker's `authorization` component is
# linked against it, so its absence is not an ImportError on some module
# nobody has heard of -- it is moonraker exiting during component load, which
# from the outside looks exactly like "moonraker did not start".
#
# This is the negative control for that, in the same shape as the
# LD_LIBRARY_PATH control in case-mcu-bringup.sh: prove the fix works, then
# prove the thing it fixes is real by taking it away again. Only the printer
# can answer either -- these are its libraries and its interpreter.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
skip() { echo "  SKIP  $*"; }

PY=/usr/prog/Python-3.8.2/bin/python3
MR=/usr/prog/moonraker/moonraker
MR_MAIN=/usr/prog/moonraker/moonraker/moonraker/moonraker.py
S60=/tmp/payload/init.d/S60web

[ -x "$PY" ] || { bad "no interpreter at $PY"; exit 1; }
[ -f "$S60" ] || { bad "payload does not carry init.d/S60web"; exit 1; }

if [ ! -d "$MR/moonraker" ]; then
    skip "no moonraker tree at $MR -- nothing to load"
    exit 0
fi
ok "moonraker tree present at $MR"

# The list S60web really sets, taken from the script rather than retyped here:
# a copy would pass while the shipped script had drifted.
# grep -o, not sed: the list is written several directories to a line and a
# sed capture would take one per line and silently test a truncated path.
LIBS=`grep -o '/usr/prog/[A-Za-z0-9._-]*/lib' $S60 | sort -u`
[ -n "$LIBS" ] && ok "S60web names `echo "$LIBS" | wc -l` library directories" \
                || bad "could not read any library directories out of S60web"

echo "$LIBS" | grep -q '/usr/prog/libsodium/lib' \
    && ok "libsodium is one of them" \
    || bad "S60web does not put libsodium on the path"

FULL=""
for d in $LIBS; do
    [ -d "$d" ] && FULL="$d:$FULL"
done
export PATH=$PATH:/usr/prog/Python-3.8.2/bin

# 1. with the full path, the component that needs libsodium must import.
#
#    `authorization` is the subject on purpose: it is the one that failed on
#    a user's printer, and it is present in every moonraker tree this has to
#    work against. moonraker-preflight.py would be the fuller check, but it
#    enters at moonraker.server and the STOCK tree here has no server.py --
#    it is an older layout built around app.py. That check belongs where
#    run-append.sh already runs it, against the tree being installed; this
#    gate is about the library path, so it tests the library path.
LD_LIBRARY_PATH="$FULL" "$PY" -c "
import sys
sys.path.insert(0, '$MR')
import moonraker.components.authorization
print('imported')
" >/tmp/mr-full.out 2>&1
if grep -q '^imported' /tmp/mr-full.out; then
    ok "authorization imports with S60web's library path"
else
    bad "authorization failed with S60web's path: `tail -3 /tmp/mr-full.out`"
fi

# 2. the negative control. Take libsodium away and the authorization
#    component must fail -- if it does not, this whole list is cargo and the
#    comments in S60web are wrong.
NOSODIUM=`echo "$FULL" | sed 's|/usr/prog/libsodium/lib:||'`
if [ "$NOSODIUM" = "$FULL" ]; then
    skip "libsodium was not on the assembled path -- not installed here"
else
    LD_LIBRARY_PATH="$NOSODIUM" "$PY" -c "
import sys
sys.path.insert(0, '$MR')
import moonraker.components.authorization
print('imported')
" >/tmp/mr-nosodium.out 2>&1
    if grep -q '^imported' /tmp/mr-nosodium.out; then
        bad "authorization imported WITHOUT libsodium -- the path entry is not load-bearing"
    else
        ok "without libsodium the authorization component fails, as documented"
        sed 's/^/      /' /tmp/mr-nosodium.out | tail -2
    fi
fi

# 3. S60web now starts moonraker itself, so the entry point it names has to
#    be there and the tools it uses have to exist. A path that is wrong here
#    means no web UI at all, and the failure would be a silent one.
[ -f "$MR_MAIN" ] \
    && ok "the entry point S60web names is present ($MR_MAIN)" \
    || bad "no moonraker.py at $MR_MAIN"

command -v start-stop-daemon >/dev/null 2>&1 \
    && ok "start-stop-daemon is available for the pidfile" \
    || bad "no start-stop-daemon -- S60web could not manage moonraker"

grep -q 'TMPDIR' $S60 \
    && ok "S60web sets TMPDIR off the /tmp ramdisk" \
    || bad "S60web does not set TMPDIR -- uploads would fill memory"

echo
[ $FAIL = 0 ] && echo "moonraker: all checks passed" || echo "moonraker: FAILURES"
exit $FAIL
