#!/usr/bin/env bash
# anvil-core -- the mod's own files, staged out of this checkout.
#
# WHAT IS DELIBERATELY NOT HERE, because every one of these looks like it
# belongs and does not:
#
#   payload/firmwareExe, payload/start.sh   They do not land under $MODDIR at
#       all. bin/patch.sh puts them in the SOFTWARE component, which
#       FlashForge's own run.sh copies onto /usr/prog. A package whose paths
#       are all under /usr/data cannot carry them, and the test that every
#       path lands under the prefix would catch it if this tried.
#   payload/run-append.sh, payload/run-pre.sh   Not files at all by the time
#       they ship: patch.sh injects them INTO the stock run.sh.
#   payload/klipper/extras/ff_*.py          The firmware partition again, and
#       they belong to Klipper's tree rather than to ours.
#   payload/klipper/config/printer.base.cfg and the printer.chamber.cfg.*
#       model variants                      Firmware partition, and
#       model-specific: a package cannot be per-model without a second
#       architecture string.
#   payload/anvil.conf                      See below.
#   assets/moonraker-custom.conf            A user seam. moonraker.conf
#       includes it by name and run-append.sh creates it only when missing --
#       never overwrites. A package member is overwritten on every upgrade by
#       definition, which is the opposite of what that file is for.
#
# ANVIL.CONF IS NOT IN THIS PACKAGE, and that is the one judgement here worth
# arguing with. It is templated at build time from config.env's MOD_* and
# NICE_* values, and it is a file the user edits over ssh and which
# run-append.sh preserves across updates. Those two facts make it user state
# that happens to ship with a default, not a package member: the first
# `opkg upgrade` would overwrite a printer's settings. bin/patch.sh keeps
# writing it, unchanged. When packages become the shipping vehicle rather
# than a lane beside it, the answer is a shipped anvil.conf.default plus a
# seeder that copies it only when the real file is absent -- which is what
# run-append.sh already does for moonraker-custom.conf.
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

pkg_stage "$ROOT/payload/anvil-env.sh"     "anvil-env.sh"
pkg_stage "$ROOT/payload/anvil-service.sh" "anvil-service.sh"
pkg_stage "$ROOT/payload/init.d"           "init.d"
pkg_stage "$ROOT/payload/bin"              "bin"
pkg_stage "$ROOT/assets/nginx.conf"        "nginx/nginx.conf"
pkg_stage "$ROOT/assets/moonraker.conf"    "config/moonraker.conf"

# The s6 scandir: one directory per supervised service, each holding a `run`
# script and whatever control files it needs beside it (`down` to ship in the
# down state, `notification-fd` to say where readiness arrives). Staged whole
# rather than by glob, because those control files are not scripts and a *.sh
# pattern would silently drop the two that decide whether a service starts.
[ -d "$ROOT/payload/etc/s6" ] && pkg_stage "$ROOT/payload/etc/s6" "etc/s6"

# The toolchanger's Klipper includes. These are config, they are read from
# $MODDIR/config, and they are ours -- unlike printer.base.cfg beside them,
# which goes to the firmware partition with Klipper's own tree.
for _c in "$ROOT"/payload/klipper/config/ff-*.cfg; do
    [ -f "$_c" ] || continue
    pkg_stage "$_c" "config/$(basename "$_c")"
done

# Executable bits, set here rather than inherited from the checkout, because
# a `run` that arrives without one is a service s6 can never start and reports
# only in its own log. cp -a preserved whatever git had; this makes it true
# regardless of what a contributor's umask did.
chmod +x "$PKG_WORK/stage$MODDIR/init.d"/S* "$PKG_WORK/stage$MODDIR/bin"/*
chmod +x "$PKG_WORK/stage$MODDIR"/etc/s6/*/run 2>/dev/null || true

pkg_ship "anvil-env.sh" "anvil-service.sh" "init.d" "bin" "nginx" "config" "etc"

# anvil-env.sh and anvil-service.sh are SOURCED, not executed, and shipping
# either with an executable bit would invite somebody to run it. Checked
# because the chmod above is a glob and globs grow.
for _f in anvil-env.sh anvil-service.sh; do
    [ -x "$PKG_OUT/$_f" ] && pkg_die \
        "anvil-core: $_f is executable -- it is sourced, never run"
done

pkg_end
