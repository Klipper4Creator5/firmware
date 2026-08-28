#!/usr/bin/env bash
# opkg -- the package manager itself, cross-compiled for the printer.
#
# The second recipe, and the one that says whether pkg/lib.sh is a shared build
# library or just libsodium's build with the comments moved. It shares nothing
# with libsodium except that file: different toolchain, different libc,
# different link mode, and a dependency chain of its own three builds deep.
# What is written below is only what is true about opkg.
#
# STATIC, AGAINST musl, EXACTLY LIKE s6 AND FOR THE SAME REASON. versions.env
# makes the argument for s6 and every word of it applies here: this is a
# standalone binary that has to match nothing -- it does not get dlopened by
# FlashForge's python the way libsodium does, and it links against nothing of
# ours. Static musl means no LD_LIBRARY_PATH entry, no libarchive.so or
# libz.so shipped beside it to be found or not found, and nothing on the
# printer's own library path to collide with. Static GLIBC was measured at
# 73MB for the s6 tree; musl came to 3.6MB.
#
# THE PREFIX IS PART OF THE ABI HERE, one more time, and it is the single
# thing most likely to be got wrong by whoever bumps this next. opkg BAKES ITS
# STATE DIRECTORY IN AT COMPILE TIME: an opkg configured --prefix=/usr/local
# looks for its status file in /usr/local/var/lib/opkg no matter what
# --offline-root it is handed at runtime. Measured from both sides: an
# x86-64 opkg built --prefix=/usr/local looked there, and THIS binary, run
# under qemu-mipsel, put its status file at /usr/data/anvil/var/lib/opkg --
# which is only where pkg/ipk-install writes because the two agree, not by
# coincidence. Configured anywhere but $MODDIR it comes up
# believing nothing is installed and reinstalls the world. This is the same
# trap s6's baked-in libexecdir sets (versions.env) and the same trap
# execline's shebangdir sets, which is three for three: on this printer, the
# --prefix is not a preference.
#
# THE DEPENDENCIES ARE BUILD-ONLY AND NEITHER IS SHIPPED. libarchive is what
# opkg reads .ipk files with -- its ./configure hard-fails without it, measured
# -- and zlib is what libarchive needs to read the gzip streams an .ipk is made
# of. Both go into the recipe's private sysroot and end up INSIDE the static
# binary. The zlib pin is the one bin/patch.sh already uses for CPython: one
# pinned tarball, two consumers, and no second version of zlib in the tree.
#
# WHAT SHIPS IS ONE FILE: $MODDIR/bin/opkg. Not lib/libopkg.a (a static archive
# nothing on a printer links against), not include/, not the pkgconfig .pc.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

# $OPKG_STAMP covers all three versions and is defined in bin/common.sh, not
# here: bin/fetch-assets.sh tests the same string to decide whether the musl
# toolchain has to be downloaded, and a stamp the two spell differently means
# the fetcher skips the compiler on exactly the build that needs it.
pkg_begin opkg "$OPKG_STAMP" "$OPKG_BUILD" || exit 0
pkg_toolchain musl
pkg_unpack "$ZLIB_TGZ"
pkg_unpack "$LIBARCHIVE_TGZ"
pkg_unpack "$OPKG_TGZ"

# ---- zlib. Not autoconf: its ./configure is a hand-written script that has
# never taken --host and errors on it. CHOST is the knob it does read, and it
# is the same line bin/patch.sh section 5c uses for the CPython copy.
( cd "$PKG_WORK/src/zlib-$ZLIB_VERSION"
  CHOST=$PKG_HOST ./configure --prefix="$PKG_SYSROOT" --static \
      > "$PKG_LOG/zlib-configure.log" 2>&1
  make -j"$(nproc 2>/dev/null || echo 4)" > "$PKG_LOG/zlib-make.log" 2>&1
  make install >> "$PKG_LOG/zlib-make.log" 2>&1 ) \
    || pkg_die "opkg: the zlib cross-build failed -- see $PKG_WORK/zlib-*.log"
pkg_dep_paths
pkg_say "opkg: built zlib-$ZLIB_VERSION"

# ---- libarchive, cut down to the one thing opkg asks of it: read a gzipped
# tar. Every --without below is a codec or a dependency we would otherwise
# have to cross-build as well, and each one that stayed in would be linked
# into a binary that lives on a 128MB data partition. The bsd* front-end
# programs are disabled for the same reason -- opkg wants the library.
#
# --disable-acl / --disable-xattr: this is a package manager for a tree on a
# vfat-adjacent embedded rootfs, and neither is preserved by anything else in
# this payload's install path.
pkg_dep_autotools "libarchive-$LIBARCHIVE_VERSION" \
    --enable-static --disable-shared \
    --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
    --without-bz2lib --without-libb2 --without-iconv --without-lz4 \
    --without-zstd --without-lzma --without-lzo2 --without-cng \
    --without-openssl --without-xml2 --without-expat \
    --disable-acl --disable-xattr

# ---- opkg itself.
#
# --disable-curl and --disable-ssl-curl: opkg's downloader is for fetching from
#   a feed over the network, which is phase 3 of docs/notes/85-packaging.md and
#   not this. Leaving them on would drag libcurl and OpenSSL into a static
#   binary for a capability nothing uses yet. When phase 3 arrives this is the
#   line that changes, and it changes here rather than in nine places.
# --disable-gpg: same argument. Feed signing is usign or gpg and is phase 3.
# --disable-shared: libopkg would otherwise be a .so that the opkg binary
#   needs at runtime, which is precisely the LD_LIBRARY_PATH entry static
#   linking exists to avoid. It settles what libtool BUILDS, though, not how
#   the program is LINKED -- see PKG_MAKE_ARGS below, which is the half that
#   actually produces a static binary.
# PKG_CONFIG="pkg-config --static" is not decoration either: libarchive.pc
#   lists -lz under Libs.private, and without --static pkg-config does not
#   report private libs -- so the link fails on undefined zlib symbols with
#   nothing in the error to say that a .pc file was read the wrong way.
export PKG_CONFIG="pkg-config --static"

# -all-static and not -static: libtool swallows the latter. pkg/lib.sh explains
# why this has to reach make rather than configure, and why it has to repeat
# the -L that configure would otherwise have contributed.
PKG_MAKE_ARGS=(LDFLAGS="-all-static -L$PKG_SYSROOT/lib")

pkg_autotools "opkg-$OPKG_VERSION" "$MODDIR" "$PWD/$PKG_WORK/stage" \
    --disable-curl --disable-ssl-curl --disable-gpg \
    --disable-shared --enable-static \
    --disable-dependency-tracking

pkg_ship "bin/opkg"

# It has to BE static, not merely have been asked to be. A dynamically linked
# opkg would run perfectly here under qemu and fail on the printer at the first
# missing .so -- and the message would name a library, not a link flag.
if readelf -d "$OPKG_BUILD/bin/opkg" 2>/dev/null | grep -q NEEDED; then
    readelf -d "$OPKG_BUILD/bin/opkg" | grep NEEDED >&2
    pkg_die "bin/opkg came out dynamically linked -- see the NEEDED entries above"
fi

pkg_end
