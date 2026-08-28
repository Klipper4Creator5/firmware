#!/usr/bin/env bash
# expat -- cross-compiled for the printer, as a build dependency of CPython.
#
# CPython bundles its own expat, and this replaces it: configure is given --with-system-expat so pyexpat links this one. One expat in the build rather than two is the same argument zlib settled.
#
# NOTHING INSTALLS THIS ON A PRINTER. It is a static library: it ends up inside
# the interpreter, and there is no .so to ship or to find. The package exists
# so that CPython builds against something with a version and a checksum
# instead of against a directory somebody filled in earlier.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin expat || exit 0
pkg_toolchain
pkg_unpack "$EXPAT_TGZ"

# -fPIC because these are linked into extension modules, which are shared
# objects; -D_FILE_OFFSET_BITS=64 for the reason every cross-build in this tree
# carries it (32-bit build, 64-bit inodes -- see versions.env).
pkg_build "expat-$EXPAT_VERSION" \
    --build="$(uname -m)-linux-gnu" \
    --disable-shared --enable-static --with-pic \
    --without-docbook --without-examples --without-tests \
    CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"

pkg_ship "include/expat.h" "include/expat_external.h" "lib/libexpat.a" "lib/pkgconfig/expat.pc"
pkg_end
