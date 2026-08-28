# The shape every mod service script has. Sourced, never executed.
#
#     MODDIR=/usr/data/anvil
#     [ -f $MODDIR/anvil.conf ] && . $MODDIR/anvil.conf
#     . $MODDIR/anvil-service.sh
#     SVC_NAME=moonraker
#
# WHY THIS FILE EXISTS. Every script in init.d/ has the same four problems: how
# to say something in the boot log, how to tell whether the daemon is still
# there, how to stop it without leaving a stale pidfile, and how to wait on
# hardware without holding up the boot. This is the shared answer, so fixing one
# of them fixes it everywhere rather than in whichever script the bug was
# noticed in -- and so the busybox corrections below (see svc_stop_daemon) live
# in one place where the comment cannot drift away from the code.
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
#   -- talking to s6, for the services that have been moved to it --
#   SVC_S6_BIN        where the s6 binaries are; $MODDIR/bin
#   SVC_S6_SCANDIR    the scandir S40s6 scans; $MODDIR/etc/s6
#
#   svc_s6_running                  is the SCANNER alive and listening?
#   svc_s6_svc NAME OPT...          s6-svc OPT... $SVC_S6_SCANDIR/NAME
#   svc_s6_up NAME [SECONDS]        bring NAME up and WAIT until it is up
#   svc_s6_down NAME [SECONDS]      bring NAME down and WAIT until it is down
#   svc_s6_stat NAME                one line of s6-svstat, on stdout
#   svc_s6_ready NAME [SECONDS]     block until NAME declares itself READY
#
# The script defines start(), stop() and status(); this file defines
# everything else. A script with an extra verb intercepts it before handing the
# rest over -- see svc_dispatch.

# ---- saying things ---------------------------------------------------------
#
# Every line these scripts print is "name: something", because firmwareExe runs
# them all into one boot log and a bare "started" says nothing about which
# started. Name it once, at the top, in SVC_NAME.
#
# The "!!" on svc_warn is what somebody greps for when a printer boots wrong,
# and means the same everywhere else in the mod (firmwareExe and start.sh).
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
# svc_pid_alive is for a daemon WE started through start-stop-daemon, so the
# pid is known exactly. Prefer it: it cannot be confused by a second copy, by a
# grep matching its own pipeline, or by an unrelated process with a similar
# name. The pidfile can still lie -- pids get recycled -- which is why
# svc_stop_daemon below removes it.
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
# The caller announces success itself, with the path or port that makes it
# useful. Failure is announced here with the exit code: busybox
# start-stop-daemon exits non-zero when a process matching the pidfile is
# ALREADY running, which after a `restart` means the old one outlived the wait
# in stop(). Either way nothing new started, and a script that prints nothing
# at that moment looks like it worked.
#
# SVC_NICE, non-empty and non-zero, becomes start-stop-daemon's -N. klippy
# shares two cores with everything the mod added, and Klipper reports a host
# that misses its step deadlines as an MCU "Timer too close" shutdown, so the
# services around it should yield to it. CPU only: this busybox has no ionice
# applet, so eMMC contention has no equivalent knob.
#
# -N rather than a `nice -n` wrapper because --exec is what start-stop-daemon
# matches and records, and wrapping would make that the nice binary rather than
# the program.
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
# returns immediately, and does not remove the pidfile. Both are wrong here:
#
#   * Not waiting makes `restart` race its own start. stop() returns, start()
#     runs start-stop-daemon -S, the old process is still holding the pidfile,
#     -S refuses, and the service is now stopped rather than restarted.
#   * Not removing the pidfile leaves svc_pid_alive testing a pid that the
#     kernel is free to hand to something else, so `status` eventually reports
#     an unrelated process as a running service.
#
# So: signal, wait for it to actually be gone, then remove the file. 15 seconds
# is long enough for moonraker to finish writing its database and short enough
# that a stuck process does not hold a boot open. A process still there at the
# end is said out loud, because the next start is about to fail and this is the
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
# So the waiting happens detached and start() returns at once. The cost is that
# the detached lines arrive in the boot log out of order, after the later
# services'.
#
# It returns 0 unconditionally: letting `func &` be the last statement of
# start() would hand the caller the shell's opinion of a fork rather than a
# verdict on the service. SVC_BG_PID is for a supervisor that has to be
# killable -- S65camera writes it to a pidfile, because killing only the
# streamer it supervises gets the streamer restarted three seconds later.
svc_detach() {
    "$@" &
    SVC_BG_PID=$!
    return 0
}

# ---- talking to s6 ---------------------------------------------------------
#
# Everything above is the hand-rolled supervisor; everything below is how a
# service asks the real one instead. Both sets exist at once: S40s6 starts the
# scanner and the services move into it ONE AT A TIME, each keeping its S*
# script as the interface people already type. A service that has not moved
# uses the functions above and does not know these exist.
#
# WHERE THE PATHS COME FROM. s6 bakes its own prefix in at COMPILE time -- its
# waiting verbs exec s6-svlisten, which spawns s6-ftrigrd out of the libexecdir
# chosen by ./configure -- so the binaries only work from the prefix they were
# built for (/usr/data/anvil; see tools/supervisor/README.md, where shipping
# them elsewhere made every waiting verb fail while status and respawn kept
# working). The scandir is the second thing every script has to agree about
# with S40s6. Both are overridable so a test can point at its own scandir
# without reinstalling the payload.
SVC_S6_BIN=${SVC_S6_BIN:-${MODDIR:-/usr/data/anvil}/bin}
# Not written as one ${MODDIR:-/usr/data/anvil} expression ending in etc/s6:
# test_paths.py's absolute-path regex reads the closing brace immediately
# followed by that suffix as a STOCK rootfs path in its own right (its
# lookbehind excludes a preceding word character or dot, but not a brace),
# and this directory is not something any stock FlashForge rootfs ships -- it
# lives under $MODDIR, on the data partition. Splitting the fallback onto its
# own line puts a word character (the variable name) right before the suffix
# instead, which the same lookbehind does exclude.
_s6_default_scandir=${MODDIR:-/usr/data/anvil}
_s6_default_scandir=$_s6_default_scandir/etc/s6
SVC_S6_SCANDIR=${SVC_S6_SCANDIR:-$_s6_default_scandir}
unset _s6_default_scandir

# Is the SCANNER there? Asked by BEHAVIOUR, not by process name.
# `s6-svscanctl -a` is the request to rescan the scandir: harmless, idempotent,
# and it travels down $SCANDIR/.s6-svscan/control, a FIFO opened non-blocking.
# With nothing reading that FIFO the open fails with ENXIO and s6-svscanctl
# exits 100, "supervisor not listening". A dead scanner leaves the FIFO on
# disk, so this is a distinction `ps | grep` cannot make.
#
# It answers false rather than exploding when s6 is not installed at all,
# because that is a real state on a printer half-way through an update.
svc_s6_running() {
    [ -x "$SVC_S6_BIN/s6-svscanctl" ] || return 1
    "$SVC_S6_BIN/s6-svscanctl" -a "$SVC_S6_SCANDIR" >/dev/null 2>&1
}

# The raw verb, for anything the four wrappers below do not cover. NAME first
# and the options after, which is the opposite order to s6-svc's own -- s6
# wants `s6-svc OPTIONS servicedir` -- because in ash it is the first argument
# that can be shifted off cleanly, and because every caller here is naming a
# service, not a directory. The directory is this file's business.
svc_s6_svc() {
    _svc_s6_name=$1
    shift
    "$SVC_S6_BIN/s6-svc" "$@" "$SVC_S6_SCANDIR/$_svc_s6_name"
    _svc_s6_rc=$?
    unset _svc_s6_name
    return $_svc_s6_rc
}

# Up and down, each WAITING for what it asked for, which is the reason to
# prefer a supervisor to start-stop-daemon. -wu/-wD do not return until the
# service is really up or really down, and -T bounds that in MILLISECONDS so a
# service that never comes down cannot hold a boot or an ssh session open. The
# 15-second default is svc_stop_daemon's bound and reasoning.
svc_s6_up() {
    svc_s6_svc "$1" -wu -T "$(( ${2:-15} * 1000 ))" -u
}

svc_s6_down() {
    svc_s6_svc "$1" -wD -T "$(( ${2:-15} * 1000 ))" -d
}

# One line about a service, on stdout, for a status() to print. s6-svstat's own
# output is already the right shape -- "up (pid 1234) 71 seconds" -- so it is
# passed through rather than paraphrased. 2>&1 because "unable to open
# supervise/status" is also an answer.
svc_s6_stat() {
    "$SVC_S6_BIN/s6-svstat" "$SVC_S6_SCANDIR/$1" 2>&1
}

# READINESS -- the reason this is s6 and not runit. A service that writes to
# its notification-fd is telling the supervisor it is USABLE, not merely
# forked, and s6-svwait -U blocks until it does; runit's `sv start` returns on
# the fork, which says nothing.
#
# Unused today: S65camera polls /dev/video0 for up to 30 seconds and S70klipper
# retries an MCU handshake for up to 90, both inside their own scripts, and
# both become "declare ready when the device is there" plus a caller that waits
# here. Timeout in seconds, converted to the milliseconds s6 wants; non-zero if
# it ran out, so a caller can carry on degraded rather than block.
svc_s6_ready() {
    "$SVC_S6_BIN/s6-svwait" -U -t "$(( ${2:-30} * 1000 ))" "$SVC_S6_SCANDIR/$1"
}

# ---- the verb block --------------------------------------------------------
#
# Every one of these scripts ends in the same case statement, spelled once here.
#
# `restart` has NO sleep between stop and start. A sleep there stands in for a
# wait nobody is doing -- busybox start-stop-daemon -K returns before the
# process is dead -- and svc_stop_daemon waits for the process to actually be
# gone, for as long as it takes. A stop() that does not wait is a bug to fix in
# stop(); a sleep only hides it for two seconds.
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
