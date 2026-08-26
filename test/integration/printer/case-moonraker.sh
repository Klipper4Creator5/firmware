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
# shipped tools -- anvil-env.sh, anvil-service.sh and init.d/S62moonraker --
# and then looks at what happened. Only the printer can answer: these are its
# libraries, its interpreter, its busybox start-stop-daemon and its moonraker.
#
# S60web is gone: nginx and moonraker are two scripts now, because they fail
# separately and are debugged separately. That split is itself a claim about
# behaviour -- stopping one must leave the other alone -- so it is checked
# here too, at step 10.
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
# WHERE MOONRAKER LIVES NOW. The mod's Moonraker rides in the payload and is
# installed by being extracted, so the entry point is on the DATA partition at
# /usr/data/anvil/moonraker/moonraker.py and nothing is written to /usr/prog.
# MRROOT is the directory that goes on sys.path -- the parent of the package,
# not the package itself.
MRROOT=$MODDIR
MOONRAKER_MAIN=$MRROOT/moonraker/moonraker.py
# FlashForge's own 2022 tree, which the mod no longer uses or touches. It is
# named here only as the stand-in described at the staging step below.
STOCK_MR=/usr/prog/moonraker/moonraker/moonraker
S62=$MODDIR/init.d/S62moonraker
S60N=$MODDIR/init.d/S60nginx

[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }
[ -x "$PY" ] || { bad "no interpreter at $PY"; exit 1; }

# ---- install the payload, as run-append.sh does ----------------------------
mkdir -p $MODDIR/init.d
cp -f $PAYLOAD/anvil-env.sh $MODDIR/ 2>/dev/null
# anvil-service.sh is not optional and not decoration: every init.d script
# sources it for svc_start_daemon/svc_stop_daemon and exits immediately if it
# is not there. Leaving it out of the installer is a printer that boots with
# no services at all, which is exactly why it is copied -- and asserted --
# here.
cp -f $PAYLOAD/anvil-service.sh $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/anvil.conf $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/init.d/S* $MODDIR/init.d/ 2>/dev/null
chmod +x $MODDIR/init.d/S* 2>/dev/null
[ -f $MODDIR/anvil-env.sh ] || { bad "the payload ships no anvil-env.sh"; exit 1; }
[ -f $MODDIR/anvil-service.sh ] \
    || { bad "the payload ships no anvil-service.sh -- every service script exits at once without it"; exit 1; }
[ -x "$S62" ] || { bad "the payload ships no init.d/S62moonraker"; exit 1; }
ok "payload installed to $MODDIR"

# ---- the Moonraker tree, at the path the mod now runs it from --------------
# /tmp/payload is the SOURCE payload directory, not the built one: the
# Moonraker tree is staged into work/modpayload by bin/patch.sh out of a
# tarball fetch-assets.sh downloads, so it is not on this mount unless the
# caller put it there. When it is absent the printer's own 2022 tree stands in
# at the new path.
#
# The stand-in is honest about what it can and cannot answer. What is tested
# from step 8 down is the MECHANISM -- start-stop-daemon writes a pidfile, the
# environment reaches the process, stop waits and clears the pidfile, restart
# yields a new pid -- and that is the same mechanism whichever tree is under
# it. Whether the SHIPPED Moonraker imports and stays up is a question about
# the build, and it is answered by the install gate, which puts a real package
# on a real stick. Steps 6 and 7 already skip themselves on the old layout
# rather than pretend.
if [ -d $PAYLOAD/moonraker ]; then
    rm -rf $MODDIR/moonraker
    cp -a $PAYLOAD/moonraker $MODDIR/moonraker
    ok "the payload's own Moonraker staged at $MODDIR/moonraker"
elif [ -d "$STOCK_MR" ]; then
    rm -rf $MODDIR/moonraker
    cp -a "$STOCK_MR" $MODDIR/moonraker
    skip "the payload mount carries no moonraker/ -- the printer's own tree stands in at $MODDIR/moonraker"
else
    skip "no Moonraker tree available at all -- the start/stop checks below will report it"
fi

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
if [ -d "$MRROOT/moonraker" ]; then
    "$FF_PYTHON" -c "
import sys
sys.path.insert(0, '$MRROOT')
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
sys.path.insert(0, '$MRROOT')
import moonraker.components.authorization
print('imported')
" >/tmp/mr-nosodium.out 2>&1
        grep -q '^imported' /tmp/mr-nosodium.out \
            && bad "authorization imported WITHOUT libsodium -- that path entry is cargo" \
            || ok "without libsodium the authorization component fails, as documented"
    fi
else
    skip "no moonraker package at $MRROOT/moonraker"
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
if [ -d "$MRROOT/moonraker" ]; then
    "$FF_PYTHON" - "$MRROOT" /usr/data/config/moonraker.conf <<'PY' >/tmp/mr-pre.out 2>&1
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

# ---- 8. S62moonraker starts moonraker, and it comes up ---------------------
moonraker_pid() { cat /run/moonraker.pid 2>/dev/null; }
moonraker_alive() {
    p=`moonraker_pid`
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
answers() {
    wget -q -O - -T 3 http://127.0.0.1:7125/server/info 2>/dev/null | grep -q klippy
}

if [ ! -f "$MOONRAKER_MAIN" ]; then
    bad "no moonraker.py at $MOONRAKER_MAIN -- S62moonraker has nothing to start"
else
    ok "the entry point S62moonraker names is present ($MOONRAKER_MAIN)"
    $S62 stop >/dev/null 2>&1
    $S62 start > /tmp/s62-start.out 2>&1
    sed 's/^/      /' /tmp/s62-start.out

    # qemu is slow and moonraker loads a lot of components.
    waited=0
    while [ $waited -lt 45 ] && ! moonraker_alive; do
        sleep 2
        waited=$((waited + 2))
    done
    if moonraker_alive; then
        FIRST_PID=`moonraker_pid`
        ok "moonraker is running after ${waited}s (pid $FIRST_PID)"
    else
        FIRST_PID=""
        bad "moonraker did not start -- last words:"
        tail -n 15 /usr/data/logs/moonraker.log 2>/dev/null | sed 's/^/      /'
    fi

    # It has to be OUR interpreter running OUR entry point, on the data
    # partition -- not the stock tree on /usr/prog and not something the stock
    # daemon left behind. This is what the old grep could not see.
    if moonraker_alive; then
        CMD=`tr '\0' ' ' < /proc/\`moonraker_pid\`/cmdline 2>/dev/null`
        case "$CMD" in
            *"$PY"*) ok "it is the printer's own interpreter that is running" ;;
            *) bad "moonraker is running under '$CMD', not $PY" ;;
        esac
        case "$CMD" in
            *"$MOONRAKER_MAIN"*) ok "running the entry point S62moonraker names" ;;
            *) bad "running '$CMD', not $MOONRAKER_MAIN" ;;
        esac
        # And NOT the copy on the firmware partition. That second tree is the
        # thing this release removed: while it existed, "which moonraker is
        # this printer running?" depended on what was flashed last.
        case "$CMD" in
            *"$STOCK_MR"*) bad "moonraker is running FlashForge's /usr/prog tree, not the mod's" ;;
            *) ok "nothing under $STOCK_MR is being run" ;;
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
    $S62 status 2>&1 | grep -q 'moonraker: running' \
        && ok "status reports it running" \
        || bad "status does not report a running moonraker"

    $S62 stop >/dev/null 2>&1
    if moonraker_alive; then
        bad "moonraker is still alive after stop"
    else
        ok "stop actually stopped it"
    fi
    # svc_stop_daemon removes the pidfile because busybox start-stop-daemon
    # does not. A stale one is how `status` came to report a recycled pid as a
    # running server.
    [ -f /run/moonraker.pid ] \
        && bad "stop left a stale pidfile -- status would report a recycled PID" \
        || ok "stop cleared the pidfile"

    $S62 restart > /tmp/s62-restart.out 2>&1
    waited=0
    while [ $waited -lt 45 ] && ! moonraker_alive; do
        sleep 2
        waited=$((waited + 2))
    done
    if moonraker_alive; then
        ok "restart brought it back (pid `moonraker_pid`)"
        # It must be a NEW process. `restart` used to race its own start --
        # busybox start-stop-daemon -K returns before the process is dead, so
        # the -S that followed refused and the old pid simply carried on,
        # which looks identical to a successful restart from the outside.
        if [ -n "$FIRST_PID" ] && [ "`moonraker_pid`" = "$FIRST_PID" ]; then
            bad "restart left the ORIGINAL pid $FIRST_PID running -- nothing was restarted"
        else
            ok "restart produced a new process, not the old one"
        fi
    else
        bad "restart left nothing running: `tail -2 /tmp/s62-restart.out`"
    fi
    $S62 stop >/dev/null 2>&1
fi

# ---- 10. nginx and moonraker are independent -------------------------------
# WHY THIS IS HERE. These were one script, S60web, and the whole point of
# splitting them is that `S62moonraker restart` -- the one you run over and
# over while chasing a moonraker config -- must not take the web UI down with
# it. That is a claim about behaviour, not about file layout, so it is checked
# by taking moonraker down with nginx running and then looking at nginx.
#
# The config is a STAND-IN: assets/nginx.conf is staged into the built payload
# by bin/patch.sh and is not on this mount, so the printer's own stock
# nginx.conf is borrowed purely to get a live nginx to point at. What is
# measured here is which process survives, not what nginx serves. Everything
# below skips rather than fails when this printer cannot run nginx at all: a
# failure there would be a statement about FlashForge's nginx build, which is
# not what this gate is for.
NGINX_BIN=/usr/prog/nginx/sbin/nginx
NGINX_PID=$MODDIR/nginx/logs/nginx.pid
nginx_alive() { [ -f "$NGINX_PID" ] && kill -0 "`cat $NGINX_PID 2>/dev/null`" 2>/dev/null; }

if [ ! -x "$NGINX_BIN" ]; then
    skip "no nginx on this printer -- cannot check that the two services are independent"
elif [ ! -x "$S60N" ]; then
    bad "the payload ships no init.d/S60nginx"
elif [ ! -f "$MOONRAKER_MAIN" ]; then
    skip "no moonraker to take away -- cannot check the split"
else
    mkdir -p $MODDIR/nginx/logs $MODDIR/nginx/tmp
    [ -f $MODDIR/nginx/nginx.conf ] \
        || cp -f /usr/prog/nginx/conf/nginx.conf $MODDIR/nginx/nginx.conf 2>/dev/null
    $S60N start > /tmp/s60nginx.out 2>&1
    sed 's/^/      /' /tmp/s60nginx.out
    if ! nginx_alive; then
        skip "nginx did not come up here -- cannot check the split"
    else
        ok "nginx is running (pid `cat $NGINX_PID`)"
        $S62 start >/dev/null 2>&1
        waited=0
        while [ $waited -lt 45 ] && ! moonraker_alive; do
            sleep 2
            waited=$((waited + 2))
        done
        if ! moonraker_alive; then
            skip "moonraker would not start alongside nginx -- nothing to take away"
        else
            $S62 stop >/dev/null 2>&1
            moonraker_alive \
                && bad "stopping moonraker did not stop moonraker" \
                || ok "stopping moonraker stopped moonraker"
            if nginx_alive; then
                ok "nginx survived it -- the two services really are independent"
            else
                bad "stopping moonraker took nginx down with it -- the split is not real"
            fi
            $S60N status 2>&1 | grep -q 'nginx: running' \
                && ok "S60nginx still reports itself running" \
                || bad "S60nginx does not report itself running after moonraker stopped"
        fi
        $S60N stop >/dev/null 2>&1
        $S62 stop >/dev/null 2>&1
    fi
fi

# ---- 11. a missing tree is reported, not routed around ---------------------
# There is no stock moonraker to fall back to any more, so the one thing this
# must never do is fail silently.
if [ -f "$MOONRAKER_MAIN" ]; then
    mv "$MOONRAKER_MAIN" "$MOONRAKER_MAIN.hidden"
    $S62 start > /tmp/s62-missing.out 2>&1
    sleep 2
    if moonraker_alive; then
        bad "S62moonraker started something with no moonraker.py present"
    elif grep -qi 'moonraker' /tmp/s62-missing.out; then
        ok "a missing moonraker.py is reported: `grep -i moonraker /tmp/s62-missing.out | head -1`"
    else
        bad "a missing moonraker.py produced no message at all"
    fi
    mv "$MOONRAKER_MAIN.hidden" "$MOONRAKER_MAIN"
    $S62 stop >/dev/null 2>&1
fi

echo
[ $FAIL = 0 ] && echo "moonraker: all checks passed" || echo "moonraker: FAILURES"
exit $FAIL
