#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/. Idempotent.
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$ROOT/pkgs/lib.sh"

SOFTWARE_DIR=work/software
[ -d "$SOFTWARE_DIR" ] || { echo "run bin/unpack.sh first" >&2; exit 1; }

# Counting .ipk, not testing the directory: a cleaned tree leaves it empty.
if [ -z "$(ls "$PKG_FEED"/*.ipk 2>/dev/null)" ]; then
    echo "no package feed at $PKG_FEED" >&2
    echo "  the recipes this script runs build against it -- run 'make packages' first." >&2
    exit 1
fi

say() { printf '>> %s\n' "$*"; }
skip() { printf '   (skip) %s\n' "$*"; }

# Built OUTSIDE the software component: /usr/prog is on the firmware partition
# and would overflow on ~100MB of Mainsail and HelixScreen.
rm -rf "$PAYLOAD_ROOT" "$SOFTWARE_DIR/mod"

# --- 0. the payload, installed
# Installed by the printer's own opkg inside the replica, so `opkg
# list-installed` answers what a release installs off the payload itself.
say "payload: installing the feed with the printer's own opkg"

# Not model-specific; TARGET_MACHINE names only the OUTPUT file, because
# runFirmwareExe.sh refuses a package whose machine is not its own.

# The roots, not the closure: Depends brings the rest, so the metadata is
# exercised on every build. A root with no .ipk is skipped -- that is how the
# PKG_WHEN gates reach here -- but a missing DEPENDENCY is still opkg's error.
# The two loose python packages are Recommends, which opkg has no field for.
#
# greenlet and cffi are deliberately NOT here: the klipper service execs
# $FF_PYTHON, so they are ordinary Depends of anvil-klipper now. Listed here
# they were installed by every build and by no `opkg install anvil-klipper`,
# which is the one command that has to work on a printer.
MOD_ROOTS="anvil-core anvil-opkg anvil-s6-rc anvil-klipper
           anvil-moonraker anvil-python-pillow anvil-python-preprocess-cancellation
           anvil-mainsail anvil-helixscreen anvil-busybox"

# Named, not versioned -- except anvil-core, whose PKG_VERSION is MOD_VER, so a
# feed built yesterday would install yesterday's anvil-core.
[ -f "$(pkg_ipk anvil-core)" ] || pkg_die \
    "the feed has no $(basename "$(pkg_ipk anvil-core)") -- rerun ./bin/build-packages.sh"

MOD_INSTALL=""
for _p in $MOD_ROOTS; do
    for _f in "$PKG_FEED/${_p}_"*.ipk; do
        if [ -f "$_f" ]; then MOD_INSTALL="$MOD_INSTALL $_p"; fi
        break
    done
done

# The machine's own opkg installs the feed onto its own filesystem: needs a
# privileged container, hence `make build`'s docker lane.
# shellcheck disable=SC2086
./bin/build-payload.py $MOD_INSTALL

say "payload: $(grep -c '^Package:' "$PAYLOAD_DIR/var/lib/opkg/status") packages installed (both chamber configs; the printer picks)"

# --- 1. Klipper
# Nothing is staged here any more: anvil-klipper installs the whole klippy tree
# at $MODDIR/klipper/klippy and the klipper s6-rc service execs it there on our
# own $FF_PYTHON, so the package IS the printer's Klipper. /usr/prog/klipper
# keeps FlashForge's stock klippy, unread -- the only file still read there is
# klipper_pri.sh, their SCHED_FIFO helper. klipperDaemon at that path is a
# symlink to our shim, pointed there by anvil-link-prog.sh.
#
# Nothing is asserted here either. The two gates that were -- a klippy tree at
# $MODDIR/klipper/klippy, and a c_helper.so inside it -- asked whether opkg had
# just installed the package it was handed, of a staging root three lines after
# it was filled. qa/replica/test_install.py::test_klippy_is_present asks it of
# an installed filesystem, and bin/verify.sh asks it of the packed artefact, so
# the same absence is already caught twice on the two vehicles that reach a
# printer. A gate here could only fail on a build that both of those fail on.

# --- 2. Toolchanger
# Gone with section 1: the ff_*.py ride the klippy tree anvil-klipper installs
# and the ff-*.cfg are anvil-klipper-config's, so BUILD_TOOLCHANGE is answered
# entirely by that recipe's PKG_WHEN.

# --- 3. the user's seams
# In the payload and in NO package: a package member is overwritten on every
# upgrade by definition, and this is the user's own file.
[ -f pkgs/moonraker/seed/moonraker-custom.conf ] \
    && cp -f pkgs/moonraker/seed/moonraker-custom.conf "$PAYLOAD_DIR/config/moonraker-custom.conf"

# moonraker.conf ships with pkgs/moonraker, not anvil-core: unconditional, a
# BUILD_MOONRAKER=0 build overwrote the config of a server it did not install.

# --- 5b-2. the s6-rc database
# Compiled in the replica by case-build-payload.sh, with the s6-rc-compile
# anvil-s6-rc ships, straight after opkg installs the feed. It used to be built
# here by a second NATIVE build of the same four tarballs, cached in
# work/.s6-native -- 110 lines whose entire hazard was that both stacks had to
# be --prefix=$MODDIR or the #! baked into the oneshot runner pointed at the
# build host's execline. Compiling with the compiler we SHIP cannot get that
# wrong. (Byte-identical either way: 80-s6-migration.md, measured 2026-08-28.)
#
# So there is nothing left to assert. compiled/current resolving was gated here
# and is gated in bin/verify.sh, which also reads the one thing a host can tell
# about the database -- the execline the oneshot runner's #! names. On a
# machine, qa/replica/test_s6rc.py boots the thing: s6-rc-init reads the
# database, the boot set comes up, and a database moved aside is reported.

# --- 6. SSH
# Nothing to install: the stock rootfs ships dropbear and an enabled
# S50dropbear, so ssh is already listening. Only the password is missing.
if [ -n "${ROOT_PW_HASH:-}" ]; then
    say "SSH: stock dropbear is already running; setting a known root password"
else
    say "SSH: no ROOT_PW_HASH -- the installer will pick a random root password"
    say "     and write it to anvil-password.txt on the USB stick."
    say "     Set ROOT_PW_HASH to choose your own instead."
fi
# --- 7. root password
if [ -n "${ROOT_PW_HASH:-}" ]; then
    say "Accounts: setting root password hash"
    # /etc is a bind mount of /usr/prog/etc, so this is the live shadow dropbear
    # reads at auth time, though it started from the read-only squashfs.
    awk -v h="$ROOT_PW_HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
        "$SOFTWARE_DIR/shadow" > "$SOFTWARE_DIR/shadow.new" && mv -f "$SOFTWARE_DIR/shadow.new" "$SOFTWARE_DIR/shadow"
else
    skip "root password (set ROOT_PW_HASH)"
fi

# --- 8. firmwareExe + start.sh -- anvil-core's, and NOT in the component
# Both install at $MODDIR/prog/ and anvil-link-prog.sh points the stock paths
# at them, on the flash path (run-append.sh) and on `opkg upgrade anvil-core`
# (postinst). Nothing execs either between run.sh copying the component and
# link-prog running, so the component copy bought no ordering -- and it cost:
# our wrapper with no payload never starts a UI, it logs and sleeps for ever,
# turning a failed install into an unbootable printer. Absent, app_startup.sh
# restores a firmwareExe from a version directory and the stock recovery works.
# Stock run.sh is set -x, not set -e, so its two cp lines are noisy no-ops.
say "firmwareExe + start.sh: dropped from the component (anvil-core owns both)"
rm -f "$SOFTWARE_DIR/firmwareExe" "$SOFTWARE_DIR/start.sh"

# --- 10. the install manifest
# Every path this payload installs, so the next update deletes exactly what this
# one left behind -- a renamed init script leaves no stale twin. It names
# ITSELF, and is moved in from a temp file so `find` cannot list a
# half-written manifest.
MOD_MANIFEST=.install-manifest
{ ( cd "$PAYLOAD_DIR" && find . -mindepth 1 | sed 's|^\./||' )
  echo "$MOD_MANIFEST"
} | LC_ALL=C sort -u > work/.install-manifest
mv -f work/.install-manifest "$PAYLOAD_DIR/$MOD_MANIFEST"
say "install manifest: $(wc -l < "$PAYLOAD_DIR/$MOD_MANIFEST") paths -> $MODDIR/$MOD_MANIFEST"

# --- 11. run.sh
# NOTHING, and this is where the mod's install used to reach the printer. Two
# marked blocks were spliced into FlashForge's own run.sh -- one after its
# WORK_DIR line so the backup caught the stock files, one before its final exit
# -- because the software component's run.sh was the ONLY place the stock
# updater would execute anything of ours. That is what the component was for.
#
# installer/runFirmwareExe.sh IS the installer now, run by app_startup.sh
# directly, and bin/pack.sh stages it. The splice, its idempotence markers and
# the component itself all went with it, and FlashForge's run.sh is left doing
# exactly what FlashForge wrote it to do -- on the --full packages that still
# carry a component to run it from.

echo
echo "Patched."
echo "  software component: $(du -sh "$SOFTWARE_DIR" | cut -f1)  (-> /usr/prog, firmware partition)"
echo "  mod payload:        $(du -sh "$PAYLOAD_DIR" | cut -f1)  (-> /usr/data/anvil, data partition)"
echo "Now run ./bin/pack.sh"
