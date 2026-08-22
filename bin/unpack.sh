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

echo "$STOCK_SW_VER" > work/.stock_sw_ver
echo "$SRC"          > work/.source_pkg

echo
echo "Unpacked. Edit work/software/ then run ./pack.sh"
echo "  stock software version: $STOCK_SW_VER"
echo "  files: $(find work/software -type f | wc -l)"
