# The environment every mod process needs. Sourced, never executed.
#
#     MODDIR=/usr/data/anvil
#     . $MODDIR/anvil-env.sh
#
# FlashForge builds each native dependency into its own /usr/prog/<package>/
# and puts none of them on the default loader path; app_startup.sh exports the
# whole set before it launches anything, so on a normal boot every child
# inherits them. That inheritance is the trap -- it holds for the boot path
# and NOWHERE else. Re-run any of our scripts over ssh and the environment is
# bare, the interpreter dies on "libpython3.8.so.1.0: cannot open shared
# object file", and the service looks like it never started.
#
# THE LIST IS WHAT IS ACTUALLY MAPPED, not the union of what FlashForge
# exports. To add one: some process the mod runs must map it -- a measurement
# (read /proc/PID/maps), not an argument.
#
# Sourcing twice is safe: each directory is added only if not already there.

# The /usr/prog library packages, in app_startup.sh's own order. Each is here
# for a failure that has been watched happen:
#
#   Python-3.8.2    libpython3.8.so.1.0; without it no python starts at all.
#   openssl-1.0.2d  NOT for `import ssl`. _ssl and zlib are BUILTIN on this
#                   interpreter, so libpython3.8.so.1.0 ITSELF carries
#                   DT_NEEDED on libssl/libcrypto 1.0.0 -- take this away and
#                   the interpreter does not start. The rootfs has 1.1 only,
#                   a different soname that cannot stand in.
#   libffi-3.4.4    _ctypes wants libffi.so.8 and the rootfs has .so.7 only.
#                   The cost in moonraker is four components.
#
# NOT /usr/prog/mjpg-streamer: a plugin directory carrying its own
# libjpeg.so.9, and putting it in front of every python process invites a
# version conflict for one service. init.d/S65camera prepends it for itself.
#
# NOT libsodium: the only importer of libnacl is Moonraker, on our 3.13, whose
# libnacl resolves $MODDIR/lib/libsodium.so by absolute path.
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

# The interpreter, named absolutely and exported. There is deliberately NO
# `|| FF_PYTHON=python3` fallback: the base rootfs ships no other python3, so
# it would resolve to this same binary or to something never tested. A missing
# interpreter is a broken printer and should say so where it is missing.
#
# IT IS OUR OWN 3.13 ($MODDIR/bin/python3.13, from pkg/python), not
# FlashForge's 3.8.2: it has the sqlite3 3.8.2 lacks, and every third-party C
# extension its callers need -- tornado, lmdb, cffi, greenlet, libnacl -- is
# built beside it in $MODDIR/lib/python3.13/site-packages.
#
# WHO ELSE THIS MOVES: grep FF_PYTHON payload/ bin/ before touching this line
# again. Today it is Moonraker, klippy, ff-startup.py, ffscreen.py and
# ff_mcu_bringup.py. Three of the five are stdlib-only; the two with
# C-extension surface are Moonraker, measured serving on the replica, and
# klippy -- which reaches c_helper.so through _cffi_backend, the reason this
# interpreter had to be a glibc build.
#
# klippy's numpy gap (extras/stepper_resonance_tester.py) is this switch's
# problem and it is NOT a smaller item. This comment used to say the module
# guards its own import, so the printer runs without it and loses resonance
# testing. Both halves are wrong: line 1 of that file is a bare
# `import numpy as np`, and klippy.py:122 loads EVERY config section through a
# load_object that does not catch ImportError. printer.base.cfg includes
# FlashForge's printer.vibration.cfg, which declares
# [stepper_resonance_tester] -- so on this interpreter klippy does not come up
# at all, rather than coming up without one feature.
#
# See docs/notes/44-vfa-calibration.md for the chain and the options. Nothing
# here is fixed by editing this line; it takes either a packaged numpy or a
# guarded import in the fork.
#
# Note what is NOT on PATH below: $MODDIR/bin is prepended and the interpreter
# is in there, but it is called python3.13 and only that. bin/payload.sh
# deliberately drops the `python3` symlink CPython installs, so adding our
# bin/ to PATH cannot quietly change what `python3` means.
FF_PYTHON=$MODDIR/bin/python3.13
export FF_PYTHON

case ":$PATH:" in
    *":/usr/prog/Python-3.8.2/bin:"*) ;;
    *) PATH="$PATH:/usr/prog/Python-3.8.2/bin" ;;
esac

# And the mod's own bin.
#
# NOT FOR s6's SAKE, which is what this comment used to say. Measured in the
# replica: every s6-to-s6 exec goes through a path compiled in at --prefix
# time, with no bare names in any of them, so a scanner started with a bare
# PATH still spawns its supervisor. anvil-service.sh calls every s6 program as
# "$SVC_S6_BIN/<name>", so our own scripts do not need it either.
#
# What is left is people: an ssh session that wants s6-svstat without typing
# the prefix. Prepended, not appended, so a printer that ever grows a second
# s6 gets the one we shipped.
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
