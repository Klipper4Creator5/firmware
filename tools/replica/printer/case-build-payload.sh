#!/bin/sh
# Build $MODDIR the way a printer would, and hand it back on /out.
#
# bin/patch.sh's section 0, run on the machine it is for: the printer's own
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
# bin/patch.sh so the two cannot drift.
[ -n "${MOD_ROOTS:-}" ] || { echo "payload: MOD_ROOTS is empty" >&2; exit 1; }
$OPKG install $MOD_ROOTS
echo "payload: $($OPKG list-installed | wc -l) packages installed"

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
