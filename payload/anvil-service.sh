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
svc_start_daemon() {
    _svc_pidfile=$1
    shift
    _svc_exec=$1
    shift
    start-stop-daemon -S -b -m -p "$_svc_pidfile" --exec "$_svc_exec" -- "$@"
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

# ---- talking to s6 ---------------------------------------------------------
#
# Everything above this line is the hand-rolled supervisor: a liveness test we
# wrote, a stop-and-wait we wrote, and -- in S65camera -- a respawn loop we
# wrote. Everything below is how a service asks the real one instead. Both
# sets exist at once and will for a while: S40s6 starts the scanner, and the
# six services move into it ONE AT A TIME, each keeping its S* script as the
# interface people already type. A service that has not moved uses the
# functions above and does not know these exist.
#
# WHERE THE PATHS COME FROM, and why they are here rather than in each script.
# s6 bakes its own prefix in at COMPILE time -- its waiting verbs exec
# s6-svlisten, which spawns s6-ftrigrd out of the libexecdir chosen by
# ./configure, so the binaries only work from the prefix they were built for
# (/usr/data/anvil; see tools/supervisor/README.md, where shipping them
# elsewhere made every waiting verb fail while status and respawn kept
# working, i.e. it failed late and partially). The scandir is a second thing
# every one of these scripts has to agree about with S40s6, and the way to
# make several scripts agree is to say it once, in the file they all source.
# Both are overridable so a test can point at a scandir of its own without
# reinstalling the payload.
SVC_S6_BIN=${SVC_S6_BIN:-${MODDIR:-/usr/data/anvil}/bin}
SVC_S6_SCANDIR=${SVC_S6_SCANDIR:-${MODDIR:-/usr/data/anvil}/etc/s6}

# Is the SCANNER there? Not "is there a process called s6-svscan" -- this is
# asked BY BEHAVIOUR, which is the rule the rest of this file was rewritten to
# follow. `s6-svscanctl -a` is the request to rescan the scandir: harmless,
# idempotent, and it travels down $SCANDIR/.s6-svscan/control, a FIFO opened
# non-blocking. If nothing is reading that FIFO the open fails with ENXIO and
# s6-svscanctl exits 100 saying "supervisor not listening" -- measured on the
# replica, both ways round. A dead scanner leaves the FIFO on disk, so this is
# a distinction `ps | grep` genuinely cannot make, and it is the same class of
# lie as the stale pidfile and the stale klippy socket that this file already
# has two comments about.
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

# Up and down, each WAITING for the thing it asked for -- which is the entire
# reason for preferring a supervisor to start-stop-daemon. -wu/-wD mean "do
# not return until the service is really up / really down", and -T is a bound
# in MILLISECONDS so that a service which never comes down cannot hold a boot
# or an ssh session open for ever. The default is 15 seconds, the same bound
# and the same reasoning as svc_stop_daemon: long enough for moonraker to
# finish writing its database, short enough not to hang a boot.
#
# This pair is what deletes the busybox correction at the top of this file.
# start-stop-daemon -K returns before the process is dead, which is how
# `restart` came to race its own start; s6-svc -wD returns when it is dead,
# and it is C rather than a `while ... sleep 1` we maintain.
svc_s6_up() {
    svc_s6_svc "$1" -wu -T "$(( ${2:-15} * 1000 ))" -u
}

svc_s6_down() {
    svc_s6_svc "$1" -wD -T "$(( ${2:-15} * 1000 ))" -d
}

# One line about a service, on stdout, for a status() to print. s6-svstat's
# own output is already the right shape -- "up (pid 1234) 71 seconds" or
# "down 5 seconds, normally up" -- so it is passed through rather than
# paraphrased, exactly as S50wifi passes ifconfig through: it is the answer
# you came for, in the shape you would have typed the command to get.
# 2>&1 because "unable to open supervise/status" is also an answer.
svc_s6_stat() {
    "$SVC_S6_BIN/s6-svstat" "$SVC_S6_SCANDIR/$1" 2>&1
}

# READINESS -- the reason this is s6 and not runit, and the one thing here
# that no amount of shell could have provided. A service that writes to its
# notification-fd is telling the supervisor it is USABLE, not merely forked,
# and s6-svwait -U blocks until it does. runit's `sv start` returns when the
# process has been forked, which says nothing at all.
#
# It is unused today and that is expected: it is the seam phase 4 is aimed at.
# S65camera currently polls /dev/video0 for up to 30 seconds and S70klipper
# retries an MCU handshake for up to 90, both inside their own scripts, and
# both of those become "declare ready when the device is there" plus a caller
# that waits here. Timeout in seconds, converted to the milliseconds s6 wants;
# non-zero if it ran out, so a caller can carry on degraded rather than block.
svc_s6_ready() {
    "$SVC_S6_BIN/s6-svwait" -U -t "$(( ${2:-30} * 1000 ))" "$SVC_S6_SCANDIR/$1"
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
