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
# THE LIST WAS THE UNION UNTIL IT WAS MEASURED, AND IS NOW THE FOUR THAT ARE
# ACTUALLY MAPPED. What stood here said that the subset a script needs today
# is a property of the component set in moonraker.conf -- which the user edits
# -- so handing every caller all ten was the defence against a config change
# reaching for one of the others. That defence guards nothing on this
# firmware. Six of the ten have no Python consumer at all: /proc/PID/maps of
# the processes the mod really runs maps four of them and none of the other
# six, and a DT_NEEDED walk over every ELF in
# /usr/prog/{PROGRAM,bin,nginx,mjpg-streamer,klipper,module,modules,wifi},
# /usr/bin, /usr/sbin, /bin and /sbin found exactly ONE consumer of ffmpeg,
# x264, opencv, nim and libzip between them: FlashForge's Qt binary
# /usr/prog/PROGRAM/software/firmwareExe, WHICH THIS MOD REPLACES WITH A SHELL
# SCRIPT. curl is the interesting one, because it did have a Python consumer:
# pycurl, in site-packages -- which does not import on this firmware at all.
# "undefined symbol: curl_global_sslset", a symbol that arrived in curl 7.56
# while /usr/prog ships 7.55.1, and the shipped pycurl links libssl.so.1.1
# where this curl links 1.0.0. No moonraker.conf edit can reach a library
# through a module that cannot be imported in the first place. nginx runs with
# LD_LIBRARY_PATH="" and mjpg_streamer maps only its own plugin directory and
# glibc, so neither wanted any of the ten either.
#
# WHAT WOULD HAVE TO BE TRUE TO PUT ONE BACK: some process the mod runs maps
# it. That is a measurement, not an argument -- start the process and read
# /proc/PID/maps. test/integration/printer/case-libpath.sh is where that
# measurement lives, in both directions: each of the four below is taken away
# one at a time and made to fail, and a python running with only these four is
# shown to map none of the six that went. A new entry arrives with the process
# that needs it and a check in that gate; an entry nothing can be shown to map
# is how this list got to ten in the first place.
#
# Sourcing twice is safe: each directory is added only if it is not already
# there, so firmwareExe sourcing this and then running init.d/S62moonraker --
# which sources it again with the first copy already inherited -- does not grow
# the variable on every boot.

# The /usr/prog library packages, in app_startup.sh's own order. Each is here
# for a failure that has been watched happen:
#
#   Python-3.8.2    libpython3.8.so.1.0. Without it no python starts at all:
#                   "libpython3.8.so.1.0: cannot open shared object file".
#   openssl-1.0.2d  NOT for `import ssl`. _ssl and zlib are BUILTIN on this
#                   interpreter, statically linked into libpython, so
#                   libpython3.8.so.1.0 ITSELF carries DT_NEEDED on
#                   libssl.so.1.0.0 and libcrypto.so.1.0.0 -- take this away
#                   and the interpreter does not start, before it has read a
#                   line of anyone's python. The rootfs has 1.1 only, which is
#                   a different soname and cannot stand in.
#   libffi-3.4.4    _ctypes wants libffi.so.8 and the rootfs has libffi.so.7
#                   only. `import ctypes` is the visible failure; the cost in
#                   moonraker is four components -- file_manager,
#                   authorization, machine, proc_stats.
#
# NOT /usr/prog/mjpg-streamer: that one is a plugin directory rather than a
# library package, it carries its own libjpeg.so.9, and putting it in front of
# every python process invites a version conflict for the sake of one service.
# init.d/S65camera prepends it for itself.
#
# libsodium is NOT here any more. It existed only for 3.8's libnacl, in
# FlashForge's site-packages, which asks the loader for libsodium.so.18 --
# the rootfs has none, hence the entry. FF_PYTHON below no longer runs
# anything that imports libnacl: Moonraker is the only FF_PYTHON process that
# does, and it moved to our 3.13, whose libnacl resolves $MODDIR/lib/libsodium.so
# by absolute path (bin/patch.sh section 5d) with no library path entry at
# all. klippy still runs on 3.8 -- see FF_PYTHON below for why that is a
# different interpreter entirely -- but klippy has no libnacl import.
ANVIL_LIBS="/usr/prog/Python-3.8.2/lib
/usr/prog/openssl-1.0.2d/lib
/usr/prog/libffi-3.4.4/lib"

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
#
# THE SWITCH. This used to be FlashForge's 3.8.2, on purpose, until three
# things were true at once: the payload carries a complete CPython 3.13 of our
# own ($MODDIR/bin/python3.13, cross-built by bin/patch.sh section 5c) with a
# working sqlite3 3.8.2 has not got; every third-party C extension FF_PYTHON's
# callers need -- tornado, lmdb, cffi, greenlet, libnacl -- is cross-built
# beside it in $MODDIR/lib/python3.13/site-packages; and Moonraker has been
# measured SERVING on that interpreter THROUGH THE REAL BOOT PATH on the
# replica (test/integration/printer/case-moonraker313-s6.sh): S40s6's scandir,
# S62moonraker, s6-svwait -U gating on :7125 actually listening rather than on
# the process forking, a kill -9 respawning onto 3.13 again, stop staying
# stopped, and a churn loop when site-packages is moved away -- not just an
# interpreter that imports cleanly.
#
# WHO ELSE THIS MOVES. grep FF_PYTHON payload/ bin/ before touching this line
# again -- the answer changes as callers are added. Today it is Moonraker,
# ff-startup.py, ffscreen.py and ff_mcu_bringup.py (the MCU bootloader
# handshake start.sh runs before Klipper). The last three are stdlib-only
# (os/sys/termios/time/argparse/json/subprocess/urllib -- checked against
# CPython's own removed-in-3.13 list), so the only one with any C-extension
# surface is Moonraker, and that is the one measured above.
#
# WHO THIS DOES NOT MOVE. Klipper is not on this list. It is started by
# FlashForge's own /usr/prog/klipper/start.sh, hardcoded to
# /usr/prog/Python-3.8.2/bin/python3, independently of FF_PYTHON -- see
# init.d/S70klipper's own header. klippy's numpy gap
# (extras/stepper_resonance_tester.py) is therefore not this switch's problem;
# it stays open as a separate, smaller item.
#
# FlashForge's tree is not touched either way: nothing here writes to
# /usr/prog, and everything of ours lives under /usr/data/anvil like every
# other thing this mod installs.
#
# Note what is NOT on PATH below: $MODDIR/bin is prepended (s6 needs it), and
# the interpreter is in there, but it is called python3.13 and only that.
# bin/patch.sh deliberately drops the `python3` symlink CPython installs, so
# that adding our bin/ to PATH cannot quietly change what `python3` means for
# every process that sources this file.
FF_PYTHON=$MODDIR/bin/python3.13
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
