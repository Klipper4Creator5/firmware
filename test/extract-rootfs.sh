#!/usr/bin/env bash
# Extract the printer's REAL root filesystem from the stock update package.
#
# The kernel-*.tar.xz component carries ota_kernel_emmc/ota_v1/rootfs.squashfs
# -- the genuine buildroot rootfs: busybox 1.31.1, /etc/inittab, /etc/init.d
# (including the stock S50dropbear), /usr/sbin/dropbear, the real ash.
#
# test/sim-install.sh uses it to run the installer inside the ACTUAL printer
# userland under qemu-mipsel, where `uname -m` genuinely reports "mips" and
# busybox applets behave exactly as they do on the machine. That is a far
# better test than approximating with a Debian container.
#
# Never committed: it is FlashForge's proprietary firmware.
set -euo pipefail
. "$(dirname "$0")/../bin/common.sh"

command -v unsquashfs >/dev/null 2>&1 || { echo "need squashfs-tools (the build image has it)" >&2; exit 1; }

[ -d work/outer ] || { echo "run bin/unpack.sh first" >&2; exit 1; }
KERN=$(ls -1 work/outer/kernel-*.tar.xz 2>/dev/null | head -n1)
[ -n "$KERN" ] || { echo "no kernel-*.tar.xz in the package (a --slim build has none)" >&2; exit 1; }

rm -rf work/kern work/rootfs
mkdir -p work/kern
tar -xf "$KERN" -C work/kern

SQ=$(find work/kern -name 'rootfs.squashfs*' | head -n1)
[ -n "$SQ" ] || { echo "no rootfs.squashfs inside $KERN" >&2; exit 1; }
echo ">> $(basename "$SQ")"

unsquashfs -q -d work/rootfs "$SQ"
rm -rf work/kern

echo
echo "printer rootfs: work/rootfs"
echo "   busybox: $(work/rootfs/bin/busybox 2>/dev/null | head -1 || echo 'MIPS binary')"
echo "   init.d : $(ls work/rootfs/etc/init.d | tr '\n' ' ')"
echo "   dropbear: $([ -x work/rootfs/usr/sbin/dropbear ] && echo present || echo MISSING)"
