#!/usr/bin/env bash
# 2/3 -- build the mod payload from the package feed. Idempotent.
#
# Install the feed with the printer's own apk, seed the user's
# moonraker-custom.conf, write the manifest. Everything it produces goes to
# $MODDIR on the data partition and nothing to /usr/prog, so it needs the
# package feed and no stock FlashForge package at all.
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$ROOT/pkgs/lib.sh"

# Counting packages, not testing the directory: a cleaned tree leaves it empty.
if [ -z "$(ls "$PKG_FEED"/*."$PKG_EXT" 2>/dev/null)" ]; then
    echo "no package feed at $PKG_FEED" >&2
    echo "  the recipes this script runs build against it -- run 'make packages' first." >&2
    exit 1
fi

say() { printf '>> %s\n' "$*"; }
skip() { printf '   (skip) %s\n' "$*"; }

# Everything goes to /usr/data: /usr/prog is the firmware partition and would
# overflow on ~100MB of Mainsail and HelixScreen.
rm -rf "$PAYLOAD_ROOT"

# --- 1. the payload, installed
# Installed by the printer's own apk inside the replica, so `apk info` answers
# what a release installs off the payload itself.
say "payload: installing the feed with the printer's own apk"

# Not model-specific; TARGET_MACHINE names only the OUTPUT file, because
# runFirmwareExe.sh refuses a package whose machine is not its own.

# The roots, not the closure: depends brings the rest, so the metadata is
# exercised on every build. A root with no package is skipped -- that is how
# the PKG_WHEN gates reach here -- but a missing DEPENDENCY is still apk's
# error.
#
# The two loose python packages are Recommends in spirit. apk HAS a recommends
# field and nothing in its solver reads it, so they stay roots; install-if is
# the field that would actually work and moving them to it is its own change
# with its own gate.
#
# greenlet and cffi are deliberately NOT here: the klipper service execs
# $FF_PYTHON, so they are ordinary depends of anvil-klipper now. Listed here
# they were installed by every build and by no `apk add anvil-klipper`, which
# is the one command that has to work on a printer.
MOD_ROOTS="anvil-core anvil-s6-rc anvil-klipper
           anvil-moonraker anvil-python-pillow anvil-python-preprocess-cancellation
           anvil-mainsail anvil-helixscreen anvil-busybox anvil-sntpd"

# THE PACKAGE MANAGER IS A ROOT TOO. Appended rather than written into the
# list above so that the list stays a literal one: qa/static reads it out of
# this file as text.
MOD_ROOTS="$MOD_ROOTS anvil-apk-tools"

# Named, not versioned -- except anvil-core, whose PKG_VERSION is MOD_VER, so a
# feed built yesterday would install yesterday's anvil-core.
[ -f "$(pkg_pkgfile anvil-core)" ] || pkg_die \
    "the feed has no $(basename "$(pkg_pkgfile anvil-core)") -- rerun ./bin/build-packages.sh"

# BY EXACT FILENAME, not by prefix. The .apk name puts `-` between the package
# name and its version, so `anvil-python-*` matches anvil-python-pillow and a
# package that was never built would look present. pkg_name_map answers
# exactly.
_names=$(pkg_name_map)
MOD_INSTALL=""
for _p in $MOD_ROOTS; do
    _f=$(printf '%s\n' "$_names" | awk -v n="$_p" '$1 == n { print $2; exit }')
    if [ -n "$_f" ] && [ -f "$_f" ]; then MOD_INSTALL="$MOD_INSTALL $_p"; fi
done

# The machine's own apk installs the feed onto its own filesystem: needs a
# privileged container, hence `make build`'s docker lane.
# shellcheck disable=SC2086
./bin/build-payload.py $MOD_INSTALL

# Counted out of the database the install just wrote, which is the only record
# that says what a printer will actually have. CHECKED FOR EXISTENCE FIRST:
# read through a command substitution, a missing file yields an empty count and
# prints "  packages installed" instead of failing, which is how a broken
# install looks fine.
_db="$PAYLOAD_DIR/lib/apk/db/installed"
[ -f "$_db" ] || pkg_die "the install wrote no package database at $_db"
say "payload: $(grep -c '^P:' "$_db") packages installed (both chamber configs; the printer picks)"

# --- 2. Klipper
# Nothing to do, and nothing to assert. anvil-klipper installs the whole klippy
# tree at $MODDIR/klipper/klippy and the klipper s6-rc service execs it there on
# our own $FF_PYTHON, so the package IS the printer's Klipper. /usr/prog/klipper
# keeps FlashForge's stock klippy, unread -- the only file still read there is
# klipper_pri.sh, their SCHED_FIFO helper. klipperDaemon at that path is a
# symlink to our shim, pointed there by anvil-link-prog.sh.
#
# A gate here would ask whether apk had installed the package it was just
# handed, of a staging root three lines after it was filled.
# qa/replica/test_install.py::test_klippy_is_present asks it of an installed
# filesystem instead, which is the vehicle that reaches a printer.

# --- 3. the user's seams
# In the payload and in NO package: a package member is overwritten on every
# upgrade by definition, and this is the user's own file.
[ -f pkgs/moonraker/seed/moonraker-custom.conf ] \
    && cp -f pkgs/moonraker/seed/moonraker-custom.conf "$PAYLOAD_DIR/config/moonraker-custom.conf"

# moonraker.conf ships with pkgs/moonraker, not anvil-core: unconditional, a
# BUILD_MOONRAKER=0 build overwrote the config of a server it did not install.

# --- 4. the s6-rc database
# Compiled in the replica by case-build-payload.sh, with the s6-rc-compile
# anvil-s6-rc ships, straight after apk installs the feed. Compiling with the
# compiler we SHIP is what makes the #! baked into the oneshot runner point at
# the execline we ship rather than the build host's -- a native second build of
# the same tarballs had to be held to --prefix=$MODDIR by hand to get that
# right. (Byte-identical either way: 80-s6-migration.md, measured 2026-08-28.)
#
# Nothing to assert here either. qa/replica/test_s6rc.py boots the database on
# a machine: s6-rc-init reads it, the boot set comes up, and a database moved
# aside is reported.

echo
echo "Payload built."
echo "  mod payload: $(du -sh "$PAYLOAD_DIR" | cut -f1)  (-> /usr/data/anvil, data partition)"
echo "  nothing goes to /usr/prog: no software component is shipped."
echo "Now run ./bin/pack.sh"
