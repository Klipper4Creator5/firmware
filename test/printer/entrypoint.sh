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
/opt/printer/assemble.sh

# A real /usr/prog, if we were given one. It goes in before anything else so
# that nothing -- not the stubs, not the stock installer -- can silently
# shadow a genuine file.
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
if [ -n "${BASE_PKG:-}" ] && [ -f "$BASE_PKG" ]; then
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
if [ -d /payload ]; then
    mkdir -p $R/tmp/payload
    cp -a /payload/. $R/tmp/payload/
fi

# The USB stick.
for spec in ${PKGS:-}; do
    name="${spec%%=*}"; path="${spec#*=}"
    cp "$path" "$R/mnt/$name"
done

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
exit $RC
