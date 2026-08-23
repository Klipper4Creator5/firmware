#!/usr/bin/env bash
# Build a Docker image that IS the printer.
#
#   ./test/build-printer-image.sh            build
#   ./test/build-printer-image.sh --push     build and push
#
# ONE image covers both models. That is not a shortcut -- there is genuinely
# nothing model-specific to put in a second one:
#
#   * rootfs.squashfs is byte-for-byte identical in the Creator 5 and
#     Creator 5 Pro packages. Their kernel-*.tar.xz differ, but only in the
#     eMMC/SD kernel images and module.tar, not in the root filesystem.
#   * /usr/prog comes from the factory image, and only the Pro's was ever
#     published.
#
# The model is decided by whichever stock package a test installs into the
# replica: that overwrites app_startup.sh, firmwareExe, start.sh, klipper,
# passwd and shadow with that model's genuine files. An earlier version of
# this script published :pro and :std tags that were byte-for-byte identical
# apart from a label, which was worse than useless -- pulling :std without a
# baseline install gave you a Pro.
#
# The Dockerfile downloads the firmware itself, so nothing has to be staged
# locally, config.env is not needed, and the build context is just
# test/printer. Override to build against different firmware:
#
#   STOCK_URL=  FACTORY_URL=  FW_VERSION=
#
# The image carries the printer's real rootfs and its real /usr/prog and
# /usr/data, pre-unpacked into /parts, so a replica run bind-mounts them and
# copies nothing.
#
# THE IMAGE CONTAINS PROPRIETARY FLASHFORGE FIRMWARE. Pushing it redistributes
# their software.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

NS="${IMAGE_NS:-monstrofil}"
NAME="${IMAGE_NAME:-creator5-printer}"
FWVER="${FW_VERSION:-1.9.7-1.2.9-20260810}"

REL="https://github.com/ghzserg/FF/releases/download/R"
# Either model's package yields the same rootfs; the Pro's is the one used.
STOCK_URL="${STOCK_URL:-$REL/Creator5Pro-$FWVER.tgz}"
FACTORY_URL="${FACTORY_URL:-$REL/Creator5Pro-factory.tar.xz}"

PUSH=0
for a in "$@"; do case "$a" in --push) PUSH=1 ;; esac; done

DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe

echo "=============================================================="
echo " $NS/$NAME:$FWVER"
echo "=============================================================="
echo "   stock:   $STOCK_URL"
echo "   factory: $FACTORY_URL"
echo

$DOCKER build -t "$NS/$NAME:$FWVER" -t "$NS/$NAME:latest" \
    --build-arg "STOCK_URL=$STOCK_URL" \
    --build-arg "FACTORY_URL=$FACTORY_URL" \
    --build-arg "FF_KEY=${FF_KEY:-FFP0331&*%root}" \
    --build-arg "FW_VERSION=$FWVER" \
    -f test/printer/Dockerfile.full test/printer

if [ "$PUSH" = 1 ]; then
    echo ">> pushing"
    $DOCKER push "$NS/$NAME:$FWVER"
    $DOCKER push "$NS/$NAME:latest"
fi

echo
echo "built: $NS/$NAME:$FWVER"
echo
echo "Use it instead of building the replica locally:"
echo "    PRINTER_IMAGE=$NS/$NAME:$FWVER make test-install"
