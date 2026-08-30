#!/usr/bin/env bash
# anvil-core -- the mod's own files, staged out of this checkout.
#
# THE RECIPE IS A LOOP OVER A DIRECTORY, which is the point of the layout:
# pkgs/anvil-core/payload/ is the $MODDIR overlay this package installs, laid
# out exactly as it lands, so a file added to that tree is shipped without an
# edit here.
#
# THE ONE SIBLING DIRECTORY THAT IS NOT SHIPPED is pkgs/anvil-core/seed/ --
# anvil.conf.in, TEMPLATED at build time from config.env and then PRESERVED
# across updates by installer/run-append.sh. Those two facts make it user
# state rather than a package member: the first `opkg upgrade` would overwrite
# a printer's settings. The answer is a shipped anvil.conf.default plus a
# seeder, which needs maintainer-script support pkgs/lib.sh does not have yet.
#
# WHAT LIVES UNDER ANOTHER RECIPE, because ownership follows the component:
#   moonraker.conf, moonraker-custom.conf     pkgs/moonraker
#   ff-*.cfg, printer.base.cfg, chamber/      pkgs/klipper-config
#   klippy extras                             pkgs/klipper
#
# payload/prog/ holds the three files the printer reads from /usr/prog, and
# this package owns the script that links them there.
#
# THE s6-rc SERVICE SOURCE IS HERE and is not compiled by this recipe:
# payload/etc/s6-rc/source/ is text, and the replica runs s6-rc-compile over
# it once the payload is assembled, so this package stays buildable on a
# checkout that has never run a cross-compiler.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin anvil-core || exit 0
pkg_intree

# One entry per top-level name, rather than one cp of the whole tree, because
# pkg_stage takes a destination and `.` is not one -- and because the list it
# produces is exactly the list pkg_ship needs below.
_top=""
for _e in "$PKG_DIR"/payload/*; do
    [ -e "$_e" ] || continue
    _n=$(basename "$_e")
    pkg_stage "$_e" "$_n"
    _top="$_top $_n"
done
[ -n "$_top" ] || pkg_die "anvil-core: nothing under $PKG_DIR/payload"

# Executable bits, set here rather than inherited from the checkout, because a
# `run` that arrives without one is a service s6 can never start and reports
# only in its own log.
chmod +x "$PKG_WORK/stage$MODDIR/bin"/* "$PKG_WORK/stage$MODDIR/prog"/*
# The service definitions s6-supervise and the oneshot runner exec. `up` and
# `down` are execline command lines rather than files, so they are not here.
chmod +x "$PKG_WORK/stage$MODDIR"/etc/s6-rc/source/*/run 2>/dev/null || true

# shellcheck disable=SC2086
pkg_ship $_top

# anvil-env.sh is SOURCED, not executed, and shipping it with an executable
# bit would invite somebody to run it. Checked because the chmod above is a
# glob and globs grow.
for _f in anvil-env.sh; do
    [ -x "$PKG_OUT/$_f" ] && pkg_die \
        "anvil-core: $_f is executable -- it is sourced, never run"
done

pkg_end
