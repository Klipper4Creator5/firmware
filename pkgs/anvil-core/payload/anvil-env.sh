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
# with no library path entry at all. klippy is on that same 3.13 and has no
# libnacl import.
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
# KLIPPY, ff-startup.py, ffscreen.py and ff_mcu_bringup.py (the MCU bootloader
# handshake that runs before Klipper). Three of those five are stdlib-only
# (os/sys/termios/time/argparse/json/subprocess/urllib -- checked against
# CPython's own removed-in-3.13 list); the two with C-extension surface are
# Moonraker, measured above, and klippy.
#
# KLIPPY IS ON THIS LIST NOW. This block used to say it was not -- that
# FlashForge's own start.sh started it, hardcoded to
# /usr/prog/Python-3.8.2/bin/python3. Both halves are gone:
# etc/s6-rc/source/klipper/run execs $FF_PYTHON against $MODDIR/klipper/klippy,
# and prog/start.sh is a `s6-rc -u change klipper` and nothing else. klippy
# reaches c_helper.so through _cffi_backend, which is the reason this
# interpreter had to be a glibc build; anvil-klipper declares cffi, greenlet,
# pyserial and jinja2 against it.
#
# klippy's numpy gap (extras/stepper_resonance_tester.py) IS this switch's
# problem now, and stays open as a separate, smaller item: the module guards
# its own import, so the printer runs without it and loses resonance testing.
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

# And the mod's own bin.
#
# NOT FOR s6's SAKE, which is what this comment used to say. It claimed
# s6-svscan execs s6-supervise by name off PATH and that s6-svc -w does the
# same for s6-svlisten, so a printer without $MODDIR/bin on PATH would
# supervise nothing. Measured in the replica against the binaries we ship, and
# it is false -- every s6-to-s6 exec goes through a path compiled in at
# --prefix time, and there are no bare names in any of them:
#
#     s6-svscan              -> /usr/data/anvil/bin/s6-supervise
#     s6-svc                 -> /usr/data/anvil/bin/{s6-svlisten,s6-svwait,s6-svc}
#     s6-svwait, s6-svlisten1-> /usr/data/anvil/libexec/s6-ftrigrd
#
# A scanner started with PATH=/bin:/sbin:/usr/bin:/usr/sbin spawns its
# supervisor and says nothing, because there is nothing to say. So does a copy
# of the scanner alone in an empty directory: the path is in the binary, not in
# the environment and not relative to argv[0].
#
# anvil-service.sh calls every s6 program as "$SVC_S6_BIN/<name>", so our own
# scripts do not need it either. What is left is people: an ssh session that
# wants s6-svstat without typing the prefix. Prepended, not appended, so a
# printer that ever grows a second s6 gets the one we shipped.
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
