#!/usr/bin/env bash
# libsodium, cross-compiled for the printer into $SODIUM_BUILD (work/.sodium).
#
# This was bin/patch.sh section 5d, and then it was that same block moved into
# a file; it is now the block with everything generic taken out of it and put
# in pkg/lib.sh. What is left is the four facts that are actually about
# libsodium. patch.sh runs this and stages what it leaves behind, so the
# tarball's copy and the .ipk's copy are one build.
#
# WHY IT IS THE INGENIC GLIBC TOOLCHAIN and not the musl one pkg/opkg uses:
# libnacl is pure python and reaches libsodium through ctypes.cdll.LoadLibrary,
# which is dlopen -- performed by FlashForge's own glibc interpreter. A
# musl-linked libsodium is not loadable by it. opkg, next door, talks to
# nothing of ours and is static musl for exactly the same reason s6 is.
#
# WHY IT CANNOT BE STATIC, when the interpreter's seven dependencies all are:
# you cannot dlopen an archive. Moonraker's `authorization` component signs its
# JWTs with the ed25519 pair libnacl exposes, so this is on the startup path of
# the web UI rather than beside it.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin libsodium "$SODIUM_VERSION" "$SODIUM_BUILD" || exit 0
pkg_toolchain ingenic
pkg_unpack "$SODIUM_TGZ"

# --disable-static: nothing links this statically and a .a would only be
#   deleted again by pkg_ship.
# --with-pic and -fPIC: it is dlopened, so it has to be position independent
#   whatever the toolchain's default happens to be this decade.
# libsodium's runtime feature probes are AC_RUN_IFELSE with cross defaults
#   supplied, so nothing here needs qemu.
pkg_autotools "libsodium-$SODIUM_VERSION" "$MODDIR" "$PWD/$PKG_WORK/stage" \
    --disable-static --enable-shared --with-pic CFLAGS="-O2 -fPIC"

# All three names: libsodium.so -> libsodium.so.26 -> libsodium.so.26.2.0. The
# bare `libsodium.so` is not a development leftover to be trimmed -- it is the
# FIRST name libnacl asks dlopen for, and the only one its
# __file__[0:__file__.find("lib")+3] + "/libsodium.so" fallback can construct.
pkg_ship "lib/libsodium.so*"

[ -L "$SODIUM_BUILD/lib/libsodium.so" ] \
    || pkg_die "lib/libsodium.so is not a symlink -- libnacl's dlopen fallback asks for that exact name"

pkg_end
