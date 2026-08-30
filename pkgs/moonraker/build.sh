#!/usr/bin/env bash
# Moonraker -- stage the pinned source tree into the prefix.
#
# GitHub's generated tarball wraps everything in moonraker-<sha>/, and the
# thing we want is the moonraker/ package directory inside it -- not the
# repository root, which also carries docs, scripts and a test suite. So the
# unpack keeps the wrapper and the stage reaches through it, rather than
# --strip-components hiding the shape of the archive from whoever reads this.
#
# WHAT IS REMOVED, AND WHY IT IS REMOVED HERE. tests/ is a sizeable part of
# the tree and never runs on a printer. It was trimmed by bin/payload.sh before
# this recipe existed and is trimmed in the same place it always was -- once,
# on the way in. The __pycache__ sweep that stood beside it is pkg_ship's
# now: it was written here and in pkgs/klipper and missing from anvil-core,
# which is the recipe that was actually shipping bytecode.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin moonraker || exit 0
pkg_unpack "$MOONRAKER_TGZ"

_src="$PKG_WORK/src/moonraker-$MOONRAKER_VERSION/moonraker"
# The guard bin/payload.sh has always had, kept: a tarball whose shape changed
# under us would otherwise stage nothing, which looks like a clean build and a
# dead web UI.
[ -f "$_src/moonraker.py" ] || pkg_die \
    "moonraker: no moonraker/moonraker.py in $(basename "$MOONRAKER_TGZ")"

pkg_stage "$_src" "moonraker"
rm -rf "$PKG_WORK/stage$MODDIR/moonraker/tests"

# moonraker.conf, which was anvil-core's until now. It is Moonraker's config:
# it names Moonraker's socket, its trusted clients and its components, and it
# is meaningless without the server it configures. The reason it lived in
# anvil-core is that anvil-core was the first recipe and everything of ours
# started there, not a decision anybody made.
#
# It installs to $MODDIR/config, which is a STAGING directory rather than
# where Moonraker reads it: installer/run-append.sh copies $MODDIR/config/*
# into /usr/data/config/, and moonraker.conf takes the compare-and-.mod-new
# branch there because a printer reached through a tuned trusted_clients block
# must not lose that access on an update. payload/ mirrors the install, so the
# path here is the staging path.
pkg_stage "$PKG_DIR/payload/config" "config"

pkg_ship "moonraker" "config"
pkg_end
