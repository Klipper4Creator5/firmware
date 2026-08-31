#!/usr/bin/env bash
# libsodium, cross-compiled for the printer into $SODIUM_BUILD.
#
# One build and one vehicle: the package this produces is what bin/payload.sh
# installs into the payload, so there is no second copy to drift from.
#
# WHOSE INTERPRETER DLOPENS IT: libnacl reaches libsodium through
# ctypes.cdll.LoadLibrary, and the process doing that is OUR CPython 3.13, not
# FlashForge's 3.8.2. It has to match whatever interpreter loads it.
#
# WHY IT CANNOT BE STATIC, when the interpreter's seven dependencies all are:
# you cannot dlopen an archive. Moonraker's `authorization` component signs
# its JWTs with the ed25519 pair libnacl exposes, so this is on the startup
# path of the web UI.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin libsodium || exit 0
pkg_toolchain
pkg_unpack "$SODIUM_TGZ"

# --disable-static: nothing links this statically and a .a would only be
#   deleted again by pkg_ship.
# --with-pic and -fPIC: it is dlopened, so it has to be position independent
#   whatever the toolchain's default happens to be this decade.
# libsodium's runtime feature probes are AC_RUN_IFELSE with cross defaults
#   supplied, so nothing here needs qemu.
pkg_build "libsodium-$SODIUM_VERSION" \
    --disable-static --enable-shared --with-pic CFLAGS="-O2 -fPIC"

# All three names: libsodium.so -> .so.26 -> .so.26.2.0. The bare
# `libsodium.so` is not a development leftover to be trimmed -- it is the
# FIRST name libnacl asks dlopen for, and the only one its
# __file__[0:__file__.find("lib")+3] + "/libsodium.so" fallback constructs.
pkg_ship "lib/libsodium.so*"

[ -L "$SODIUM_BUILD/lib/libsodium.so" ] \
    || pkg_die "lib/libsodium.so is not a symlink -- libnacl's dlopen fallback asks for that exact name"

pkg_end
