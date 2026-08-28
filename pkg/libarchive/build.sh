#!/usr/bin/env bash
# libarchive -- what opkg reads .ipk files with.
#
# NOT OPTIONAL FOR opkg: its ./configure hard-fails at the pkg-config check for
# libarchive, and opkg 0.3.0 dropped the internal tar fallback.
#
# CUT DOWN TO ALMOST NOTHING. An .ipk is an ar archive of two gzipped tarballs,
# so gzip and tar is the entire requirement. Every --without below names a
# codec or a dependency that would otherwise have to be cross-built as well and
# then linked into a binary that lives on a 128MB data partition. The bsd*
# front-end programs go for the same reason: opkg wants the library.
#
# --disable-acl / --disable-xattr: this is a package manager for a tree on an
# embedded rootfs, and neither is preserved by anything else in this payload's
# install path.
#
# A NOTE FOR WHOEVER BUMPS THIS. libarchive renames its configure options
# occasionally, and an option it no longer recognises is a WARNING rather than
# an error -- so a bump can quietly switch a codec back on and grow the binary
# with nothing failing. Read the configure log for "unrecognized options" after
# changing the pin; the exit code will not tell you.
#
# WHAT SHIPS IS DEV FILES ONLY, like anvil-zlib: the headers, the static
# archive and the .pc file. No libarchive.so reaches the printer -- it is
# linked into opkg and that is the only consumer.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin libarchive || exit 0
pkg_toolchain
pkg_deps
pkg_unpack "$LIBARCHIVE_TGZ"

pkg_build "libarchive-$LIBARCHIVE_VERSION" \
    --enable-static --disable-shared \
    --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
    --without-bz2lib --without-libb2 --without-iconv --without-lz4 \
    --without-zstd --without-lzma --without-lzo2 --without-cng \
    --without-openssl --without-xml2 --without-expat \
    --disable-acl --disable-xattr \
    CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"

pkg_ship "include/archive.h" "include/archive_entry.h" \
         "lib/libarchive.a" "lib/pkgconfig/libarchive.pc"

pkg_end
