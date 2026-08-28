#!/usr/bin/env bash
# s6 -- the supervisor, cross-compiled against the packaged skalibs and
# execline and linked dynamically against the printer's own glibc.
#
# WHAT SHIPS IS A SUBSET, AND THE SUBSET GREW. s6 installs about 40 binaries.
# Thirteen of them are the supervision machinery this mod has always shipped:
# the scanner and its control channel, one supervisor per service and the verb
# that talks to it, "is it up", the readiness wait that is the whole reason for
# s6, the listening verbs those exec, and the fifodir tools they need.
#
# Eight more are here because s6-rc's generated scripts exec them, which is not
# something you can tell by reading s6's own documentation -- it was found by
# running a real s6-rc up/down cycle with a PATH containing only the
# candidates and adding whatever the next failure named. s6rc-oneshot-runner's
# run script needs the ipcserver chain and s6-sudod; s6-rc itself execs s6-sudo
# on the client side, which execs s6-sudoc; the fdholder servicedir, which
# s6-rc-compile writes into EVERY database whether or not our services use it,
# needs s6-fdholder-daemon and s6-ipcclient. Leaving any of them out gives
# "s6-rc: warning: unable to spawn subprocess" at boot.
#
# NOT --disable-execline ANY MORE. s6 links execline by default and the flag
# used to turn that off, on the argument that we ship no execline. We do now:
# s6-rc has no equivalent flag and needs an execline-enabled s6.
#
# THE PTHREAD LINE IS NOT OPTIONAL. See PKG_MAKE_ARGS below.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin s6 || exit 0
pkg_toolchain
pkg_deps
pkg_unpack "$S6_TGZ"

# glibc 2.29 keeps pthread_mutex_timedlock in libpthread; 2.34 merged it into
# libc. skalibs' pthread_mutex_tailock reaches it, s6's own PTHREAD_LIB is
# wired only to --enable-nsss so no configure flag gets there, and its Makefile
# appends $(LDLIBS) last. Without this the link dies on an undefined reference
# in a file nobody in this repo wrote. Upstream never sees it and musl never
# had the split, which is why it appeared the moment the libc changed.
PKG_MAKE_ARGS="LDLIBS=-lpthread"

_sr="$PKG_SYSROOT$MODDIR"
pkg_autotools "s6-$S6_VERSION" "$MODDIR" "$PWD/$PKG_WORK/stage" \
    --with-sysdeps="$_sr/lib/skalibs/sysdeps" \
    --with-include="$_sr/include" \
    --with-lib="$_sr/lib" \
    --enable-absolute-paths \
    --disable-shared --enable-static \
    CFLAGS="-Os -D_FILE_OFFSET_BITS=64"

PKG_STRIP_ARGS=""

# The list lives here and nowhere else. bin/patch.sh used to hold it as
# S6_BINS/S6_LIBEXEC and check the count after staging; it is checked below
# instead, which means `make packages` catches a missing binary too rather
# than only a full firmware build.
S6_BINS="s6-svscan s6-svscanctl s6-supervise s6-svc s6-svstat s6-svwait s6-svok
         s6-svlisten s6-svlisten1 s6-ftrig-listen1 s6-mkfifodir s6-cleanfifodir
         s6-notifyoncheck
         s6-ipcserver-socketbinder s6-ipcserverd s6-ipcserver-access s6-sudod
         s6-ipcclient s6-fdholder-daemon s6-sudo s6-sudoc"
S6_LIBEXEC="s6-ftrigrd"

# shellcheck disable=SC2086
pkg_ship $(for b in $S6_BINS; do printf 'bin/%s ' "$b"; done) \
         $(for b in $S6_LIBEXEC; do printf 'libexec/%s ' "$b"; done) \
         "include/s6" "lib/libs6.a"

for b in $S6_BINS; do
    [ -s "$PKG_OUT/bin/$b" ] || pkg_die "s6: bin/$b is missing or empty"
done
for b in $S6_LIBEXEC; do
    [ -s "$PKG_OUT/libexec/$b" ] || pkg_die "s6: libexec/$b is missing or empty"
done

# THE LINK HAS TO BE WHAT IT WAS ASKED TO BE. A statically linked s6 would run
# here and be four times the size on the printer; one that picked up a shared
# libskarnet would fail at the first missing .so, naming a library rather than
# a link flag. libc and libpthread are expected, everything else is not.
_needed=$(readelf -d "$PKG_OUT/bin/s6-svscan" 2>/dev/null \
    | awk '/NEEDED/{gsub(/[][]/,"",$5); print $5}')
case "$_needed" in
    *skarnet*|*execline*)
        printf '%s\n' "$_needed" >&2
        pkg_die "s6-svscan links a shared skalibs or execline -- both belong inside it" ;;
esac
printf '%s\n' "$_needed" | grep -q '^libc\.so' \
    || pkg_die "s6-svscan has no NEEDED libc.so -- it should link the printer's glibc dynamically"
pkg_say "s6: s6-svscan links $(printf '%s' "$_needed" | tr '\n' ' ')"

pkg_end
