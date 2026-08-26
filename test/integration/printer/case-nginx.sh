#!/bin/sh
# Is nginx really supervised now, or does it just look like it?
#
# WHAT IS BEING PROVED. init.d/S60nginx used to start nginx and walk away. If
# the master process fell over -- OOM, a bad config reload, a kernel that took
# the wrong page -- the printer's only web UI was gone until somebody noticed
# and ssh'd in, and the script could do nothing about it because a shell that
# has returned cannot restart anything. Phase 4 hands nginx to s6, and the
# claim being made is exactly one sentence: kill nginx and it comes back, ask
# it to stop and it stays stopped. Both halves matter and only the second one
# is easy to get wrong -- a `stop` the supervisor quietly undoes is the classic
# bug of a migration like this, and it looks like a success from the outside
# until somebody tries to stop the service and cannot.
#
# NOTHING HERE READS A SHIPPED SCRIPT. Every assertion below runs the real
# tools -- the printer's own nginx out of /usr/prog, the cross-built s6 out of
# the payload, and init.d/S60nginx itself -- and then asks the process table,
# the supervisor and port 80 what happened. A grep over S60nginx would pass on
# a script that starts nothing and fail on a rename, which is the wrong way
# round for both.
#
# WHAT IT NEEDS. The real s6 binaries, which are cross-compiled by bin/patch.sh
# into work/.s6 and are NOT in payload/, so they arrive as a tarball exactly as
# case-supervisor.sh takes them:
#
#     printer-exec.py case-nginx.sh sup.tgz=work/.s6-gate.tgz
#
# and a real nginx at /usr/prog/nginx/sbin/nginx. This replica has one --
# FlashForge's own build, nginx 1.5.0 -- and section 0 checks for it and says
# out loud what it found, because a case that quietly tests nothing when a
# binary is missing is worse than one that fails.
FAIL=0
ok()   { echo "  PASS  $*"; }
bad()  { echo "  FAIL  $*"; FAIL=1; }
note() { echo "  ..    $*"; }
skip() { echo "  SKIP  $*"; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
NGINX=/usr/prog/nginx/sbin/nginx
S6=$MODDIR/bin
SCANDIR=$MODDIR/etc/s6
SVCDIR=$SCANDIR/nginx
S60=$MODDIR/init.d/S60nginx
S40=$MODDIR/init.d/S40s6

# The three questions everything below is asked in terms of. All of them go to
# something outside our own scripts: the supervisor, the kernel, the port.
svstat()  { $S6/s6-svstat "$SVCDIR" 2>&1; }
svpid()   { $S6/s6-svstat -p "$SVCDIR" 2>/dev/null; }
http()    { wget -q -O /dev/null -T 4 http://127.0.0.1/ && echo UP || echo down; }
# UP != READY, and this is where you can watch the difference. `s6-svc -wu`
# returns when the service is UP -- when the process s6 forked exists -- and
# nginx is not listening yet at that instant: it still has to parse the config,
# bind and fork a worker, which on this qemu-mipsel replica takes seconds, not
# milliseconds. Measured here: the first version of this case checked :80 the
# moment S60nginx start returned and got a refused connection from an nginx
# that was perfectly healthy two seconds later.
#
# That gap is exactly what readiness notification closes, and it is the reason
# the plan chose s6 over runit -- a service that writes to its notification-fd
# is saying "usable", not "forked", and svc_s6_ready blocks until it does.
# nginx has no notification-fd support, so waiting on the PORT is the honest
# stand-in, bounded so a genuinely dead server fails instead of hanging.
http_wait() {
    _hw=0
    while [ $_hw -lt "${1:-25}" ]; do
        [ "`http`" = UP ] && return 0
        sleep 1
        _hw=$((_hw + 1))
    done
    return 1
}
# nginx rewrites its own argv ("nginx: master process ...", "nginx: worker
# process"), and under qemu the command line is the qemu one with the binary
# path still in it, so both shapes are counted. /proc rather than `ps` because
# busybox ps truncates to the terminal width and cuts the path in half -- the
# same reason the `run` script reads /proc, and it was measured here first.
nginx_procs() {
    _n=0
    for _d in /proc/[0-9]*; do
        [ -r "$_d/cmdline" ] || continue
        _a=`tr '\0' ' ' < "$_d/cmdline" 2>/dev/null`
        case "$_a" in
            "nginx: "*|*"$NGINX"*) _n=$((_n + 1)) ;;
        esac
    done
    echo $_n
}

echo "=== 0. what is actually on this printer? ==="
if [ ! -x "$NGINX" ]; then
    bad "no $NGINX on this replica -- this case cannot test nginx supervision"
    echo "        (everything below would be a test of nothing; failing rather than skipping"
    echo "         because the whole point of the case is the real binary.)"
    exit 1
fi
ok "nginx is here: `$NGINX -v 2>&1 | head -1`"
[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }
[ -f /mnt/sup.tgz ] || { bad "no sup.tgz -- pass sup.tgz=<the built s6 tarball>"; exit 1; }

# ---- install the payload, as run-append.sh does ---------------------------
mkdir -p $MODDIR/init.d $MODDIR/nginx/logs $MODDIR/nginx/tmp /usr/data/logs
cp -f $PAYLOAD/anvil-env.sh $PAYLOAD/anvil-service.sh $PAYLOAD/anvil.conf $MODDIR/
cp -f $PAYLOAD/init.d/S* $MODDIR/init.d/
chmod +x $MODDIR/init.d/S*
# The service directory, staged the way bin/patch.sh stages payload/etc/ --
# contents and mode. If this ever stops being copied by the build, the case
# does not silently pass: S60nginx says so and section 3 fails.
if [ -d "$PAYLOAD/etc/s6/nginx" ]; then
    mkdir -p $SVCDIR
    cp -f $PAYLOAD/etc/s6/nginx/* $SVCDIR/
    chmod +x $SVCDIR/run
    ok "the payload ships an s6 service directory for nginx"
else
    bad "the payload has no etc/s6/nginx/ -- nothing to supervise"
    exit 1
fi
gzip -dc /mnt/sup.tgz | tar -x -C $MODDIR || { bad "cannot unpack sup.tgz"; exit 1; }
chmod +x $S6/* $MODDIR/libexec/* 2>/dev/null
[ -x $S6/s6-svscan ] || { bad "sup.tgz has no bin/s6-svscan"; exit 1; }
ok "the real cross-built s6 is installed in $S6"

# A config to point it at. assets/nginx.conf is staged into the built payload
# rather than living in payload/, so it is not here; FlashForge's own is
# borrowed exactly as case-moonraker.sh borrows it. What is being measured is
# which process is alive and who put it there, not what nginx serves --
# except for the one thing the config has to get right for this case, which is
# that it listens on :80 so that "is it actually serving?" has an answer.
cp -f /usr/prog/nginx/conf/nginx.conf $MODDIR/nginx/nginx.conf
sed -i 's/^worker_processes.*/worker_processes 1;/' $MODDIR/nginx/nginx.conf
$NGINX -p $MODDIR/nginx -c $MODDIR/nginx/nginx.conf -t >/dev/null 2>&1 \
    && ok "the stand-in nginx.conf parses" \
    || { bad "the stand-in nginx.conf does not parse: `$NGINX -p $MODDIR/nginx -c $MODDIR/nginx/nginx.conf -t 2>&1 | tail -1`"; exit 1; }

echo
echo "=== 1. s6-svscan needs \$MODDIR/bin on PATH, and this is the measurement ==="
# THIS SECTION IS EVIDENCE, NOT A FEATURE. s6-svscan spawns one s6-supervise
# per service directory, and it finds that program on PATH -- there is no
# compiled-in path for it, unlike s6-ftrigrd, which s6-svlisten does resolve
# out of the prefix. $MODDIR/bin is not on any PATH on this printer: the mod's
# own anvil-env.sh appends /usr/prog/Python-3.8.2/bin and nothing else. With an
# EMPTY scandir, which is all phase 3 shipped, that costs nothing and nobody
# noticed. The moment a service directory exists, the scanner logs "unable to
# spawn s6-supervise for nginx: No such file or directory" and supervises
# nothing at all, which is a printer with no web UI and a puzzling log.
#
# The fix belongs in anvil-env.sh (one PATH entry, next to the one that is
# already there) and that file is not this agent's to change, so the sequence
# below both proves the problem and stands in for the fix, loudly. Everything
# after this section exports PATH by hand for exactly that reason.
mkdir -p /tmp/pathctl/nginx
cp -f $SVCDIR/run /tmp/pathctl/nginx/run
chmod +x /tmp/pathctl/nginx/run
touch /tmp/pathctl/nginx/down          # nothing may actually start in here
env -i /bin/sh -c "PATH=/bin:/sbin:/usr/bin:/usr/sbin $S6/s6-svscan /tmp/pathctl" \
    >/tmp/pathctl.log 2>&1 &
sleep 6
if grep -q "s6-supervise" /tmp/pathctl.log; then
    ok "without $S6 on PATH the scanner cannot spawn s6-supervise: `head -1 /tmp/pathctl.log`"
else
    bad "expected 'unable to spawn s6-supervise' with a bare PATH, log was: `head -2 /tmp/pathctl.log | tr '\n' ' '`"
fi
$S6/s6-svscanctl -t /tmp/pathctl 2>/dev/null
sleep 2
note "the rest of this case exports PATH=$S6:\$PATH, standing in for the"
note "one-line anvil-env.sh change this measurement asks for."
PATH=$S6:$PATH
export PATH

echo
echo "=== 2. the scanner, started the way the boot starts it ==="
$S40 start 2>&1 | sed 's/^/        /'
if $S40 status | grep -q "scanning $SCANDIR"; then
    ok "S40s6 has a scanner on $SCANDIR"
else
    bad "no scanner after S40s6 start: `$S40 status 2>&1 | head -2 | tr '\n' ' '`"
    exit 1
fi

echo
echo "=== 3. nginx ships DOWN, and MOD_WEB is what lifts it ==="
# The scandir is not where the MOD_WEB decision is made, because anvil.conf is
# read on the printer at runtime and the payload was built weeks earlier. So
# the service directory ships with a `down` file and the scanner starts it in
# the down state; init.d/S60nginx is what brings it up, after it has sourced
# anvil.conf. If this ever stops being true, MOD_WEB=0 becomes "nginx runs for
# two seconds on every boot and is then shot".
sleep 3
st=`svstat`
case "$st" in
    down*) ok "the scanner started nginx DOWN, as the down file asks: $st" ;;
    *)     bad "nginx came up on its own, before anything read anvil.conf: $st" ;;
esac
[ "`http`" = down ] && ok "nothing is listening on :80 yet" \
                    || bad ":80 is already answering before anything started nginx"
# And the down file is not empty -- it carries the paragraphs explaining why it
# is there. s6 is documented to care only that the file EXISTS, and this case
# is running with the real text in place, so the assertion above has just
# measured that as well rather than taking it on faith.
[ -s $SVCDIR/down ] \
    && ok "the down file s6 obeyed has `wc -l < $SVCDIR/down | tr -d ' '` lines of prose in it -- existence is the signal, not content" \
    || note "the down file is empty in this payload"

echo
echo "=== 4. S60nginx start ==="
$S60 start 2>&1 | sed 's/^/        /'
st=`svstat`
PID1=`svpid`
case "$st" in
    up*) ok "s6-svstat: $st" ;;
    *)   bad "s6-svstat after S60nginx start: $st"; ;;
esac
http_wait 25 && ok "port 80 is answering (pid $PID1)" \
              || bad "nginx is 'up' but :80 never answered -- `svstat`"
$S60 status 2>&1 | grep -q "^nginx: running" \
    && ok "S60nginx status: `$S60 status 2>&1 | head -1`" \
    || bad "S60nginx status does not say running: `$S60 status 2>&1 | head -1`"

echo
echo "=== 5. kill it -- THE point of the migration ==="
# SIGKILL, not SIGTERM, because SIGTERM is the polite path s6 itself uses and
# it is not what a crash looks like. This is also the harder case: nginx's
# worker survives a SIGKILLed master, keeps the listening socket, and goes on
# answering, so a naive respawn cannot bind and s6 loops for ever printing
# "still could not bind()" while an unsupervised leftover serves the UI. The
# `run` script sweeps that leftover before it execs, and this is the assertion
# that says whether it works -- a new pid AND a port that answers, from the
# supervisor and from the network rather than from the log.
note "killing pid $PID1 with SIGKILL"
kill -9 "$PID1" 2>/dev/null
sleep 12
st=`svstat`
PID2=`svpid`
case "$st" in
    up*) ok "s6 brought it back: $st" ;;
    *)   bad "s6 did NOT bring nginx back: $st" ;;
esac
if [ -n "$PID2" ] && [ "$PID2" != "$PID1" ]; then
    ok "the pid changed ($PID1 -> $PID2) -- this is a new nginx, not the old one"
else
    bad "no new pid after the kill (was '$PID1', now '$PID2')"
fi
http_wait 25 \
    && ok "and the respawned nginx actually bound :80 (no orphaned worker holding it)" \
    || bad "the respawned nginx is not serving -- `tail -2 $MODDIR/nginx/logs/error.log 2>/dev/null | tr '\n' ' '`"
note "nginx processes now: `nginx_procs` (a master and its worker)"

echo
echo "=== 6. restart gives a genuinely new process ==="
PID3=`svpid`
$S60 restart 2>&1 | sed 's/^/        /'
PID4=`svpid`
if [ -n "$PID4" ] && [ "$PID4" != "$PID3" ]; then
    ok "S60nginx restart: $PID3 -> $PID4"
else
    bad "S60nginx restart did not produce a new pid (was '$PID3', now '$PID4')"
fi
http_wait 25 && ok "and it is serving again after the restart" \
              || bad ":80 is not answering after restart -- `svstat`"

echo
echo "=== 7. stop, and STAY stopped ==="
# The bug this section exists for: `s6-svc -d` is not "kill the process", it is
# "the service is wanted down", and a stop implemented as a kill would be
# undone by the supervisor a second later. Nobody would notice until they
# tried to stop nginx and could not.
$S60 stop 2>&1 | sed 's/^/        /'
st=`svstat`
case "$st" in
    down*) ok "s6-svstat immediately after stop: $st" ;;
    *)     bad "S60nginx stop did not bring it down: $st" ;;
esac
[ "`http`" = down ] && ok ":80 stopped answering" \
                    || bad ":80 is still answering after stop -- something is left over"
$S60 status 2>&1 | grep -q "^nginx: not running" \
    && ok "S60nginx status: `$S60 status 2>&1 | head -1`" \
    || bad "S60nginx status is not honest about the stopped service: `$S60 status 2>&1 | head -1`"
note "waiting 12s to see whether the supervisor puts it back"
sleep 12
st=`svstat`
case "$st" in
    down*) ok "12 seconds later it is STILL down: $st" ;;
    *)     bad "the supervisor undid the stop: $st" ;;
esac
[ "`nginx_procs`" = 0 ] && ok "no nginx processes are left at all" \
                        || bad "`nginx_procs` nginx processes survived the stop"

echo
echo "=== 8. MOD_WEB=0 means no nginx ==="
sed -i 's/^MOD_WEB=.*/MOD_WEB=0/' $MODDIR/anvil.conf
grep -q '^MOD_WEB=0' $MODDIR/anvil.conf || bad "could not set MOD_WEB=0 in anvil.conf"
out=`$S60 start 2>&1`
echo "$out" | sed 's/^/        /'
echo "$out" | grep -q "MOD_WEB=0" \
    && ok "S60nginx start says it is disabled" \
    || bad "S60nginx start did not mention MOD_WEB: $out"
sleep 5
st=`svstat`
case "$st" in
    down*) ok "and nginx is still down: $st" ;;
    *)     bad "MOD_WEB=0 but nginx is running: $st" ;;
esac
[ "`http`" = down ] && ok ":80 is not answering with MOD_WEB=0" \
                    || bad ":80 answers with MOD_WEB=0 -- the gate does not gate"
sed -i 's/^MOD_WEB=.*/MOD_WEB=1/' $MODDIR/anvil.conf

echo
echo "=== 9. negative control: the same service WITHOUT 'daemon off;' ==="
# Everything above rests on nginx staying in the foreground, and "we passed the
# right flag" is precisely the kind of claim that goes on being true in a
# comment long after it has stopped being true in the code. So here is the
# service somebody would have written by copying the old start line -- nginx
# with its default, which is to fork a master into the background and exit --
# supervised by the same s6, in a scandir of its own so it cannot disturb
# anything (and on port 8099, so it is not fighting for :80 either).
#
# It must CHURN: s6 supervises the process that forked and exited, sees it die
# at once, and starts it again, for ever. That is what the pid moving under a
# service that has not been touched proves. If this control ever passes
# quietly, the assertions above are measuring nothing.
#
# It gets a PREFIX AND A CONFIG OF ITS OWN, written from scratch rather than
# sed'd out of the one above. The first version of this section reused
# $MODDIR/nginx and patched the port with sed; the `pid` line in FlashForge's
# config is commented out, so the patch missed it, the control's nginx wrote
# $MODDIR/nginx/logs/nginx.pid, and section 10 then read that pidfile and
# reported the CONTROL's process as the service. A control that leaks into the
# thing it is controlling for is worse than no control.
mkdir -p /tmp/negctl/naive $MODDIR/nginx-naive/logs
cat > $MODDIR/nginx-naive/naive.conf <<'EOC'
worker_processes 1;
error_log logs/error.log warn;
pid       logs/naive.pid;
events { worker_connections 32; }
http { server { listen 8099; } }
EOC
cat > /tmp/negctl/naive/run <<EOR
#!/bin/sh
exec $NGINX -p $MODDIR/nginx-naive -c $MODDIR/nginx-naive/naive.conf
EOR
chmod +x /tmp/negctl/naive/run
$S6/s6-svscan /tmp/negctl >/tmp/negctl.log 2>&1 &
# Five samples of "which process is s6 supervising", eight seconds apart at
# the start and then quickly, because a service that is being respawned every
# second has no stable answer and one that is genuinely up has exactly one.
# -1 is s6-svstat's answer for "down right now", which is itself churn.
sleep 8
NSEEN=
NDISTINCT=0
for _i in 1 2 3 4 5; do
    _p=`$S6/s6-svstat -p /tmp/negctl/naive 2>/dev/null`
    case " $NSEEN " in
        *" $_p "*) ;;
        *) NSEEN="$NSEEN $_p"; NDISTINCT=$((NDISTINCT + 1)) ;;
    esac
    sleep 3
done
if [ $NDISTINCT -ge 2 ]; then
    ok "negative control: a daemonising nginx is respawned over and over (pids seen:$NSEEN)"
else
    bad "negative control: a daemonising service looked stable (pids seen:$NSEEN) -- the foreground flag is not what makes the checks above pass"
fi
$S6/s6-svc -d /tmp/negctl/naive 2>/dev/null
$S6/s6-svscanctl -t /tmp/negctl 2>/dev/null
sleep 3
kill -9 `cat $MODDIR/nginx-naive/logs/naive.pid 2>/dev/null` 2>/dev/null
sleep 2
for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    case "`tr '\0' ' ' < "$d/cmdline" 2>/dev/null`" in
        *nginx-naive*) kill -9 "${d#/proc/}" 2>/dev/null ;;
    esac
done
sleep 2
note "nginx processes after the control was cleaned up: `nginx_procs`"

echo
echo "=== 10. no supervisor at all: does S60nginx degrade honestly? ==="
# MOD_S6=0 is a switch S40s6 honours and a failed s6 build is a state that
# happens, so "no scanner" is not hypothetical. The choice made in S60nginx is
# to start nginx the old way and SAY SO with the "!!" people grep for, rather
# than to refuse: a printer that loses its web UI because a supervisor did not
# build has lost it for a reason that has nothing to do with nginx. What must
# not happen is that it degrades silently, or that it crashes.
$S40 stop >/dev/null 2>&1
sleep 3
out=`$S60 start 2>&1`
echo "$out" | sed 's/^/        /'
echo "$out" | grep -q "!!" \
    && ok "with no scanner, S60nginx warns before falling back" \
    || bad "S60nginx fell back to a direct start without saying so: $out"
http_wait 25 \
    && ok "and it started nginx anyway -- the UI survives a dead supervisor" \
    || bad "no supervisor and no nginx either: `$S60 status 2>&1 | head -1`"
$S60 status 2>&1 | grep -q "unsupervised" \
    && ok "status admits the process is unsupervised: `$S60 status 2>&1 | head -1`" \
    || bad "status hides that nothing is supervising nginx: `$S60 status 2>&1 | head -1`"
$S60 stop >/dev/null 2>&1
sleep 3
[ "`http`" = down ] && ok "the fallback path can stop it again" \
                    || bad "the unsupervised nginx would not stop"

# ---- leave nothing running ------------------------------------------------
$S40 stop >/dev/null 2>&1
for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    a=`tr '\0' ' ' < "$d/cmdline" 2>/dev/null`
    case "$a" in
        "nginx: "*|*"$NGINX"*|*s6-svscan*|*s6-supervise*) kill -9 "${d#/proc/}" 2>/dev/null ;;
    esac
done

echo
[ $FAIL -eq 0 ] && echo "  nginx under s6: all checks passed"
exit $FAIL
