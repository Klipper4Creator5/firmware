#!/bin/sh
# The replica's stock entrypoint, with a writable /out inside the chroot.
#
# WHY A WRAPPER. /opt/printer/entrypoint.sh assembles the machine and then, as
# its last act, runs the case under `chroot /printer`. There is no hook
# afterwards, so a case that BUILDS something has no way to hand it back.
#
# AND WHY THE MOUNT IS NOT `docker run -v ...:/printer/out`. assemble.sh binds
# /printer-src onto /printer and remounts it read-only, and a bind does not
# carry the submounts underneath it -- a docker mount at /printer/out is
# buried the moment the machine is assembled, silently, leaving an empty
# directory. Mounting at /printer-src/out instead trips the `rm -rf
# /printer-src` assemble.sh opens with.
#
# So the mount belongs between assemble.sh and the case. Running the stock
# entrypoint with a case that does nothing makes that seam.
set -e

CASE="${1:?usage: entrypoint-out.sh <script-to-run-inside-chroot>}"
R=/printer

printf '#!/bin/sh\nexit 0\n' > /tmp/noop.sh
chmod +x /tmp/noop.sh
/opt/printer/entrypoint.sh /tmp/noop.sh

# The mountpoint is made through /printer-src, the writable side of the same
# bind: creating it under /printer directly would be a write to a read-only
# mount. The bind itself is fine over a read-only parent -- a mount is not a
# write to the filesystem it lands on, and it carries its own flags.
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
# own scratch directory.
if [ -n "${OUT_UID:-}" ]; then
    chown -R "$OUT_UID:${OUT_GID:-$OUT_UID}" /out 2>/dev/null || true
fi
exit $RC
