#!/usr/bin/env bash
# s6-rc -- the service manager, cross-compiled against the packaged skalibs,
# execline and s6.
#
# --bootdb AND --livedir ARE BAKED IN, like every other prefix in this stack.
# --bootdb is where s6-rc-init looks for the compiled database; its default
# happens to be where we want it, and is spelled out here because a default
# that happens to be right is not the same as a decision. --livedir stays at
# /run/s6-rc: it must be on a tmpfs that is empty at boot, because s6-rc-init
# refuses to run over a live directory that already exists. Whether /run is
# tmpfs on this printer is the one thing here not checked on hardware.
#
# WHAT SHIPS is the runtime, not the whole toolbox. s6-rc-compile is a BUILD
# tool -- it runs where the database is compiled, not on the printer.
# s6-rc-update swaps a live database without a reboot, which on this machine
# an update is anyway. What is left is the three programs that bring services
# up and down and the two the generated databases exec by absolute path.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin s6-rc || exit 0
pkg_toolchain
pkg_deps
pkg_unpack "$S6RC_TGZ"

# The same glibc 2.29 pthread split s6 hits; see pkgs/3rdparty/s6/build.sh.
PKG_MAKE_ARGS="LDLIBS=-lpthread"

_sr="$PKG_SYSROOT$MODDIR"
pkg_build "s6-rc-$S6RC_VERSION" \
    --with-sysdeps="$_sr/lib/skalibs/sysdeps" \
    --with-include="$_sr/include" \
    --with-lib="$_sr/lib" \
    --bootdb="$MODDIR/etc/s6-rc/compiled/current" \
    --livedir=/run/s6-rc \
    --enable-absolute-paths \
    --disable-shared --enable-static \
    CFLAGS="-Os -D_FILE_OFFSET_BITS=64"

PKG_STRIP_ARGS=""

# s6-rc-compile ships even though it is a build tool, and that is a judgement
# rather than an oversight: it is 78KB, and it is the only way to recover a
# printer whose database is wrong without rebuilding a package on a laptop.
S6RC_BINS="s6-rc s6-rc-init s6-rc-db s6-rc-compile"
S6RC_LIBEXEC="s6-rc-oneshot-run s6-rc-fdholder-filler"

# shellcheck disable=SC2086
pkg_ship $(for b in $S6RC_BINS; do printf 'bin/%s ' "$b"; done) \
         $(for b in $S6RC_LIBEXEC; do printf 'libexec/%s ' "$b"; done)

for b in $S6RC_BINS; do
    [ -s "$PKG_OUT/bin/$b" ] || pkg_die "s6-rc: bin/$b is missing or empty"
done
for b in $S6RC_LIBEXEC; do
    [ -s "$PKG_OUT/libexec/$b" ] || pkg_die "s6-rc: libexec/$b is missing or empty"
done

_needed=$(readelf -d "$PKG_OUT/bin/s6-rc" 2>/dev/null \
    | awk '/NEEDED/{gsub(/[][]/,"",$5); print $5}')
case "$_needed" in
    *skarnet*|*execline*|*libs6*)
        printf '%s\n' "$_needed" >&2
        pkg_die "s6-rc links a shared skalibs, execline or s6 -- all three belong inside it" ;;
esac
pkg_say "s6-rc: s6-rc links $(printf '%s' "$_needed" | tr '\n' ' ')"

pkg_end
