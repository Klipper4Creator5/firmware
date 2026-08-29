#!/usr/bin/env bash
# opkg -- the package manager itself, cross-compiled for the printer.
#
# NOTHING WAITS FOR opkg. The package manager does not have to be built first
# to install everyone else's build dependencies: pkg_deps fills a sysroot with
# opkg-unbuild, upstream's own inverse of opkg-build. So there is no bootstrap
# stage and no qemu in the build path -- opkg is an ordinary recipe that builds
# late only because it has two dependencies.
#
# opkg IS NOT SPECIAL AND NOTHING WAITS FOR IT. The package manager does not
# have to be built first so it can install everything else's build
# dependencies: pkg_deps fills a sysroot with opkg-unbuild, upstream's own
# inverse of opkg-build. There is no bootstrap stage and no qemu in the build
# path -- opkg is an ordinary recipe that builds late because it has two
# dependencies.
#
# THE PREFIX IS PART OF THE ABI HERE, and the thing most likely to be got
# wrong by whoever bumps this next: opkg bakes its state directory in at
# compile time, so one configured --prefix=/usr/local looks for its status
# file in /usr/local/var/lib/opkg whatever --offline-root it is handed at
# runtime. Measured from both sides. Built this way it lands at
# /usr/data/anvil/var/lib/opkg, which is where the payload's own database
# goes. Same trap as s6's baked-in
# libexecdir and execline's shebangdir, and the reason $MODDIR lives in
# bin/common.sh where a recipe cannot spell it differently.
#
# THIS IS THE ONLY opkg. bin/build-payload.py assembles the payload with it,
# in the replica, so the binary that builds the payload is the binary that
# ships.
#
# DYNAMIC AGAINST THE PRINTER'S glibc, STATIC FOR EVERYTHING ELSE. zlib and
# libarchive exist in the sysroot only as .a, so they end up inside the binary
# and there is no libarchive.so or libz.so to ship or find. libc is the one
# dynamic link, and it is the libc.so.6 2.29 the interpreter already uses.
#
# WHAT SHIPS IS ONE FILE: $MODDIR/bin/opkg. Not lib/libopkg.a, not include/,
# not the pkgconfig .pc.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin opkg || exit 0
pkg_toolchain
pkg_deps
pkg_unpack "$OPKG_TGZ"

# --disable-curl and --disable-ssl-curl: opkg's downloader fetches from a feed
#   over the network, which is phase 3 of docs/notes/85-packaging.md. Leaving
#   them on drags libcurl and OpenSSL into the binary for nothing.
# --disable-gpg: same argument -- feed signing is phase 3 too.
# --disable-shared: libopkg would otherwise be a .so that the opkg binary needs
#   at runtime, which is an LD_LIBRARY_PATH entry for no reason.
# PKG_CONFIG="pkg-config --static" is not decoration: libarchive.pc lists -lz
#   under Libs.private, and without --static pkg-config does not report private
#   libraries -- so the link fails on undefined zlib symbols with nothing in
#   the error to say that a .pc file was read the wrong way.
export PKG_CONFIG="pkg-config --static"

pkg_build "opkg-$OPKG_VERSION" \
    --disable-curl --disable-ssl-curl --disable-gpg \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    CFLAGS="-O2 -D_FILE_OFFSET_BITS=64"

pkg_ship "bin/opkg"

# THE LINK HAS TO BE WHAT IT WAS ASKED TO BE. An opkg that picked up a shared
# libarchive or libz would run perfectly here and fail on the printer at the
# first missing .so, naming a library rather than a link flag.
_needed=$(readelf -d "$OPKG_BUILD/bin/opkg" 2>/dev/null \
    | awk '/NEEDED/{gsub(/[][]/,"",$5); print $5}')
case "$_needed" in
    *libarchive*|*libz*)
        printf '%s\n' "$_needed" >&2
        pkg_die "bin/opkg links a shared libarchive or libz -- they are meant to be inside it" ;;
esac
printf '%s\n' "$_needed" | grep -q '^libc\.so' \
    || pkg_die "bin/opkg has no NEEDED libc.so -- it should link the printer's glibc dynamically"
pkg_say "opkg: links $(printf '%s' "$_needed" | tr '\n' ' ')"

pkg_end
