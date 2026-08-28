#!/usr/bin/env bash
# zlib -- the compression library, built once for everybody.
#
# THIS IS THE RECIPE THAT MADE THE CASE FOR ALL OF THEM. zlib was cross-built
# TWICE in this tree: once inside bin/patch.sh section 5c, into a private
# sysroot for CPython's zlib module and OpenSSL's compression, and once inside
# pkgs/3rdparty/opkg/build.sh, into a different private sysroot for libarchive. Same
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
# SECOND exception ever shows up, that is the signal that pkgs/lib.sh needs
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
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin zlib || exit 0
pkg_toolchain
pkg_unpack "$ZLIB_TGZ"

# ZLIB'S CONFIGURE IS NOT AN AUTOCONF CONFIGURE. It rejects --host outright
# and takes the cross prefix from $CHOST in the environment instead, which is
# why this recipe used to run ./configure itself -- the only one that did, with
# a carve-out in qa/static/test_ipk.py permitting it by name. That exception is
# gone: PKG_CONFIGURE_AUTO=0 says "do not prepend --host and --prefix", and
# everything zlib does want is passed here like any other argument.
PKG_CONFIGURE_AUTO=0
export CHOST="$PKG_HOST"
export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"
pkg_build "zlib-$ZLIB_VERSION" --prefix="$MODDIR" --static

pkg_ship "include/zlib.h" "include/zconf.h" "lib/libz.a" "lib/pkgconfig/zlib.pc"

pkg_end
