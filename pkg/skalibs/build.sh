#!/usr/bin/env bash
# skalibs -- cross-compiled for the printer, as a package.
#
# THE FOUR --with-sysdep-* ANSWERS ARE THE POINT OF THIS FILE. skalibs settles
# these by COMPILING AND RUNNING a probe, which it cannot do when the target is
# a mipsel box and the builder is x86. Left unanswered, configure stops. The
# answers are the printer's: /dev/urandom exists, posix_spawn does not return
# early, /proc/self/exe is readable, and select() accepts an infinite timeout.
#
# THEY ARE ANSWERS ABOUT THE LIBC, WHICH IS WHY THIS IS A PACKAGE: change the
# toolchain and they have to be re-settled rather than reused. As a package it
# has a stamp, the stamp contains the toolchain, and a toolchain change rebuilds
# it. A private sysroot inside the s6 recipe would have been reused, because
# nothing about it had a version, and that failure shipped once.
#
# The static/dynamic decision is not made here -- skalibs has no option for it
# (its configure warns on an unknown flag and carries on) -- it is made by the
# consumers, which link libc dynamically against the printer's own.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin skalibs || exit 0
pkg_toolchain
pkg_unpack "$SKALIBS_TGZ"

# -D_FILE_OFFSET_BITS=64 is not tuning. Without it readdir() returns EOVERFLOW
# on this box -- 32-bit build, 64-bit inodes -- and a supervisor cannot see its
# own service directory: it starts cleanly and then does nothing. Measured on
# the replica; see versions.env.
pkg_build "skalibs-$SKALIBS_VERSION" \
    --disable-shared --enable-static \
    --with-sysdep-devurandom=yes \
    --with-sysdep-posixspawnearlyreturn=no \
    --with-sysdep-procselfexe=/proc/self/exe \
    --with-sysdep-selectinfinite=yes \
    CFLAGS="-Os -D_FILE_OFFSET_BITS=64"

pkg_ship "include/skalibs" "lib/libskarnet.a" "lib/skalibs"

# The sysdeps `target` file is what every consumer compares its own --host
# against, and a mismatch stops their configure with a message about a file
# rather than about a flag. Assert it here, where the fix is one variable.
_target=$(cat "$PKG_OUT/lib/skalibs/sysdeps/target" 2>/dev/null || true)
[ "$_target" = "$PKG_HOST" ] || pkg_die \
    "skalibs: sysdeps/target says '$_target' but this build is for '$PKG_HOST' --
     execline, s6 and s6-rc all refuse to configure against a mismatched cache"

pkg_end
