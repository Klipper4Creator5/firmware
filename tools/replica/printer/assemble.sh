#!/bin/sh
# Build a working replica of the printer's filesystem at /printer.
#
# Layout mirrors the machine (see /etc/init.d/S09mount_mmc_prog,
# S21mount_mmc_ext4 and /etc/fstab inside the real rootfs):
#
#   /            rootfs.squashfs  -- READ-ONLY, exactly like the printer
#   /usr/prog    ext4 "usershare" partition   (rw)
#   /usr/data    ext4 "userdata"  partition   (rw)
#   /tmp /run    tmpfs
#   /mnt         the USB stick the user plugs in
#
# Mounting / read-only is deliberate: on the printer a write to /bin or /etc
# silently fails, and a mod that depended on one would pass a permissive
# simulation and brick the machine.
set -e

SRC=/printer-src        # the squashfs contents
R=/printer              # the assembled machine
ROOTFS=${ROOTFS:-/rootfs}

[ -d "$ROOTFS/bin" ] || { echo "assemble: no rootfs at $ROOTFS -- the image is built wrong, rebuild it with 'make printer-image'" >&2; exit 1; }

rm -rf $SRC; mkdir -p $SRC $R
rsync -a --exclude=/proc/ --exclude=/sys/ "$ROOTFS/" $SRC/
mkdir -p $SRC/proc $SRC/sys $SRC/tmp $SRC/run $SRC/dev $SRC/mnt \
         $SRC/usr/prog $SRC/usr/data

# These would act on the host kernel, or drive real hardware. Neuter them
# while the tree is still writable, and record every substitution. cmd_mcu is
# in this list because klipper's start.sh calls `cmd_mcu write_firmware` --
# neutering the genuine binary is honest, whereas shadowing it with a stub
# earlier in PATH would depend on PATH order and hide the real one.
NEUTERED=""
for c in insmod rmmod modprobe reboot poweroff halt cmd_mcu; do
    for d in sbin usr/sbin bin usr/bin; do
        [ -e "$SRC/$d/$c" ] || continue
        # These are symlinks into busybox. Writing through one would overwrite
        # the multi-call binary itself and destroy the whole userland.
        rm -f "$SRC/$d/$c"
        printf '#!/bin/sh\n# SIMULATED stub\necho "[sim] %s $*" >> /tmp/sim-neutered.log\nexit 0\n' "$c" > "$SRC/$d/$c"
        chmod +x "$SRC/$d/$c"
        NEUTERED="$NEUTERED /$d/$c"
    done
done

# app_startup.sh mounts the stick with `-o,codepage=936,iocharset=utf8`. The
# printer's kernel has nls_cp936 built in; a container kernel almost never
# does, and the mount then fails with EINVAL -- which would make the boot
# script skip the update and the test pass for the wrong reason. Try the real
# options first and only fall back if the kernel rejects them, so a host that
# CAN do cp936 runs the genuine call.
if [ "${USB_STICK:-0}" = 1 ]; then
    rm -f "$SRC/bin/mount"
    cat > "$SRC/bin/mount" <<'MOUNTSH'
#!/bin/sh
/bin/busybox mount "$@" 2>/tmp/mount.err && exit 0
N=$#; i=0; S=0
while [ $i -lt $N ]; do
    a="$1"; shift
    case "$a" in *codepage=*) a=$(echo "$a" | sed 's/codepage=[0-9]*//g'); S=1 ;; esac
    set -- "$@" "$a"
    i=$((i+1))
done
[ "$S" = 1 ] || { cat /tmp/mount.err >&2; exit 1; }
echo "[sim] mount: kernel has no nls_cp936, retried without codepage=" >> /tmp/sim-neutered.log
exec /bin/busybox mount "$@"
MOUNTSH
    chmod +x "$SRC/bin/mount"
    MOUNT_WRAPPED=1
fi

# --- mount it the way the printer mounts it -----------------------------------
mount --bind $SRC $R
mount -o remount,bind,ro $R           # squashfs is read-only

mount -t proc  proc  $R/proc
mount -t sysfs sys   $R/sys -o ro 2>/dev/null || true
mount -t tmpfs tmpfs $R/tmp -o mode=1777
mount -t tmpfs tmpfs $R/run
# The two ext4 partitions. They are disk-backed rather than tmpfs because a
# real /usr/prog is ~830MB and holding that in RAM is a needless way to make
# the suite fail on a small runner.
#
# Their SIZES are NOT modelled unless you say what they are. The real numbers
# come off the machine (`df -h` over ssh); until PROG_MB/DATA_MB are set from
# it these are unbounded, and an install that runs the machine out of space
# passes here and fails there.
mkdir -p /parts/prog /parts/data
if [ -n "${PROG_MB:-}" ]; then mount -t tmpfs tmpfs $R/usr/prog -o size=${PROG_MB}m
else mount --bind /parts/prog $R/usr/prog; fi                      # "usershare"
if [ -n "${DATA_MB:-}" ]; then mount -t tmpfs tmpfs $R/usr/data -o size=${DATA_MB}m
else mount --bind /parts/data $R/usr/data; fi                      # "userdata"
mount -t tmpfs tmpfs $R/mnt           # the USB stick

mount -t tmpfs tmpfs $R/dev
mkdir -p $R/dev/pts $R/dev/shm
mount -t devpts devpts $R/dev/pts 2>/dev/null || true
mount -t tmpfs  tmpfs  $R/dev/shm
for n in null zero full random urandom tty; do
    : > $R/dev/$n; mount --bind /dev/$n $R/dev/$n 2>/dev/null || rm -f $R/dev/$n
done
: > $R/dev/fb0                        # `cat start.img > /dev/fb0` must work

# ---- the USB stick as a real block device ------------------------------------
# USB_STICK=1 makes /dev/sda1 a genuine FAT filesystem on a loop device, so
# app_startup.sh can run VERBATIM: its own `mount -t vfat /dev/sda1 /mnt` is
# what puts the package in front of the installer. Without this the boot script
# finds no block device, skips the whole update block, and the end-to-end test
# would be testing nothing.
if [ "${USB_STICK:-0}" = 1 ]; then
    [ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237 2>/dev/null || true
    LOOP=$(losetup -f --show /stick.img) || {
        echo "assemble: cannot attach /stick.img to a loop device" >&2; exit 1; }
    MAJ=$(stat -c %t "$LOOP"); MIN=$(stat -c %T "$LOOP")
    mknod "$R/dev/sda1" b "$((0x$MAJ))" "$((0x$MIN))"
    echo "$LOOP" > /stick.loop
fi

# Start the record of everything that is not authentic. seed-prog.sh appends
# to it; entrypoint.sh prints the count on every run.
mkdir -p $R/usr/prog
: > $R/usr/prog/.SIMULATED
for f in $NEUTERED; do
    echo "$f (neutered: would act on the host kernel)" >> $R/usr/prog/.SIMULATED
done
[ "${MOUNT_WRAPPED:-0}" = 1 ] && \
    echo '/bin/mount (wrapped: falls back when the host kernel has no nls_cp936)' \
        >> $R/usr/prog/.SIMULATED

# The rest of the prog partition is seeded by seed-prog.sh, which
# entrypoint.sh runs after any real /usr/prog dump has been unpacked.
exit 0
