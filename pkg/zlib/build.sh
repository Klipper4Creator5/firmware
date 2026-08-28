#!/usr/bin/env bash
# zlib -- the compression library, built once for everybody.
#
# THIS IS THE RECIPE THAT MADE THE CASE FOR ALL OF THEM. zlib was cross-built
# TWICE in this tree: once inside bin/patch.sh section 5c, into a private
# sysroot for CPython's zlib module and OpenSSL's compression, and once inside
# pkg/opkg/build.sh, into a different private sysroot for libarchive. Same
# pinned tarball, same flags, two builds, and neither one could see the other
# because each was an implementation detail of the thing that needed it. Now it
# is a package, and both consumers name it as a dependency.
#
# NOT AUTOTOOLS, WHICH IS WHY THIS RECIPE HAS A ./configure LINE OF ITS OWN.
# zlib's configure is a hand-written script that has never accepted --host and
# errors on it; CHOST is the knob it does read. That makes this the one
# sanctioned exception to the rule that recipes do not run configure
# themselves, and qa/static/test_ipk.py enforces the exception by name -- a
# ./configure line in a recipe is a failure unless it carries CHOST=. If a
# SECOND exception ever shows up, that is the signal that pkg/lib.sh needs
# another verb, not that the test needs another name.
#
# THE FLAGS ARE NOT DECORATION. -fPIC because CPython links this into shared
# extension modules, and a non-PIC .a cannot go into a .so on MIPS.
# -D_FILE_OFFSET_BITS=64 because it changes zlib's off_t, and therefore the
# signature of gzopen, in the public headers: a zlib built without it and a
# consumer built with it disagree about the size of an argument and fail in a
# way that compiles cleanly. Section 5c already sets both for every one of
# CPython's dependencies, so these are the flags that make one build usable by
# both consumers rather than two builds that merely look alike.
#
# WHAT SHIPS IS DEV FILES ONLY: headers, the static archive and the .pc. There
# is no libz.so here on purpose -- both consumers link it in statically, which
# is what keeps the payload from having a library on the printer's search path
# that could be found instead of, or by, one of FlashForge's own.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin zlib || exit 0
pkg_toolchain
pkg_unpack "$ZLIB_TGZ"

_stage="$PWD/$PKG_WORK/stage"
(
    set -e
    cd "$PKG_WORK/src/zlib-$ZLIB_VERSION"
    export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"
    CHOST=$PKG_HOST ./configure --prefix="$MODDIR" --static > "$PKG_LOG/zlib-configure.log" 2>&1
    make -j"$(nproc 2>/dev/null || echo 4)" > "$PKG_LOG/zlib-make.log" 2>&1
    make install DESTDIR="$_stage" >> "$PKG_LOG/zlib-make.log" 2>&1
) || pkg_die "zlib: the cross-build failed -- see $PKG_WORK/zlib-configure.log and $PKG_WORK/zlib-make.log"
pkg_say "zlib: built zlib-$ZLIB_VERSION"

pkg_ship "include/zlib.h" "include/zconf.h" "lib/libz.a" "lib/pkgconfig/zlib.pc"

pkg_end
