#!/bin/sh
# Does the s6 the BUILD produced actually supervise on the printer's own
# kernel? Behaviour only -- no greps.
#
# The supervisor choice itself is settled -- s6 over runit, on readiness
# notification, which runit has no concept of; the measurements are in
# tools/supervisor/README.md, and the contrast note in section 3 is why we are
# here. This gate is fed the `bin/` and `libexec/` the recipes produced, which
# is what bin/patch.sh stages into the payload.
#
# s6 has its own prefix baked in at compile time, so it can only be unpacked
# where it was configured to live: /usr/data/anvil, the mod's prefix root.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
note(){ echo "  ..    $*"; }

mkdir -p /usr/data/anvil
gzip -dc /mnt/sup.tgz | tar -x -C /usr/data/anvil || { bad "cannot unpack sup.tgz"; exit 1; }
chmod +x /usr/data/anvil/bin/* /usr/data/anvil/libexec/* 2>/dev/null
S6=/usr/data/anvil/bin
export PATH=$S6:$PATH

echo "=== 0. do the binaries execute on this box at all? ==="
$S6/s6-svstat 2>&1 | head -1 | grep -qi usage \
    && ok "s6-svstat runs (static mipsel is loadable here)" \
    || bad "s6-svstat did not run: `$S6/s6-svstat 2>&1 | head -1`"
# Every binary the payload promises, not just the one above: a cross-build can
# emit an object this kernel refuses (wrong endianness, wrong ABI) for one
# tool and not another, and the ones that only matter at stop/wait time are
# exactly the ones nobody would notice until a service had to be stopped.
MISSING=
for b in s6-svscan s6-svscanctl s6-supervise s6-svc s6-svstat s6-svwait \
         s6-svok s6-svlisten s6-svlisten1 s6-ftrig-listen1 s6-mkfifodir \
         s6-cleanfifodir s6-notifyoncheck; do
    [ -x "$S6/$b" ] || { MISSING="$MISSING $b"; continue; }
    # No argument and no service: every one of these exits non-zero with a
    # usage line. What is being asked is only "did the kernel load it", so
    # ENOEXEC ("cannot execute binary file") is the failure being looked for.
    out=`$S6/$b 2>&1 | head -1`
    case "$out" in
        *"cannot execute"*|*"not executable"*|*"Exec format error"*)
            MISSING="$MISSING $b(ENOEXEC)" ;;
    esac
done
[ -z "$MISSING" ] && ok "all 13 supervision binaries load and run" \
                  || bad "binaries the kernel would not run:$MISSING"
[ -x /usr/data/anvil/libexec/s6-ftrigrd ] \
    && ok "libexec/s6-ftrigrd is present (section 3 proves it is reachable)" \
    || bad "no libexec/s6-ftrigrd -- every waiting verb will fail"

# A fake daemon that logs its pid and stays in the foreground -- exactly the
# shape every one of our real services already has.
mkdir -p /usr/data/anvil/fake
cat > /usr/data/anvil/fake/daemon.sh <<'EOD'
#!/bin/sh
echo "started pid $$" >> /tmp/daemon.log
while true; do sleep 1; done
EOD
chmod +x /usr/data/anvil/fake/daemon.sh

echo
echo "=== 1. supervise, status, restart-on-death, blocking stop ==="
rm -f /tmp/daemon.log
mkdir -p /usr/data/anvil/s6sv/cam
cat > /usr/data/anvil/s6sv/cam/run <<'EOR'
#!/bin/sh
exec /usr/data/anvil/fake/daemon.sh
EOR
chmod +x /usr/data/anvil/s6sv/cam/run

# The readiness service is created BEFORE the scanner starts, so section 2 does
# not have to rescan a live scandir. Its run script tells s6 it is ready only
# after a deliberate 5s delay -- standing in for a device that takes a while to
# appear, which is exactly the camera's situation.
mkdir -p /usr/data/anvil/s6sv/slow
echo 3 > /usr/data/anvil/s6sv/slow/notification-fd
cat > /usr/data/anvil/s6sv/slow/run <<'EOR'
#!/bin/sh
sleep 5
echo ready >&3
exec /usr/data/anvil/fake/daemon.sh
EOR
chmod +x /usr/data/anvil/s6sv/slow/run

$S6/s6-svscan /usr/data/anvil/s6sv >/tmp/s6svscan.log 2>&1 &
SVSCAN_PID=$!
sleep 8

note "svscan alive? `kill -0 $SVSCAN_PID 2>&1 && echo yes || echo NO`"
note "svscan log: `cat /tmp/s6svscan.log 2>&1 | head -5`"
note "service dir: `ls -a /usr/data/anvil/s6sv/cam 2>&1 | tr '\n' ' '`"
note "daemon.log: `cat /tmp/daemon.log 2>&1 | head -3`"
st=`$S6/s6-svstat /usr/data/anvil/s6sv/cam 2>&1`
case "$st" in
    up*) ok "s6-svstat -> $st" ;;
    *)   bad "s6-svstat -> $st" ;;
esac

before=`grep -c started /tmp/daemon.log 2>/dev/null`
pid=`$S6/s6-svstat -p /usr/data/anvil/s6sv/cam 2>/dev/null`
if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    sleep 8
    after=`grep -c started /tmp/daemon.log 2>/dev/null`
    if [ "${after:-0}" -gt "${before:-0}" ]; then
        ok "s6 respawned the daemon after kill -9 ($before -> $after starts)"
    else
        bad "s6 did NOT respawn (starts $before -> $after)"
    fi
else
    bad "s6: could not read a pid out of s6-svstat -p (got '$pid')"
fi

# -wD means "do not return until the service is actually down"; -d is the
# request to bring it down and keep it down. This is the thing
# svc_stop_daemon hand-rolls, and the first place a wrongly-prefixed s6 would
# fail: -w execs s6-svlisten, which spawns s6-ftrigrd out of the libexecdir
# compiled into the binary.
stopout=`$S6/s6-svc -wD -T 20000 -d /usr/data/anvil/s6sv/cam 2>&1`
[ -n "$stopout" ] && note "s6-svc said: $stopout"
st=`$S6/s6-svstat /usr/data/anvil/s6sv/cam 2>&1`
case "$st" in
    down*) ok "s6 's6-svc -wD -d' returned with the service already down" ;;
    *)     bad "s6 stop returned but status is: $st" ;;
esac

echo
echo "=== 2. readiness notification (the reason s6 and not runit) ==="
# This is the whole reason to prefer s6: the service tells the supervisor when
# it is READY, so a dependent can wait on readiness instead of polling. Our
# camera service currently polls /dev/video0 for up to 30 seconds.
# Restart it so the 5s ready delay starts now, then time how long s6-svwait -U
# blocks. If readiness works, it returns at ~5s -- not instantly (which would
# mean it only checked "is the process up") and not at the timeout.
$S6/s6-svc -wD -T 20000 -d /usr/data/anvil/s6sv/slow 2>/dev/null
start=`date +%s`
$S6/s6-svc -u /usr/data/anvil/s6sv/slow 2>/dev/null
if waitout=`$S6/s6-svwait -U -t 30000 /usr/data/anvil/s6sv/slow 2>&1`; then
    end=`date +%s`
    elapsed=$((end - start))
    if [ $elapsed -ge 3 ] && [ $elapsed -le 25 ]; then
        ok "s6-svwait -U blocked until the service declared itself ready (${elapsed}s)"
    else
        bad "s6-svwait -U returned after ${elapsed}s -- not the ~5s readiness delay"
    fi
else
    bad "s6-svwait -U did not see a readiness notification: $waitout"
fi
note "for contrast, runit has no readiness concept: 'sv start' returns when the"
note "process has been forked, not when the service is usable. That is what"
note "decided this; see tools/supervisor/README.md."

echo
echo "=== 3. footprint per supervised service ==="
note "supervisor RSS (kB):"
ps -o rss,comm 2>/dev/null | grep -E "s6-supervise|s6-svscan" | head
note "on-disk, stripped, static:"
du -sh /usr/data/anvil/bin /usr/data/anvil/libexec 2>/dev/null

pkill -f s6-svscan 2>/dev/null
pkill -f s6-supervise 2>/dev/null

echo
[ $FAIL -eq 0 ] && echo "  supervisor: all checks passed"
exit $FAIL
