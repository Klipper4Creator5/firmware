#!/usr/bin/env bash
# libarchive -- what opkg reads .ipk files with.
#
# NOT OPTIONAL FOR opkg: its ./configure hard-fails at the pkg-config check
# for libarchive, and opkg 0.3.0 dropped the internal tar fallback.
#
# CUT DOWN TO ALMOST NOTHING. An .ipk is an ar archive of two gzipped
# tarballs, so gzip and tar is the entire requirement; every --without below
# names a codec that would otherwise have to be cross-built and linked into a
# binary living on a 128MB data partition. --disable-acl / --disable-xattr for
# the same reason: nothing else in this install path preserves either.
#
# A NOTE FOR WHOEVER BUMPS THIS: libarchive renames its configure options
# occasionally, and an unrecognised one is a WARNING rather than an error, so
# a bump can quietly switch a codec back on. Read the configure log for
# "unrecognized options"; the exit code will not tell you.
#
# WHAT SHIPS IS DEV FILES ONLY, like anvil-zlib. No libarchive.so reaches the
# printer -- it is linked into opkg, the only consumer.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

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
