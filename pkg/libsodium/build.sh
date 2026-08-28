#!/usr/bin/env bash
# libsodium, cross-compiled for the printer into $SODIUM_BUILD (work/.sodium).
#
# THIS IS bin/patch.sh SECTION 5d'S BUILD BLOCK, MOVED -- not a second copy of
# it. patch.sh now runs this script and then stages what it leaves behind, so
# there is exactly one set of configure flags in the repo and the .ipk that
# bin/build-packages.sh emits is built by the same code as the payload's copy.
# That property is what the migration in docs/notes/85-packaging.md rests on:
# a package cannot drift from the tarball while both come out of here.
#
# Everything below the cache check is unchanged from where it lived. The
# comments came with it.
#
#     ./pkg/libsodium/build.sh        # build if work/.sodium is stale
#
# Output: $SODIUM_BUILD/lib/libsodium.so{,.26,.26.2.0} and a .version stamp.
# Nothing is staged into the payload here -- that is patch.sh's half.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"

say() { printf '>> %s\n' "$*"; }
skip() { printf '   (skip) %s\n' "$*"; }

# WHY IT CANNOT BE STATIC, when the interpreter's seven dependencies all are.
# libnacl is pure python: it reaches libsodium through
# ctypes.cdll.LoadLibrary, which is dlopen, and you cannot dlopen an archive.
# Moonraker's `authorization` component signs its JWTs with the ed25519 pair
# libnacl exposes, so this is on the startup path of the web UI rather than
# beside it.
#
# CACHED ON THE VERSION, like s6 and unlike c_helper.so. 24 seconds is not the
# reason -- the reason is bin/fetch-assets.sh: an uncached build of this drags
# the ~203MB Ingenic toolchain download along behind it on every build of a
# checkout that has nothing else to compile. The stamp is what lets the
# fetcher skip it, so the stamp is what makes it free.
SODIUM_XW=work/.sodium-xw
if [ "$(cat "$SODIUM_BUILD/.version" 2>/dev/null || true)" = "$SODIUM_VERSION" ]; then
    skip "libsodium: work/.sodium already holds $SODIUM_VERSION"
    exit 0
fi

if [ ! -x "$PY_TOOLCHAIN_DIR/bin/$PY_HOST-gcc" ]; then
    [ -f "${MIPS_TOOLCHAIN_TGZ:-}" ] || {
        echo "   !! libsodium needs (re)building and there is no toolchain:" >&2
        echo "      $MIPS_TOOLCHAIN_TGZ is missing. Run ./bin/fetch-assets.sh." >&2
        exit 1; }
    say "libsodium: unpacking the Ingenic MIPS toolchain"
    mkdir -p work/.mips-toolchain
    tar -xzf "$MIPS_TOOLCHAIN_TGZ" -C work/.mips-toolchain
fi
[ -f "${SODIUM_TGZ:-}" ] || {
    echo "   !! no libsodium source at '$SODIUM_TGZ' -- run ./bin/fetch-assets.sh" >&2
    exit 1; }
say "libsodium: cross-compiling $SODIUM_VERSION for $MODDIR/lib"
rm -rf work/.sodium-src work/.sodium-stage "$SODIUM_XW" "$SODIUM_BUILD"
mkdir -p work/.sodium-src "$SODIUM_XW/bin"
tar -xzf "$SODIUM_TGZ" -C work/.sodium-src
(
    set -e
    # A subshell, as in 5b and 5c, so the cross-compiler cannot leak.
    TC="$PWD/$PY_TOOLCHAIN_DIR"
    XW="$PWD/$SODIUM_XW"
    STAGE="$PWD/work/.sodium-stage"
    LOG="$PWD/work"
    # The same wrapper trick, rebuilt here rather than shared with 5c:
    # 5c deletes work/.py-xw when its build succeeds, and this step has to
    # work on a run where 5c did nothing at all because its cache was
    # warm. -EL -mnan=2008 in the driver, where libsodium's libtool link
    # lines cannot drop them.
    for t in gcc g++ cpp; do
        printf '#!/bin/sh\nexec %s/bin/%s-%s -EL -mnan=2008 "$@"\n' \
            "$TC" "$PY_HOST" "$t" > "$XW/bin/$PY_HOST-$t"
        chmod +x "$XW/bin/$PY_HOST-$t"
    done
    for t in ar as ld nm objcopy objdump ranlib readelf strip strings size; do
        ln -sf "$TC/bin/$PY_HOST-$t" "$XW/bin/$PY_HOST-$t"
    done
    export PATH="$XW/bin:$PATH"
    cd "$PWD/work/.sodium-src/libsodium-$SODIUM_VERSION"
    # --disable-static: nothing links this statically and a .a would only
    #   be deleted again below.
    # --host is what makes autoconf reach for the mips-linux-gnu- prefixed
    #   tools in the wrapper directory, which is the entire point of them.
    # libsodium's runtime feature probes are AC_RUN_IFELSE with cross
    #   defaults supplied, so nothing here needs qemu.
    ./configure --host="$PY_HOST" --prefix="$MODDIR" \
        --disable-static --enable-shared --with-pic \
        CFLAGS="-O2 -fPIC" >"$LOG/.sodium-configure.log" 2>&1
    make -j"$(nproc 2>/dev/null || echo 4)" >"$LOG/.sodium-make.log" 2>&1
    make install DESTDIR="$STAGE" >>"$LOG/.sodium-make.log" 2>&1
) || { echo "   !! the libsodium cross-build failed -- work/.sodium-configure.log" >&2
       echo "      and work/.sodium-make.log; the source tree is still in" >&2
       echo "      work/.sodium-src." >&2
       exit 1; }
# lib/ ONLY. include/ and lib/pkgconfig exist to BUILD against libsodium,
# which happens on a developer's machine and not on a printer -- and
# pkgconfig would otherwise drop a .pc file describing this build into the
# prefix's shared lib/, next to the interpreter's stdlib. The .la file goes
# for the same reason plus one more: it names absolute build-machine paths.
mkdir -p "$SODIUM_BUILD/lib"
cp -a "work/.sodium-stage$MODDIR/lib/"libsodium.so* "$SODIUM_BUILD/lib/"
rm -f "$SODIUM_BUILD/lib/"*.la
find "$SODIUM_BUILD/lib" -type f -name 'libsodium.so*' \
    -exec "$PY_TOOLCHAIN_DIR/bin/$PY_HOST-strip" --strip-unneeded {} +
rm -rf work/.sodium-src work/.sodium-stage "$SODIUM_XW"
echo "$SODIUM_VERSION" > "$SODIUM_BUILD/.version"
