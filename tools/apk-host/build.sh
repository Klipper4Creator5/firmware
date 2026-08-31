#!/usr/bin/env bash
# A NATIVE apk for the build machine, at $APK_BIN. Not a package, not shipped.
#
# The feed producer needs `apk mkpkg` and `apk mkndx`, and those run here, on
# x86-64, not on the printer. An upstream tool, from the pinned source, doing
# the packaging -- rather than this repo re-deriving a format somebody else
# maintains.
#
# UNPATCHED, DELIBERATELY. pkgs/3rdparty/apk-tools/prefix.patch defaults the
# database root to $MODDIR, which is right for a printer and wrong for a build
# machine: this binary only ever reads and writes package FILES named on its
# command line. Building it without the patch is also a standing check that the
# patch is not load-bearing for anything but the printer.
#
# It is built from $APK_TOOLS_DIR, the same commit-pinned checkout the cross
# recipe uses, so the tool that writes a package and the tool that reads it on
# the machine are the same version by construction.
set -euo pipefail
. ./bin/common.sh

STAMP="apk-host $APK_TOOLS_COMMIT"
if [ "$(cat "$APK_HOST_DIR/.version" 2>/dev/null || true)" = "$STAMP" ]; then
    echo "   (skip) apk-host: $APK_BIN already holds this build"
    exit 0
fi

[ -d "$APK_TOOLS_DIR/.git" ] || {
    echo "!! no apk-tools checkout at $APK_TOOLS_DIR -- run ./bin/fetch-assets.sh" >&2
    exit 1; }

WORK="$ROOT/work/.apk-host-build"
LOG="$WORK/make.log"
rm -rf "$WORK" "$APK_HOST_DIR"
mkdir -p "$WORK"

# A scratch copy, so vendor/ stays exactly at the sha bin/fetch-assets.sh
# verified -- the same rule pkg_checkout follows.
cp -a "$APK_TOOLS_DIR" "$WORK/src"
rm -rf "$WORK/src/.git"

cd "$WORK/src"

# The same three things the cross build needs, for the same reasons, and they
# are worth restating because nothing about them is x86-specific:
#
#  * strlcpy. Upstream's portability/ shims are wired into the MESON build
#    only; the legacy Makefile assumes musl, where there is nothing to shim.
#    Debian is glibc, so the link fails on strlcpy exactly as it does for the
#    printer. One object, from upstream's own source.
#  * LIBS_apk. src/Makefile says `-lapk` with both libapk.so and libapk.a in
#    the output directory, so the shared one wins and the binary needs
#    LD_LIBRARY_PATH to run. A build tool that has to be run through a wrapper
#    is a build tool somebody will run wrong.
#  * SCDOC. Forty man pages with a tool the image does not carry.
#
# -lpthread -ldl are named even though this Debian's glibc folded them in at
# 2.34: naming them is harmless where they are stubs, and the alternative is a
# build that works here and not on an older image.
gcc -O2 -fPIC -Iportability -c portability/strlcpy.c -o portability/strlcpy.o \
    > "$LOG" 2>&1 \
    || { echo "!! apk-host: could not compile upstream's strlcpy shim -- see $LOG" >&2; exit 1; }

export LDFLAGS="${LDFLAGS:-} $PWD/portability/strlcpy.o -lpthread -ldl"

make -j"$(nproc 2>/dev/null || echo 4)" \
    LUA=no ZSTD=no SCDOC=/bin/true \
    LIBS_apk=-Wl,--start-group,-l:libapk.a,libfetch/libfetch.a,-lssl,-lcrypto,-lz,--end-group \
    >> "$LOG" 2>&1 \
    || { echo "!! apk-host: build failed -- see $LOG" >&2; exit 1; }

mkdir -p "$APK_HOST_DIR/bin"
cp src/apk "$APK_BIN"

# Prove it before anything depends on it: a binary that cannot report its own
# version is not a packager, and the failure would otherwise land three steps
# later as an unreadable feed.
"$APK_BIN" --version > /dev/null \
    || { echo "!! apk-host: $APK_BIN does not run" >&2; exit 1; }

echo "$STAMP" > "$APK_HOST_DIR/.version"
rm -rf "$WORK"
echo ">> apk-host: $("$APK_BIN" --version)"
