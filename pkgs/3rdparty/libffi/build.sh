#!/usr/bin/env bash
# libffi -- cross-compiled for the printer, as a build dependency of CPython.
#
# libffi is how ctypes calls a C function it was told about at runtime. CPython's _ctypes module does not build without it, and libnacl reaches libsodium through ctypes -- so this is on the path of Moonraker's JWT signing, three layers down.
#
# NOTHING INSTALLS THIS ON A PRINTER. It is a static library: it ends up inside
# the interpreter, and there is no .so to ship or to find. The package exists
# so that CPython builds against something with a version and a checksum
# instead of against a directory somebody filled in earlier.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin libffi || exit 0
pkg_toolchain
pkg_unpack "$LIBFFI_TGZ"

# -fPIC because these are linked into extension modules, which are shared
# objects; -D_FILE_OFFSET_BITS=64 for the reason every cross-build in this tree
# carries it (32-bit build, 64-bit inodes -- see versions.env).
pkg_build "libffi-$LIBFFI_VERSION" \
    --build="$(uname -m)-linux-gnu" \
    --disable-shared --enable-static --with-pic \
    --disable-docs \
    CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"

pkg_ship "include/ffi.h" "include/ffitarget.h" "lib/libffi.a" "lib/pkgconfig/libffi.pc"
pkg_end
