#!/bin/sh
# Install the mod package into /parts ONCE, and leave the container ready to
# be committed as an image that IS a printer with the mod on it.
#
# Modelled on tools/replica/printer/bake.sh, which does the same for the STOCK
# baseline: the install needs binfmt_misc and chroot, so it needs
# --privileged, so it cannot happen in a `docker build` step. The caller runs
# this in a container and commits the result.
#
# The install itself is /case.sh (install-package.sh), which boots the
# machine's own app_startup.sh. Nothing re-implements the update.
#
#   PKGS       "name=/pkgs/name" -- entrypoint.sh puts it on the FAT stick
#   USB_STICK  must be 1, so the package arrives the way it really arrives
set -e

[ "${USB_STICK:-0}" = 1 ] || {
    echo "qa-bake: USB_STICK must be 1 -- the package has to arrive on a real" >&2
    echo "         FAT filesystem, because that is the path app_startup.sh" >&2
    echo "         actually takes. Handing it over any other way would test a" >&2
    echo "         route no printer has." >&2
    exit 1
}

/opt/printer/entrypoint.sh /case.sh

# Unwind, so the committed image has no leftovers from the bake. /parts is a
# plain directory that was bind-mounted into the chroot; unmounting leaves the
# installed files exactly where the next run expects them.
umount -R /printer 2>/dev/null || umount -l /printer 2>/dev/null || true
# Deliberately no `rm -rf /printer`: if the unmount above ever failed, that
# would delete the partitions this whole image exists to carry.
rmdir /printer 2>/dev/null || true
rm -rf /printer-src /stick.img /stick /tmp/case.sh

# Prove the install actually landed in the partition that survives the commit.
# Without this a bake whose chroot was unmounted early would commit a stock
# machine under a name that says otherwise, and every test built on it would
# be asserting against firmware it was not told it had.
[ -d /parts/data/anvil ] || {
    echo "qa-bake: nothing at /parts/data/anvil -- the install did not reach" >&2
    echo "         the userdata partition, so there is nothing to commit." >&2
    exit 1
}
echo "qa-bake: mod installed, $(ls /parts/data/anvil | tr '\n' ' ')"
