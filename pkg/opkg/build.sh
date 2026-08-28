#!/usr/bin/env bash
# opkg -- the package manager itself, cross-compiled for the printer.
#
# THIS RECIPE USED TO BUILD THREE THINGS. It unpacked zlib, built it into a
# private sysroot, unpacked libarchive, built that against it, and then finally
# built opkg -- one script, three libraries, one shipped binary. Both of those
# libraries are now packages of their own, and the only trace left here is the
# PKG_BUILD_DEPENDS line in pkg.conf. What that bought: zlib is compiled once
# for this and for CPython instead of twice, either dependency can be bumped
# without touching this file, and the .ipk files they produce are checked --
# by this build failing -- to actually contain the headers a consumer needs.
#
# opkg IS NOT SPECIAL AND NOTHING WAITS FOR IT. It would be natural to assume
# the package manager has to be built first so that it can install everything
# else's build dependencies. It does not: pkg_deps fills a sysroot with
# opkg-unbuild, which is upstream's own inverse of opkg-build and comes out of
# the same pinned opkg-utils checkout. So there is no bootstrap stage and no
# qemu in the build path -- opkg is an ordinary recipe that happens to build
# late because it has two dependencies.
#
# THE PREFIX IS PART OF THE ABI HERE, and it is the single thing most likely to
# be got wrong by whoever bumps this next. opkg BAKES ITS STATE DIRECTORY IN AT
# COMPILE TIME: an opkg configured --prefix=/usr/local looks for its status
# file in /usr/local/var/lib/opkg no matter what --offline-root it is handed at
# runtime. Measured from both sides -- an x86-64 opkg built --prefix=/usr/local
# looked there, and a mipsel one built this way put its status file at
# /usr/data/anvil/var/lib/opkg, which is only where pkg/ipk-install writes
# because the two agree rather than by coincidence. Configured anywhere but
# $MODDIR it comes up believing nothing is installed and reinstalls the world.
# Same trap as s6's baked-in libexecdir and execline's shebangdir; three for
# three, and the reason $MODDIR lives in bin/common.sh where a recipe cannot
# spell it differently.
#
# DYNAMIC AGAINST THE PRINTER'S glibc, STATIC FOR EVERYTHING ELSE. zlib and
# libarchive exist in the sysroot only as .a, so they end up inside the binary
# and there is no libarchive.so or libz.so to ship or to find. libc is the one
# thing linked dynamically, and it is the same libc.so.6 2.29 the interpreter
# already links -- so this adds no dependency the payload did not have. An
# earlier revision linked opkg fully static against musl; that made it the only
# thing in the tree with a second libc, and a second libc means a second copy
# of every library both worlds want, which a feed cannot express without lying
# about one of them.
#
# WHAT SHIPS IS ONE FILE: $MODDIR/bin/opkg. Not lib/libopkg.a (a static archive
# nothing on a printer links against), not include/, not the pkgconfig .pc.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin opkg || exit 0
pkg_toolchain
pkg_deps
pkg_unpack "$OPKG_TGZ"

# --disable-curl and --disable-ssl-curl: opkg's downloader is for fetching from
#   a feed over the network, which is phase 3 of docs/notes/85-packaging.md and
#   not this. Leaving them on would drag libcurl and OpenSSL into the binary
#   for a capability nothing uses yet. When phase 3 arrives this is the line
#   that changes, and it changes here rather than in nine places.
# --disable-gpg: same argument. Feed signing is usign or gpg and is phase 3.
# --disable-shared: libopkg would otherwise be a .so that the opkg binary needs
#   at runtime, which is an LD_LIBRARY_PATH entry for no reason.
# PKG_CONFIG="pkg-config --static" is not decoration: libarchive.pc lists -lz
#   under Libs.private, and without --static pkg-config does not report private
#   libraries -- so the link fails on undefined zlib symbols with nothing in
#   the error to say that a .pc file was read the wrong way.
export PKG_CONFIG="pkg-config --static"

pkg_autotools "opkg-$OPKG_VERSION" "$MODDIR" "$PWD/$PKG_WORK/stage" \
    --disable-curl --disable-ssl-curl --disable-gpg \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    CFLAGS="-O2 -D_FILE_OFFSET_BITS=64"

pkg_ship "bin/opkg"

# THE LINK HAS TO BE WHAT IT WAS ASKED TO BE, checked rather than assumed. An
# opkg that picked up a shared libarchive or libz would run perfectly here and
# fail on the printer at the first missing .so, and the message would name a
# library rather than a link flag. libc is expected and everything else is not,
# so the check is spelled that way round: anything NEEDED that is not a libc is
# a dependency nobody decided to take.
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
