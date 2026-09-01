#!/bin/sh
# Build $MODDIR the way a printer would, and hand it back on /out.
#
# bin/payload.sh's section 0, run on the machine it is for: the printer's own
# apk installs onto the printer's own filesystem, so the maintainer scripts
# execute under qemu-mipsel against the paths they will see on a machine. The
# feed arrives on the simulated USB stick at /mnt.
set -e

PREFIX=/usr/data/anvil
FEED=/mnt

echo "payload: $(uname -m), busybox $(busybox 2>&1 | head -1 | cut -d' ' -f2)"

# --- bootstrap the package manager ------------------------------------------
# It is one of the packages, so the first one cannot be installed the usual
# way.
[ -n "${MOD_ROOTS:-}" ] || { echo "payload: MOD_ROOTS is empty" >&2; exit 1; }

# THE BINARY COMES ON THE STICK, NOT OUT OF A PACKAGE. A v3 .apk is an ADB
# stream, not a tar -- `tar` refuses it, measured -- so there is no way to
# open one without an apk. bin/build-payload.py puts the cross-built binary
# at /mnt/apk.
#
# It is the same build that anvil-apk-tools contains, and that package is
# an ordinary member of MOD_ROOTS, so the tree that ships still holds the
# PACKAGED copy with a database row to match. This one never lands.
APK=$FEED/apk
[ -x "$APK" ] || { echo "payload: no bootstrap apk at $APK" >&2; exit 1; }

# The repositories entry NAMES THE INDEX FILE, and that is what keeps the
# feed flat: apk reads a path ending .adb as a v3 index in place, with the
# packages as its siblings. A bare directory would send it looking for
# <dir>/<arch>/Packages.adb instead.
#
# ON THE STICK AND NOT AT $PREFIX/etc/apk/repositories, which is the path apk
# reads by default and which anvil-core OWNS: it ships that file pointing at
# the network feed, and a build that wrote its own copy there would either be
# overwritten mid-install or have to delete the package's afterwards. With
# --repositories-file apk reads this one and nothing else (database.c: the
# default file and repositories.d are consulted only when no file is named),
# so what the payload ships is whatever anvil-core installed, unread here.
mkdir -p $PREFIX/etc/apk
BOOTSTRAP_REPOS=/tmp/anvil-bootstrap-repositories
echo "$FEED/anvil.adb" > $BOOTSTRAP_REPOS

# THE TRUST DIRECTORY IS SEEDED FROM THE STICK, when the feed is signed.
# anvil-core ships the same public key so a printer keeps it, but
# anvil-core is one of the packages being installed -- at this point
# nothing has been installed yet, so there is nowhere apk could have read
# it from. Absent, the feed is unsigned and installs untrusted; that is a
# supported configuration and the reason this is a branch.
UNTRUSTED=--allow-untrusted
if [ -f $FEED/anvil.pub ]; then
    mkdir -p $PREFIX/etc/apk/keys
    cp $FEED/anvil.pub $PREFIX/etc/apk/keys/
    UNTRUSTED=
    echo "payload: feed is signed -- verifying against $(basename $FEED/anvil.pub)"
fi

# --arch: the compiled-in arch is the bare `mipsel`, so a package built for
# this feed's name is refused as uninstallable without it. Written into the
# database once by --initdb, not repeated on every command.
# shellcheck disable=SC2086
$APK --initdb --repositories-file $BOOTSTRAP_REPOS $UNTRUSTED --arch "$IPK_ARCH" add
# shellcheck disable=SC2086
$APK --repositories-file $BOOTSTRAP_REPOS $UNTRUSTED add $MOD_ROOTS
# --repositories-file HERE TOO, on a command that reads no repository: by now
# anvil-core has installed the one naming the network feed, and without this
# `apk info` tries to fetch it and warns that a host which does not exist yet
# is unreachable. It is only a warning -- measured, and the reason a URL can
# ship before its host -- but a build that reaches for the network is not one
# whose output depends on whether it had any.
echo "payload: $($APK --repositories-file $BOOTSTRAP_REPOS info | wc -l) packages installed"

# --- compile the boot database ---------------------------------------------
# WITH THE s6-rc-compile WE SHIP, on the machine it is for, right after the
# packages that own the source tree landed. s6-rc-compile bakes the #! of the
# execline the COMPILER was linked against into the oneshot runner, so a
# native compiler built with the wrong --prefix kills every oneshot on the
# printer with ENOENT. Here the compiler IS the shipped one, so the shebang is
# right by construction. (Byte-identical to the host-compiled database;
# measured 2026-08-28, docs/notes/80-s6-migration.md.)
#
# compiled/<stamp> with `current` a symlink, so the boot command never changes
# when the database does. Not s6-rc-init's default /etc/s6-rc/, which is
# inside the read-only squashfs.
#
# THROUGH THE SCRIPT anvil-core SHIPS, which the postinsts of anvil-core and
# anvil-s6-rc also call, so an `opkg upgrade` on a printer compiles the
# database the same way this does. Naming the database here is what keeps the
# payload reproducible: given a name the script removes every other database,
# so the timestamped ones those postinsts just wrote do not ship.
S6RC_SRC=$PREFIX/etc/s6-rc/source
S6RC_DB=db-${MOD_VER:-0}
S6RC_COMPILE=$PREFIX/bin/anvil-s6-rc-compile.sh
[ -d "$S6RC_SRC" ] || { echo "payload: no s6-rc source at $S6RC_SRC -- anvil-core did not install" >&2; exit 1; }
[ -x $PREFIX/bin/s6-rc-compile ] || { echo "payload: no $PREFIX/bin/s6-rc-compile -- anvil-s6-rc did not install" >&2; exit 1; }
[ -x "$S6RC_COMPILE" ] || { echo "payload: no $S6RC_COMPILE -- anvil-core did not install" >&2; exit 1; }
"$S6RC_COMPILE" "$S6RC_DB" \
    || { echo "payload: s6-rc-compile refused $S6RC_SRC" >&2; exit 1; }
echo "payload: s6-rc database $S6RC_DB compiled -- `ls "$S6RC_SRC" | wc -l` definitions"

# --- make it shippable -----------------------------------------------------
# Installing from a file: feed leaves the cache full of SYMLINKS into the feed
# directory rather than copies, so shipping it would put dangling links on
# every printer.
#
# $PREFIX/etc/apk/repositories STAYS, and used to be deleted here: it named
# /mnt, a USB stick that will not be there. It now comes out of anvil-core
# naming the network feed (bin/common.sh's $FEED_URL), so it is a package
# member like any other and deleting it would ship a printer that has no idea
# where its updates come from.
#
# $PREFIX/var IS THE BUILD'S, NOT THE PRINTER'S. apk opens
# <root>/var/log/apk.log whenever it writes (src/context.c) and records
# every operation with a timestamp, so shipping it would put this build's
# clock and this build's install transcript on every machine. The whole
# directory goes rather than the log alone: nothing else of ours lives
# there now that the database is under lib/apk, and an empty var/ in the
# payload is a directory no package owns. apk recreates what it needs at
# the first real operation on the printer.
rm -rf $PREFIX/var

# NO CLOCK TO NORMALISE, and that is a property rather than an omission:
# apk records no install time, and mkpkg sets no build-time, so
# $PREFIX/lib/apk/db/installed carries no `t:` line at all. Measured.
# qa/static/test_apk.py asserts the absence rather than trusting this
# comment.

# -C /usr/data so the members are anvil/..., and made by the printer's own tar
# so the modes and symlinks in it are the ones the machine produced.
tar -cf /out/payload.tar -C /usr/data anvil
echo "payload: $(tar -tf /out/payload.tar | wc -l) members -> /out/payload.tar"
