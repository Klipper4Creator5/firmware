#!/bin/sh
# The REAL Moonraker, on OUR CPython 3.13, brought up by init.d/S62moonraker
# under the s6 we cross-built. The last gate before FF_PYTHON moves.
#
# WHY THIS IS A THIRD CASE AND NOT AN EXTENSION OF EITHER OF THE OTHER TWO.
# There were two obvious homes for this and both of them are the wrong one for
# a reason worth writing down, because "why is there a third moonraker case?"
# is the first question anybody reading this directory will ask.
#
#   case-moonraker.sh runs the real init scripts and the real s6, and it is
#   the gate that catches a Moonraker pin that cannot import -- but its
#   supervision sections (12 to 16) deliberately stand the ENTRY POINT in with
#   a 30-line python that binds :7125 after a controllable delay. That is the
#   right decision there and it is written out at length in that file: what
#   those sections measure is a timing relationship, and the real Moonraker's
#   "forked at t=0, listening at t=n" has an n of the better part of a minute
#   on qemu, which measures s6 badly and takes ten minutes doing it. Making
#   that case ALSO do the whole thing twice, once per interpreter, would
#   double a 1000-line case that already takes the longest of any gate here,
#   and it would put the 3.8 run and the 3.13 run in one replica, sharing one
#   /usr/data, one :7125 and one scandir.
#
#   case-moonraker313.sh runs the real Moonraker on the real 3.13 -- and its
#   header says, in as many words, that it drives the entry point DIRECTLY on
#   purpose, "so that anything that fails is the interpreter, the extensions
#   or Moonraker itself". Putting init scripts back into it would destroy the
#   property that case exists to have.
#
# So the two of them leave exactly one hole between them, and this is it: the
# real tree, the real interpreter, the real supervisor, the real init script,
# all at once. Nothing here stands anything in. It is slower than both of its
# parents and it is the only one of the three whose failure means "do not
# switch FF_PYTHON".
#
# WHAT IT ASSERTS, in the order the boot does them:
#
#   * S40s6 starts the scanner, which picks the service directory up and
#     leaves moonraker DOWN, because the payload ships a `down` file.
#   * MOD_WEB=0 keeps it down. That is checked first, while it is cheap.
#   * S62moonraker start brings it up through svc_s6_up, and the process s6
#     ends up holding is OUR interpreter running OUR entry point -- read out
#     of /proc/PID/cmdline, not inferred.
#   * READINESS ACTUALLY GATES. s6-svwait -U must not return because the
#     process was forked; it must return when :7125 is LISTENING. Asserted two
#     ways so it cannot pass vacuously -- see section 5.
#   * GET /server/info answers, with components loaded and none failed.
#   * the running process maps ZERO libraries under /usr/prog.
#   * kill -9 and s6 puts it back, on 3.13 again, listening again.
#   * S62moonraker stop stops it and the supervisor does not undo that.
#   * negative control: take our site-packages away and the same service
#     cannot come up, however hard s6 tries.
#
# THE SWITCH, AND HOW THIS CASE RUNS ON BOTH SIDES OF IT. What is under test
# is the POST-switch configuration: FF_PYTHON at $MODDIR/bin/python3.13 and no
# /usr/prog/libsodium on ANVIL_LIBS. Before payload/anvil-env.sh has made that
# change this case applies it itself, to the installed copy, with the same two
# edits the commit makes -- and says out loud that it did. Afterwards it
# applies nothing and asserts the shipped file already says so. Either way the
# thing measured is identical, which is what stops this gate from either
# blocking the switch it exists to authorise or rotting the day after it.
#
# WHAT ARRIVES, AND FROM WHERE. Three tarballs, because none of the three is
# in payload/ -- they are build outputs, exactly as work/.s6 is:
#
#     sup.tgz     work/.s6            bin/ + libexec/, the cross-built s6
#     pref.tgz    work/pkg/python* +   bin/python3.13, lib/python3.13 (stdlib
#                 work/.sodium        AND site-packages) and libsodium.so*.
#                                     One tarball because it is one prefix:
#                                     bin/patch.sh sections 5c and 5d put both
#                                     of them under $MODDIR.
#     mr.tgz      vendor/ + assets/   moonraker/ and config/, the two payload
#                                     subtrees patch.sh builds from those.
#
# The payload itself is mounted at /tmp/payload, as in every other case here.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
skip() { echo "  SKIP  $*"; }
note() { echo "  ..    $*"; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
PY313=$MODDIR/bin/python3.13
PY38=/usr/prog/Python-3.8.2/bin/python3
SP=$MODDIR/lib/python3.13/site-packages
MOONRAKER_MAIN=$MODDIR/moonraker/moonraker.py
S6=$MODDIR/bin
SCANDIR=$MODDIR/etc/s6
SVCDIR=$SCANDIR/moonraker
S40=$MODDIR/init.d/S40s6
S62=$MODDIR/init.d/S62moonraker
PORT=7125
SODIUM_PROG=/usr/prog/libsodium/lib

[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }
for t in /mnt/sup.tgz /mnt/pref.tgz /mnt/mr.tgz; do
    [ -f "$t" ] || { bad "no $t -- this case needs all three build outputs"; exit 1; }
done

# ---- install, the way run-append.sh installs -------------------------------
# Same order and the same tools: the payload files first, then the tarballs
# unpacked into $MODDIR (which is what the installer's `tar -x` does to the
# real package), then the configs copied into /usr/data/config the way
# run-append.sh's config loop does for a first install.
mkdir -p $MODDIR/init.d $MODDIR/etc
cp -f $PAYLOAD/anvil-env.sh $PAYLOAD/anvil-service.sh $PAYLOAD/anvil.conf $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/init.d/S* $MODDIR/init.d/ 2>/dev/null
chmod +x $MODDIR/init.d/S* 2>/dev/null
# cp -a, contents and mode: a per-file copy silently drops `down` and
# `notification-fd` (neither is a script and neither matches any *.sh glob)
# and can lose the +x on `run`, which is a service s6 can never start and
# reports only in its own log.
[ -d $PAYLOAD/etc/s6 ] && cp -a $PAYLOAD/etc/s6 $MODDIR/etc/ 2>/dev/null

gzip -dc /mnt/sup.tgz  | tar -x -C $MODDIR || { bad "cannot unpack sup.tgz";  exit 1; }
gzip -dc /mnt/pref.tgz | tar -x -C $MODDIR || { bad "cannot unpack pref.tgz"; exit 1; }
gzip -dc /mnt/mr.tgz   | tar -x -C $MODDIR || { bad "cannot unpack mr.tgz";   exit 1; }
chmod +x $S6/* $MODDIR/libexec/* $PY313 2>/dev/null
mkdir -p /usr/data/config /usr/data/logs /usr/data/tmp
cp -f $MODDIR/config/moonraker.conf $MODDIR/config/moonraker-custom.conf \
      /usr/data/config/ 2>/dev/null

[ -x "$PY313" ]        || { bad "no interpreter at $PY313"; exit 1; }
[ -f "$MOONRAKER_MAIN" ] || { bad "no moonraker.py at $MOONRAKER_MAIN"; exit 1; }
[ -x "$S6/s6-svscan" ] || { bad "no s6-svscan at $S6"; exit 1; }
[ -x "$S62" ]          || { bad "the payload ships no init.d/S62moonraker"; exit 1; }
[ -f /usr/data/config/moonraker.conf ] \
    || { bad "no moonraker.conf at /usr/data/config -- the run script reads its port from there"; exit 1; }
ok "installed: payload + s6 + the 3.13 prefix + the Moonraker tree, all under $MODDIR"
note "interpreter: `$PY313 -c 'import sys; print(sys.version)' 2>&1 | head -1`"

echo
echo "=== 1. the switch: which interpreter does the shipped env name? ==="
# Read by BEHAVIOUR wherever behaviour can answer -- what a caller gets when it
# sources the file -- and by grep only for the question grep is the right tool
# for, which is "has the shipped source been changed yet".
if grep -q '^FF_PYTHON=.*/bin/python3\.13$' $MODDIR/anvil-env.sh; then
    SHIPPED_SWITCH=1
    ok "the SHIPPED anvil-env.sh already points FF_PYTHON at 3.13 -- nothing forced here"
else
    SHIPPED_SWITCH=0
    note "PRE-SWITCH: the shipped anvil-env.sh still names FlashForge's 3.8.2."
    note "This case applies the two edits the switch commit makes, to the"
    note "INSTALLED copy only, and then measures the result. That is what makes"
    note "it the gate that authorises the switch rather than one that waits for it."
    sed -i "s|^FF_PYTHON=.*|FF_PYTHON=$PY313|" $MODDIR/anvil-env.sh
    # And the other half of the same one-commit change. It is not cosmetic
    # here: with /usr/prog/libsodium/lib still on LD_LIBRARY_PATH, libnacl's
    # bare dlopen("libsodium.so") can be answered by FlashForge's copy, and
    # section 7's "zero /usr/prog libraries" would then be measuring a
    # configuration nobody is proposing to ship.
    #
    # Done by APPENDING a correction rather than by deleting the line from the
    # ANVIL_LIBS assignment, and that is not laziness. ANVIL_LIBS is one
    # multi-line quoted string whose LAST entry carries the closing quote, so a
    # line-delete gets the quoting right only for as long as libsodium stays
    # last -- a sed that silently produces an unterminated string would break
    # every script that sources this file, and it would do it in a case whose
    # job is to tell the truth about that file. Appending after the loop that
    # builds LD_LIBRARY_PATH reaches the same environment by a route that
    # cannot depend on the order of the list.
    cat >> $MODDIR/anvil-env.sh <<EOSW

# Appended by case-moonraker313-s6.sh: the second half of the FF_PYTHON switch,
# applied to this INSTALLED copy only. Delete this block once payload/
# anvil-env.sh has dropped $SODIUM_PROG from ANVIL_LIBS itself.
LD_LIBRARY_PATH=\`echo "\$LD_LIBRARY_PATH" | sed -e 's|$SODIUM_PROG:||g' -e 's|:$SODIUM_PROG||g'\`
export LD_LIBRARY_PATH
EOSW
fi

# What a caller actually gets. Everything below runs in this environment,
# exactly as init.d/S62moonraker and etc/s6/moonraker/run both do.
. $MODDIR/anvil-env.sh

[ "$FF_PYTHON" = "$PY313" ] \
    && ok "sourcing anvil-env.sh gives FF_PYTHON=$FF_PYTHON" \
    || bad "FF_PYTHON is '$FF_PYTHON', expected $PY313"
if "$FF_PYTHON" -c 'import sys; print("py " + sys.version.split()[0])' > /tmp/ver.out 2>&1; then
    ok "and it runs: `grep '^py ' /tmp/ver.out`"
else
    bad "FF_PYTHON does not run: `tail -2 /tmp/ver.out`"
fi
case ":$LD_LIBRARY_PATH:" in
    *":$SODIUM_PROG:"*) bad "$SODIUM_PROG is still on LD_LIBRARY_PATH -- our libsodium is not the one that will be found" ;;
    *)                  ok "$SODIUM_PROG is off LD_LIBRARY_PATH" ;;
esac
# The one thing that must NOT have happened: this is not a rename of
# FlashForge's interpreter, it is a different one.
[ "$FF_PYTHON" = "$PY38" ] && bad "FF_PYTHON is FlashForge's 3.8.2 -- nothing below tests 3.13"
# A cheap positive control on the claim the whole exercise is for. If 3.8 could
# do this, none of this would have been built.
"$PY38" -c 'import sqlite3' >/dev/null 2>&1 \
    && note "NOTE: FlashForge's 3.8.2 imports sqlite3 here -- unexpected; see case-python.sh" \
    || ok "control: FlashForge's 3.8.2 still cannot import sqlite3, and ours can:"
"$FF_PYTHON" -c 'import sqlite3; print("        sqlite3 " + sqlite3.sqlite_version)' 2>&1 | sed 's/^/  /'

echo
echo "=== 2. negative controls, before anything is started ==="
port_listening() {
    awk -v p=":`printf '%04X' $PORT`" '$2 ~ p"$" && $4 == "0A" { f = 1 }
                                       END { exit !f }' /proc/net/tcp 2>/dev/null
}
# If something in this rootfs were already holding :7125, every readiness and
# respawn check below would be true for free.
port_listening \
    && bad "something is ALREADY listening on :$PORT before anything was started" \
    || ok "nothing is listening on :$PORT"
# And no moonraker of any interpreter is running yet, so a "moonraker came up"
# below cannot be somebody else's leftover.
NPRE=0
for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    case "`tr '\0' ' ' < "$p/cmdline" 2>/dev/null`" in
        *moonraker.py*) NPRE=$((NPRE + 1)) ;;
    esac
done
[ "$NPRE" = 0 ] \
    && ok "and no moonraker.py process exists yet" \
    || bad "$NPRE moonraker.py process(es) are already running"

echo
echo "=== 3. S40s6: the scanner, and a service it leaves alone ==="
$S40 start 2>&1 | sed 's/^/      /'
sleep 3
if $S40 status | grep -q "scanning $SCANDIR"; then
    ok "S40s6 has a scanner on $SCANDIR"
else
    bad "no scanner after S40s6 start: `$S40 status 2>&1 | head -2 | tr '\n' ' '`"
    echo "RESULT: FAIL (nothing below can run without a scanner)"
    exit 1
fi
[ -x $SVCDIR/run ] && ok "the payload ships an executable $SVCDIR/run" \
                   || bad "$SVCDIR/run is missing or not executable"
[ -f $SVCDIR/notification-fd ] \
    && ok "it declares a notification-fd (`cat $SVCDIR/notification-fd`)" \
    || bad "no notification-fd -- readiness cannot work at all"
[ -s $SVCDIR/down ] && ok "and a 'down' file, so the scanner does not start it" \
                    || bad "no 'down' file -- the MOD_WEB gate would be decorative"
st=`$S6/s6-svstat $SVCDIR 2>&1`
case "$st" in
    down*) ok "the scanner picked moonraker up and left it DOWN: $st" ;;
    *)     bad "moonraker came up on its own, before anything read anvil.conf: $st" ;;
esac
# THE NEGATIVE CONTROL FOR READINESS ITSELF, and it has to be taken here rather
# than at section 5: s6-svwait -U against a service that has never declared
# itself must FAIL. If it succeeded, the timing measured at 5 would mean
# nothing at all.
if $S6/s6-svwait -U -t 4000 $SVCDIR >/dev/null 2>&1; then
    bad "s6-svwait -U SUCCEEDED on a service that never notified -- readiness is a no-op here"
else
    ok "s6-svwait -U times out on a service that has not declared itself ready"
fi

echo
echo "=== 4. MOD_WEB=0 leaves it down ==="
# Checked before the expensive part, because it costs nothing: the whole point
# of MOD_WEB=0 is that no moonraker is started, so there is nothing to wait for.
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
port_listening && bad ":$PORT answers with MOD_WEB=0 -- the gate does not gate" \
               || ok "nothing is listening on :$PORT with MOD_WEB=0"
sed -i 's/^MOD_WEB=.*/MOD_WEB=1/' $MODDIR/anvil.conf

echo
echo "=== 5. S62moonraker start -- and READINESS THAT ACTUALLY GATES ==="
#
# The bug this section exists to catch is a readiness notification that fires
# on FORK. It would look perfectly healthy: the service comes up, s6-svwait -U
# returns, S62moonraker prints "answering on :7125" -- and every caller that
# waited (bin/ff-startup.py above all) would go on to poll an API that is not
# there yet, which is the exact failure the notification-fd was added to end.
#
# It is asserted TWO ways, because either on its own can pass for the wrong
# reason:
#
#   (a) THE INSTANT OBSERVATION. Immediately after `S62moonraker start`
#       returns -- which svc_s6_up makes "when s6 has FORKED the run script",
#       deliberately, see the comment there -- the service must be UP and
#       s6-svwait -U must still be BLOCKING, with :7125 not yet bound. Up and
#       not-ready, asserted together, is what stops this passing vacuously
#       against a service that never started at all: case-camera.sh and
#       case-moonraker.sh both take the same pair.
#   (b) THE ORDERING. A sampler records the first second at which :7125 is
#       listening; the waiter records the second at which s6-svwait -U
#       returned. readiness must not precede the bind. Unlike (a) this one is
#       always measurable -- it does not depend on the observation landing
#       inside a window -- so if Moonraker on this replica ever gets fast
#       enough to bind before `start` returns, the gate degrades to (b) rather
#       than silently measuring nothing.
#
# There is no stand-in delay here and there must not be one. What (a) is
# measuring is the REAL gap between fork and listen for the real Moonraker on
# the real interpreter -- a number nothing else in this suite has ever
# reported, because case-moonraker.sh stands the entry point in precisely so
# that it does not have to wait for it.
rm -f /tmp/ready.at /tmp/bound.at
T0=`date +%s`
# The bind sampler. Deliberately NOT a 1-second poll -- section (b) below
# compares this timestamp against s6-svwait -U, which is event-driven and
# returns within a fraction of a second of the run script's own internal
# check confirming the port is bound. A 1-second poll here can lag the TRUE
# bind moment by up to a second, and `date +%s` truncates both readings to
# whole seconds -- so a bind at 5.05s sampled at 6.0s reads as "6", while a
# readiness signal at 5.10s reads as "5", and (b) sees ready before bound
# though the real events were in the right order microseconds apart. Measured
# exactly that flake once. 0.2s polling shrinks the lag fivefold; the 300s
# timeout budget is kept by scaling the iteration count with it.
( _n=0
  while [ $_n -lt 1500 ]; do
      if port_listening; then date +%s > /tmp/bound.at; exit 0; fi
      sleep 0.2
      _n=$((_n + 1))
  done ) &
BINDER=$!
( $S6/s6-svwait -U -t 300000 $SVCDIR >/dev/null 2>&1 && date +%s > /tmp/ready.at ) &
WAITER=$!

# NOT `$S62 start | sed`. start() detaches its readiness reporter with
# svc_detach and that child inherits stdout, so down a pipe `sed` does not see
# end-of-input until the reporter exits -- and the whole readiness wait would
# be charged to `start`, closing the window at (a) before it opened. A file has
# no such property. (Measured in case-moonraker.sh; the same trap, kept.)
$S62 start > /tmp/s62-start.out 2>&1
OBS=$((`date +%s` - T0))
st=`$S6/s6-svstat $SVCDIR 2>&1`
sed 's/^/      /' /tmp/s62-start.out

case "$st" in
    up*) ok "${OBS}s after start, s6 reports the service UP: $st" ;;
    *)   bad "the service is not up ${OBS}s after start: $st" ;;
esac
if port_listening; then
    note "(a) could not be measured: :$PORT was already bound ${OBS}s in, so"
    note "    there was no fork-but-not-listening window left to observe."
    note "    (b) below is then the whole of the readiness claim."
    INSTANT=0
else
    INSTANT=1
    ok "(a) :$PORT is NOT bound ${OBS}s in -- there is a window to measure"
    case "$st" in
        up*) if [ -f /tmp/ready.at ]; then
                 bad "(a) s6-svwait -U had ALREADY returned while moonraker was up and NOT listening -- it is answering 'forked', not 'ready'"
             else
                 ok "(a) and s6-svwait -U is still blocking although the process is up -- UP IS NOT READY"
             fi ;;
        *)   bad "(a) the service is not up, so this observation says nothing" ;;
    esac
fi

# Now let it finish coming up. Generous, because this is the real component
# tree importing on a qemu-mipsel replica: the run script's own prober allows
# 180s and S62moonraker's detached reporter 120s, so a bound here shorter than
# either would report a printer that was still working as broken.
w=0
while [ $w -lt 300 ]; do
    [ -f /tmp/ready.at ] && [ -f /tmp/bound.at ] && break
    sleep 3
    w=$((w + 3))
done
kill $BINDER $WAITER 2>/dev/null

if [ -f /tmp/bound.at ] && [ -f /tmp/ready.at ]; then
    BOUND_AT=$((`cat /tmp/bound.at` - T0))
    READY_AT=$((`cat /tmp/ready.at` - T0))
    note "T0 -> :$PORT listening: ${BOUND_AT}s;  T0 -> s6-svwait -U returned: ${READY_AT}s"
    if [ "$READY_AT" -ge "$BOUND_AT" ]; then
        ok "(b) readiness did not precede the bind (${READY_AT}s >= ${BOUND_AT}s)"
    else
        bad "(b) s6-svwait -U returned ${READY_AT}s in, BEFORE :$PORT was bound at ${BOUND_AT}s -- readiness means 'forked'"
    fi
    # And how much (b) is worth, which depends entirely on there having been an
    # interval for readiness to be wrong about. This is NOT a failure when the
    # interval is short: a Moonraker that comes up fast is a Moonraker working
    # well, and a gate that failed a printer for being quick would be exactly
    # the kind of check this suite exists to replace. It is a statement about
    # how much weight (b) can carry -- and when it can carry none, (a) has to
    # have been measured, which is what the last clause insists on.
    if [ "$BOUND_AT" -ge 3 ]; then
        ok "and the bind took ${BOUND_AT}s, so (b) had a real interval to distinguish"
    else
        note "the bind took only ${BOUND_AT}s, so (b) is weak here -- (a) is the measurement"
        [ "$INSTANT" = 1 ] \
            || bad "readiness was not actually measured: the bind was too fast for (b) and there was no window for (a)"
    fi
else
    [ -f /tmp/bound.at ] || bad "moonraker never bound :$PORT within ${w}s"
    [ -f /tmp/ready.at ] || bad "s6-svwait -U never saw a readiness notification within ${w}s -- the notification-fd path is broken"
    tail -n 30 /usr/data/logs/moonraker.log 2>/dev/null | sed 's/^/      /'
    tail -n 20 /usr/data/logs/s6.log 2>/dev/null | sed 's/^/      /'
fi
# And what S62moonraker itself said, now that its detached reporter has had its
# answer. That line is the whole reason the init script waits on readiness
# rather than on a pid: it is true when it is printed.
sleep 2
sed 's/^/      /' /tmp/s62-start.out
grep -q "answering on :$PORT" /tmp/s62-start.out \
    && ok "S62moonraker's detached reporter said so too: `grep 'answering' /tmp/s62-start.out | head -1`" \
    || bad "S62moonraker never reported the API as up: `tail -1 /tmp/s62-start.out`"

echo
echo "=== 6. it is OUR interpreter that s6 is holding ==="
# The pid comes from the SUPERVISOR. There is no pidfile on this path at all,
# which is the point: s6-svstat -p cannot go stale the way /run/moonraker.pid
# could.
moonraker_pid() {
    p=`$S6/s6-svstat -p $SVCDIR 2>/dev/null`
    [ -n "$p" ] && [ "$p" -gt 0 ] 2>/dev/null && echo "$p"
}
# Does the pid s6 is holding OWN the listening socket, or is it merely true
# that both exist? The two are not the same claim, and the difference is the
# whole of section 8: after a kill -9 something has to be shown to have bound
# :7125 AGAIN, and "the port is listening" a second or two after the kill is
# also exactly what a socket that was never released would look like.
#
# /proc/net/tcp's tenth field is the socket's INODE, and a listening socket
# appears in its owner's /proc/PID/fd as socket:[inode]. Matching the two is
# the kernel's own answer to "whose port is this", and it needs no tool this
# busybox has not got -- no lsof, no fuser, no ss, none of which are here.
port_owner_is() {
    _pi=`awk -v p=":\`printf '%04X' $PORT\`" \
             '$2 ~ p"$" && $4 == "0A" { print $10; exit }' /proc/net/tcp 2>/dev/null`
    [ -n "$_pi" ] || return 1
    ls -l /proc/$1/fd 2>/dev/null | grep -q "socket:\[$_pi\]"
}
MRPID=`moonraker_pid`
if [ -z "$MRPID" ]; then
    bad "s6 has no pid for the service -- nothing to inspect"
else
    ok "s6-svstat -p: pid $MRPID"
    port_owner_is "$MRPID" \
        && ok "and :$PORT is held by THAT pid -- the supervisor's process is the server" \
        || bad "the pid s6 holds does not own the listening socket on :$PORT"
    CMD=`tr '\0' ' ' < /proc/$MRPID/cmdline 2>/dev/null`
    note "cmdline: $CMD"
    case "$CMD" in
        *"$PY313"*) ok "the process s6 holds is running $PY313 -- OUR interpreter" ;;
        *)          bad "the process s6 holds is '$CMD', not $PY313" ;;
    esac
    case "$CMD" in
        *"$PY38"*) bad "it is FlashForge's 3.8.2 that is running -- FF_PYTHON did not take" ;;
        *)         ok "and nothing under /usr/prog/Python-3.8.2 is being run" ;;
    esac
    case "$CMD" in
        *"$MOONRAKER_MAIN"*) ok "running the entry point S62moonraker names" ;;
        *)                   bad "running '$CMD', not $MOONRAKER_MAIN" ;;
    esac
    case "$CMD" in
        */bin/sh*) bad "s6 is holding a SHELL -- the run script never exec'd, so every stop signals the wrong process" ;;
        *)         ok "s6 holds the python process itself, not the run script's shell" ;;
    esac
    if [ -r /proc/$MRPID/environ ]; then
        TD=`tr '\0' '\n' < /proc/$MRPID/environ | sed -n 's/^TMPDIR=//p'`
        case "$TD" in
            /usr/data/*) ok "TMPDIR is $TD -- off the ramdisk, so an upload cannot fill memory" ;;
            "")          bad "moonraker has no TMPDIR" ;;
            *)           bad "TMPDIR is $TD, which is not on the data partition" ;;
        esac
    fi
fi

echo
echo "=== 7. the API answers, and the process maps nothing of FlashForge's ==="
# The HTTP client is our own 3.13, which is convenient and also honest: an
# interpreter that cannot make an HTTP request has a bigger problem than
# Moonraker. Same helper as case-moonraker313.sh, for the same reason -- a
# failure names the URL rather than being a bare non-zero from wget.
cat > /tmp/get.py <<'EOP'
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=20) as r:
        print("HTTP %d" % r.status)
        print(r.read().decode())
except Exception as exc:
    print("REQUEST FAILED: %r" % (exc,))
    sys.exit(1)
EOP
"$FF_PYTHON" /tmp/get.py "http://127.0.0.1:$PORT/server/info" > /tmp/info.out 2>&1
if grep -q '^HTTP 200' /tmp/info.out; then
    ok "GET /server/info answers 200"
    "$FF_PYTHON" - <<'EOP' > /tmp/info2.out 2>&1
import json
raw = open("/tmp/info.out").read().split("\n", 1)[1]
d = json.loads(raw)["result"]
comps = sorted(d.get("components", []))
fail = sorted(map(str, d.get("failed_components", []) or []))
print("klippy_connected=%s klippy_state=%s" % (d.get("klippy_connected"),
                                               d.get("klippy_state")))
print("components(%d): %s" % (len(comps), ", ".join(comps)))
print("failed_components(%d): %s" % (len(fail), ", ".join(fail)))
print("warnings: %s" % (d.get("warnings"),))
EOP
    sed 's/^/      /' /tmp/info2.out
    NCOMP=`sed -n 's/^components(\([0-9]*\)).*/\1/p' /tmp/info2.out`
    [ -n "$NCOMP" ] && [ "$NCOMP" -ge 16 ] 2>/dev/null \
        && ok "the JSON names $NCOMP loaded components" \
        || bad "/server/info reports only '$NCOMP' components"
    grep -q '^failed_components(0)' /tmp/info2.out \
        && ok "and NONE of them failed" \
        || bad "`grep '^failed_components' /tmp/info2.out`"
    # klippy is not running in the replica and must not be waited for: a
    # moonraker reporting klippy_state=error IS moonraker doing its job. Said
    # out loud so that nobody later reads a green run as "klippy works".
    note "klippy is not up in the replica -- the klippy_apis paths loaded but were never exercised"
else
    bad "GET /server/info: `tail -2 /tmp/info.out`"
fi
# A second endpoint, from a DIFFERENT component: /server/info is the Server
# object itself, /machine/system_info is `machine` reading this box's /proc.
# Two components answering is the difference between "tornado routes" and
# "Moonraker runs".
"$FF_PYTHON" /tmp/get.py "http://127.0.0.1:$PORT/machine/system_info" > /tmp/sys.out 2>&1
grep -q '^HTTP 200' /tmp/sys.out \
    && ok "GET /machine/system_info answers 200 too (a different component)" \
    || bad "GET /machine/system_info: `tail -2 /tmp/sys.out`"

# ---- /usr/prog, read off the RUNNING supervised process ---------------------
# Not off a python that imported some modules: off the pid s6 is holding, with
# every component loaded and the database open. This is the claim the whole
# phase is for, and this is the first time it has been made about a process an
# init script started.
if [ -n "$MRPID" ] && [ -r /proc/$MRPID/maps ]; then
    awk '{print $NF}' /proc/$MRPID/maps 2>/dev/null | grep '^/' | sort -u > /tmp/maps.txt
    sed 's/^/        /' /tmp/maps.txt
    NPROG=`grep -c '^/usr/prog' /tmp/maps.txt`
    [ "$NPROG" = 0 ] \
        && ok "the supervised moonraker maps 0 libraries under /usr/prog" \
        || bad "$NPROG librar(ies) under /usr/prog are mapped: `grep '^/usr/prog' /tmp/maps.txt | tr '\n' ' '`"
    # POSITIVE CONTROL FOR THE METHOD. "Nothing under /usr/prog" is also true
    # of an empty maps file, so the maps has to be shown to be saying
    # something: our libsodium is a shared object this process cannot be
    # running the authorization component without.
    if grep -q "^$MODDIR/lib/libsodium" /tmp/maps.txt; then
        ok "and it maps OUR libsodium from the prefix: `grep libsodium /tmp/maps.txt`"
    else
        bad "our libsodium is NOT mapped -- either authorization did not load, or another libsodium answered"
    fi
else
    bad "cannot read /proc/$MRPID/maps -- the /usr/prog claim was not measured"
fi

echo
echo "=== 8. kill -9: s6 puts it back, on 3.13, listening again ==="
# SIGKILL and not SIGTERM: SIGTERM is the polite path s6 itself uses and is not
# what a crash looks like. This is THE point of the migration -- before it, a
# moonraker that fell over stayed fallen until somebody noticed the UI was
# dead. And the respawn is a harder test on this branch than it was on 3.8:
# s6-supervise re-execs the `run` script, which sources anvil-env.sh again from
# the SCANNER's environment, so a respawn that came back on a different
# interpreter would be a service that works on the boot path and quietly
# changes underneath itself afterwards.
if [ -z "$MRPID" ]; then
    bad "no pid to kill -- section 5 left nothing running"
else
    note "killing pid $MRPID with SIGKILL"
    kill -9 "$MRPID" 2>/dev/null
    w=0
    NEWPID=$MRPID
    while [ $w -lt 60 ]; do
        sleep 2
        w=$((w + 2))
        NEWPID=`moonraker_pid`
        [ -n "$NEWPID" ] && [ "$NEWPID" != "$MRPID" ] && break
    done
    if [ -n "$NEWPID" ] && [ "$NEWPID" != "$MRPID" ]; then
        ok "s6 respawned moonraker after kill -9 ($MRPID -> $NEWPID, ${w}s)"
    else
        bad "moonraker was NOT respawned after kill -9 (still '$NEWPID') -- nothing is supervising it"
    fi
    # It has to be the same interpreter, and it has to serve. A respawn that
    # comes back as a shell, or on 3.8, or that never binds, is a respawn that
    # bought nothing.
    w=0
    while [ $w -lt 300 ] && ! port_listening; do
        sleep 3
        w=$((w + 3))
    done
    # Asked of the supervisor again rather than reusing the pid from the loop
    # above: s6 may have restarted the service more than once by now (a slow
    # first respawn that lost the port race would do it), and the question
    # below is about whoever is holding :$PORT NOW.
    NEWPID=`moonraker_pid`
    if port_listening; then
        # And it is the NEW process holding it. Without this, "the port is
        # listening" a couple of seconds after a kill -9 is equally true of a
        # socket that was never released, which would make the whole respawn
        # section pass against a supervisor that had done nothing at all.
        if port_owner_is "$NEWPID"; then
            ok "and the respawned moonraker bound :$PORT again (${w}s), pid $NEWPID owning the socket"
        else
            bad ":$PORT is listening after the respawn but pid $NEWPID does not own it -- whose socket is this?"
        fi
    else
        bad "the respawned moonraker never bound :$PORT -- see /usr/data/logs/s6.log"
        tail -n 20 /usr/data/logs/s6.log 2>/dev/null | sed 's/^/      /'
    fi
    CMD2=`tr '\0' ' ' < /proc/$NEWPID/cmdline 2>/dev/null`
    case "$CMD2" in
        *"$PY313"*) ok "the respawned process is running $PY313 as well" ;;
        *)          bad "the respawn came back as '$CMD2'" ;;
    esac
    "$FF_PYTHON" /tmp/get.py "http://127.0.0.1:$PORT/server/info" > /tmp/info4.out 2>&1
    grep -q '^HTTP 200' /tmp/info4.out \
        && ok "and it answers /server/info -- the respawn is a working server, not just a process" \
        || bad "the respawned moonraker holds :$PORT but does not answer: `tail -1 /tmp/info4.out`"
fi

echo
echo "=== 9. S62moonraker stop, and STAY stopped ==="
# `s6-svc -d` is not "kill the process", it is "the service is WANTED down".
# A stop implemented as a kill would be undone by the supervisor a second
# later and nobody would notice until they tried to stop moonraker and could
# not -- which is the classic mistake of this whole migration.
$S62 stop 2>&1 | sed 's/^/      /'
st=`$S6/s6-svstat $SVCDIR 2>&1`
case "$st" in
    down*) ok "s6-svstat immediately after stop: $st" ;;
    *)     bad "S62moonraker stop did not bring it down: $st" ;;
esac
port_listening && bad ":$PORT is still bound after stop" || ok ":$PORT stopped answering"
$S62 status 2>&1 | grep -q '^moonraker: not running' \
    && ok "status is honest about it: `$S62 status 2>&1 | head -1`" \
    || bad "status does not say 'not running' after stop: `$S62 status 2>&1 | head -1`"
note "waiting 15s to see whether the supervisor puts it back"
sleep 15
st=`$S6/s6-svstat $SVCDIR 2>&1`
case "$st" in
    down*) ok "15 seconds later it is STILL down: $st" ;;
    *)     bad "the supervisor undid the stop: $st" ;;
esac
port_listening && bad "something respawned moonraker after stop -- :$PORT is bound again" \
               || ok "and :$PORT is still free"

echo
echo "=== 10. negative control: it is OUR site-packages doing all of this ==="
# Move the tree aside and start the same service through the same init script.
# If it still comes up then something else -- FlashForge's 3.8 site-packages,
# some other tornado -- has been answering all along, and every PASS above
# belongs to somebody else's build.
#
# What happens instead is the churn s6 is supposed to produce: moonraker dies
# on ImportError, s6 starts it again, for ever. That is measured the way
# case-moonraker.sh measures churn, by AGE rather than by pid -- a service
# being restarted every second or two is DOWN whenever you look at it, so a
# naive distinct-pid count reads it as perfectly stable, while s6-svstat's
# "N seconds" (time since the last state change) can never climb.
mv $SP $SP.away
$S62 start > /tmp/s62-neg.out 2>&1
w=0
while [ $w -lt 60 ] && ! port_listening; do
    sleep 3
    w=$((w + 3))
done
if port_listening; then
    bad "moonraker bound :$PORT with our site-packages moved away -- some other tree is being imported"
else
    ok "with $SP moved away it never binds (${w}s)"
fi
MAXAGE=0
for i in 1 2 3 4 5; do
    a=`$S6/s6-svstat $SVCDIR 2>/dev/null | sed -n 's/.* \([0-9][0-9]*\) seconds.*/\1/p'`
    [ -n "$a" ] && [ "$a" -gt "$MAXAGE" ] 2>/dev/null && MAXAGE=$a
    sleep 3
done
[ "$MAXAGE" -le 8 ] \
    && ok "and the service never ages past ${MAXAGE}s -- s6 is respawning a moonraker that keeps dying" \
    || bad "the service aged to ${MAXAGE}s with no site-packages, i.e. something came up anyway"
note "what it died of: `grep -i 'no module named\|importerror\|traceback' /usr/data/logs/s6.log 2>/dev/null | tail -1 | cut -c1-100`"
$S62 stop >/dev/null 2>&1
mv $SP.away $SP

echo
echo "=== 11. teardown ==="
$S62 stop >/dev/null 2>&1
$S40 stop 2>&1 | sed 's/^/      /'
sleep 3
LEFT=`ps 2>/dev/null | grep 's6-svscan\|s6-supervise' | grep -v grep | grep -v case`
[ -z "$LEFT" ] \
    && ok "S40s6 stop took the supervisors down with it" \
    || bad "s6 processes survived: `echo "$LEFT" | tr '\n' ';'`"
port_listening && bad ":$PORT is still bound after everything was stopped" \
               || ok "nothing is left listening on :$PORT"

echo
if [ "$SHIPPED_SWITCH" = 1 ]; then
    echo "anvil-env.sh as SHIPPED names 3.13; this run tested the shipped file."
else
    echo "anvil-env.sh as shipped still names 3.8.2; this run applied the switch"
    echo "to the INSTALLED copy and tested the result. So what passed above is the"
    echo "post-switch configuration, not the shipped one -- which is the point:"
    echo "this gate is what makes that switch a measured change rather than a"
    echo "hopeful one, whenever it is decided to make it."
fi
echo
[ $FAIL = 0 ] && echo "moonraker on 3.13 under s6: all checks passed" \
              || echo "moonraker on 3.13 under s6: FAILURES"
exit $FAIL
