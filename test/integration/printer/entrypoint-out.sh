#!/bin/sh
# The replica's stock entrypoint, with a writable /out inside the chroot.
#
# WHY A WRAPPER AT ALL. /opt/printer/entrypoint.sh assembles the machine and
# then, as the last thing it does, runs the case script under `chroot
# /printer`. Everything it mounts is arranged before that; there is no hook
# afterwards and nothing of ours inside. So a case that BUILDS something --
# the payload, installed by the printer's own opkg -- has no way to hand it
# back.
#
# WHY THE MOUNT CANNOT SIMPLY BE `docker run -v ...:/printer/out`. assemble.sh
# binds /printer-src onto /printer and remounts it read-only, and a bind mount
# does not carry the submounts underneath it. A docker mount at /printer/out
# is buried the moment the machine is assembled: the directory is still there,
# still empty, and nothing reports an error. Mounting at /printer-src/out
# instead trips the `rm -rf /printer-src` assemble.sh opens with, which cannot
# unlink a busy mountpoint and takes the run down with it.
#
# So the mount has to happen AFTER assemble.sh and BEFORE the case, and the
# stock entrypoint offers no seam between the two. Running it with a case that
# does nothing makes one: it leaves the assembled machine behind at /printer,
# and the mount and the real case follow. Only the last four lines are copied
# from it -- everything that builds the replica is still the stock script.
set -e

CASE="${1:?usage: entrypoint-out.sh <script-to-run-inside-chroot>}"
R=/printer

printf '#!/bin/sh\nexit 0\n' > /tmp/noop.sh
chmod +x /tmp/noop.sh
/opt/printer/entrypoint.sh /tmp/noop.sh

# The mountpoint is made through /printer-src, the writable side of the same
# bind: creating it under /printer directly would be a write to a read-only
# mount. The bind itself is fine over a read-only parent -- a mount is not a
# write to the filesystem it lands on, and it carries its own flags, so /out
# is read-write inside a root that is not.
mkdir -p /printer-src/out
mount --bind /out $R/out

cp "$CASE" $R/tmp/case.sh
chmod +x $R/tmp/case.sh
set +e
chroot $R /bin/sh /tmp/case.sh
RC=$?
set -e

# Hand the results to the invoking user rather than to root. The replica runs
# privileged, so anything it writes to the bind mount lands root-owned in the
# repo -- and the build lane, which runs as the caller, then cannot delete its
# own scratch directory. OUT_UID/OUT_GID are set by ffsim/replica.py.
if [ -n "${OUT_UID:-}" ]; then
    chown -R "$OUT_UID:${OUT_GID:-$OUT_UID}" /out 2>/dev/null || true
fi
exit $RC
