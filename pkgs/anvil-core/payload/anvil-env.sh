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
# One list, one place, every caller: a per-script copy drifts, and a build can
# then pass the install-time check and still fail to run.
#
# THE LIST IS WHAT IS ACTUALLY MAPPED, not the union of what FlashForge
# exports. WHAT WOULD HAVE TO BE TRUE TO ADD ONE: some process the mod runs
# maps it -- a measurement, not an argument. Start the process and read
# /proc/PID/maps. test/integration/printer/case-libpath.sh holds that
# measurement in both directions: each entry below is taken away one at a time
# and made to fail, and a python running with only these is shown to map
# nothing else.
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
# NOT /usr/prog/mjpg-streamer: a plugin directory rather than a library
# package, carrying its own libjpeg.so.9, and putting it in front of every
# python process invites a version conflict for the sake of one service.
# init.d/S65camera prepends it for itself.
#
# NOT libsodium either: the only importer of libnacl is Moonraker, which runs
# on our 3.13, whose libnacl resolves $MODDIR/lib/libsodium.so by absolute path
# with no library path entry at all. klippy runs on 3.8 and has no libnacl
# import.
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
# There is deliberately NO `|| FF_PYTHON=python3` fallback: the base rootfs
# ships no other python3, so it would either resolve to this same binary or to
# something never tested, moving the failure somewhere harder to read. A
# missing interpreter is a broken printer and should say so where it is
# missing.
#
# IT IS OUR OWN 3.13 ($MODDIR/bin/python3.13, from pkg/python), not
# FlashForge's 3.8.2: it has the sqlite3 3.8.2 lacks, and every third-party C
# extension FF_PYTHON's callers need -- tornado, lmdb, cffi, greenlet, libnacl
# -- is built beside it in $MODDIR/lib/python3.13/site-packages. Moonraker is
# measured SERVING on it through the real boot path on the replica
# (test/integration/printer/case-moonraker313-s6.sh).
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
