#!/usr/bin/env bash
# End-to-end update test: put the package on a USB stick in a replica of the
# printer and let the machine install it the way it really does.
#
# The replica is the real extracted rootfs.squashfs running under qemu-mipsel,
# with /usr/prog installed by the stock updater itself. The package sits on a
# genuine FAT filesystem at /dev/sda1 and the printer's own app_startup.sh
# finds it, mounts it, decrypts it and runs the installer -- three boots, the
# last one with the stick pulled. Every command involved is the printer's.
# See test/printer/case-install.sh and test/printer-exec.sh.
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
    M="no stock package configured for $(basename "$PKG_ABS") -- set STOCK_TGZ_* in config.env"
    [ "${REQUIRE_PRINTER_SIM:-0}" = 1 ] && { echo "  FAIL: $M" >&2; exit 1; }
    echo "  SKIP: $M"; exit 0
fi

USB_STICK=1 BASE_PKG="$BASE" exec "$ROOT/test/printer-exec.sh" \
    "$ROOT/test/printer/case-install.sh" \
    "$(basename "$PKG_ABS")=$PKG_ABS"
