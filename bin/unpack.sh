#!/usr/bin/env bash
# 1/3 -- decrypt the stock package and open the software component.
#   ./bin/unpack.sh [<file>]     default: $STOCK_TGZ from config.env
# -> work/outer/ (the 8 top-level files), work/software/ (the tree to edit)
set -euo pipefail
. "$(dirname "$0")/common.sh"

SRC="${1:-$STOCK_TGZ}"
[ -f "$SRC" ] || { echo "no such package: $SRC" >&2; exit 1; }

rm -rf work/outer work/software
mkdir -p work/outer work/software

echo ">> decrypting $(basename "$SRC")"
# The printer's /usr/prog/bin/unTar runs exactly this, minus -md md5 (its
# OpenSSL 1.0.2 defaulted to MD5 key derivation; modern OpenSSL needs it said).
openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "$SRC" 2>/dev/null \
    | tar -xf - -C work/outer

echo ">> outer contents:"
ls -la work/outer | sed 's/^/   /'

SW_TARBALL=$(ls -1 work/outer/software-*.tar.xz 2>/dev/null | head -n1 || true)
[ -n "$SW_TARBALL" ] || { echo "no software-*.tar.xz in package" >&2; exit 1; }

STOCK_SW_VER=$(basename "$SW_TARBALL" | sed 's/^software-//; s/\.tar\.xz$//')
echo ">> extracting software component $STOCK_SW_VER"
tar -xf "$SW_TARBALL" -C work/software

# runFirmwareExe.sh refuses a MACHINE/PID mismatch; recorded for verify.sh.
PKG_MACHINE=$(sed -n 's/^MACHINE=//p' work/outer/runFirmwareExe.sh | head -n1)
PKG_PID=$(sed -n 's/^PID=//p' work/outer/runFirmwareExe.sh | head -n1)
echo "${PKG_MACHINE:-unknown}" > work/.pkg_machine
echo "${PKG_PID:-unknown}"     > work/.pkg_pid
echo ">> package installs on: ${PKG_MACHINE:-unknown} (PID ${PKG_PID:-unknown})"

echo "$STOCK_SW_VER" > work/.stock_sw_ver
echo "$SRC"          > work/.source_pkg

# Ours is FlashForge's file with the chamber block replaced by an include, so
# drift means a stale pin map or stepper current. Checked here because this is
# the only moment a pristine stock tree exists. A warning, not a gate.
STOCK_BASE=work/software/klipper/config/printer.base.cfg
OURS=pkgs/klipper-config/prog/config/printer.base.cfg
if [ -f "$STOCK_BASE" ] && [ -f "$OURS" ]; then
    # Section/option lines only: comments differ by design, and the chamber
    # and ff-*.cfg includes are ours.
    strip() { grep -vE '^\s*(#|$)' "$1" | grep -vE '^\[(heater_generic|verify_heater) chamber_heater\]|^\[include printer\.chamber\.cfg\]|^\[include ff-[a-z-]+\.cfg\]'; }
    if strip "$STOCK_BASE" | diff -q - <(strip "$OURS") >/dev/null 2>&1; then
        echo ">> printer.base.cfg matches the stock file"
    else
        echo "   !! printer.base.cfg DIFFERS from this package's stock file." >&2
        echo "      FlashForge may have changed pins/currents/limits. Review:" >&2
        echo "      diff $STOCK_BASE $OURS" >&2
    fi
fi

echo
echo "Unpacked. Edit work/software/ then run ./bin/pack.sh"
echo "  stock software version: $STOCK_SW_VER"
echo "  files: $(find work/software -type f | wc -l)"
