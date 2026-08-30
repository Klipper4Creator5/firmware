#!/usr/bin/env bash
# zlib -- the compression library, built once for everybody.
#
# ONE BUILD, TWO CONSUMERS: CPython's zlib module and OpenSSL's compression on
# one side, libarchive and so opkg on the other. It used to be cross-built
# twice, once inside each.
#
# NOT AUTOTOOLS: zlib's configure is hand-written and has never accepted
# --host, the knob pkg_build would otherwise add. CHOST is what it does read,
# so PKG_CONFIGURE_AUTO=0 turns the flag off and the recipe exports CHOST.
#
# THE FLAGS ARE NOT DECORATION. -fPIC because CPython links this into shared
# extension modules, and a non-PIC .a cannot go into a .so on MIPS.
# -D_FILE_OFFSET_BITS=64 because it changes zlib's off_t, and so the signature
# of gzopen, in the public headers: a zlib built without it and a consumer
# built with it disagree about the size of an argument and fail in a way that
# compiles cleanly. Both consumers set the same two.
#
# WHAT SHIPS IS DEV FILES ONLY: headers, the static archive and the .pc. No
# libz.so on purpose -- both consumers link it statically, which keeps a
# library of ours off the printer's search path.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin zlib || exit 0
pkg_toolchain
pkg_unpack "$ZLIB_TGZ"

# ZLIB'S CONFIGURE IS NOT AN AUTOCONF CONFIGURE: it rejects --host outright
# and takes the cross prefix from $CHOST instead. PKG_CONFIGURE_AUTO=0 stops
# pkg_build prepending --host and --prefix.
PKG_CONFIGURE_AUTO=0
export CHOST="$PKG_HOST"
export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"
pkg_build "zlib-$ZLIB_VERSION" --prefix="$MODDIR" --static

pkg_ship "include/zlib.h" "include/zconf.h" "lib/libz.a" "lib/pkgconfig/zlib.pc"

pkg_end
