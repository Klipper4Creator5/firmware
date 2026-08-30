#!/usr/bin/env bash
# Moonraker -- stage the pinned source tree into the prefix.
#
# GitHub's generated tarball wraps everything in moonraker-<sha>/, and what we
# want is the moonraker/ package directory inside it, not the repository root.
# The unpack keeps the wrapper and the stage reaches through it, rather than
# --strip-components hiding the archive's shape from whoever reads this.
#
# tests/ is a sizeable part of the tree and never runs on a printer, so it is
# trimmed here, once, on the way in.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin moonraker || exit 0
pkg_unpack "$MOONRAKER_TGZ"

_src="$PKG_WORK/src/moonraker-$MOONRAKER_VERSION/moonraker"
# The guard bin/patch.sh has always had, kept: a tarball whose shape changed
# under us would otherwise stage nothing, which looks like a clean build and a
# dead web UI.
[ -f "$_src/moonraker.py" ] || pkg_die \
    "moonraker: no moonraker/moonraker.py in $(basename "$MOONRAKER_TGZ")"

pkg_stage "$_src" "moonraker"
rm -rf "$PKG_WORK/stage$MODDIR/moonraker/tests"

# moonraker.conf is Moonraker's config -- its socket, its trusted clients and
# its components -- and is meaningless without the server it configures.
#
# It installs to $MODDIR/config, a STAGING directory rather than where
# Moonraker reads it: installer/run-append.sh copies $MODDIR/config/* into
# /usr/data/config/, and moonraker.conf takes the compare-and-.mod-new branch
# there, because a printer reached through a tuned trusted_clients block must
# not lose that access on an update.
pkg_stage "$PKG_DIR/payload/config" "config"

pkg_ship "moonraker" "config"
pkg_end
