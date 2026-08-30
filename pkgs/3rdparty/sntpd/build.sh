#!/usr/bin/env bash
# sntpd -- cross-compiled for the printer. One autotools project, one binary.
#
# WHAT SHIPS IS $MODDIR/sbin/sntpd AND NOTHING ELSE. The tarball can install
# two more programs, and both are left at their upstream default of off:
#
#   adjtimex    --with-adjtimex. A kernel-clock tuning tool. Nothing here
#               calls it and a printer is not where anybody debugs one.
#   ntpclient   --with-ntpclient. A symlink to the same binary that makes it
#               take Larry Doolittle's older option set instead. It is there
#               for people with a script written against the ntpclient this
#               project forked from; we have no such script, and shipping the
#               second name would mean two documented spellings of one
#               service.
#
# Neither is passed as --without-*, so this recipe states what it wants rather
# than restating what upstream already decided.
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
    CFLAGS="-O2 -D_FILE_OFFSET_BITS=64"

# The man page is installed by `make install` into the staging tree and is not
# shipped: pkg_ship copies what it is given, and $MODDIR/share/man on a printer
# with no man reader is bytes in a 128MB partition.
pkg_ship "sbin/sntpd"
pkg_end
