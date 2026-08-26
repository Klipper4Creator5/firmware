#!/bin/sh
# The camera, under s6. Does phase 4 actually buy what it claimed to buy?
#
# WHY THIS EXISTS. S65camera used to hand-roll two things: a `while true;
# mjpg_streamer; sleep 3; done` respawn loop, and a poll that waited up to
# thirty seconds for /dev/video0. Phase 4 replaced the first with s6 and the
# second with a READINESS NOTIFICATION -- the one capability s6 has and runit
# has not, and the reason the supervisor choice went the way it did. A gate for
# that has to prove readiness GATES: that `s6-svwait -U` blocks until the
# camera is usable and does not return merely because a process was forked. A
# check that would pass either way proves nothing, so section 2 below is
# written to fail if readiness is a no-op.
#
# WHAT IS REAL HERE AND WHAT IS A STAND-IN -- read this before believing any
# line of output.
#
#   REAL  s6. Every s6 binary used below is the cross-built mipsel one from
#         sup.tgz, unpacked into /usr/data/anvil the way case-supervisor.sh
#         does, because s6 resolves s6-ftrigrd through the prefix baked into
#         it at compile time and every waiting verb -- which is all of the
#         interesting ones -- fails from anywhere else.
#   REAL  our service directory ($MODDIR/etc/s6/camera: run, down,
#         notification-fd) and our payload/init.d/S65camera, installed from
#         the payload under test. That is the thing being tested.
#   REAL  mjpg_streamer. The replica's rootfs carries FlashForge's genuine
#         /usr/prog/mjpg-streamer/mjpg_streamer 2.0 with its plugins, and the
#         readiness condition our run script probes -- a real HTTP server
#         bound to :8080, checked through /proc/net/tcp and fetched with wget
#         -- is produced by that real binary.
#   REAL  /proc/net/tcp, the process table, and the port.
#
#   STAND-IN  the camera itself. There is no /dev/video0 in the replica and no
#         V4L2 device behind it; input_uvc.so exits at once with "init_VideoIn
#         failed" -- measured. So /dev/video0 is faked as a plain file (the run
#         script's precondition is `[ -e ]`, which is what a device node
#         satisfies), and mjpg_streamer is wrapped: the wrapper waits a
#         configurable number of seconds and then execs the REAL streamer with
#         input_file.so instead of input_uvc.so, so it binds the real port and
#         serves real frames without a camera. That wrapper is what makes the
#         readiness timing observable at all -- a delay between "forked" and
#         "listening" is exactly what a slow camera has, and it is what
#         section 2 measures.
#
#   NOT TESTED HERE  whether input_uvc.so can talk to a real webcam. That
#         needs hardware and is not a claim this change makes.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
note(){ echo "  ..    $*"; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
CAMDIR=/usr/prog/mjpg-streamer
SCANDIR=$MODDIR/etc/s6
S6=$MODDIR/bin
VIDEO=/dev/video0
PORT=8080

[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }

# ---- the real s6 -----------------------------------------------------------
mkdir -p $MODDIR/bin
[ -f /mnt/sup.tgz ] || { bad "no sup.tgz -- this case is meaningless without the real s6 (see the header)"; exit 1; }
gzip -dc /mnt/sup.tgz | tar -x -C $MODDIR || { bad "cannot unpack sup.tgz"; exit 1; }
chmod +x $MODDIR/bin/* $MODDIR/libexec/* 2>/dev/null
[ -x $S6/s6-svwait ] || { bad "sup.tgz has no s6-svwait"; exit 1; }
ok "unpacked the real cross-built s6 into $MODDIR"

# ---- install the payload, as run-append.sh does ----------------------------
# init.d/ and the two sourced libraries, plus etc/s6/ -- the service directory
# is the new half of this payload and the whole subject of this case. It is
# copied with `cp -a` so the `down` file, the `notification-fd` file and the
# executable bit on `run` arrive exactly as shipped; a `run` that lost +x is a
# service s6 can never start, and it is the kind of thing a per-file cp gets
# wrong silently.
mkdir -p $MODDIR/init.d $MODDIR/etc
cp -f $PAYLOAD/anvil-env.sh $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/anvil-service.sh $MODDIR/ 2>/dev/null
cp -f $PAYLOAD/init.d/S* $MODDIR/init.d/ 2>/dev/null
chmod +x $MODDIR/init.d/S* 2>/dev/null
if [ -d $PAYLOAD/etc/s6/camera ]; then
    cp -a $PAYLOAD/etc/s6 $MODDIR/etc/ 2>/dev/null
else
    bad "the payload ships no etc/s6/camera -- nothing to supervise"
    exit 1
fi
[ -x $SCANDIR/camera/run ] \
    && ok "the payload ships an executable $SCANDIR/camera/run" \
    || bad "$SCANDIR/camera/run is missing or not executable -- s6 could never start it"
[ -f $SCANDIR/camera/notification-fd ] \
    && ok "the service directory declares a notification-fd (`cat $SCANDIR/camera/notification-fd`)" \
    || bad "no notification-fd -- readiness cannot work at all"
[ -f $SCANDIR/camera/down ] \
    && ok "the service directory ships a 'down' file -- s6 will not start it on its own" \
    || bad "no 'down' file -- s6 would start the camera before anything read MOD_CAM"

# anvil.conf, because both S65camera and the run script read it at runtime and
# the MOD_CAM section below edits it. Shipped defaults where there are any.
cp -f $PAYLOAD/anvil.conf $MODDIR/anvil.conf 2>/dev/null
[ -f $MODDIR/anvil.conf ] || echo "MOD_CAM=1" > $MODDIR/anvil.conf

# ---- the one thing s6 needs from the environment ---------------------------
#
# s6 IS NOT SELF-CONTAINED, and this cost a whole run of this case to find. Two
# of its binaries exec a third BY NAME, off PATH, not by an absolute path and
# not through the compiled-in prefix that tools/supervisor/README.md is about:
#
#   s6-svscan  execs `s6-supervise` for each service directory. Without it on
#              PATH the scanner starts, stays up, answers its control socket
#              and supervises NOTHING, logging one line:
#                  s6-svscan: warning: unable to spawn s6-supervise for
#                  camera: No such file or directory
#              -- measured on the replica, both ways round.
#   s6-svc -w  execs `s6-svlisten`, so every WAITING verb -- which is all the
#              ones anvil-service.sh wraps -- dies with
#                  s6-svc: fatal: unable to exec s6-svlisten
#
# Phase 3 could not see this: its scandir was empty, so no s6-supervise was
# ever spawned and no service was ever waited on. It becomes visible with the
# first real service, which is this one.
#
# The fix belongs in payload/anvil-env.sh -- the one file that defines the
# mod's environment, already sourced by S40s6 (so the SCANNER inherits it,
# which is what matters for s6-supervise) and by every init script (which is
# what matters for s6-svlisten). This check is behavioural: source the
# installed copy and ask whether the name resolves. If it does not, the case
# says so and then patches its own installed copy, because every section below
# would otherwise fail with the same unrelated message and say nothing about
# the camera.
if ( . $MODDIR/anvil-env.sh >/dev/null 2>&1; command -v s6-supervise >/dev/null 2>&1 ); then
    ok "anvil-env.sh puts $MODDIR/bin on PATH -- s6-svscan can exec s6-supervise"
else
    bad "anvil-env.sh leaves $MODDIR/bin off PATH: s6-svscan cannot exec s6-supervise and s6-svc -w cannot exec s6-svlisten"
    note "patching the INSTALLED copy so the rest of this case can still say something"
    echo 'PATH=/usr/data/anvil/bin:$PATH; export PATH' >> $MODDIR/anvil-env.sh
fi

# ---- the stand-in camera and the stand-in streamer -------------------------
# See the header. The real mjpg_streamer moves aside and keeps doing the work;
# the wrapper only adds the delay between fork and listening that a real camera
# has and this replica does not.
mkdir -p /tmp/frames
echo "not really a jpeg" > /tmp/frames/pic_001.jpg
[ -f $CAMDIR/mjpg_streamer.real ] || cp -f $CAMDIR/mjpg_streamer $CAMDIR/mjpg_streamer.real
cat > $CAMDIR/mjpg_streamer <<'EOSTREAM'
#!/bin/sh
# Stand-in streamer. Waits /tmp/cam-delay seconds -- standing in for a camera
# that takes a while to open and negotiate a format -- and then execs the REAL
# mjpg_streamer with input_file.so, which needs no V4L2 device but binds the
# same port through the same output_http.so. Arguments from the run script are
# printed and otherwise ignored: what is under test is our service definition
# and s6's behaviour, not input_uvc.so.
D=`cat /tmp/cam-delay 2>/dev/null`
[ -n "$D" ] || D=0
echo "standin: invoked as: $*"
echo "standin: sleeping ${D}s before binding"
sleep "$D"
exec /usr/prog/mjpg-streamer/mjpg_streamer.real \
    -i "input_file.so -f /tmp/frames" \
    -o "output_http.so -p 8080 -w www"
EOSTREAM
chmod +x $CAMDIR/mjpg_streamer
echo 0 > /tmp/cam-delay

# Is anything listening on $PORT? Exactly the test the run script uses for
# readiness, spelled the same way, so that a bug in one is visible as a
# disagreement with the other rather than as two matching wrong answers.
port_listening() {
    awk -v p=":`printf '%04X' $PORT`" '$2 ~ p"$" && $4 == "0A" { f = 1 }
                                       END { exit !f }' /proc/net/tcp 2>/dev/null
}

# Run a command with a stopwatch and a hard bound. Prints the elapsed seconds
# on stdout; returns 1 if the bound ran out, which is how a hang becomes a
# failure instead of a test that never reports.
ELAPSED=0
timed() {
    _bound=$1; shift
    rm -f /tmp/timed.rc /tmp/timed.out
    _t0=`date +%s`
    ( "$@" >/tmp/timed.out 2>&1; echo $? > /tmp/timed.rc ) &
    _p=$!
    _w=0
    while [ ! -f /tmp/timed.rc ] && [ $_w -lt "$_bound" ]; do
        sleep 1
        _w=$((_w + 1))
    done
    ELAPSED=$((`date +%s` - _t0))
    if [ -f /tmp/timed.rc ]; then return 0; fi
    kill -9 $_p 2>/dev/null
    return 1
}

echo
echo "=== 0. negative control: nothing is ready before anything starts ==="
# If the checks below could pass against a box where nothing is running, they
# would prove nothing at all. Two things are asserted to be FALSE first: the
# port is not already bound by something else in this rootfs (which would make
# every readiness check trivially true), and s6-svwait -U on a service that
# nobody has started does not return success.
rm -f /tmp/timed.rc
if port_listening; then
    bad "negative control: something is ALREADY listening on :$PORT -- every readiness check below would pass for free"
else
    ok "negative control: nothing is listening on :$PORT before we start"
fi

echo
echo "=== 1. the scanner, then the camera ==="
$MODDIR/init.d/S40s6 start
sleep 3
$MODDIR/init.d/S40s6 status | grep -q "scanning $SCANDIR" \
    && ok "s6-svscan is running on $SCANDIR" \
    || { bad "the scanner did not start: `$MODDIR/init.d/S40s6 status | head -2 | tr '\n' ' '`"; exit 1; }

# THE 'down' FILE, PROVED BY BEHAVIOUR. The scanner has now seen the camera
# directory and started an s6-supervise for it. Nothing has read MOD_CAM yet,
# so if the camera is up at this point the `down` file did not work and the
# MOD_CAM gate is decorative.
st=`$S6/s6-svstat $SCANDIR/camera 2>&1`
case "$st" in
    down*) ok "s6 picked the service up and left it DOWN, as the 'down' file asks ($st)" ;;
    *)     bad "the camera is not down before anything started it: $st" ;;
esac
port_listening \
    && bad "the streamer is listening on :$PORT before S65camera ever ran" \
    || ok "nothing is streaming until S65camera says so"

# NEGATIVE CONTROL FOR READINESS ITSELF, and it belongs here rather than at the
# end: s6-svwait -U against a service that has never declared itself must FAIL.
# If it succeeded, section 2's timing would be measuring nothing.
if $S6/s6-svwait -U -t 4000 $SCANDIR/camera >/dev/null 2>&1; then
    bad "negative control: s6-svwait -U SUCCEEDED on a service that never notified -- readiness is a no-op here"
else
    ok "negative control: s6-svwait -U times out on a service that has not declared itself ready"
fi

echo
echo "=== 2. readiness gates: -U blocks on READY, not on FORKED ==="
# The whole reason for s6. The stand-in streamer is told to wait 10 seconds
# before it binds the port, standing in for a camera that enumerates slowly.
# Then three things are measured against the SAME start:
#
#   * s6 reports the service UP almost immediately -- the process was forked.
#   * s6-svwait -U is still blocking at that moment.
#   * s6-svwait -U returns at about ten seconds, when the port is bound.
#
# The middle one is the check that cannot be faked: a readiness that returned
# on fork would already have returned by then, and the elapsed-time assertion
# alone could be satisfied by a slow `s6-svwait` for any reason.
touch $VIDEO
echo 10 > /tmp/cam-delay

rm -f /tmp/ready.at
T0=`date +%s`
( $S6/s6-svwait -U -t 40000 $SCANDIR/camera >/dev/null 2>&1 && date +%s > /tmp/ready.at ) &
$MODDIR/init.d/S65camera start
sleep 4

# The two halves are asserted TOGETHER, because either alone is worthless: "the
# wait is still blocking" is trivially true of a service that never started, so
# it only means something while s6 is simultaneously reporting the service up.
st=`$S6/s6-svstat $SCANDIR/camera 2>&1`
case "$st" in
    up*)
        ok "4s after start s6 reports the service UP: $st"
        if [ -f /tmp/ready.at ]; then
            bad "s6-svwait -U had ALREADY returned while the streamer was still 6s away from binding -- it is answering 'forked', not 'ready'"
        else
            ok "s6-svwait -U is still blocking although the process is up -- UP IS NOT READY"
        fi ;;
    *)
        bad "the service is not up 4s after start, so nothing here measures readiness: $st" ;;
esac
port_listening \
    && bad "the port is bound 4s in, so the 10s stand-in delay did not happen and this section measured nothing" \
    || ok "and nothing is listening on :$PORT yet, which is why it is not ready"

# Now let it finish and time the notification.
w=0
while [ ! -f /tmp/ready.at ] && [ $w -lt 45 ]; do
    sleep 1
    w=$((w + 1))
done
if [ -f /tmp/ready.at ]; then
    E=$((`cat /tmp/ready.at` - T0))
    if [ $E -ge 7 ] && [ $E -le 30 ]; then
        ok "s6-svwait -U returned after ${E}s -- when the streamer bound :$PORT, not when it forked"
    else
        bad "s6-svwait -U returned after ${E}s, which is neither the ~10s readiness delay nor a timeout"
    fi
else
    bad "s6-svwait -U never saw a readiness notification (waited ${w}s) -- the notification-fd path is broken"
fi
port_listening \
    && ok "and the port really is bound now" \
    || bad "nothing is listening on :$PORT at the end of the readiness wait"

# And the stream is genuinely served, by the real mjpg_streamer, over the real
# port. Readiness that is not followed by a working stream is a bug in what
# "ready" was defined to mean.
if wget -q -O - -T 5 "http://127.0.0.1:$PORT/" 2>/dev/null | grep -qi html; then
    ok "http://127.0.0.1:$PORT/ serves the streamer's page"
else
    bad "the port is bound but :$PORT served nothing"
fi

echo
echo "=== 3. s6 respawns it, and no hand-rolled loop exists ==="
echo 0 > /tmp/cam-delay
pid1=`$S6/s6-svstat -p $SCANDIR/camera 2>/dev/null`
if [ -n "$pid1" ] && [ "$pid1" -gt 0 ] 2>/dev/null; then
    kill -9 "$pid1" 2>/dev/null
    w=0
    pid2=$pid1
    while [ $w -lt 30 ]; do
        sleep 1
        w=$((w + 1))
        pid2=`$S6/s6-svstat -p $SCANDIR/camera 2>/dev/null`
        [ -n "$pid2" ] && [ "$pid2" -gt 0 ] 2>/dev/null && [ "$pid2" != "$pid1" ] && break
    done
    if [ -n "$pid2" ] && [ "$pid2" != "$pid1" ]; then
        ok "s6 respawned the streamer after kill -9 (pid $pid1 -> $pid2, ${w}s)"
    else
        bad "the streamer was not respawned after kill -9 (still '$pid2')"
    fi
else
    bad "could not read a pid out of s6-svstat -p (got '$pid1')"
fi

# THE RESPAWN IS S6'S, NOT OURS. Three things say so, and none of them is a
# grep over a shipped script.
#
# The old loop's pidfile is never written -- that file was the loop's only
# handle on itself, so its absence is the absence of the loop.
[ -f $MODDIR/mjpg.pid ] \
    && bad "$MODDIR/mjpg.pid exists -- something is still hand-rolling the respawn" \
    || ok "no $MODDIR/mjpg.pid: nothing here is hand-rolling a respawn loop"
# There is a separate supervisor PROCESS doing the work. Asked of `ps` by name
# only -- the command line is truncated by this busybox's ps width and the
# service directory does not survive into the visible part of it, which is why
# the next check rather than this one is the one that names the camera.
ps 2>/dev/null | grep 's6-supervise' | grep -v grep | grep -q s6-supervise \
    && ok "an s6-supervise process exists -- supervision is a separate program, not our shell" \
    || bad "no s6-supervise in the process table: nothing is supervising anything"
# And it is OUR service it is supervising. s6-svstat reads $SCANDIR/camera's
# own supervise/status, and answers "s6-supervise not running" when there is no
# supervisor behind that exact directory -- measured, and it is what every
# failure in the first run of this case looked like. So a status that starts
# with "up" is the supervisor identifying itself by the directory it holds.
st=`$S6/s6-svstat $SCANDIR/camera 2>&1`
case "$st" in
    up*) ok "and it is $SCANDIR/camera it holds: $st" ;;
    *)   bad "no supervisor behind $SCANDIR/camera: $st" ;;
esac

echo
echo "=== 4. S65camera stop, and s6 leaves it stopped ==="
$MODDIR/init.d/S65camera stop
st=`$S6/s6-svstat $SCANDIR/camera 2>&1`
case "$st" in
    down*) ok "stop returned with the service already down ($st)" ;;
    *)     bad "stop returned but the service is: $st" ;;
esac
port_listening \
    && bad ":$PORT is still bound after stop" \
    || ok "nothing is listening on :$PORT after stop"
# The part a `killall mjpg_streamer` could never give you: a supervisor that
# has been told DOWN stays that way. Ten seconds is three times the old loop's
# three-second respawn delay, so a loop that survived would have fired.
sleep 10
st=`$S6/s6-svstat $SCANDIR/camera 2>&1`
case "$st" in
    down*) ok "still down 10s later -- nothing respawned it" ;;
    *)     bad "something brought the camera back after stop: $st" ;;
esac
port_listening \
    && bad "something respawned the streamer after stop -- :$PORT is bound again" \
    || ok "and :$PORT is still free"

echo
echo "=== 5. no camera: the boot does not hang and the log is honest ==="
# The behaviour the 30-second poll used to provide, moved into the run script.
# Two claims: start() returns promptly even though the camera will never
# appear, and something eventually says so in words.
rm -f $VIDEO /usr/data/logs/mjpg.log /tmp/camstart.log
if timed 20 $MODDIR/init.d/S65camera start; then
    if [ "$ELAPSED" -le 12 ]; then
        ok "with no $VIDEO, S65camera start returned in ${ELAPSED}s -- the boot is not held"
    else
        bad "S65camera start took ${ELAPSED}s with no camera -- that is a boot the printer waits through"
    fi
    note "it said: `head -2 /tmp/timed.out | tr '\n' ' '`"
else
    bad "S65camera start NEVER RETURNED with no camera -- this would hang every boot"
fi
# The run script's own 30-second wait, and its verdict. s6 restarts the run
# script when it exits, so this is a service that keeps looking rather than one
# that gave up -- which is the improvement over the old poll.
w=0
while [ $w -lt 60 ]; do
    grep -q "never appeared" /usr/data/logs/mjpg.log 2>/dev/null && break
    sleep 2
    w=$((w + 2))
done
if grep -q "never appeared" /usr/data/logs/mjpg.log 2>/dev/null; then
    ok "the run script said so honestly: `grep 'never appeared' /usr/data/logs/mjpg.log | head -1`"
else
    bad "nothing in /usr/data/logs/mjpg.log explains the missing camera after ${w}s"
fi
port_listening \
    && bad "something is listening on :$PORT with no camera present" \
    || ok "and no stream was served for a camera that is not there"
# Still trying, not dead: plug the camera in later and it comes up, which is
# the thing the old give-up-after-30s poll could not do.
$MODDIR/init.d/S65camera status | head -1 | grep -q "^camera:" \
    && ok "status still answers and names itself: `$MODDIR/init.d/S65camera status | head -1`" \
    || bad "status printed nothing useful with no camera"
$MODDIR/init.d/S65camera stop >/dev/null 2>&1

echo
echo "=== 6. MOD_CAM=0 means it does not run ==="
sed -i 's/^MOD_CAM=.*/MOD_CAM=0/' $MODDIR/anvil.conf 2>/dev/null
grep -q '^MOD_CAM=0' $MODDIR/anvil.conf || echo "MOD_CAM=0" >> $MODDIR/anvil.conf
touch $VIDEO
echo 0 > /tmp/cam-delay
out=`$MODDIR/init.d/S65camera start 2>&1`
echo "$out" | grep -qi "disabled" \
    && ok "MOD_CAM=0: $out" \
    || bad "MOD_CAM=0 but start said: $out"
sleep 6
st=`$S6/s6-svstat $SCANDIR/camera 2>&1`
case "$st" in
    down*) ok "MOD_CAM=0 left the service down ($st)" ;;
    *)     bad "MOD_CAM=0 and yet the camera is: $st" ;;
esac
port_listening \
    && bad "MOD_CAM=0 and something is streaming on :$PORT" \
    || ok "MOD_CAM=0: nothing on :$PORT"

# And back on again, in the same session, without reinstalling anything: the
# gate is a runtime read of a runtime file, which is the reason it is in the
# init script rather than baked into the payload at build time.
sed -i 's/^MOD_CAM=.*/MOD_CAM=1/' $MODDIR/anvil.conf
$MODDIR/init.d/S65camera start >/dev/null 2>&1
w=0
while [ $w -lt 30 ] && ! port_listening; do
    sleep 1
    w=$((w + 1))
done
port_listening \
    && ok "MOD_CAM=1 after an edit brings it straight back (${w}s) -- the gate is read at runtime" \
    || bad "MOD_CAM=1 did not bring the camera back after ${w}s"

echo
echo "=== 7. tidy up ==="
$MODDIR/init.d/S65camera stop >/dev/null 2>&1
$MODDIR/init.d/S40s6 stop >/dev/null 2>&1
sleep 2
LEFT=`ps 2>/dev/null | grep 's6-svscan\|s6-supervise' | grep -v grep | grep -v case.sh`
[ -z "$LEFT" ] \
    && ok "S40s6 stop took the supervisors down with it" \
    || bad "s6 processes survived: `echo "$LEFT" | tr '\n' ';'`"

echo
[ $FAIL -eq 0 ] && echo "  camera: all checks passed"
exit $FAIL
