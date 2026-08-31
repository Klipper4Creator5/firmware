#!/usr/bin/env bash
# sntpd -- cross-compiled for the printer. One autotools project, one binary.
#
# WHAT SHIPS IS THE BINARY AND ITS ntpclient NAME, both at $MODDIR/sbin.
#
#   ntpclient   --with-ntpclient. A symlink to the same binary, which makes it
#               take Larry Doolittle's older option set. THE ntp SERVICE EXECS
#               THIS NAME, and has to: the step that sets the clock is
#               `if (!dry && ntpc->set_clock)` at sntpd.c:485, and set_clock is
#               raised in exactly one place -- the ntpclient argument parser,
#               `case 's'` at sntpd.c:1459. sntpd's own parser initialises it
#               to zero and has no option to raise it (its -s is logging), so
#               under that name the daemon only ever disciplines the clock
#               FREQUENCY through adjtimex. This printer has no RTC and boots
#               in 1970; a frequency correction in parts per million does not
#               close a fifty-six year gap, and the clock stays there for ever.
#               Measured on a printer, 2026-08-31.
#   adjtimex    --with-adjtimex, left at upstream's default of off. A
#               kernel-clock tuning tool; nothing here calls it and a printer
#               is not where anybody debugs one.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin sntpd || exit 0
pkg_toolchain
pkg_unpack "$SNTPD_TGZ"

# --disable-siocgstamp is deliberately NOT passed: it is for "Linux pre 3.0"
# and this kernel is 3.10, so the precise SIOCGSTAMP receive timestamp works
# and is what makes a poll worth anything over wifi.
#
# THE PREFIX IS LEFT ALONE, so this lands at $MODDIR/sbin/sntpd from upstream's
# own sbin_PROGRAMS. It is the first thing this repo ships into $MODDIR/sbin --
# everything else is in bin/ -- and that is the right split rather than an
# accident: sbin is where a daemon nobody types goes, and keeping bin/ to the
# things a printer owner runs by hand is worth one more directory.
#
# -D_FILE_OFFSET_BITS=64 for the reason every cross-build in this tree carries
# it (32-bit build, 64-bit inodes -- see versions.env).
pkg_build "sntpd-$SNTPD_VERSION" \
    --build="$(uname -m)-linux-gnu" \
    --with-ntpclient \
    CFLAGS="-O2 -D_FILE_OFFSET_BITS=64"

# The man page is installed by `make install` into the staging tree and is not
# shipped: pkg_ship copies what it is given, and $MODDIR/share/man on a printer
# with no man reader is bytes in a 128MB partition.
pkg_ship "sbin/sntpd" "sbin/ntpclient"

# The symlink is upstream's install hook, and a `cp` that dereferenced it would
# put a second 60KB binary in the package. Asserted because pkg_ship's copy is
# the one place that could quietly change.
[ -L "$PKG_OUT/sbin/ntpclient" ] || pkg_die \
    "sntpd: sbin/ntpclient is not a symlink -- the package carries the binary twice"

pkg_end
