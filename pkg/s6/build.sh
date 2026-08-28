#!/usr/bin/env bash
# s6 -- the supervisor, cross-compiled against the packaged skalibs and
# execline and linked dynamically against the printer's own glibc.
#
# WHAT SHIPS IS A SUBSET of the ~40 binaries s6 installs. Thirteen are the
# supervision machinery: the scanner and its control channel, one supervisor
# per service and the verb that talks to it, "is it up", the readiness wait,
# the listening verbs those exec, and the fifodir tools they need.
#
# Eight more are here because s6-rc's GENERATED scripts exec them, which s6's
# own documentation does not say -- it was found by running a real s6-rc
# up/down cycle with a PATH containing only the candidates. s6rc-oneshot-runner
# needs the ipcserver chain and s6-sudod; s6-rc execs s6-sudo, which execs
# s6-sudoc; the fdholder servicedir, which s6-rc-compile writes into EVERY
# database whether our services use it or not, needs s6-fdholder-daemon and
# s6-ipcclient. Leaving any out gives "s6-rc: warning: unable to spawn
# subprocess" at boot.
#
# Execline is deliberately left enabled: s6-rc has no flag to disable it and
# needs an execline-enabled s6.
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
pkg_build "s6-$S6_VERSION" \
    --with-sysdeps="$_sr/lib/skalibs/sysdeps" \
    --with-include="$_sr/include" \
    --with-lib="$_sr/lib" \
    --enable-absolute-paths \
    --disable-shared --enable-static \
    CFLAGS="-Os -D_FILE_OFFSET_BITS=64"

PKG_STRIP_ARGS=""

# The list lives here and nowhere else, and is checked below, so `make
# packages` catches a missing binary rather than only a full firmware build.
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
# a link flag.
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
