#!/usr/bin/env bash
# OpenSSL -- the one project here whose configure is not an autoconf configure.
#
# THREE TRAPS, ALL OF THEM HIT FOR REAL, kept from bin/payload.sh section 5c:
#
#  * `no-docs` only exists from 3.1. On 3.0.x it is an "Unsupported options"
#    HARD ERROR, not a warning -- so it is not passed here.
#  * the linux-mips32 target hardcodes -mips2 into its cflags, and this
#    toolchain defaults to -mfp64, which gcc refuses below mips32r2 ("'-mgp32'
#    and '-mfp64' can only be combined if the target supports the mfhc1 and
#    mthc1 instructions"). User cflags land AFTER the target's, so -mips32r2
#    puts the ISA back where the printer actually is. If a future OpenSSL
#    orders them the other way round, linux-generic32 -- portable C, no mips
#    assembly -- is the fallback, and it is TAKEN AUTOMATICALLY rather than
#    left as a note, because the failure is a wall of assembler errors that
#    says nothing about ISA levels.
#  * --openssldir is where the interpreter looks for CA certificates on the
#    printer. See pkg.conf.
#
# THE FALLBACK IS WHY pkg_build RETURNS RATHER THAN DIES. Under the recipe's
# own `set -e` a failed build aborts anyway, which is what every other recipe
# wants; here there is something to try next, and `if ! pkg_build` is how that
# is said. OpenSSL gets no verb of its own -- it sets three of pkg_build's
# knobs, the same three any other project with a non-autoconf configure would
# set.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin openssl || exit 0
pkg_toolchain
pkg_unpack "$OPENSSL_TGZ"

_src="openssl-$OPENSSL_VERSION"

# ./Configure, not ./configure; a target name instead of --host; and
# install_sw rather than install, because the full target also writes man
# pages and the certificate directory, neither of which belongs in a package
# of headers and archives.
PKG_CONFIGURE=./Configure
PKG_CONFIGURE_AUTO=0
PKG_INSTALL_TARGET=install_sw

_ossl_args="--prefix=$MODDIR --libdir=lib --openssldir=$MODDIR/ssl
            no-shared no-tests -fPIC -O2 -D_FILE_OFFSET_BITS=64"

# shellcheck disable=SC2086
if ! pkg_build "$_src" linux-mips32 -mips32r2 $_ossl_args; then
    pkg_say "openssl: linux-mips32 failed; falling back to linux-generic32"
    ( cd "$PKG_WORK/src/$_src" && make distclean >/dev/null 2>&1 ) || true
    # shellcheck disable=SC2086
    pkg_build "$_src" linux-generic32 no-asm $_ossl_args \
        || pkg_die "openssl: both linux-mips32 and linux-generic32 failed -- see $PKG_WORK/$_src-*.log"
fi

pkg_ship "include/openssl" "lib/libssl.a" "lib/libcrypto.a" \
         "lib/pkgconfig/libssl.pc" "lib/pkgconfig/libcrypto.pc" \
         "lib/pkgconfig/openssl.pc"
pkg_end
