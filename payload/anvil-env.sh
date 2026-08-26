# The environment every mod process needs. Sourced, never executed.
#
#     MODDIR=/usr/data/anvil
#     . $MODDIR/anvil-env.sh
#
# WHY THIS FILE EXISTS. FlashForge builds each native dependency into its own
# /usr/prog/<package>/ directory and puts none of them on the default loader
# path. app_startup.sh exports the whole set before it launches anything, so
# on a normal boot every child inherits them and nothing here looks necessary.
# That inheritance is the trap: it holds for the boot path and NOWHERE else.
# Re-run any of our scripts over ssh and the environment is bare, the
# interpreter dies on "libpython3.8.so.1.0: cannot open shared object file",
# and the service looks like it simply never started.
#
# Every script that starts a process used to carry its own copy of the list.
# They drifted, which is exactly the bug this file removes: run-append.sh's
# install-time pre-flight named ten directories while S60web started moonraker
# with four, so a build could pass the check that decides whether to install it
# and then fail to run. One list, one place, every caller.
#
# THE LIST IS THE UNION, DELIBERATELY. It is tempting to give each script the
# subset it needs today, but "what moonraker links against" is a property of
# the component set in moonraker.conf, which the user edits. A caller that
# gets the full environment cannot be broken by a config change.
#
# Sourcing twice is safe: each directory is added only if it is not already
# there, so firmwareExe sourcing this and then running init.d/S62moonraker --
# which sources it again with the first copy already inherited -- does not grow
# the variable on every boot.

# The /usr/prog library packages, in app_startup.sh's own order.
#
# NOT /usr/prog/mjpg-streamer: that one is a plugin directory rather than a
# library package, it carries its own libjpeg.so.9, and putting it in front of
# every python process invites a version conflict for the sake of one service.
# init.d/S65camera prepends it for itself.
ANVIL_LIBS="/usr/prog/Python-3.8.2/lib
/usr/prog/openssl-1.0.2d/lib
/usr/prog/curl-7.55.1/lib
/usr/prog/ffmpeg-402/lib
/usr/prog/x264/lib
/usr/prog/libffi-3.4.4/lib
/usr/prog/libsodium/lib
/usr/prog/opencv-4.2/lib
/usr/prog/nim/lib
/usr/prog/libzip-1.10.1/lib"

for _anvil_lib in $ANVIL_LIBS; do
    [ -d "$_anvil_lib" ] || continue
    case ":$LD_LIBRARY_PATH:" in
        *":$_anvil_lib:"*) ;;
        *) LD_LIBRARY_PATH="$_anvil_lib:$LD_LIBRARY_PATH" ;;
    esac
done
unset _anvil_lib
export LD_LIBRARY_PATH

# The interpreter. Named absolutely and exported, because every caller wants
# the same one and one of them (start.sh, for the MCU bring-up) cannot start
# Klipper without it.
#
# There is NO `|| FF_PYTHON=python3` here any more. That fallback read as
# safety and was not: the base rootfs ships no other python3, so it either
# resolved to this same binary -- in which case it did nothing -- or it
# resolved to something we have never tested and the failure moved somewhere
# harder to read. A missing interpreter is a broken printer and should say so
# at the point it is missing.
FF_PYTHON=/usr/prog/Python-3.8.2/bin/python3
export FF_PYTHON

case ":$PATH:" in
    *":/usr/prog/Python-3.8.2/bin:"*) ;;
    *) PATH="$PATH:/usr/prog/Python-3.8.2/bin" ;;
esac

# And the mod's own bin, which s6 needs on PATH and not merely installed.
#
# s6 bakes its --prefix in at compile time, so it was reasonable to assume the
# binaries could find each other wherever they were. They cannot, and the two
# rules are different: s6-ftrigrd is found through the compiled-in libexecdir,
# but s6-svscan execs S6-SUPERVISE BY NAME OFF PATH, and s6-svc -w execs
# s6-svlisten the same way. With $MODDIR/bin absent from PATH the scanner
# starts, stays up, answers its control socket -- and supervises nothing,
# saying so once, in its own log, where nobody is looking:
#
#     s6-svscan: warning: unable to spawn s6-supervise for camera:
#                No such file or directory
#     s6-svc: fatal: unable to exec s6-svlisten: No such file or directory
#
# It is here rather than in one init script because both halves need it and
# they inherit it from different places: S40s6 sources this file before
# starting the SCANNER, which is the process that has to find s6-supervise,
# and every service script sources it before running s6-svc, which is the
# process that has to find s6-svlisten. Prepended, not appended: these are
# ours and nothing on the base rootfs answers to those names, but a printer
# that ever grows a second s6 should get the one we shipped.
#
# Note this could not have been caught one phase earlier. The scanner ran with
# an EMPTY scandir, so it never spawned a supervisor, so it never needed the
# thing it could not find.
case ":$PATH:" in
    *":/usr/data/anvil/bin:"*) ;;
    *) PATH="/usr/data/anvil/bin:$PATH" ;;
esac
export PATH

# Callers that are about to run the interpreter use this to fail with a
# sentence instead of a loader error.
anvil_python_ok() {
    [ -x "$FF_PYTHON" ]
}
