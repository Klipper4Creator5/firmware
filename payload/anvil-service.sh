# The shape every mod service script has. Sourced, never executed.
#
#     MODDIR=/usr/data/anvil
#     [ -f $MODDIR/anvil.conf ] && . $MODDIR/anvil.conf
#     . $MODDIR/anvil-service.sh
#     SVC_NAME=moonraker
#
# WHY THIS FILE EXISTS. The five scripts in init.d/ were written one at a time,
# months apart, each solving the same four problems as it hit them: how to say
# something in the boot log, how to tell whether the daemon is still there, how
# to stop it without leaving a stale pidfile, and how to wait on hardware
# without holding up the boot. They arrived at four different answers to the
# liveness question alone -- a pidfile and `kill -0`, two spellings of
# `ps | grep`, `pgrep -f` with a ps fallback, and a socket test -- and at two
# different answers to `restart`. None of those differences were decisions;
# they were the order the scripts got written in. This file is the shared
# answer, so that fixing one of these problems fixes it everywhere instead of
# in whichever script the bug was noticed in.
#
# It is deliberately small. Nothing here does anything a service script could
# not do in three lines; what it buys is that all of them now do it the same
# way, and that the busybox corrections below (see svc_stop_daemon) live in one
# place where the comment explaining them cannot drift away from the code.
#
# THE API, in full:
#
#   SVC_NAME          the log prefix, set once per script. Required.
#   SVC_EXTRA_VERBS   optional; extra verbs for the usage line, e.g.
#                     SVC_EXTRA_VERBS="|force-start"
#
#   svc_say MSG                     -> "name: MSG"
#   svc_warn MSG                    -> "name: !! MSG"
#   svc_pid_alive PIDFILE           is the pid in this file still a process?
#   svc_proc_alive PATTERN          is a process matching this pattern running?
#   svc_start_daemon PIDFILE EXEC [ARGS...]
#                                   start-stop-daemon -S, backgrounded, with a
#                                   pidfile; warns and returns non-zero if
#                                   nothing was started
#   svc_stop_daemon PIDFILE         stop it, WAIT for it to actually be gone,
#                                   remove the pidfile
#   svc_detach FUNC [ARGS...]       run a slow thing in the background and
#                                   return at once; SVC_BG_PID is its pid
#   svc_dispatch "$@"               the start|stop|restart|status block; calls
#                                   the start(), stop() and status() the script
#                                   defines, and exits
#
# The script defines start(), stop() and status(); this file defines
# everything else. A script with an extra verb intercepts it before handing the
# rest over -- see svc_dispatch.

# ---- saying things ---------------------------------------------------------
#
# Every line any of these scripts has ever printed is "name: something", because
# firmwareExe runs all five into the same boot log and a bare "started" tells
# nobody which of them started. Repeating the name in every echo is how one of
# them ended up printing "web: stopped" from a script that by then also owned
# the camera. Name it once, at the top, in SVC_NAME.
#
# The "!!" on svc_warn is not decoration: it is what somebody greps for when a
# printer boots wrong, and it already means "this is why your printer is not
# working" everywhere else in the mod (firmwareExe and start.sh both use it).
svc_say() {
    echo "${SVC_NAME:-service}: $*"
}

svc_warn() {
    echo "${SVC_NAME:-service}: !! $*"
}

# ---- is it alive? ----------------------------------------------------------
#
# Two answers, because there are genuinely two situations.
#
# svc_pid_alive is for a daemon WE started through start-stop-daemon, so we
# know its pid exactly. It is the better of the two and should be preferred:
# it cannot be confused by a second copy, by a grep matching its own pipeline,
# or by an unrelated process with a similar name.
#
# The pidfile can still lie -- a pid gets recycled -- which is the whole reason
# svc_stop_daemon below removes it. A stale pidfile plus this check is how
# `status` came to report a dead moonraker as running.
svc_pid_alive() {
    [ -f "$1" ] || return 1
    kill -0 "`cat "$1" 2>/dev/null`" 2>/dev/null
}

# svc_proc_alive is for a process we did NOT start with a pidfile -- klippy,
# launched by FlashForge's start.sh; wpa_supplicant, which backgrounds itself
# with -B; mjpg_streamer under its own respawn loop. All we have is the name.
#
# pgrep is tried first and is not assumed: this busybox is built with it on the
# printers we have looked at, but that is a build option and a rootfs we do not
# control ships it. The fallback is plain `ps` (busybox ps takes no options
# worth relying on, so this is deliberately bare) piped through grep, with the
# `grep -v grep` that stops the pipeline from matching itself.
#
# Pass the pattern in the form pgrep wants; `klippy\.py` matches both, because
# grep reads the backslash-escaped dot the same way.
svc_proc_alive() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "$1" >/dev/null 2>&1
    else
        ps 2>/dev/null | grep "$1" | grep -v grep >/dev/null 2>&1
    fi
}

# ---- starting and stopping -------------------------------------------------
#
# start-stop-daemon -S with -b (background it), -m (write the pidfile) and -p.
# The pidfile is the point: without one there is no way to stop the daemon
# except by name, and by-name is how you kill the wrong python.
#
# The caller announces success itself, because "started" is worth saying with
# the path or the port that makes it useful. Failure is announced here, with
# the exit code, because there is exactly one thing to say about it and it went
# unsaid for a long time: busybox start-stop-daemon exits non-zero when a
# process matching the pidfile is ALREADY running, which after a `restart`
# means the old one outlived the wait in stop(). Either way nothing new was
# started, and a script that prints nothing at that moment looks like it worked.
#
# SVC_NICE, when the caller sets it to a non-empty non-zero number, becomes
# start-stop-daemon's -N: the daemon starts at that nice value. It exists
# because klippy shares two cores with everything else the mod added, and
# Klipper reports a host that misses its step deadlines as an MCU "Timer too
# close" shutdown -- so the services around it should yield to it rather than
# compete on equal terms. Only CPU: busybox 1.31.1 on this printer has no
# ionice applet (checked in the replica, not assumed), so eMMC contention has
# no equivalent knob and is not addressed here.
#
# Why -N and not a `nice -n` wrapper: --exec is what start-stop-daemon matches
# and records, and wrapping would make that the nice binary rather than the
# program itself. -N keeps the exec path real. Both were verified to produce
# the wanted nice value on the printer's own busybox; -N is the one that keeps
# the pidfile honest.
svc_start_daemon() {
    _svc_pidfile=$1
    shift
    _svc_exec=$1
    shift
    # An empty or 0 SVC_NICE means "as before": no -N, normal priority.
    if [ -n "${SVC_NICE:-}" ] && [ "${SVC_NICE:-0}" != 0 ]; then
        start-stop-daemon -S -b -m -N "$SVC_NICE" \
            -p "$_svc_pidfile" --exec "$_svc_exec" -- "$@"
    else
        start-stop-daemon -S -b -m -p "$_svc_pidfile" --exec "$_svc_exec" -- "$@"
    fi
    _svc_rc=$?
    [ $_svc_rc = 0 ] || svc_warn "FAILED to start -- start-stop-daemon returned $_svc_rc"
    unset _svc_pidfile _svc_exec
    return $_svc_rc
}

# The correction busybox needs. Its start-stop-daemon -K sends the signal and
# returns immediately, and it does not remove the pidfile. Both of those are
# wrong for us, in ways that took a while to read as bugs:
#
#   * Not waiting makes `restart` race its own start. stop() returns, start()
#     runs start-stop-daemon -S, the old process is still holding the pidfile,
#     -S refuses, and the service is now stopped rather than restarted.
#   * Not removing the pidfile leaves svc_pid_alive testing a pid that the
#     kernel is free to hand to something else, so `status` eventually reports
#     an unrelated process as a running service.
#
# So: signal, then wait for it to actually be gone, then remove the file. The
# bound is 15 seconds because that is long enough for moonraker to finish
# writing its database and short enough that a stuck process does not hold a
# boot open; a process still there at the end gets said out loud rather than
# silently abandoned, because the next start is about to fail and this is the
# line that explains why.
svc_stop_daemon() {
    [ -f "$1" ] || return 0
    start-stop-daemon -K -p "$1" 2>/dev/null
    _svc_waited=0
    while svc_pid_alive "$1" && [ $_svc_waited -lt 15 ]; do
        sleep 1
        _svc_waited=$((_svc_waited + 1))
    done
    svc_pid_alive "$1" && svc_warn "still running after ${_svc_waited}s"
    unset _svc_waited
    rm -f "$1"
    return 0
}

# ---- not making the boot wait ----------------------------------------------
#
# firmwareExe runs $MODDIR/init.d/S* one at a time, in the FOREGROUND, in
# filename order. So every second a start() spends waiting is a second the
# services after it do not exist -- and the waits in these scripts are all
# hardware: up to 15s for wlan0 to register after the 8821cu insmod and 20s
# more to associate, 30s for a USB camera to enumerate, 90s for klippy to give
# up on an MCU. Inline, the longest delay lands on exactly the machine with no
# network, no camera or no heater board, which is the machine somebody needs to
# ssh into to find out why.
#
# The rule firmwareExe already states for a service that FAILS, applied to one
# that is merely slow: the waiting happens detached and start() returns at
# once. The cost is that the detached lines arrive in the boot log after the
# later services' lines, out of order. That is the trade, and it is the right
# way round.
#
# It returns 0 unconditionally: nothing is going to read the exit status of a
# background job, and letting `func &` be the last statement of start() would
# hand the caller the shell's opinion of a fork rather than a verdict on the
# service. SVC_BG_PID is there for a supervisor that has to be killable --
# S65camera writes it to a pidfile, because killing only the streamer it
# supervises gets the streamer restarted three seconds later.
svc_detach() {
    "$@" &
    SVC_BG_PID=$!
    return 0
}

# ---- the verb block --------------------------------------------------------
#
# Every one of these scripts ends in the same case statement, and they had
# drifted: two spellings of the usage line, and `restart` implemented twice --
# `stop; start` in one, `stop; sleep 2; start` in the others.
#
# THE SLEEP IS GONE, on purpose. It was standing in for a wait that nobody was
# doing: busybox start-stop-daemon -K returns before the process is dead, so
# something had to pass before the start could succeed, and two seconds was a
# guess that happened to be enough most of the time. svc_stop_daemon now waits
# for the process to actually be gone, which is the thing the sleep was
# approximating -- and does it correctly, for as long as it genuinely takes. A
# stop() that waits makes the sleep redundant; a stop() that does not is a bug
# to fix in stop(), because the sleep only ever hid it for two seconds.
#
# EXTRA VERBS. S70klipper has `force-start`, which overrides its hand-off to
# ff-startup.py. A script with a verb of its own handles it first and hands the
# rest here, and names it in SVC_EXTRA_VERBS so the usage line stays true:
#
#     SVC_EXTRA_VERBS="|force-start"
#     case "$1" in
#         force-start) start force ;;
#         *)           svc_dispatch "$@" ;;
#     esac
#
# This exits rather than returns, so it is the last statement of the script.
# The exit code is the one start(), stop() or status() produced -- an unknown
# verb is the only thing this file decides, and it is 1.
svc_dispatch() {
    case "$1" in
        start|'') start; exit $? ;;
        stop)     stop; exit $? ;;
        restart)  stop; start; exit $? ;;
        status)   status; exit $? ;;
        *) echo "usage: $0 {start|stop|restart|status${SVC_EXTRA_VERBS:-}}"; exit 1 ;;
    esac
}
