#!/usr/bin/env bash
# Parse every on-printer script with the PRINTER'S OWN busybox ash.
#
# The payload runs under busybox 1.31.1 ash on MIPS, not under bash or dash.
# `sh -n` on a build machine catches only some of the difference. Here we run
# the genuine /bin/busybox out of the printer's real rootfs under qemu-mipsel,
# so a construct that busybox rejects is caught before it ever reaches the
# machine -- where a parse error in firmwareExe means a blank screen.
#
# No binfmt registration and no chroot are needed: `busybox sh -n` is a single
# process and forks nothing, so plain `qemu-mipsel-static -L` is enough.
#
# It runs inside the printer replica image, which already carries
# qemu-user-static -- and, when PRINTER_IMAGE is set, the rootfs too. The
# earlier version started a bare debian container and apt-installed qemu on
# every single run, which made a local syntax check depend on the network.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RFS="$ROOT/work/rootfs"

DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
command -v $DOCKER >/dev/null 2>&1 || { echo "  SKIP: docker not available"; exit 0; }
$DOCKER info >/dev/null 2>&1 || { echo "  SKIP: docker daemon not running"; exit 0; }

IMAGE="${PRINTER_IMAGE:-}"
MOUNT=()
if [ -n "$IMAGE" ]; then
    :                                   # the image carries /rootfs itself
elif [ -f "$RFS/bin/busybox" ]; then
    IMAGE=creator5-printer-sim
    MOUNT=(-v "$RFS:/rootfs:ro")
    $DOCKER build -q -t "$IMAGE" -f "$ROOT/test/printer/Dockerfile" "$ROOT/test/printer" >/dev/null \
        || { echo "  FAIL: could not build $IMAGE"; exit 1; }
else
    echo "  SKIP: no printer rootfs -- run 'make rootfs' (needs the stock package),"
    echo "        or set PRINTER_IMAGE to a prebuilt printer image"
    exit 0
fi

$DOCKER run --rm -i --entrypoint sh \
    "${MOUNT[@]}" \
    -v "$ROOT/payload:/payload:ro" \
    "$IMAGE" -s <<'INNER'
set -u
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }

ASH="qemu-mipsel-static -L /rootfs /rootfs/bin/busybox"

V=$($ASH 2>&1 | head -1)
echo "  using: $(echo "$V" | cut -c1-46)"
[ "$($ASH uname -m 2>/dev/null)" = mips ] \
    && ok "genuine MIPS userland (uname -m = mips)" \
    || bad "not running the printer userland"

echo
for f in /payload/firmwareExe /payload/start.sh /payload/run-pre.sh \
         /payload/run-append.sh /payload/init.d/S*; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    if $ASH sh -n "$f" 2>/tmp/err; then
        ok "parses under busybox ash: $n"
    else
        bad "busybox ash REJECTS $n"
        head -3 /tmp/err | sed 's/^/        /'
    fi
done

echo
echo "  -- applet behaviour the payload and the stock installer depend on --"
$ASH ps >/dev/null 2>&1 && ok "busybox ps available (UI liveness check)" \
                        || bad "no busybox ps -- the UI liveness check degrades"
$ASH head -c 2 /rootfs/bin/busybox >/dev/null 2>&1 \
    && ok "busybox head -c available (used to detect our wrapper script)" \
    || bad "busybox head -c missing"

# FlashForge's own runFirmwareExe.sh slices the version out of a filename with
# ${file_name:${#start_head}:${version_length}} -- a bash-compat expansion that
# dash rejects. The stock installer only works because this busybox was built
# with ASH_BASH_COMPAT. If a future firmware ships a busybox without it, the
# stock updater breaks and so does ours.
SUB=$($ASH sh -c 'v=software-1.9.7.tar.xz; echo ${v:9:5}' 2>/dev/null)
[ "$SUB" = "1.9.7" ] \
    && ok "busybox ash supports \${var:off:len} (the stock installer needs it)" \
    || bad "busybox ash lacks bash-compat substrings -- the STOCK installer would fail too"

# The payload has no `timeout` anywhere for a reason: this busybox has no such
# applet. Assert the absence, so nobody 'fixes' a script by adding one.
$ASH timeout 1 true >/dev/null 2>&1 \
    && echo "        (this busybox DOES have timeout -- test/applets.allow can be relaxed)" \
    || ok "no timeout applet, as expected (the payload must not use one)"

echo
[ "$FAIL" = 0 ] && echo "  payload is busybox-ash clean" || echo "  ASH CONFORMANCE FAILED"
exit $FAIL
INNER
