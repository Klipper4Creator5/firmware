#!/bin/sh
# Do our init.d services all behave like the same kind of thing?
#
# WHY THIS EXISTS. anvil-service.sh makes each of these decisions once --
# liveness, log spelling, the verb block -- and this gate is what stops the
# services drifting apart again. Two real bugs came out of that drift: a stop
# that returned before the process was gone, so the restart that followed saw
# it in the process table and declined to start anything; and a status that
# read a socket klippy does not unlink on exit, so a dead klippy reported
# itself running.
#
# Deliberately NOT a grep over the scripts -- that would pass on a service that
# cannot start anything and fail on a rename. It installs the payload and RUNS
# every service, on the printer's own busybox, and asserts on what came back.
#
# What it does NOT do is start real daemons: that is case-moonraker.sh's job
# for the web stack, and wifi/camera/klipper need hardware the replica has
# none of. What is checked here is the contract every service shares --
# it loads its library, it answers `status` without blowing up, it names
# itself in what it prints, and it rejects a verb it does not know with a
# usage line and exit 1.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
SERVICES="S40s6 S50wifi S60nginx S62moonraker S65camera S70klipper S80ui"

[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }

# ---- install the payload, as run-append.sh does ----------------------------
mkdir -p $MODDIR/init.d
cp -f $PAYLOAD/anvil-env.sh $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/anvil-service.sh $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/init.d/S* $MODDIR/init.d/ 2>/dev/null
# The s6 service directories, as bin/patch.sh stages them. Installing init.d
# without these would be a layout no printer ever has, and it is exactly the
# half where the interesting mistakes live: a `run` that arrived without its
# executable bit, or a service that ships without `down` and therefore starts
# before anything has read anvil.conf.
mkdir -p $MODDIR/etc/s6
[ -d $PAYLOAD/etc/s6 ] && cp -a $PAYLOAD/etc/s6/. $MODDIR/etc/s6/ 2>/dev/null
chmod +x $MODDIR/init.d/S* 2>/dev/null

# ---- the supervisor S40s6 needs -------------------------------------------
# S40s6 starts s6-svscan, and the real binaries are NOT in payload/: they are
# cross-compiled by bin/patch.sh into work/.s6 and staged from there, so the
# directory this case has mounted does not contain them. Two ways in:
#
#   the real thing   pass the built tarball, exactly as case-supervisor.sh is
#                    given it:
#                        printer-exec.py case-services.sh sup.tgz=work/s6.tgz
#                    Then every assertion below is about s6 itself as well as
#                    about our script, including "an empty scandir is not an
#                    error", which only the real scanner can answer.
#
#   a stand-in       otherwise. NOT a mock of s6 -- a mock of the three things
#                    S40s6 actually asks of it, written to the same contract
#                    that was MEASURED on the replica and is quoted in
#                    anvil-service.sh: a scanner that never returns and holds
#                    a control point; `s6-svscanctl -a` that succeeds while it
#                    is alive and exits 100 when it is not; `s6-svscanctl -t`
#                    that takes it down. That contract is what S40s6's start,
#                    stop and status are built on, so a stand-in obeying it
#                    exercises every line of them. What it cannot do is answer
#                    for s6, which is why the checks that are about s6 rather
#                    than about us say so and are skipped.
#
# Either way the point stands: nothing below decides anything by reading a
# script. It runs S40s6 and asks the filesystem and the process table what
# happened.
S6_REAL=0
mkdir -p $MODDIR/bin
if [ -f /mnt/sup.tgz ]; then
    gzip -dc /mnt/sup.tgz | tar -x -C $MODDIR && S6_REAL=1
    chmod +x $MODDIR/bin/* $MODDIR/libexec/* 2>/dev/null
fi
if [ "$S6_REAL" = 1 ] && [ -x $MODDIR/bin/s6-svscan ]; then
    ok "s6: testing against the real cross-built binaries from sup.tgz"
else
    S6_REAL=0
    echo "  ..    s6: no sup.tgz -- using a stand-in scanner (see the header)"
    cat > $MODDIR/bin/s6-svscan <<'EOSCAN'
#!/bin/sh
# Stand-in s6-svscan: never returns, holds a control point, dies on TERM.
SCANDIR=$1
mkdir -p "$SCANDIR/.s6-svscan" || exit 1
echo $$ > "$SCANDIR/.s6-svscan/standin.pid"
trap 'rm -f "$SCANDIR/.s6-svscan/standin.pid"; exit 0' TERM INT
while true; do sleep 1; done
EOSCAN
    cat > $MODDIR/bin/s6-svscanctl <<'EOCTL'
#!/bin/sh
# Stand-in s6-svscanctl: -a pings, -t terminates. Exit 100 when nothing is
# listening, which is what the real one does and what svc_s6_running reads.
VERB=$1
SCANDIR=$2
P=`cat "$SCANDIR/.s6-svscan/standin.pid" 2>/dev/null`
[ -n "$P" ] && kill -0 "$P" 2>/dev/null || {
    echo "s6-svscanctl: fatal: unable to control $SCANDIR: supervisor not listening" >&2
    exit 100
}
case "$VERB" in
    -t) kill -TERM "$P" 2>/dev/null ;;
esac
exit 0
EOCTL
    chmod +x $MODDIR/bin/s6-svscan $MODDIR/bin/s6-svscanctl
fi

# How many s6 processes are there right now? By name, from the process table,
# because "stop leaves nothing behind" is a claim about the process table and
# nothing else can answer it. pgrep does not exist on this rootfs -- checked,
# it is not in this busybox -- so this is plain ps, with the grep -v that
# stops the pipeline matching itself, and -v case.sh so that this very script
# (whose path contains no s6, but whose children's command lines do) cannot
# count itself.
s6_procs() {
    ps 2>/dev/null | grep 's6-svscan\|s6-supervise' | grep -v grep | grep -v case.sh
}

# The library is sourced, never executed, so bin/patch.sh stages it with a
# plain cp and no chmod +x. It once did not stage it at all, which would have
# made every service below abort at boot -- hence checking for it by itself,
# before anything tries to use it.
[ -f $MODDIR/anvil-service.sh ] \
    && ok "the payload ships anvil-service.sh" \
    || { bad "the payload ships no anvil-service.sh -- every service aborts"; exit 1; }

for s in $SERVICES; do
    [ -x $MODDIR/init.d/$s ] || { bad "$s is missing or not executable"; continue; }

    out=`$MODDIR/init.d/$s status 2>&1`
    rc=$?
    case "$out" in
        *"no /usr/data/anvil/anvil-service.sh"*)
            bad "$s cannot find its library at runtime" ;;
        "")
            bad "$s status printed nothing (rc=$rc) -- a service must always answer" ;;
        *)
            ok "$s status -> `echo "$out" | head -1`" ;;
    esac

    # One dispatcher means one answer to a verb nobody implements. Getting
    # this wrong is how a typo in a boot script becomes a silent no-op.
    uout=`$MODDIR/init.d/$s bogusverb 2>&1`
    urc=$?
    if [ $urc -eq 1 ] && echo "$uout" | grep -q "usage:"; then
        ok "$s rejects an unknown verb with a usage line and exit 1"
    else
        bad "$s: unknown verb gave rc=$urc, output: $uout"
    fi
done

# S70klipper is the one service with a verb of its own. force-start exists
# because start() normally stands aside for bin/ff-startup.py, and the
# firmwareExe wrapper needs a way to say "no, actually start it" when that
# program returned and left no klippy behind. If the shared dispatcher ever
# swallows it, the printer loses its last-resort path to a running Klipper.
$MODDIR/init.d/S70klipper bogusverb 2>&1 | grep -q "force-start" \
    && ok "S70klipper still advertises its extra force-start verb" \
    || bad "S70klipper lost force-start from its usage line"

# Every line a service prints is "name: something". It is what makes a boot
# log readable when five services are interleaving their output -- and the
# services background their slow work precisely so that they DO interleave.
for s in $SERVICES; do
    first=`$MODDIR/init.d/$s status 2>&1 | head -1`
    echo "$first" | grep -qE "^(s6|wifi|nginx|moonraker|camera|klipper|ui)" \
        && ok "$s names itself in its output" \
        || bad "$s output is unprefixed: $first"
done

# ---- the supervisor, and the boot it must not hang -------------------------
#
# S40s6 starts s6-svscan, and s6-svscan NEVER RETURNS -- that is its job.
# firmwareExe runs $MODDIR/init.d/S* one at a time IN THE FOREGROUND, so a
# start() that runs the scanner inline does not slow the boot down, it ends
# it: no wifi, no ssh, no Mainsail, no Klipper, no screen, for ever, on every
# boot, with no way in to find out why. That is the failure this section
# exists for, and it is why the harness below is BOUNDED rather than a plain
# call -- a test that hangs is a test that reports nothing.
echo
echo "--- s6-svscan ---"

# Run a directory of S* scripts exactly the way firmwareExe runs them -- one
# at a time, in the foreground, in filename order -- but with a stopwatch on
# the whole sequence. $1 is the directory, $2 the bound in seconds. Returns 0
# if the sequence finished, 1 if it was still going when the bound ran out.
#
# The marker file is what makes "finished" a fact rather than an inference:
# the subshell writes it only after the last script has returned, so its
# absence at the end of the wait means some script never came back.
run_init_sequence() {
    rm -f /tmp/initseq.done /tmp/initseq.log
    (
        for service in "$1"/S*; do
            [ -x "$service" ] || continue
            echo "--- `basename $service` ---"
            "$service" start || echo "`basename $service`: returned $?"
        done
        echo done > /tmp/initseq.done
    ) >/tmp/initseq.log 2>&1 &
    SEQ_PID=$!
    SEQ_WAITED=0
    while [ ! -f /tmp/initseq.done ] && [ $SEQ_WAITED -lt "$2" ]; do
        sleep 1
        SEQ_WAITED=$((SEQ_WAITED + 1))
    done
    [ -f /tmp/initseq.done ] && return 0
    kill -9 $SEQ_PID 2>/dev/null
    return 1
}

# THE NEGATIVE CONTROL, and it comes first on purpose: a stopwatch that cannot
# catch a hang would let the real check below pass no matter what S40s6 did.
# So here is the naive implementation somebody would write -- the scanner in
# the foreground, which is what you get by deleting the svc_detach from
# S40s6 -- run through the SAME harness. It has to time out. Its own scandir,
# because the real s6 takes a lock on the one it is scanning and a second
# instance on the same directory EXITS rather than hangs, which would make
# this control pass for entirely the wrong reason.
mkdir -p /tmp/naive-init.d $MODDIR/etc/s6-negctl
cat > /tmp/naive-init.d/S41hang <<EOH
#!/bin/sh
exec $MODDIR/bin/s6-svscan $MODDIR/etc/s6-negctl
EOH
chmod +x /tmp/naive-init.d/S41hang
if run_init_sequence /tmp/naive-init.d 15; then
    bad "negative control: an init script that runs the scanner inline RETURNED -- the stopwatch below proves nothing"
else
    ok "negative control: a foreground scanner hangs the sequence and the stopwatch catches it (${SEQ_WAITED}s)"
fi
# It is still sitting there holding the foreground; take it down before the
# real sequence runs, or the process-table checks later count it.
$MODDIR/bin/s6-svscanctl -t $MODDIR/etc/s6-negctl 2>/dev/null
sleep 2
kill -9 `ps 2>/dev/null | grep s6-negctl | grep -v grep | awk '{print $1}'` 2>/dev/null
rm -rf /tmp/naive-init.d $MODDIR/etc/s6-negctl

# Now the real thing: every service the payload ships, run the way firmwareExe
# runs them. 90 seconds is generous -- the whole point of svc_detach is that
# these return in well under a second each -- and generous is right for a
# bound whose only job is to turn a hang into a failure.
if run_init_sequence $MODDIR/init.d 90; then
    ok "the init sequence returned (${SEQ_WAITED}s) -- S40s6 did not hang the boot"
else
    bad "the init sequence did NOT return within ${SEQ_WAITED}s -- the boot would never reach klipper or the UI"
    echo "$(cat /tmp/initseq.log 2>/dev/null)" | sed 's/^/        /'
fi

# And the scanner is actually there afterwards. Asked of the scanner itself,
# not of `ps`: svc_s6_running pings the control FIFO, which a dead scanner
# leaves behind on disk, so this distinguishes "running" from "the socket is
# still lying there" the way a name match cannot.
if $MODDIR/init.d/S40s6 status | grep -q "scanning $MODDIR/etc/s6"; then
    ok "the scanner is running after the init sequence"
else
    bad "the scanner is not running after the init sequence: `$MODDIR/init.d/S40s6 status 2>&1 | head -2 | tr '\n' ' '`"
fi

# The scandir S40s6 created for itself. It ships empty from bin/patch.sh and
# is mkdir -p'd again at runtime, and this case installs the payload by hand
# without the staged etc/, so what is being checked here is the runtime mkdir.
[ -d $MODDIR/etc/s6 ] \
    && ok "the scandir $MODDIR/etc/s6 exists" \
    || bad "no scandir at $MODDIR/etc/s6"

# AN EMPTY SCANDIR IS NOT AN ERROR. This is the whole shape of phase 3: the
# scanner is alive and supervising NOTHING, and it has to be content with
# that -- if it exited, or complained, every boot would carry a scary log line
# and the first service to move in phase 4 would be debugged against a
# scanner that was already unhappy.
# Every service directory the payload ships has to be startable BY s6 and has
# to start DOWN. The executable bit is the one that goes wrong quietly: s6
# reports a non-executable `run` in its own log and nowhere else, so the
# service simply never comes up and nothing says why. And `down` is what keeps
# the gate in anvil.conf meaningful -- without it the scanner starts the
# service the instant it appears, before any script has read MOD_WEB or
# MOD_CAM, so "disabled" would mean "runs for a moment on every boot".
SVCDIRS=0
for d in $MODDIR/etc/s6/*; do
    [ -d "$d" ] || continue
    SVCDIRS=$((SVCDIRS + 1))
    n=`basename "$d"`
    [ -x "$d/run" ] \
        && ok "$n ships a run script s6 can execute" \
        || bad "$n has no executable run -- s6 would report that only in its own log"
    [ -f "$d/down" ] \
        && ok "$n ships 'down', so the scanner does not start it before anvil.conf is read" \
        || bad "$n has no 'down' file -- it would start regardless of its MOD_* gate"
done
[ $SVCDIRS -gt 0 ] \
    && ok "$SVCDIRS service directories shipped in $MODDIR/etc/s6" \
    || bad "no service directories in $MODDIR/etc/s6 -- nothing was staged"
sleep 3
if $MODDIR/init.d/S40s6 status | grep -q scanning; then
    ok "the scanner is still up 3s later -- it did not exit"
else
    bad "the scanner exited"
fi
if [ "$S6_REAL" = 1 ]; then
    # A healthy s6-svscan says nothing at all. Anything in its log is a fault,
    # and the one that matters here is the -D_FILE_OFFSET_BITS=64 trap from
    # tools/supervisor/README.md: "unable to readdir .: Value too large for
    # defined data type", which is a scanner that started and then went blind.
    if [ -s /usr/data/logs/s6.log ]; then
        bad "s6-svscan wrote to its log: `head -3 /usr/data/logs/s6.log | tr '\n' ' '`"
    else
        ok "s6-svscan logged nothing -- a scandir of services that all ship 'down' is a quiet, healthy state"
    fi
else
    echo "  ..    skipped (stand-in scanner): whether the real s6 is quiet on an"
    echo "  ..    empty scandir is case-supervisor.sh's question, not this one"
fi

# Starting it twice is what a hand-run `S40s6 start` over ssh does, and what
# firmwareExe's last-resort re-check does if it misreads the status. It must
# be a no-op with exit 0, not a second scanner: the real s6-svscan takes a
# lock on the scandir and the second instance dies, leaving a pidfile pointing
# at a corpse and `status` answering for the wrong process.
out=`$MODDIR/init.d/S40s6 start 2>&1`
rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q already; then
    ok "a second start is a no-op: $out"
else
    bad "a second start did not say already-running (rc=$rc): $out"
fi

# STOP LEAVES NOTHING BEHIND. The scanner is the process that would otherwise
# put everything back, so a stop that kills the services and not the scanner
# is not a stop at all -- the same mistake as killing mjpg_streamer without
# S65camera's respawn loop. Asked of the process table, which is the only
# thing that can answer it.
$MODDIR/init.d/S40s6 stop >/dev/null 2>&1
sleep 2
LEFT=`s6_procs`
[ -z "$LEFT" ] \
    && ok "stop left no s6 processes behind" \
    || bad "s6 processes survived stop: `echo "$LEFT" | tr '\n' ';'`"
$MODDIR/init.d/S40s6 status | grep -q "not running" \
    && ok "status reports the stopped scanner as not running" \
    || bad "status still claims a scanner after stop: `$MODDIR/init.d/S40s6 status | head -1`"
# And the pidfile is gone, so the next status cannot be answered by a pid the
# kernel has since handed to something else -- the stale-pidfile bug this
# whole library has two comments about.
[ ! -f $MODDIR/s6-svscan.pid ] \
    && ok "stop removed the pidfile" \
    || bad "stop left $MODDIR/s6-svscan.pid behind"

echo
[ $FAIL -eq 0 ] && echo "  init.d services: all checks passed"
exit $FAIL
