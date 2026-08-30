#!/usr/bin/env bash
# moonraker-timelapse -- two files out of the pinned tarball. Nothing is
# compiled, and the encoder is anvil-ffmpeg's problem, not this recipe's.
#
# UPSTREAM'S scripts/install.sh IS NOT USED: it clones into a home directory,
# symlinks into a Moonraker checkout, appends to live config and registers an
# update_manager entry that re-clones over the network -- all of which this
# repo does differently. The tarball is just a source, and the two files it
# actually contributes are placed by hand.
#
# GitHub wraps the archive in moonraker-timelapse-<sha>/; the paths reach
# through that rather than hiding the archive's shape behind --strip-components.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin timelapse || exit 0
pkg_unpack "$TIMELAPSE_TGZ"

_src="$PKG_WORK/src/moonraker-timelapse-$TIMELAPSE_VERSION"

# pkgs/moonraker's guard, for the same reason: a tarball whose shape changed
# would stage nothing, which is a clean build and a tab that never appears.
[ -f "$_src/component/timelapse.py" ] || pkg_die \
    "timelapse: no component/timelapse.py in $(basename "$TIMELAPSE_TGZ")"
[ -f "$_src/klipper_macro/timelapse.cfg" ] || pkg_die \
    "timelapse: no klipper_macro/timelapse.cfg in $(basename "$TIMELAPSE_TGZ")"

# Inside anvil-moonraker's directory, because Moonraker resolves a component
# with import_module(".components.<name>", "moonraker") and looks nowhere else.
# Two packages, different files, one directory -- opkg is content, and
# anvil-moonraker's Depends orders the install.
pkg_stage "$_src/component/timelapse.py" "moonraker/components/timelapse.py"

# $MODDIR/config is a staging directory: runFirmwareExe.sh copies it into
# /usr/data/config, where printer.base.cfg's [include timelapse.cfg] resolves.
pkg_stage "$_src/klipper_macro/timelapse.cfg" "config/timelapse.cfg"

pkg_ship "moonraker/components/timelapse.py" "config/timelapse.cfg"
pkg_end
