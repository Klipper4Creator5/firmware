#!/usr/bin/env bash
# 1/3 -- decrypt the stock package and open the software component.
#
#   ./unpack.sh            uses $STOCK_TGZ from config.env
#   ./unpack.sh <file>     unpack some other package
#
# Result:
#   work/outer/      the 8 top-level files (runFirmwareExe.sh, *.tar.xz, imgs)
#   work/software/   the extracted software-<ver> tree -- EDIT THIS
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

# Every package carries a model gate. runFirmwareExe.sh compares the MACHINE
# and PID it was built for against the ones app_startup.sh passes in (which
# come from the firmware already on the printer) and REFUSES to install on a
# mismatch. Record it so verify.sh can check it against your printer.
PKG_MACHINE=$(sed -n 's/^MACHINE=//p' work/outer/runFirmwareExe.sh | head -n1)
PKG_PID=$(sed -n 's/^PID=//p' work/outer/runFirmwareExe.sh | head -n1)
echo "${PKG_MACHINE:-unknown}" > work/.pkg_machine
echo "${PKG_PID:-unknown}"     > work/.pkg_pid
echo ">> package installs on: ${PKG_MACHINE:-unknown} (PID ${PKG_PID:-unknown})"

echo "$STOCK_SW_VER" > work/.stock_sw_ver
echo "$SRC"          > work/.source_pkg

# ---- has FlashForge changed printer.base.cfg under us? ---------------------
# Our payload/klipper/config/printer.base.cfg is FlashForge's file with the
# chamber block replaced by an include, so a change on their side means a pin
# map, stepper current or endstop we are shipping stale.
#
# This lives HERE, and not in a test, because here is the only moment a
# pristine stock tree exists: bin/patch.sh copies our file straight over
# work/software/klipper/config/printer.base.cfg a few steps later. test-base-cfg.py
# read it afterwards and so spent its life diffing our file against itself --
# green on a cold tree, red on a second run, and blind to the drift either way.
#
# A warning, not a gate: their file changing is news, not a broken build, and
# it can only happen when you point the build at a new stock package.
STOCK_BASE=work/software/klipper/config/printer.base.cfg
OURS=payload/klipper/config/printer.base.cfg
if [ -f "$STOCK_BASE" ] && [ -f "$OURS" ]; then
    # Compare only the section/option lines: comments and blank lines differ by
    # design, and our chamber include replaces their heater block.
    strip() { grep -vE '^\s*(#|$)' "$1" | grep -vE '^\[(heater_generic|verify_heater) chamber_heater\]|^\[include printer\.chamber\.cfg\]'; }
    if strip "$STOCK_BASE" | diff -q - <(strip "$OURS") >/dev/null 2>&1; then
        echo ">> printer.base.cfg matches the stock file"
    else
        echo "   !! printer.base.cfg DIFFERS from this package's stock file." >&2
        echo "      FlashForge may have changed pins/currents/limits. Review:" >&2
        echo "      diff $STOCK_BASE $OURS" >&2
    fi
fi

echo
echo "Unpacked. Edit work/software/ then run ./pack.sh"
echo "  stock software version: $STOCK_SW_VER"
echo "  files: $(find work/software -type f | wc -l)"
