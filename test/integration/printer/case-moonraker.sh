#!/bin/sh
# Does the web stack actually start on this printer?
#
# NOTHING HERE GREPS A SHIPPED SCRIPT. A grep passes on a script that cannot
# start anything and fails on a rename, and it cannot answer the only question
# worth asking: does the printer end up running the moonraker we shipped, on
# the interpreter we meant, and does it come up?
#
# So this installs the payload the way an update does, drives the shipped tools
# -- anvil-env.sh, anvil-service.sh and init.d/S62moonraker -- and then looks
# at what happened. Only the printer can answer: these are its libraries, its
# interpreter, its busybox start-stop-daemon and its moonraker.
#
# nginx and moonraker are two scripts and two supervised services, because they
# fail separately and are debugged separately. That split is itself a claim
# about behaviour -- stopping one must leave the other alone -- so step 10
# checks it.
#
# WHAT PHASE 5 ADDED, and why this case grew rather than being replaced.
# moonraker is supervised by s6: $MODDIR/etc/s6/moonraker/ holds a `run` script
# that execs it in the FOREGROUND, a `down` file so the scanner does not start
# it before anvil.conf has been read, and a `notification-fd` so that "ready"
# means the API is LISTENING rather than the process was forked.
# init.d/S62moonraker is a thin wrapper over s6-svc. Every one of those is a
# claim about behaviour and every one of them is measured below by running
# things: sections 7b and 12 through 15. What was here before is untouched,
# because it proves something the supervision does not -- that the printer runs
# the moonraker WE shipped, on the interpreter we meant, from the data
# partition, with a TMPDIR off the ramdisk.
#
# THE REAL s6, OR NONE. The cross-built binaries are not in payload/ -- they
# are built by bin/patch.sh into work/.s6 -- so they arrive as a tarball:
#
#     printer-exec.py case-moonraker.sh sup.tgz=work/.s6-gate.tgz
#
# Without one this case DEGRADES rather than skipping: sections 1 to 7 are
# about the Moonraker build and not about s6 at all (they are the only place a
# pin that cannot import gets caught before it ships), and the start/stop/
# restart sections then exercise the no-supervisor fallback in S62moonraker,
# which is real shipped code that a printer with MOD_S6=0 or a failed s6 build
# genuinely runs. Which of the two it did is said out loud at 7b, because a
# case that quietly tests half of itself is worse than one that fails.
#
# The negative controls matter as much as the positive ones. Proving moonraker
# starts WITH the environment says nothing unless taking the environment away
# stops it, or the whole library list is cargo and the comments in
# anvil-env.sh are wrong. The same applies to everything s6 is asked here: a
# readiness wait that returns for a service nobody started, or a service
# directory that looks supervised while daemonising behind s6's back, would
# make the sections below pass while proving nothing. Both are controlled for.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
skip() { echo "  SKIP  $*"; }
note() { echo "  ..    $*"; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
# FF_PYTHON's target: $MODDIR/bin/python3.13, cross-built by bin/patch.sh
# section 5c. Named directly rather than read out of anvil-env.sh, because
# section 3 below exists specifically to prove that sourcing the shipped file
# resolves FF_PYTHON to exactly this path -- an independent expectation is
# what makes that a real check instead of a tautology.
PY=$MODDIR/bin/python3.13
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
S40=$MODDIR/init.d/S40s6
# s6: the binaries, the scandir, and our service directory inside it. S6_REAL
# is set at 7b and every s6 assertion below is guarded on it -- see the header
# for why this case degrades instead of skipping when no tarball arrives.
S6=$MODDIR/bin
SCANDIR=$MODDIR/etc/s6
SVCDIR=$SCANDIR/moonraker
S6_REAL=0
PORT=7125

[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }

# ---- install the payload, as run-append.sh does ----------------------------
mkdir -p $MODDIR/init.d
# The interpreter FF_PYTHON is going to resolve to. Unlike sup.tgz (s6) this
# is not optional: there is no fallback interpreter the way there is a
# no-supervisor fallback for s6, so gates.py's moonraker() Skips the whole
# case rather than staging one, and reaching here with none is a harness bug,
# not an absent feature.
[ -f /mnt/pref.tgz ] || { bad "no pref.tgz mounted -- gates.py should have Skipped this case instead"; exit 1; }
gzip -dc /mnt/pref.tgz | tar -x -C $MODDIR || { bad "cannot unpack pref.tgz"; exit 1; }
[ -x "$PY" ] || { bad "no interpreter at $PY after unpacking pref.tgz"; exit 1; }
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
# The s6 service directories, laid out the way anvil-core ships payload/etc/ --
# with cp -a, contents and mode. A per-file cp would silently drop the `down`
# and `notification-fd` control files (they are not scripts and match no *.sh
# glob) and could lose the executable bit on `run`, which is a service s6 can
# never start and reports only in its own log.
mkdir -p $MODDIR/etc
[ -d $PAYLOAD/etc/s6 ] && cp -a $PAYLOAD/etc/s6 $MODDIR/etc/ 2>/dev/null
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
# Asked HERE, at build time, rather than by the installer on the printer: by
# the time a user is flashing a machine it is far too late to find out the
# Moonraker in the package does not load, and there is no second build to fall
# back to.
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

# ---- 7b. the supervisor, and the service directory it is handed ------------
#
# Everything from here down runs against s6 when a tarball was passed, and
# against S62moonraker's no-supervisor fallback when one was not. Both are code
# a printer really runs; what must not happen is that the case does not say
# which.
echo
echo "--- s6 ---"
if [ -f /mnt/sup.tgz ]; then
    gzip -dc /mnt/sup.tgz | tar -x -C $MODDIR && S6_REAL=1
    chmod +x $S6/* $MODDIR/libexec/* 2>/dev/null
fi
if [ "$S6_REAL" = 1 ] && [ -x $S6/s6-svscan ]; then
    ok "the real cross-built s6 is installed in $S6"
else
    S6_REAL=0
    skip "no sup.tgz -- sections 12 to 15 need the real s6; the rest of this case"
    skip "now exercises S62moonraker's no-supervisor fallback instead"
fi

if [ "$S6_REAL" = 1 ]; then
    # THE SERVICE DIRECTORY, as it arrived from the payload. These three files
    # are the whole of what the payload has to ship for moonraker to be
    # supervised, and each of them fails silently if it is wrong: a `run`
    # without +x is reported by s6 in its own log and nowhere else, a missing
    # `down` means the scanner starts moonraker before anything read MOD_WEB,
    # and a missing `notification-fd` means readiness quietly never happens.
    [ -x $SVCDIR/run ] \
        && ok "the payload ships an executable $SVCDIR/run" \
        || bad "$SVCDIR/run is missing or not executable -- s6 could never start it"
    [ -f $SVCDIR/notification-fd ] \
        && ok "the service directory declares a notification-fd (`cat $SVCDIR/notification-fd`)" \
        || bad "no notification-fd -- readiness cannot work at all"
    [ -s $SVCDIR/down ] \
        && ok "it ships a 'down' file with `wc -l < $SVCDIR/down | tr -d ' '` lines of prose in it -- existence is the signal, not content" \
        || bad "no 'down' file -- s6 would start moonraker before anything read MOD_WEB"

    # s6-svscan execs s6-supervise BY NAME off PATH, and s6-svc -w execs
    # s6-svlisten the same way, so $MODDIR/bin has to be on PATH or the scanner
    # supervises nothing and every waiting verb dies. anvil-env.sh is the file
    # that puts it there; this asks the question by behaviour rather than by
    # grepping it, because it is the one that made the first run of the camera
    # case fail on every section at once.
    if ( . $MODDIR/anvil-env.sh >/dev/null 2>&1; command -v s6-supervise >/dev/null 2>&1 ); then
        ok "anvil-env.sh puts $S6 on PATH -- s6-svscan can exec s6-supervise"
    else
        bad "anvil-env.sh leaves $S6 off PATH: the scanner could not spawn a supervisor"
    fi

    $S40 start 2>&1 | sed 's/^/      /'
    sleep 3
    if $S40 status | grep -q "scanning $SCANDIR"; then
        ok "S40s6 has a scanner on $SCANDIR"
    else
        bad "no scanner after S40s6 start: `$S40 status 2>&1 | head -2 | tr '\n' ' '`"
        S6_REAL=0
    fi
fi

if [ "$S6_REAL" = 1 ]; then
    # THE 'down' FILE, PROVED BY BEHAVIOUR. The scanner has now seen the
    # service directory and started an s6-supervise for it. Nothing has read
    # MOD_WEB yet, so a moonraker that is up at this point means the `down`
    # file did not work and the MOD_WEB gate is decorative -- it would mean
    # "moonraker runs for a moment on every boot and is then shot".
    st=`$S6/s6-svstat $SVCDIR 2>&1`
    case "$st" in
        down*) ok "the scanner picked moonraker up and left it DOWN, as the down file asks: $st" ;;
        *)     bad "moonraker came up on its own, before anything read anvil.conf: $st" ;;
    esac
    # NEGATIVE CONTROL FOR READINESS ITSELF, and it belongs here rather than at
    # section 12: s6-svwait -U against a service that has never declared itself
    # must FAIL. If it succeeded, the timing measured there would mean nothing.
    if $S6/s6-svwait -U -t 4000 $SVCDIR >/dev/null 2>&1; then
        bad "negative control: s6-svwait -U SUCCEEDED on a service that never notified -- readiness is a no-op here"
    else
        ok "negative control: s6-svwait -U times out on a service that has not declared itself ready"
    fi
fi
echo

# ---- 8. S62moonraker starts moonraker, and it comes up ---------------------
# WHERE THE PID COMES FROM. Under s6 there is no pidfile: the supervisor holds
# the process and s6-svstat -p answers "which moonraker is this printer
# running" without ever being stale. The fallback path still writes a pidfile,
# so both are read here and every check below is written in terms of
# moonraker_pid, so the two paths prove the same things.
moonraker_pid() {
    if [ "$S6_REAL" = 1 ]; then
        p=`$S6/s6-svstat -p $SVCDIR 2>/dev/null`
        # s6-svstat -p prints -1 for a service that is down, which is not a pid.
        [ -n "$p" ] && [ "$p" -gt 0 ] 2>/dev/null && echo "$p"
        return 0
    fi
    cat /run/moonraker.pid 2>/dev/null
}
moonraker_alive() {
    p=`moonraker_pid`
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
answers() {
    wget -q -O - -T 3 http://127.0.0.1:$PORT/server/info 2>/dev/null | grep -q klippy
}
# Is anything LISTENING on :7125? Exactly the test the run script uses for
# readiness, spelled the same way, so that a bug in one shows up as a
# disagreement with the other rather than as two matching wrong answers.
port_listening() {
    awk -v p=":`printf '%04X' $PORT`" '$2 ~ p"$" && $4 == "0A" { f = 1 }
                                       END { exit !f }' /proc/net/tcp 2>/dev/null
}

if [ ! -f "$MOONRAKER_MAIN" ]; then
    bad "no moonraker.py at $MOONRAKER_MAIN -- S62moonraker has nothing to start"
else
    ok "the entry point S62moonraker names is present ($MOONRAKER_MAIN)"
    $S62 stop >/dev/null 2>&1
    # A negative control for every port check below: if something in this
    # rootfs were already bound to :7125, "moonraker is listening" would be
    # true for free and the readiness section would measure nothing.
    port_listening \
        && bad "negative control: something is ALREADY listening on :$PORT before anything started" \
        || ok "negative control: nothing is listening on :$PORT before S62moonraker runs"
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
        # And it is the SUPERVISOR that says so, not a file we wrote. s6-svstat
        # reads $SVCDIR's own supervise/status and answers "s6-supervise not
        # running" when there is no supervisor behind that exact directory, so
        # a status beginning with "up" is the supervisor identifying itself by
        # the service directory it holds.
        if [ "$S6_REAL" = 1 ]; then
            st=`$S6/s6-svstat $SVCDIR 2>&1`
            case "$st" in
                up*) ok "s6-svstat: $st -- it is s6 that is holding it" ;;
                *)   bad "moonraker is running but s6 does not have it: $st" ;;
            esac
            # No pidfile is written on this path at all, and that is the point:
            # the supervisor is the handle now. A pidfile appearing here would
            # mean something still went through start-stop-daemon.
            [ -f /run/moonraker.pid ] \
                && bad "a supervised moonraker wrote /run/moonraker.pid -- something still uses start-stop-daemon" \
                || ok "no /run/moonraker.pid: the supervised path has no pidfile to go stale"
        fi
    else
        FIRST_PID=""
        bad "moonraker did not start -- last words:"
        tail -n 15 /usr/data/logs/moonraker.log 2>/dev/null | sed 's/^/      /'
    fi

    # It has to be OUR interpreter running OUR entry point, on the data
    # partition -- not the stock tree on /usr/prog and not something the stock
    # daemon left behind. This is what the old grep could not see.
    #
    # WAIT FOR THE EXEC FIRST, and this is a real difference from the pidfile
    # era rather than a harness detail. start-stop-daemon wrote the pidfile
    # after the fork, so by the time this case could read a pid the python was
    # already running. s6-svstat hands over the pid the instant s6 FORKS the
    # run script, and that script is still a shell for as long as it takes to
    # source anvil-env.sh, sweep /proc and spawn the readiness prober -- seconds,
    # on qemu-mipsel. Measured here: the first version of this section read
    # "/bin/sh ./run moonraker" and reported a moonraker that was not running
    # under the printer's interpreter, one second before it was.
    #
    # So the wait is bounded and its failure is a real failure: a run script
    # that never execs is a shell holding the pid s6 signals, which is exactly
    # the bug `exec` is there to prevent -- every `S62moonraker stop` would then
    # signal a shell while moonraker carried on.
    if moonraker_alive; then
        w=0
        while [ $w -lt 60 ]; do
            CMD=`tr '\0' ' ' < /proc/\`moonraker_pid\`/cmdline 2>/dev/null`
            case "$CMD" in *"$PY"*) break ;; esac
            sleep 2
            w=$((w + 2))
        done
        case "$CMD" in
            *"$PY"*) ok "the run script exec'd the interpreter (${w}s) -- s6 holds moonraker, not a shell" ;;
            *) bad "after ${w}s the process s6 holds is still '$CMD' -- the run script never exec'd" ;;
        esac
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
    # running server. On the supervised path nothing writes it in the first
    # place, so this is a weaker statement there -- which is why the upgrade
    # path is proved for real a few lines down.
    [ -f /run/moonraker.pid ] \
        && bad "stop left a stale pidfile -- status would report a recycled PID" \
        || ok "stop cleared the pidfile"

    # THE UPGRADE PATH, which is the one case where a pidfile still matters
    # under s6. A printer running the pre-phase-5 payload has a
    # start-stop-daemon'd moonraker alive with its pid in /run/moonraker.pid.
    # Install this payload and type `S62moonraker restart` rather than
    # rebooting, and if stop() ignored that file the old server would still be
    # holding :7125 -- and the supervised copy would then fail to bind, exit,
    # be respawned, and loop for ever while s6-svstat cheerfully said "up".
    # A `sleep` stands in for the old server: what is being measured is whether
    # stop() reaps a pid it did not start, not what that pid was doing.
    sleep 300 &
    LEGACY=$!
    echo $LEGACY > /run/moonraker.pid
    $S62 stop >/dev/null 2>&1
    if kill -0 $LEGACY 2>/dev/null; then
        bad "stop left the pre-s6 moonraker (pid $LEGACY) running -- an upgraded printer would fight itself for :$PORT"
        kill -9 $LEGACY 2>/dev/null
    else
        ok "stop reaped the pre-s6 moonraker named by /run/moonraker.pid (pid $LEGACY)"
    fi
    [ -f /run/moonraker.pid ] \
        && bad "and it left the stale pidfile behind" \
        || ok "and removed the stale pidfile with it"

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
    # nginx is a supervised service too now, so `S60nginx start` returns when
    # s6 has FORKED it -- before it has parsed its config, bound :80 and
    # written logs/nginx.pid. Under start-stop-daemon the pidfile was there the
    # moment start returned; under s6 it is not, and reading it immediately
    # reported a perfectly healthy nginx as never having come up. Same fork-is-
    # not-ready gap as the exec wait above, and the same bounded fix.
    w=0
    while [ $w -lt 30 ] && ! nginx_alive; do
        sleep 2
        w=$((w + 2))
    done
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
            # AND THE INDEPENDENCE IS NOW TWO s6 SERVICES, not just two scripts.
            # They share the scandir, the scanner and MOD_WEB, so "stop one" has
            # a new way to go wrong: `s6-svc -d` against the wrong service
            # directory, or an S62moonraker stop that reached for the scanner
            # instead. Asked of s6 itself, which is the only thing that can tell
            # a service that is down on purpose from one that was never started.
            if [ "$S6_REAL" = 1 ]; then
                nst=`$S6/s6-svstat $SCANDIR/nginx 2>&1`
                mst=`$S6/s6-svstat $SVCDIR 2>&1`
                case "$nst" in
                    up*) ok "s6 still has nginx up: $nst" ;;
                    *)   bad "stopping moonraker took the nginx SERVICE down too: $nst" ;;
                esac
                case "$mst" in
                    down*) ok "and moonraker down: $mst" ;;
                    *)     bad "moonraker is not down after S62moonraker stop: $mst" ;;
                esac
            fi
        fi
        $S60N stop >/dev/null 2>&1
        $S62 stop >/dev/null 2>&1
    fi
fi

# ---- 11. a missing tree is reported, not routed around ---------------------
# There is no stock moonraker to fall back to, so the one thing this must never
# do is fail silently.
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

# ============================================================================
# Sections 12 to 16: moonraker AS A SUPERVISED SERVICE.
#
# Everything above ran the moonraker that is actually installed, which is what
# makes it the right place to ask "is this the tree and the interpreter we
# meant". It is the wrong place to ask about SUPERVISION, for the same reason
# case-camera.sh wraps mjpg_streamer: the interesting behaviour is a timing
# relationship -- forked at t=0, listening at t=n, respawned m seconds after a
# kill -- and the real moonraker's n is "the better part of a minute, if the
# tree on this replica can serve at all", which measures s6 badly and takes ten
# minutes doing it.
#
# So the ENTRY POINT is stood in for, and nothing else is. The stand-in is a
# python script at exactly the path the run script names, run by exactly the
# interpreter the run script chooses, through exactly our shipped run script,
# our shipped down file, our shipped notification-fd, our shipped
# init.d/S62moonraker and the real cross-built s6. It waits a controllable
# number of seconds and then binds :7125 and answers -- which is what a real
# moonraker does, slowly, while it imports its components. That delay is what
# makes readiness observable at all.
#
# NOT TESTED HERE: that the real Moonraker binds its port promptly. That is a
# statement about Moonraker, sections 6 to 8 are where the real tree is run,
# and it is not a claim this change makes.
if [ "$S6_REAL" != 1 ]; then
    echo
    skip "sections 12-16 (supervision, readiness, respawn, MOD_WEB) need the real s6"
    skip "-- pass sup.tgz=work/.s6-gate.tgz to run them"
else
    echo
    echo "=== 12. readiness gates: -U blocks on LISTENING, not on FORKED ==="
    $S62 stop >/dev/null 2>&1
    mv "$MOONRAKER_MAIN" "$MOONRAKER_MAIN.real"
    cat > "$MOONRAKER_MAIN" <<'EOSTANDIN'
# Stand-in moonraker. Sleeps /tmp/mr-delay seconds -- standing in for the
# component imports a real moonraker spends its startup on -- and then binds
# :7125 and answers, which is the condition our run script probes for
# readiness. The -d argument the run script passes is accepted and ignored:
# what is under test is our service definition and s6's behaviour, not
# moonraker's config parsing.
import sys, time
try:
    delay = int(open('/tmp/mr-delay').read().strip())
except Exception:
    delay = 0
sys.stderr.write('standin: argv=%r, sleeping %ds before binding\n'
                 % (sys.argv, delay))
sys.stderr.flush()
time.sleep(delay)
import socketserver
from http.server import BaseHTTPRequestHandler

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"result": {"klippy_state": "ready"}}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('0.0.0.0', 7125), H).serve_forever()
EOSTANDIN
    # THE DELAY IS 40 SECONDS, AND THAT NUMBER IS MEASURED. It has to be longer
    # than everything between "T0" and the moment this case can look at the
    # service -- and on qemu-mipsel that is not instant: `S62moonraker start`
    # sources two shell libraries, pings the scanner, runs s6-svok and s6-svc
    # -wu, and each of those is a qemu exec. The first version of this section
    # used 12 seconds, `start` alone took 13, and the "is it still blocking?"
    # check ran after the stand-in had already bound the port -- reporting that
    # readiness had answered "forked" when in fact the measurement window had
    # closed before it opened. So: a delay with room in it, and an assertion
    # below that refuses to pass if the window closed anyway.
    MRDELAY=40
    echo $MRDELAY > /tmp/mr-delay

    # Three things are measured against the SAME start:
    #
    #   * s6 reports the service UP almost immediately -- the process was
    #     forked, which is all the old pidfile and the old moonraker_check ever
    #     knew.
    #   * s6-svwait -U is STILL BLOCKING at that moment.
    #   * s6-svwait -U returns at about twelve seconds, when :7125 is bound.
    #
    # The middle one is the check that cannot be faked: a readiness that
    # returned on fork would already have returned by then, and the elapsed-time
    # assertion on its own could be satisfied by an s6-svwait that was slow for
    # any reason at all.
    rm -f /tmp/ready.at
    T0=`date +%s`
    ( $S6/s6-svwait -U -t 60000 $SVCDIR >/dev/null 2>&1 && date +%s > /tmp/ready.at ) &
    # NOT `$S62 start | sed`, and this cost a whole run of this case to find.
    # start() detaches its readiness reporter with svc_detach, and that child
    # inherits stdout -- which is the POINT on a boot, where the verdict is
    # meant to arrive in the log later, after the services that started next.
    # Down a pipe it means something else: `sed` does not see end-of-input
    # until every writer has closed, so the pipeline sat there for the whole
    # 40-second readiness wait and `start` appeared to take 43s. Measured here.
    # A file has no such property; the reporter's lines land in it when they
    # are written and this shell carries on.
    $S62 start > /tmp/s62-ready.out 2>&1
    # However long `start` took, the window is whatever is left of MRDELAY. The
    # observation is taken immediately and its elapsed time recorded with it, so
    # that "still blocking" is only ever claimed at a moment when the stand-in
    # genuinely had not bound yet.
    OBS=$((`date +%s` - T0))
    st=`$S6/s6-svstat $SVCDIR 2>&1`
    if [ $OBS -ge $((MRDELAY - 5)) ]; then
        bad "S62moonraker start took ${OBS}s, which is not less than the ${MRDELAY}s stand-in delay -- the readiness window closed before it could be measured; raise MRDELAY"
    else
        case "$st" in
            up*)
                ok "${OBS}s after start s6 reports the service UP: $st"
                if [ -f /tmp/ready.at ]; then
                    bad "s6-svwait -U had ALREADY returned while moonraker was still $((MRDELAY - OBS))s from binding -- it is answering 'forked', not 'ready'"
                else
                    ok "s6-svwait -U is still blocking although the process is up -- UP IS NOT READY"
                fi ;;
            *)
                bad "the service is not up ${OBS}s after start, so nothing here measures readiness: $st" ;;
        esac
        port_listening \
            && bad ":$PORT is bound ${OBS}s in, so the ${MRDELAY}s stand-in delay did not happen and this section measured nothing" \
            || ok "and nothing is listening on :$PORT yet, which is why it is not ready"
    fi

    w=0
    while [ ! -f /tmp/ready.at ] && [ $w -lt 90 ]; do
        sleep 1
        w=$((w + 1))
    done
    if [ -f /tmp/ready.at ]; then
        E=$((`cat /tmp/ready.at` - T0))
        if [ $E -ge $((MRDELAY - 4)) ] && [ $E -le $((MRDELAY + 40)) ]; then
            ok "s6-svwait -U returned after ${E}s -- when moonraker bound :$PORT, not when it forked (the delay is ${MRDELAY}s)"
        else
            bad "s6-svwait -U returned after ${E}s, which is neither the ~${MRDELAY}s readiness delay nor a timeout"
        fi
    else
        bad "s6-svwait -U never saw a readiness notification (waited ${w}s) -- the notification-fd path is broken"
    fi
    # And what S62moonraker itself said, now that its detached reporter has
    # had its answer. The line is the whole reason the init script waits on
    # readiness rather than on a pid: it is printed when the API is there.
    sed 's/^/      /' /tmp/s62-ready.out
    grep -q "answering on :$PORT" /tmp/s62-ready.out \
        && ok "S62moonraker's detached reporter said so too: `grep 'answering' /tmp/s62-ready.out | head -1`" \
        || bad "S62moonraker never reported the API as up: `tail -1 /tmp/s62-ready.out`"
    # Readiness that is not followed by an API that answers is a bug in what
    # "ready" was defined to mean, so the claim is checked against the thing a
    # caller actually does: an HTTP request. ff-startup.py polls this exact
    # endpoint to learn klippy_state.
    if wget -q -O - -T 5 "http://127.0.0.1:$PORT/server/info" 2>/dev/null | grep -q klippy; then
        ok "and http://127.0.0.1:$PORT/server/info answers -- ready meant usable"
    else
        bad ":$PORT is bound but /server/info served nothing"
    fi

    echo
    echo "=== 13. kill it -- THE point of the migration ==="
    # SIGKILL, not SIGTERM: SIGTERM is the polite path s6 itself uses and is not
    # what a crash looks like. Before phase 5 a moonraker that fell over stayed
    # fallen until somebody noticed the UI was dead and ssh'd in, because a
    # shell that has returned cannot restart anything.
    echo 0 > /tmp/mr-delay
    pid1=`moonraker_pid`
    if [ -z "$pid1" ]; then
        bad "no pid to kill -- section 12 left nothing running"
    else
        note "killing pid $pid1 with SIGKILL"
        kill -9 "$pid1" 2>/dev/null
        w=0
        pid2=$pid1
        while [ $w -lt 40 ]; do
            sleep 1
            w=$((w + 1))
            pid2=`moonraker_pid`
            [ -n "$pid2" ] && [ "$pid2" != "$pid1" ] && break
        done
        if [ -n "$pid2" ] && [ "$pid2" != "$pid1" ]; then
            ok "s6 respawned moonraker after kill -9 (pid $pid1 -> $pid2, ${w}s)"
        else
            bad "moonraker was NOT respawned after kill -9 (still '$pid2') -- nothing is supervising it"
        fi
        w=0
        while [ $w -lt 40 ] && ! port_listening; do
            sleep 1
            w=$((w + 1))
        done
        port_listening \
            && ok "and the respawned moonraker bound :$PORT again (${w}s)" \
            || bad "the respawned moonraker is not serving -- see /usr/data/logs/s6.log"
    fi

    echo
    echo "=== 14. S62moonraker stop, and STAY stopped ==="
    # The bug this section exists for: `s6-svc -d` is not "kill the process", it
    # is "the service is wanted down". A stop implemented as a kill would be
    # undone by the supervisor a second later, and nobody would notice until
    # they tried to stop moonraker and could not.
    $S62 stop 2>&1 | sed 's/^/      /'
    st=`$S6/s6-svstat $SVCDIR 2>&1`
    case "$st" in
        down*) ok "s6-svstat immediately after stop: $st" ;;
        *)     bad "S62moonraker stop did not bring it down: $st" ;;
    esac
    port_listening \
        && bad ":$PORT is still bound after stop" \
        || ok ":$PORT stopped answering"
    $S62 status 2>&1 | grep -q '^moonraker: not running' \
        && ok "status is honest about it: `$S62 status 2>&1 | head -1`" \
        || bad "status does not say 'not running' after stop: `$S62 status 2>&1 | head -1`"
    note "waiting 12s to see whether the supervisor puts it back"
    sleep 12
    st=`$S6/s6-svstat $SVCDIR 2>&1`
    case "$st" in
        down*) ok "12 seconds later it is STILL down: $st" ;;
        *)     bad "the supervisor undid the stop: $st" ;;
    esac
    port_listening \
        && bad "something respawned moonraker after stop -- :$PORT is bound again" \
        || ok "and :$PORT is still free"

    echo
    echo "=== 15. MOD_WEB=0 means no moonraker ==="
    # The gate is read AT RUNTIME by init.d/S62moonraker, which is the only
    # thing that has sourced anvil.conf. The `down` file is the other half: the
    # scanner never starts moonraker on its own, so "disabled" cannot degrade
    # into "runs for two seconds on every boot and is then shot".
    sed -i 's/^MOD_WEB=.*/MOD_WEB=0/' $MODDIR/anvil.conf
    grep -q '^MOD_WEB=0' $MODDIR/anvil.conf || bad "could not set MOD_WEB=0 in anvil.conf"
    out=`$S62 start 2>&1`
    echo "$out" | sed 's/^/      /'
    echo "$out" | grep -q "MOD_WEB=0" \
        && ok "S62moonraker start says it is disabled" \
        || bad "S62moonraker start did not mention MOD_WEB: $out"
    sleep 6
    st=`$S6/s6-svstat $SVCDIR 2>&1`
    case "$st" in
        down*) ok "and moonraker is still down: $st" ;;
        *)     bad "MOD_WEB=0 but moonraker is running: $st" ;;
    esac
    port_listening \
        && bad ":$PORT answers with MOD_WEB=0 -- the gate does not gate" \
        || ok "nothing is listening on :$PORT with MOD_WEB=0"
    # And back on again in the same session, without reinstalling anything:
    # the switch is a runtime read of a runtime file, which is exactly why it
    # lives in the init script rather than in the payload.
    sed -i 's/^MOD_WEB=.*/MOD_WEB=1/' $MODDIR/anvil.conf
    $S62 start >/dev/null 2>&1
    w=0
    while [ $w -lt 40 ] && ! port_listening; do
        sleep 1
        w=$((w + 1))
    done
    port_listening \
        && ok "MOD_WEB=1 after an edit brings it straight back (${w}s)" \
        || bad "MOD_WEB=1 did not bring moonraker back after ${w}s"
    $S62 stop >/dev/null 2>&1

    echo
    echo "=== 16. negative control: the same service, daemonised ==="
    # Everything from section 12 down rests on the run script exec'ing moonraker
    # in the FOREGROUND, and "we removed the -b" is precisely the kind of claim
    # that goes on being true in a comment long after it has stopped being true
    # in the code. So here is the service somebody would have written by copying
    # the old start line -- start-stop-daemon -S -b, which forks and returns --
    # supervised by the same s6, in a scandir of its own so it cannot disturb
    # anything, running `sleep` so it is not fighting for :7125 either.
    #
    # It must CHURN: s6 supervises the process that forked and exited, sees it
    # die at once, and starts it again, for ever, while an unsupervised child
    # runs on. Beside it, in the SAME scandir under the SAME scanner, is the
    # same service written the way ours is -- one `exec` and no backgrounding --
    # which must sit there stable. The pair is the point: if both looked alike,
    # the sections above would be measuring nothing.
    #
    # HOW CHURN IS MEASURED, and why it is not "the pid changed". A service
    # being restarted several times a second is DOWN whenever you look at it --
    # measured here: five samples of `s6-svstat -p` returned -1 every time,
    # which a naive distinct-pid count reads as "perfectly stable". What
    # separates the two is the AGE: s6-svstat's "N seconds" is the time since
    # the service last changed state, so a churning service can never age past
    # a second or two while a stable one climbs with the wall clock.
    mkdir -p /tmp/negctl/daemonised /tmp/negctl/foreground
    cat > /tmp/negctl/daemonised/run <<'EONEG'
#!/bin/sh
exec start-stop-daemon -S -b -m -p /tmp/negctl.pid --exec /bin/sleep -- 600
EONEG
    cat > /tmp/negctl/foreground/run <<'EOPOS'
#!/bin/sh
exec /bin/sleep 600
EOPOS
    chmod +x /tmp/negctl/daemonised/run /tmp/negctl/foreground/run
    $S6/s6-svscan /tmp/negctl >/tmp/negctl.log 2>&1 &
    sleep 6
    # The oldest age either service reaches over ~15 seconds of sampling.
    svc_max_age() {
        _max=0
        for _i in 1 2 3 4 5; do
            _a=`$S6/s6-svstat "$1" 2>/dev/null | sed -n 's/.* \([0-9][0-9]*\) seconds.*/\1/p'`
            [ -n "$_a" ] && [ "$_a" -gt "$_max" ] 2>/dev/null && _max=$_a
            sleep 3
        done
        echo $_max
    }
    NEGAGE=`svc_max_age /tmp/negctl/daemonised`
    POSAGE=`svc_max_age /tmp/negctl/foreground`
    if [ "$NEGAGE" -le 5 ]; then
        ok "negative control: a daemonising service never ages past ${NEGAGE}s -- s6 is respawning it over and over"
    else
        bad "negative control: a daemonising service aged to ${NEGAGE}s, i.e. it looked stable -- foregrounding is not what makes the checks above pass"
    fi
    if [ "$POSAGE" -gt 5 ]; then
        ok "and the same service written with a plain exec sits stable (${POSAGE}s) under the same scanner"
    else
        bad "even a plain foreground service churned here (${POSAGE}s) -- this scandir proves nothing either way"
    fi
    $S6/s6-svc -d /tmp/negctl/daemonised 2>/dev/null
    $S6/s6-svc -d /tmp/negctl/foreground 2>/dev/null
    $S6/s6-svscanctl -t /tmp/negctl 2>/dev/null
    sleep 2
    kill -9 `cat /tmp/negctl.pid 2>/dev/null` 2>/dev/null

    # ---- put the real tree back and leave nothing running ------------------
    rm -f "$MOONRAKER_MAIN"
    mv "$MOONRAKER_MAIN.real" "$MOONRAKER_MAIN"
    $S62 stop >/dev/null 2>&1
    $S60N stop >/dev/null 2>&1
    $S40 stop >/dev/null 2>&1
    sleep 2
    LEFT=`ps 2>/dev/null | grep 's6-svscan\|s6-supervise' | grep -v grep | grep -v case`
    [ -z "$LEFT" ] \
        && ok "S40s6 stop took the supervisors down with it" \
        || bad "s6 processes survived: `echo "$LEFT" | tr '\n' ';'`"
fi

echo
[ $FAIL = 0 ] && echo "moonraker: all checks passed" || echo "moonraker: FAILURES"
exit $FAIL
