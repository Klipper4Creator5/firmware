#!/usr/bin/env bash
# Host-side launcher for the printer replica.
#
#   test/printer-exec.sh <case-script> [name=package.tgz ...]
#
# The case script is executed by the printer's own busybox inside a chroot of
# the real extracted rootfs.squashfs, with MIPS binaries running under
# qemu-user. Named packages appear on the simulated USB stick as /mnt/<name>.
#
# BASE_PKG=<stock .tgz> installs stock firmware first, so /usr/prog holds the
# genuine klipper tree, unTar, app_startup.sh and firmwareExe rather than
# hand-written fakes.
#
# USB_STICK=1 puts the packages on a real FAT filesystem exposed as /dev/sda1
# instead of dropping them into /mnt, so the case script can let the printer's
# own app_startup.sh discover and mount them. Required by case-install.sh.
#
# PROG_DUMP=<tar or dir> supplies a real /usr/prog taken off a printer
# (`tar -cf /mnt/prog.tar /usr/prog` over ssh). With one, the replica has no
# invented files left at all.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE="${1:?usage: printer-exec.sh <case-script> [name=pkg.tgz ...]}"; shift

# A skip here is a test that did not run. That is fine on a laptop and fatal
# in a release, so REQUIRE_PRINTER_SIM=1 turns every skip into a failure.
skip() {
    if [ "${REQUIRE_PRINTER_SIM:-0}" = 1 ]; then echo "  FAIL: $*" >&2; exit 1; fi
    echo "  SKIP: $*"; exit 0
}

DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
command -v $DOCKER >/dev/null 2>&1 || skip "docker not available"
$DOCKER info >/dev/null 2>&1 || skip "docker daemon not running"

# PRINTER_IMAGE names a prebuilt image that already carries the firmware --
# rootfs, /usr/prog and /usr/data baked in by test/build-printer-image.sh. With
# one, nothing local is needed and a run skips the unpack entirely.
IMAGE="${PRINTER_IMAGE:-}"
PREBUILT=1
if [ -z "$IMAGE" ]; then
    PREBUILT=0
    # Say why this is about to be slow. Unpacking the factory image is ~22s
    # and installing the stock baseline is ~37s, on EVERY case; the published
    # image has both done already and starts in under a second.
    echo "  printer-sim: PRINTER_IMAGE is not set, so the replica is being built" >&2
    echo "               locally -- about a minute of setup per test case. Set" >&2
    echo "               PRINTER_IMAGE=monstrofil/creator5-printer:latest in" >&2
    echo "               test.env to skip it." >&2
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

# Stage every input inside the repo: the docker daemon resolves bind-mount
# paths on the host, and the repo is the one directory guaranteed to exist
# there under the same name.
# Per-process, so two suites running at once cannot delete each other's
# staged packages half way through a run.
STAGE="$ROOT/work/.sim-$$"
rm -rf "$STAGE"; mkdir -p "$STAGE/pkgs"
trap 'rm -rf "$STAGE"' EXIT      # the staged packages are ~80MB each
cp "$CASE" "$STAGE/case.sh"

PKGS=""
for spec in "$@"; do
    name="${spec%%=*}"; path="${spec#*=}"
    cp "$path" "$STAGE/pkgs/$name"
    PKGS="$PKGS $name=/pkgs/$name"
done

BASE_ARG=""
if [ -n "${BASE_PKG:-}" ]; then
    cp "$BASE_PKG" "$STAGE/pkgs/base.tgz"
    BASE_ARG="/pkgs/base.tgz"
fi

DUMP_MOUNT=""
DUMP_ARG=""
if [ "$PREBUILT" = 0 ] && [ -n "${PROG_DUMP:-}" ] && [ -e "$PROG_DUMP" ]; then
    DUMP_ABS="$(cd "$(dirname "$PROG_DUMP")" && pwd)/$(basename "$PROG_DUMP")"
    DUMP_MOUNT="-v $DUMP_ABS:/progdump:ro"
    DUMP_ARG="/progdump"
fi

# --privileged is needed for exactly two things: registering the binfmt handler
# for the printer's MIPS binaries, and building the mount layout that gives the
# replica a read-only root with writable prog/data partitions.
ROOTFS_MOUNT="-v $ROOT/work/rootfs:/rootfs:ro"
[ "$PREBUILT" = 1 ] && ROOTFS_MOUNT=""   # the image carries its own firmware

# shellcheck disable=SC2086
$DOCKER run --rm -i --privileged \
    $ROOTFS_MOUNT \
    -v "$STAGE/pkgs:/pkgs:ro" \
    -v "$STAGE/case.sh:/case.sh:ro" \
    -v "$ROOT/payload:/payload:ro" \
    -e "FF_KEY=${FF_KEY:-FFP0331&*%root}" \
    -e "BASE_PKG=$BASE_ARG" \
    -e "PKGS=$PKGS" \
    -e "PROG_DUMP=$DUMP_ARG" $DUMP_MOUNT \
    -e "PROG_MB=${PROG_MB:-}" -e "DATA_MB=${DATA_MB:-}" -e "SIM_VERBOSE=${SIM_VERBOSE:-0}" \
    -e "USB_STICK=${USB_STICK:-0}" \
    "$IMAGE" /case.sh
