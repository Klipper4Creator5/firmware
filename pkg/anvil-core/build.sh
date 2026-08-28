#!/usr/bin/env bash
# anvil-core -- the mod's own files, staged out of this checkout.
#
# THE RECIPE IS A LOOP OVER A DIRECTORY NOW, and that is the whole point of
# the layout. pkg/anvil-core/payload/ is the $MODDIR overlay this package
# installs, laid out exactly as it lands: payload/init.d/S60nginx becomes
# $MODDIR/init.d/S60nginx and nothing here has to say so. What used to be six
# pkg_stage lines with hand-written destinations and a glob for the .cfg files
# is one loop, and a file added to that tree is shipped without an edit here.
#
# THE TWO SIBLING DIRECTORIES ARE NOT SHIPPED, and they are named rather than
# explained because a comment cannot be checked and a path can:
#
#   pkg/anvil-core/prog/     files bin/patch.sh places on /usr/prog -- the
#       FIRMWARE partition, which is somebody else's filesystem. firmwareExe
#       is the boot entry point app_startup.sh execs, so it cannot live under
#       a --prefix root that a package installs into; the test that every
#       path in a package lands under $MODDIR would catch it if this tried.
#       It becomes a package member the day a postinst symlinks it into place
#       from a staging root -- see docs/notes/85-packaging.md phase 2.
#   pkg/anvil-core/seed/     anvil.conf.in, which is TEMPLATED at build time
#       from config.env's MOD_* and NICE_* values and then PRESERVED across
#       updates by installer/run-append.sh. Those two facts make it user
#       state that happens to ship with a default rather than a package
#       member: the first `opkg upgrade` would overwrite a printer's
#       settings. The answer is a shipped anvil.conf.default plus a seeder
#       that copies it only when the real file is absent -- which needs
#       maintainer-script support that pkg/lib.sh does not have yet.
#
# WHAT LIVES UNDER ANOTHER RECIPE, because ownership follows the component:
# Klipper's launcher, its klippy extras and its printer.*.cfg are pkg/klipper's
# (in prog/, for now, for the same /usr/prog reason); moonraker-custom.conf is
# pkg/moonraker's. The Klipper .cfg files still in payload/config/ below are
# the ones anvil-core has always shipped and they move next, with the
# ownership shift -- this file is a move, not a repackaging.
#
# THE s6 SERVICE DEFINITIONS ARE HERE, for now, and that is a decision with a
# short shelf life. Today payload/etc/s6/ is a plain s6-svscan scandir: text
# files, no build step, nothing to compile. Once the s6-rc migration lands
# they become a source tree that s6-rc-compile turns into a binary database,
# and at that point they need PKG_BUILD_DEPENDS="s6-rc" -- which this package
# must not acquire, because the repo's own shell scripts should be packageable
# on a checkout that has never run a cross-compiler. That is the moment they
# become anvil-services with a recipe of its own.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

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

# Executable bits, set here rather than inherited from the checkout, because
# a `run` that arrives without one is a service s6 can never start and reports
# only in its own log. cp -a preserved whatever git had; this makes it true
# regardless of what a contributor's umask did.
chmod +x "$PKG_WORK/stage$MODDIR/init.d"/S* "$PKG_WORK/stage$MODDIR/bin"/*
chmod +x "$PKG_WORK/stage$MODDIR"/etc/s6/*/run 2>/dev/null || true

# shellcheck disable=SC2086
pkg_ship $_top

# anvil-env.sh and anvil-service.sh are SOURCED, not executed, and shipping
# either with an executable bit would invite somebody to run it. Checked
# because the chmod above is a glob and globs grow.
for _f in anvil-env.sh anvil-service.sh; do
    [ -x "$PKG_OUT/$_f" ] && pkg_die \
        "anvil-core: $_f is executable -- it is sourced, never run"
done

pkg_end
