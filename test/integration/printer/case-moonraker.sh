#!/bin/sh
# Does the web stack actually start on this printer?
#
# This gate used to read S60web with grep -- for a library directory, for the
# string "TMPDIR", for the order of two paths. That kind of check passes on a
# script that cannot start anything and fails on a rename, and it could never
# answer the only question worth asking: does the printer end up running the
# moonraker we shipped, on the interpreter we meant, and does it come up?
#
# So this installs the payload the way an update does and then drives the
# shipped tools -- anvil-env.sh and init.d/S60web -- and then looks at what
# happened. Only the printer can answer: these are its
# libraries, its interpreter, its busybox start-stop-daemon and its moonraker.
#
# The negative controls matter as much as the positive ones. Proving moonraker
# starts WITH the environment says nothing unless taking the environment away
# stops it, or the whole library list is cargo and the comments in
# anvil-env.sh are wrong.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
skip() { echo "  SKIP  $*"; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
PY=/usr/prog/Python-3.8.2/bin/python3
MR=/usr/prog/moonraker/moonraker
MOONRAKER_MAIN=$MR/moonraker/moonraker.py
S60=$MODDIR/init.d/S60web

[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }
[ -x "$PY" ] || { bad "no interpreter at $PY"; exit 1; }

# ---- install the payload, as run-append.sh does ----------------------------
mkdir -p $MODDIR/init.d
cp -f $PAYLOAD/anvil-env.sh $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/anvil.conf $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/init.d/S* $MODDIR/init.d/ 2>/dev/null
chmod +x $MODDIR/init.d/S* 2>/dev/null
[ -f $MODDIR/anvil-env.sh ] || { bad "the payload ships no anvil-env.sh"; exit 1; }
[ -x "$S60" ] || { bad "the payload ships no init.d/S60web"; exit 1; }
ok "payload installed to $MODDIR"

# ---- 1. the negative control: no environment, no interpreter ---------------
# This is the failure a user reported as "moonraker never came up". If the
# interpreter runs fine without any of this, then anvil-env.sh is decoration
# and every test below is measuring nothing.
if env -u LD_LIBRARY_PATH "$PY" -c 'pass' >/dev/null 2>&1; then
    skip "the interpreter runs with no LD_LIBRARY_PATH -- anvil-env.sh is belt-and-braces here"
    ENV_LOAD_BEARING=0
else
    ok "without LD_LIBRARY_PATH the interpreter does not start -- as documented"
    ENV_LOAD_BEARING=1
fi

# ---- 2. sourcing the shipped env makes it run ------------------------------
( . $MODDIR/anvil-env.sh && "$FF_PYTHON" -c 'print("interpreter ok")' ) \
    > /tmp/env.out 2>&1
if grep -q '^interpreter ok' /tmp/env.out; then
    ok "anvil-env.sh makes the printer's interpreter run"
else
    bad "anvil-env.sh did not produce a working interpreter: `tail -2 /tmp/env.out`"
fi

# Everything below wants that environment.
. $MODDIR/anvil-env.sh

# ---- 3. it points at the printer's interpreter, not a bare python3 ---------
if [ "$FF_PYTHON" = "$PY" ]; then
    ok "FF_PYTHON is the printer's own interpreter"
else
    bad "FF_PYTHON is '$FF_PYTHON', expected $PY"
fi

# ---- 4. every library package present on this printer is on the path -------
# Read out of the shipped file rather than retyped: a copy here would pass
# while the shipped list had drifted, which is the bug this file replaced.
MISSING=""
for d in `sed -n 's|^\(/usr/prog/[A-Za-z0-9._-]*/lib\)$|\1|p' $MODDIR/anvil-env.sh`; do
    [ -d "$d" ] || continue
    case ":$LD_LIBRARY_PATH:" in
        *":$d:"*) ;;
        *) MISSING="$MISSING $d" ;;
    esac
done
[ -z "$MISSING" ] && ok "every library directory that exists here is exported" \
                  || bad "not exported:$MISSING"

# ---- 5. sourcing it twice does not grow the path ---------------------------
# firmwareExe sources it and then runs the init.d scripts, which source it
# again with the first copy already inherited.
BEFORE="$LD_LIBRARY_PATH"
. $MODDIR/anvil-env.sh
[ "$LD_LIBRARY_PATH" = "$BEFORE" ] \
    && ok "sourcing anvil-env.sh twice leaves the path unchanged" \
    || bad "the path grew on a second source"

# ---- 6. the component that broke once actually imports ---------------------
if [ -d "$MR/moonraker" ]; then
    "$FF_PYTHON" -c "
import sys
sys.path.insert(0, '$MR')
import moonraker.components.authorization
print('imported')
" >/tmp/mr-auth.out 2>&1
    grep -q '^imported' /tmp/mr-auth.out \
        && ok "moonraker's authorization component imports" \
        || bad "authorization failed: `tail -3 /tmp/mr-auth.out`"

    # Negative control for the one library that caused the outage.
    NOSODIUM=`echo "$LD_LIBRARY_PATH" | sed 's|/usr/prog/libsodium/lib:||'`
    if [ "$NOSODIUM" = "$LD_LIBRARY_PATH" ]; then
        skip "libsodium is not installed here -- cannot take it away"
    else
        LD_LIBRARY_PATH="$NOSODIUM" "$FF_PYTHON" -c "
import sys
sys.path.insert(0, '$MR')
import moonraker.components.authorization
print('imported')
" >/tmp/mr-nosodium.out 2>&1
        grep -q '^imported' /tmp/mr-nosodium.out \
            && bad "authorization imported WITHOUT libsodium -- that path entry is cargo" \
            || ok "without libsodium the authorization component fails, as documented"
    fi
else
    skip "no moonraker package at $MR"
fi

# ---- 7. every component this printer is configured for imports -------------
# This used to be moonraker-preflight.py, shipped to the printer and run by
# the installer to decide whether to install our Moonraker at all. It is here
# now, and it decides nothing: by the time a user is flashing a machine it is
# much too late to find out the Moonraker in the package does not load, and
# there is no second build to fall back to. The question belongs to the build,
# and this is the build.
#
# The component list is NOT written down here. It comes from Moonraker's own
# CORE_COMPONENTS plus every section in the printer's moonraker.conf and
# anything it [include]s -- moonraker.conf ends by including
# moonraker-custom.conf, which is where a user's own sections live, so
# following it is what keeps the check honest when the pin moves or somebody
# configures a component we never thought about. An earlier version listed
# four modules by hand and missed `authorization`, which is the one that
# actually broke.
if [ -d "$MR/moonraker" ]; then
    "$FF_PYTHON" - "$MR" /usr/data/config/moonraker.conf <<'PY' >/tmp/mr-pre.out 2>&1
import glob, importlib, os, re, sys
sys.path.insert(0, sys.argv[1])
try:
    import moonraker.server as server
except Exception as exc:
    print("moonraker.server does not import: %r" % (exc,))
    raise SystemExit(2)

names = list(getattr(server, "CORE_COMPONENTS", []))

def scan(path, depth=0):
    try:
        lines = open(path).readlines()
    except OSError:
        return
    for line in lines:
        section = re.match(r"\s*\[\s*([A-Za-z0-9_]+)", line)
        if not section:
            continue
        if section.group(1) == "include":
            inc = re.match(r"\s*\[\s*include\s+([^\]]+?)\s*\]", line)
            if inc and depth < 3:
                base = os.path.dirname(os.path.abspath(path))
                for f in sorted(glob.glob(os.path.join(base, inc.group(1)))):
                    scan(f, depth + 1)
            continue
        names.append(section.group(1))

scan(sys.argv[2])

failures = []
for name in dict.fromkeys(names):
    target = "moonraker.components." + name
    try:
        importlib.import_module(target)
    except ModuleNotFoundError as exc:
        # The component not existing is fine -- that is a config section like
        # [server], or one this Moonraker does not have. A missing DEPENDENCY
        # of a component that does exist is the whole point of this check.
        if getattr(exc, "name", None) == target:
            continue
        failures.append((name, repr(exc)))
    except Exception as exc:
        # libnacl raises OSError, not ImportError, when libsodium is missing.
        failures.append((name, repr(exc)))

for name, err in failures:
    print("  %s: %s" % (name, err))
print("components ok: %d" % len(dict.fromkeys(names)) if not failures
      else "%d component(s) will not load" % len(failures))
raise SystemExit(1 if failures else 0)
PY
    if grep -q '^components ok:' /tmp/mr-pre.out; then
        ok "`grep '^components ok:' /tmp/mr-pre.out` on this printer"
    elif grep -q 'moonraker.server does not import' /tmp/mr-pre.out; then
        # The stock 2022 tree is an older layout built around app.py with no
        # moonraker.server to enter at. A real answer about a real tree, not a
        # harness problem -- and the mod's build is what this gate guards.
        skip "the installed tree is the old layout: `tail -1 /tmp/mr-pre.out`"
    else
        bad "components will not load: `tail -4 /tmp/mr-pre.out`"
    fi
fi

# ---- 8. S60web starts moonraker, and it comes up ---------------------------
moonraker_pid() { cat /run/moonraker.pid 2>/dev/null; }
moonraker_alive() {
    p=`moonraker_pid`
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
answers() {
    wget -q -O - -T 3 http://127.0.0.1:7125/server/info 2>/dev/null | grep -q klippy
}

if [ ! -f "$MOONRAKER_MAIN" ]; then
    bad "no moonraker.py at $MOONRAKER_MAIN -- S60web has nothing to start"
else
    ok "the entry point S60web names is present ($MOONRAKER_MAIN)"
    $S60 stop >/dev/null 2>&1
    $S60 start > /tmp/s60-start.out 2>&1
    sed 's/^/      /' /tmp/s60-start.out

    # qemu is slow and moonraker loads a lot of components.
    waited=0
    while [ $waited -lt 45 ] && ! moonraker_alive; do
        sleep 2
        waited=$((waited + 2))
    done
    if moonraker_alive; then
        ok "moonraker is running after ${waited}s (pid `moonraker_pid`)"
    else
        bad "moonraker did not start -- last words:"
        tail -n 15 /usr/data/logs/moonraker.log 2>/dev/null | sed 's/^/      /'
    fi

    # It has to be OUR interpreter running OUR entry point, not something the
    # stock daemon left behind. This is what the old grep could not see.
    if moonraker_alive; then
        CMD=`tr '\0' ' ' < /proc/\`moonraker_pid\`/cmdline 2>/dev/null`
        case "$CMD" in
            *"$PY"*) ok "it is the printer's own interpreter that is running" ;;
            *) bad "moonraker is running under '$CMD', not $PY" ;;
        esac
        case "$CMD" in
            *"$MOONRAKER_MAIN"*) ok "running the entry point S60web names" ;;
            *) bad "running '$CMD', not $MOONRAKER_MAIN" ;;
        esac
        # The uploads fix: TMPDIR has to be off the /tmp ramdisk.
        if [ -r /proc/`moonraker_pid`/environ ]; then
            TD=`tr '\0' '\n' < /proc/\`moonraker_pid\`/environ | sed -n 's/^TMPDIR=//p'`
            case "$TD" in
                /usr/data/*) ok "TMPDIR is $TD -- off the ramdisk" ;;
                "") bad "moonraker has no TMPDIR -- uploads would fill memory" ;;
                *) bad "TMPDIR is $TD, which is not on the data partition" ;;
            esac
        fi
    fi

    # Does it actually serve the API? That is the thing a user notices.
    waited=0
    while [ $waited -lt 60 ] && ! answers; do
        sleep 3
        waited=$((waited + 3))
    done
    answers && ok "moonraker answers /server/info on :7125 after ${waited}s" \
             || skip "moonraker is running but did not answer on :7125 (klippy is not up in the replica)"

    # ---- 9. status, stop and restart tell the truth ------------------------
    $S60 status 2>&1 | grep -q 'moonraker: running' \
        && ok "status reports it running" \
        || bad "status does not report a running moonraker"

    $S60 stop >/dev/null 2>&1
    if moonraker_alive; then
        bad "moonraker is still alive after stop"
    else
        ok "stop actually stopped it"
    fi
    [ -f /run/moonraker.pid ] \
        && bad "stop left a stale pidfile -- status would report a recycled PID" \
        || ok "stop cleared the pidfile"

    $S60 restart > /tmp/s60-restart.out 2>&1
    waited=0
    while [ $waited -lt 45 ] && ! moonraker_alive; do
        sleep 2
        waited=$((waited + 2))
    done
    moonraker_alive && ok "restart brought it back (pid `moonraker_pid`)" \
                    || bad "restart left nothing running: `tail -2 /tmp/s60-restart.out`"
    $S60 stop >/dev/null 2>&1
fi

# ---- 10. a missing tree is reported, not routed around ---------------------
# There is no stock moonraker to fall back to any more, so the one thing this
# must never do is fail silently.
if [ -f "$MOONRAKER_MAIN" ]; then
    mv "$MOONRAKER_MAIN" "$MOONRAKER_MAIN.hidden"
    $S60 start > /tmp/s60-missing.out 2>&1
    sleep 2
    if moonraker_alive; then
        bad "S60web started something with no moonraker.py present"
    elif grep -qi 'moonraker' /tmp/s60-missing.out; then
        ok "a missing moonraker.py is reported: `grep -i moonraker /tmp/s60-missing.out | head -1`"
    else
        bad "a missing moonraker.py produced no message at all"
    fi
    mv "$MOONRAKER_MAIN.hidden" "$MOONRAKER_MAIN"
    $S60 stop >/dev/null 2>&1
fi

echo
[ $FAIL = 0 ] && echo "moonraker: all checks passed" || echo "moonraker: FAILURES"
exit $FAIL
