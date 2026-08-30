#!/bin/sh
# Build $MODDIR the way a printer would, and hand it back on /out.
#
# bin/payload.sh's section 0, run on the machine it is for: the printer's own
# opkg installs onto the printer's own filesystem, so the postinsts execute
# under qemu-mipsel against the paths they will see on a machine.
#
# The feed arrives on the simulated USB stick at /mnt -- .ipk files and the
# Packages index that bin/build-packages.sh wrote beside them.
set -e

PREFIX=/usr/data/anvil
OPKG=$PREFIX/bin/opkg
FEED=/mnt

echo "payload: $(uname -m), busybox $(busybox 2>&1 | head -1 | cut -d' ' -f2)"

# --- bootstrap opkg -------------------------------------------------------
# The package manager is one of the packages, so the first one is unpacked by
# hand. `ar -x` fails on this busybox with "unrecognized file type" while
# `ar -p` works, and /bin/tar is not busybox tar and has no -z. The subtree is
# named rather than unpacking at /, because the archive carries a ./usr/ entry
# of its own and / here is the read-only squashfs, exactly as on the machine.
IPK=$(ls $FEED/anvil-opkg_*.ipk 2>/dev/null | head -1)
[ -n "$IPK" ] || { echo "payload: no anvil-opkg_*.ipk in the feed" >&2; exit 1; }
ar -p "$IPK" data.tar.gz | gunzip | tar -xf - -C / ./usr/data/anvil
[ -x "$OPKG" ] || { echo "payload: $OPKG did not appear" >&2; exit 1; }

# arch: opkg's built-in list is `arch mips 10` and the feed builds
# mipsel_xburst2, so without this every package is refused as "incompatible
# architecture". No lists_dir line -- 0.7.0 rejects it as invalid.
mkdir -p $PREFIX/etc/opkg
cat > $PREFIX/etc/opkg/anvil.conf <<EOF
arch all 1
arch noarch 1
arch $IPK_ARCH 10
dest root /
src anvil file:$FEED
EOF
$OPKG update >/dev/null

# --- install the release ---------------------------------------------------
# Roots, not a closure: Depends brings the rest, which is the same question an
# `opkg install anvil-moonraker` on a printer asks. MOD_ROOTS comes in from
# bin/payload.sh so the two cannot drift.
[ -n "${MOD_ROOTS:-}" ] || { echo "payload: MOD_ROOTS is empty" >&2; exit 1; }
$OPKG install $MOD_ROOTS
echo "payload: $($OPKG list-installed | wc -l) packages installed"

# --- compile the boot database ---------------------------------------------
# WITH THE s6-rc-compile WE SHIP, on the machine it is for, right after the
# packages that own the source tree landed. bin/payload.sh used to do this on the
# build host, which meant a second NATIVE build of skalibs+execline+s6+s6-rc
# whose only job was to produce a compiler -- and whose whole hazard was that
# s6-rc-compile bakes the #! of the execline the COMPILER was linked against
# into the oneshot runner. Get that native --prefix wrong and every oneshot on
# the printer dies with ENOENT. Here the compiler IS the shipped one, so the
# shebang it writes is the one we ship by construction.
#
# The two agree byte for byte: docs/notes/80-s6-migration.md records the
# 2026-08-28 measurement -- one source tree, the host compiler and the target
# one under qemu, identical db, n and resolve.cdb and identical servicedirs.
#
# compiled/<stamp> with `current` a symlink, so the boot command never changes
# when the database does. Not /etc/s6-rc/, s6-rc-init's default, which is
# inside the read-only squashfs.
S6RC_SRC=$PREFIX/etc/s6-rc/source
S6RC_DB=db-${MOD_VER:-0}
[ -d "$S6RC_SRC" ] || { echo "payload: no s6-rc source at $S6RC_SRC -- anvil-core did not install" >&2; exit 1; }
[ -x $PREFIX/bin/s6-rc-compile ] || { echo "payload: no $PREFIX/bin/s6-rc-compile -- anvil-s6-rc did not install" >&2; exit 1; }
rm -rf $PREFIX/etc/s6-rc/compiled
mkdir -p $PREFIX/etc/s6-rc/compiled
$PREFIX/bin/s6-rc-compile $PREFIX/etc/s6-rc/compiled/$S6RC_DB "$S6RC_SRC" \
    || { echo "payload: s6-rc-compile refused $S6RC_SRC" >&2; exit 1; }
ln -sfn $S6RC_DB $PREFIX/etc/s6-rc/compiled/current
echo "payload: s6-rc database $S6RC_DB compiled -- `ls "$S6RC_SRC" | wc -l` definitions"

# --- make it shippable -----------------------------------------------------
# Installing from a file: feed leaves the cache full of SYMLINKS into the
# feed directory rather than copies, so shipping it would put dangling links
# on every printer. The lists and the feed-specific opkg.conf are just as
# meaningless there.
rm -rf $PREFIX/var/cache $PREFIX/var/lib/opkg/lists $PREFIX/etc/opkg

# The one clock opkg writes. bin/build-packages.sh builds every .ipk with
# SOURCE_DATE_EPOCH, so this is the only field that would differ between two
# builds of one commit.
sed -i "s/^Installed-Time: .*/Installed-Time: ${SOURCE_DATE_EPOCH:-1}/" \
    $PREFIX/var/lib/opkg/status

# -C /usr/data so the members are anvil/..., and made by the printer's own tar
# so the modes and symlinks in it are the ones the machine produced.
tar -cf /out/payload.tar -C /usr/data anvil
echo "payload: $(tar -tf /out/payload.tar | wc -l) members -> /out/payload.tar"
