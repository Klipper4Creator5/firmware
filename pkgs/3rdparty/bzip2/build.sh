#!/usr/bin/env bash
# bzip2 -- one library, driven straight at its Makefile.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin bzip2 || exit 0
pkg_toolchain
pkg_unpack "$BZIP2_TGZ"

# No configure at all, and no install target worth using: bzip2's own
# `install` places binaries and man pages in a prefix and does not honour
# DESTDIR. So the configure step is skipped, one target is built, and the two
# files it produces are placed below -- which files a project installs is
# recipe knowledge, not something a shared verb should guess at.
#
# -Wall -Winline are bzip2's own Makefile defaults, kept so this is the build
# upstream tests. -fPIC because it is linked into an extension module.
PKG_CONFIGURE=none
PKG_MAKE_TARGET=libbz2.a
PKG_INSTALL_TARGET=none
pkg_build "bzip2-$BZIP2_VERSION" \
    CC="$PKG_HOST-gcc" AR="$PKG_HOST-ar" RANLIB="$PKG_HOST-ranlib" \
    CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64 -Wall -Winline"

_stage="$PWD/$PKG_WORK/stage"
_src="$PKG_WORK/src/bzip2-$BZIP2_VERSION"
mkdir -p "$_stage$MODDIR/lib" "$_stage$MODDIR/include"
install -m644 "$_src/libbz2.a" "$_stage$MODDIR/lib/"
install -m644 "$_src/bzlib.h"  "$_stage$MODDIR/include/"

pkg_ship "lib/libbz2.a" "include/bzlib.h"
pkg_end
