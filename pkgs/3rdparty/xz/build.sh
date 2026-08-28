#!/usr/bin/env bash
# xz -- cross-compiled for the printer, as a build dependency of CPython.
#
# liblzma is CPython's _lzma module. Every --disable- flag here turns off a command-line program: we want the library the interpreter links, never the xz binaries, which nothing on the printer would call.
#
# NOTHING INSTALLS THIS ON A PRINTER. It is a static library: it ends up inside
# the interpreter, and there is no .so to ship or to find. The package exists
# so that CPython builds against something with a version and a checksum
# instead of against a directory somebody filled in earlier.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin xz || exit 0
pkg_toolchain
pkg_unpack "$XZ_TGZ"

# -fPIC because these are linked into extension modules, which are shared
# objects; -D_FILE_OFFSET_BITS=64 for the reason every cross-build in this tree
# carries it (32-bit build, 64-bit inodes -- see versions.env).
pkg_build "xz-$XZ_VERSION" \
    --build="$(uname -m)-linux-gnu" \
    --disable-shared --enable-static --with-pic \
    --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc --disable-nls \
    CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"

pkg_ship "include/lzma.h" "include/lzma" "lib/liblzma.a" "lib/pkgconfig/liblzma.pc"
pkg_end
