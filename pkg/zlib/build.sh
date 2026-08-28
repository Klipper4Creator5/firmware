#!/usr/bin/env bash
# zlib -- the compression library, built once for everybody.
#
# ONE BUILD, TWO CONSUMERS: CPython's zlib module and OpenSSL's compression on
# one side, libarchive and so opkg on the other. Both name it as a dependency.
#
# THE FLAGS ARE NOT DECORATION. -fPIC because CPython links this into shared
# extension modules, and a non-PIC .a cannot go into a .so on MIPS.
# -D_FILE_OFFSET_BITS=64 because it changes zlib's off_t, and therefore the
# signature of gzopen, in the public headers: a zlib built without it and a
# consumer built with it disagree about the size of an argument and fail in a
# way that compiles cleanly. Both consumers set the same two, so this is one
# build usable by both rather than two that merely look alike.
#
# WHAT SHIPS IS DEV FILES ONLY: headers, the static archive and the .pc. No
# libz.so on purpose -- both consumers link it statically, which keeps a
# library of ours off the printer's search path where it could be found instead
# of, or by, one of FlashForge's own.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin zlib || exit 0
pkg_toolchain
pkg_unpack "$ZLIB_TGZ"

# ZLIB'S CONFIGURE IS NOT AN AUTOCONF CONFIGURE: it rejects --host outright and
# takes the cross prefix from $CHOST in the environment instead. So
# PKG_CONFIGURE_AUTO=0 stops pkg_build prepending --host and --prefix, and
# everything zlib does want is passed here like any other argument.
PKG_CONFIGURE_AUTO=0
export CHOST="$PKG_HOST"
export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"
pkg_build "zlib-$ZLIB_VERSION" --prefix="$MODDIR" --static

pkg_ship "include/zlib.h" "include/zconf.h" "lib/libz.a" "lib/pkgconfig/zlib.pc"

pkg_end
