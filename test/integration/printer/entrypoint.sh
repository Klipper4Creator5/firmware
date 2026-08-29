#!/bin/sh
# Run a test case inside a replica of the printer, on the printer's own binaries.
#
#   ROOTFS      dir with the extracted rootfs.squashfs        (default /rootfs)
#   PROG_DUMP   a real /usr/prog taken off a printer (tar or dir), used
#               verbatim -- this is what removes the stubs entirely
#   BASE_PKG    stock .tgz to install first, to get an authentic baseline
#   PKGS        "name=/path/to.tgz ..." -- copied onto the simulated USB stick
#   FF_KEY      package encryption key
#   $1          script to execute inside the chroot
#
# Everything after assemble.sh runs under the printer's MIPS busybox via
# qemu-user + binfmt. There is no host shell inside the chroot.
set -e

CASE="${1:?usage: entrypoint.sh <script-to-run-inside-chroot>}"
R=/printer
FF_KEY="${FF_KEY:-FFP0331&*%root}"

/opt/printer/binfmt.sh

# USB_STICK=1 -- build a real FAT filesystem out of the packages before the
# machine is assembled, so app_startup.sh can find and mount it itself. See
# assemble.sh for the loop device, and case-install.sh for what uses it.
if [ "${USB_STICK:-0}" = 1 ]; then
    SZ=64
    for spec in ${PKGS:-}; do
        f="${spec#*=}"
        [ -f "$f" ] || { echo "entrypoint: $f is not there -- nothing to put on the stick" >&2; exit 1; }
        SZ=$((SZ + $(du -m "$f" | cut -f1)))
    done
    dd if=/dev/zero of=/stick.img bs=1M count=$SZ status=none
    mkfs.vfat -n CREATOR5 /stick.img >/dev/null
    mkdir -p /stick
    mount -o loop /stick.img /stick
    for spec in ${PKGS:-}; do
        name="${spec%%=*}"; path="${spec#*=}"
        cp "$path" "/stick/$name"
    done
    ls -l /stick | sed 's/^/printer-sim: stick: /'
    umount /stick
fi

/opt/printer/assemble.sh

# A real /usr/prog, if we were given one. It goes in before anything else so
# that nothing -- the stock installer included -- can silently shadow a genuine
# file. There are no stubs: seed-prog.sh hard-fails rather than substituting
# anything.
if [ -n "${PROG_DUMP:-}" ] && [ -e "$PROG_DUMP" ]; then
    # A dump may be a whole-filesystem factory image rooted at usr/prog/... ,
    # or hold the contents of /usr/prog directly. Decide by what is actually
    # inside it, not by the first entry -- a factory image starts with a bare
    # "usr/" line.
    if [ -d "$PROG_DUMP" ]; then
        if [ -d "$PROG_DUMP/usr/prog" ]; then cp -a "$PROG_DUMP/usr/." $R/usr/
        else cp -a "$PROG_DUMP/." $R/usr/prog/; fi
    elif tar -tf "$PROG_DUMP" 2>/dev/null | head -n 200 | grep -q '^\.\?/\?usr/prog/'; then
        # Extract INTO $R/usr with the leading `usr/` stripped. The archive
        # carries a `usr/` entry of its own and /usr is on the read-only
        # squashfs, so restoring its mode would fail the whole extraction.
        # Stripping it means tar only ever writes to prog/ and data/, which
        # are the writable partition mounts.
        STRIP=1
        tar -tf "$PROG_DUMP" 2>/dev/null | head -n 1 | grep -q '^\./' && STRIP=2
        tar -xf "$PROG_DUMP" -C $R/usr --strip-components=$STRIP
    else
        tar -xf "$PROG_DUMP" -C $R/usr/prog
    fi
    echo "printer-sim: /usr/prog from a real dump ($(basename "$PROG_DUMP"), $(du -sh $R/usr/prog | cut -f1))"
fi

ROOTFS="$ROOTFS" /opt/printer/seed-prog.sh

# Prove we really are on the printer's userland before running anything.
ID="$(chroot $R /bin/busybox sh -c 'echo "$(uname -m) $(busybox 2>&1 | head -1 | cut -d" " -f2)"')"
case "$ID" in
    mips\ v*) ;;
    *) echo "printer-sim: chroot is not the printer userland (got '$ID')" >&2; exit 1 ;;
esac
echo "printer-sim: $ID  (real rootfs, qemu-mipsel)"

# The stock package goes on first: that is the only authentic source for
# /usr/prog/klipper, firmwareExe, unTar, app_startup.sh and friends.
# Already baked into the image? test/integration/build-printer-image.sh installs
# the stock
# package once at build time and records its md5 here, because doing it per run
# costs 37 seconds of qemu and real `sleep` calls for a result that is
# identical every time.
BASELINE_SKIP=0
if [ -n "${BASE_PKG:-}" ] && [ -f "$BASE_PKG" ] && [ "${FORCE_BASELINE:-0}" != 1 ]; then
    HAVE="$(cat $R/usr/prog/.BASELINE 2>/dev/null || true)"
    if [ -n "$HAVE" ] && [ "$HAVE" = "$(md5sum "$BASE_PKG" | cut -d' ' -f1)" ]; then
        echo "printer-sim: stock baseline already in the image ($HAVE)"
        BASELINE_SKIP=1
    elif [ -n "$HAVE" ]; then
        echo "printer-sim: image was baked with a different package ($HAVE) -- reinstalling"
    fi
fi

if [ -n "${BASE_PKG:-}" ] && [ -f "$BASE_PKG" ] && [ "$BASELINE_SKIP" = 0 ]; then
    mkdir -p $R/mnt/base
    openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "$BASE_PKG" | tar -xf - -C $R/mnt/base
    # kernel-* rewrites eMMC partitions and control-* flashes MCUs over
    # /dev/ttyS*. Neither can do anything useful in a container and both are
    # destructive if they ever found real hardware, so the baseline install is
    # software+library only. /dev here has no block devices and /sys is
    # read-only, so even a stray attempt cannot reach a disk.
    rm -f $R/mnt/base/kernel-*.tar.xz $R/mnt/base/control-*.tar.xz
    chmod +x $R/mnt/base/runFirmwareExe.sh
    MACH="$(sed -n 's/^MACHINE=//p' $R/mnt/base/runFirmwareExe.sh | head -1)"
    PID="$(sed -n 's/^PID=//p'     $R/mnt/base/runFirmwareExe.sh | head -1)"
    echo "printer-sim: installing stock baseline ($MACH/$PID)"
    chroot $R /bin/sh /mnt/base/runFirmwareExe.sh "$MACH" "$PID" > $R/tmp/baseline.log 2>&1 || {
        echo "printer-sim: BASELINE stock install failed -- the harness is wrong, not the mod" >&2
        tail -30 $R/tmp/baseline.log >&2; exit 1; }
    rm -rf $R/mnt/base
    echo "printer-sim: baseline installed"
fi

# The mod payload, for cases that exercise it directly rather than through an
# installed package.
#
# ASSEMBLED FROM THREE MOUNTS, because the repository files it draws on live
# with the recipes that own them: anvil-core's $MODDIR overlay, its
# anvil.conf template (which the build normally renders from config.env --
# here the unrendered defaults are exactly what the cases want), and
# Klipper's start.sh, which is a /usr/prog file and so lives in prog/.
# The assembled tree is what /tmp/payload has always been; see the comment on
# the mounts in qa/lib/replica.py.
if [ -d /payload ]; then
    mkdir -p $R/tmp/payload
    cp -a /payload/. $R/tmp/payload/
    [ -f /payload-seed/anvil.conf.in ] \
        && cp -f /payload-seed/anvil.conf.in $R/tmp/payload/anvil.conf
    [ -f /payload-klipper/start.sh ] \
        && cp -f /payload-klipper/start.sh $R/tmp/payload/start.sh
fi

# The USB stick. In USB_STICK mode it is already a FAT filesystem on
# /dev/sda1 and the boot script mounts it itself; here we would only be
# handing the case script a shortcut it must not have.
if [ "${USB_STICK:-0}" != 1 ]; then
    for spec in ${PKGS:-}; do
        name="${spec%%=*}"; path="${spec#*=}"
        cp "$path" "$R/mnt/$name"
    done
fi

# Say out loud what is not authentic, every run. A simulation that hides its
# own substitutions is how a test ends up proving nothing.
N=$(wc -l < $R/usr/prog/.SIMULATED 2>/dev/null || echo 0)
echo "printer-sim: $N simulated pieces (/usr/prog/.SIMULATED)"
[ "${SIM_VERBOSE:-0}" = 1 ] && sed 's/^/            /' $R/usr/prog/.SIMULATED || true

cp "$CASE" $R/tmp/case.sh
chmod +x $R/tmp/case.sh
set +e
chroot $R /bin/sh /tmp/case.sh
RC=$?
set -e

# DETACH THE STICK'S LOOP DEVICE. assemble.sh attaches /stick.img with
# `losetup -f --show` and records the device in /stick.loop, and until this
# existed nothing ever read that file. Loop devices are the HOST's -- they are
# not namespaced -- so every USB_STICK=1 run leaked one permanently, and a
# WSL2 kernel has thirteen. Once they were gone every replica run failed with
# "failed to setup loop device", which looks like a docker problem and is not.
# `mount -o loop` would autoclear; `losetup` does not, so it has to be here.
if [ -f /stick.loop ]; then
    umount "$R/mnt" 2>/dev/null || true
    losetup -d "$(cat /stick.loop)" 2>/dev/null || true
fi

exit $RC
