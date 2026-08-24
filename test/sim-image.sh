# Sourced by the replica launchers (printer-exec.sh, test-ash-conformance.sh).
# One place for the docker plumbing they used to duplicate. Needs $ROOT set;
# leaves $DOCKER, $IMAGE and $PREBUILT defined.
#
#   skip()     A skip here is a test that did not run. That is fine on a
#              laptop and fatal in a release, so REQUIRE_PRINTER_SIM=1 turns
#              every skip into a failure -- for EVERY launcher, not just the
#              install simulation.
#   IMAGE      PRINTER_IMAGE names a prebuilt image that already carries the
#              firmware (rootfs, /usr/prog, /usr/data -- see
#              test/build-printer-image.sh); PREBUILT=1 then. Otherwise the
#              local sim image is built from test/printer/Dockerfile, which
#              needs the extracted rootfs at work/rootfs.

skip() {
    if [ "${REQUIRE_PRINTER_SIM:-0}" = 1 ]; then echo "  FAIL: $*" >&2; exit 1; fi
    echo "  SKIP: $*"; exit 0
}

DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
command -v $DOCKER >/dev/null 2>&1 || skip "docker not available"
$DOCKER info >/dev/null 2>&1 || skip "docker daemon not running"

IMAGE="${PRINTER_IMAGE:-}"
PREBUILT=1
if [ -z "$IMAGE" ]; then
    PREBUILT=0
    IMAGE=creator5-printer-sim
    if [ ! -d "$ROOT/work/rootfs/bin" ]; then
        skip "no printer rootfs -- run 'make rootfs' first (needs the stock package),
        or set PRINTER_IMAGE to a prebuilt printer image"
    fi
    # Always rebuild: it is a cache hit in about a second, and a stale image
    # silently testing yesterday's harness is not a trade worth making.
    $DOCKER build -q -t "$IMAGE" -f "$ROOT/test/printer/Dockerfile" "$ROOT/test/printer" >/dev/null \
        || { echo "  FAIL: could not build $IMAGE"; exit 1; }
fi
