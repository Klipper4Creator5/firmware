#!/usr/bin/env bash
# Install the package into a replica of the printer and assert it would boot.
#
# The replica is the real extracted rootfs.squashfs running under qemu-mipsel,
# with /usr/prog installed by the stock updater itself. Every command in the
# test -- the shell, tar, md5sum, expr, the unTar binary -- is the printer's.
# See test/printer-exec.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${1:?usage: sim-install.sh <package.tgz>}"
PKG_ABS="$(cd "$(dirname "$PKG")" && pwd)/$(basename "$PKG")"

# The baseline is the stock package for the same model: it is what makes
# /usr/prog authentic instead of hand-written.
# shellcheck disable=SC1091
. "$ROOT/test/test-env.sh"
case "$(basename "$PKG_ABS")" in
    Creator5Pro-*) BASE="${STOCK_TGZ_CREATOR5PRO:-}" ;;
    Creator5-*)    BASE="${STOCK_TGZ_CREATOR5:-}"    ;;
    *)             BASE="${STOCK_TGZ:-}"             ;;
esac
if [ -z "$BASE" ] || [ ! -f "$BASE" ]; then
    echo "  SKIP: no stock package configured for $(basename "$PKG_ABS") -- set STOCK_TGZ_* in config.env"
    exit 0
fi

BASE_PKG="$BASE" exec "$ROOT/test/printer-exec.sh" \
    "$ROOT/test/printer/case-install.sh" \
    "$(basename "$PKG_ABS")=$PKG_ABS"
