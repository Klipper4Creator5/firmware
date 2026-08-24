#!/bin/sh
# Teach the kernel to run the printer's binaries.
#
# The stock qemu-mipsel binfmt registration does NOT match them: its mask
# requires e_ident[EI_ABIVERSION] (byte 8) to be 0, and every binary the
# Ingenic toolchain produced for this printer has 3 there.  That single byte is
# why `exec format error` happens even with qemu installed and registered.
# Our handler masks byte 8 out; everything else is the stock mipsel matcher.
#
# Requires --privileged (or CAP_SYS_ADMIN + the binfmt_misc mount).
set -e

BF=/proc/sys/fs/binfmt_misc
NAME=c5printer
QEMU=/usr/bin/qemu-mipsel-static

[ -x "$QEMU" ] || { echo "binfmt: $QEMU missing" >&2; exit 1; }

if [ ! -f "$BF/register" ]; then
    mount -t binfmt_misc binfmt_misc "$BF" 2>/dev/null \
        || { echo "binfmt: cannot mount binfmt_misc -- run the container --privileged" >&2; exit 1; }
fi

if [ "${BINFMT_RESET:-0}" = 1 ] && [ -f "$BF/$NAME" ]; then
    echo -1 > "$BF/$NAME"
fi

if [ ! -f "$BF/$NAME" ]; then
    #        7f E  L  F  |32 |LE |v1 |os |abiver.....pad............|type |mach
    MAGIC='\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x08\x00'
    #                              ^^^^ osabi and abiversion are don't-care
    MASK='\xff\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\x00\x00\x00\x00\x00\xfe\xff\xff\xff'
    # F = interpreter is opened NOW and kept, so it resolves inside the chroot
    #     without copying qemu into the printer's filesystem.
    # O = pass the binary as an fd,  C = compute credentials from the binary.
    echo ":$NAME:M::$MAGIC:$MASK:$QEMU:OCF" > "$BF/register"
fi

grep -q '^enabled' "$BF/$NAME" || { echo "binfmt: $NAME registered but disabled" >&2; exit 1; }
