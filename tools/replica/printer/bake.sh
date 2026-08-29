#!/bin/sh
# Install the stock package into /parts ONCE, at image build time.
#
# Doing it per-run costs 37 seconds -- the stock installer is shell, running
# under qemu, and it sleeps for real. Doing it here means the published image
# already IS a machine that has had this firmware installed by FlashForge's own
# updater, and a test run starts in under a second.
#
# This cannot happen in a `docker build` step: the install needs binfmt_misc
# and chroot, so it needs --privileged. tools/replica/build-printer-image.sh
# runs this
# in a container and commits the result.
#
#   BASE_PKG      the stock .tgz to install
#   BASELINE_ID   what to record in /usr/prog/.BASELINE
set -e

[ -f "${BASE_PKG:-}" ] || { echo "bake: BASE_PKG is not a file" >&2; exit 1; }

BASELINE_ID="${BASELINE_ID:-$(md5sum "$BASE_PKG" | cut -d' ' -f1)}"
export BASELINE_ID

FORCE_BASELINE=1 /opt/printer/entrypoint.sh /opt/printer/bake-case.sh

# Unwind, so the committed image has no leftovers from the bake. /parts is a
# plain directory that was bind-mounted into the chroot; unmounting leaves the
# installed files exactly where the next run expects them.
umount -R /printer 2>/dev/null || umount -l /printer 2>/dev/null || true
# Deliberately no `rm -rf /printer`: if the unmount above ever failed, that
# would delete the partitions this whole image exists to carry.
rmdir /printer 2>/dev/null || true
rm -rf /printer-src /stick.img /stick /tmp/case.sh

[ -s /parts/prog/.BASELINE ] || { echo "bake: no baseline marker was written" >&2; exit 1; }
echo "bake: baseline installed, marker $(cat /parts/prog/.BASELINE)"
