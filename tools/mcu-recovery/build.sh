#!/usr/bin/env bash
# Rebuild the levelBoard MCU firmware from upstream Klipper plus the
# recovered FlashForge patch, and check the result against the stock image.
#
#   ./tools/mcu-recovery/build.sh [<work-dir>]
#
# The gate is the data dictionary: Klipper embeds its whole wire protocol
# in the image, so a byte-identical dictionary means the rebuilt firmware
# speaks exactly what the stock board speaks.  The machine code is NOT
# identical -- see tools/mcu-recovery/README.md for what is missing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${1:-$ROOT/work/mcu-recovery}"

# The commit FlashForge's MCU tree is based on, and the toolchain their
# images name in build_versions.  Both are pinned: a different compiler
# changes code size and a different base changes the dictionary.
KLIPPER_BASE=6d70050261ec3290f3c2e4015438e4910fd430d0
TOOLCHAIN_VER=10.3-2021.10
TOOLCHAIN_URL="https://developer.arm.com/-/media/Files/downloads/gnu-rm/${TOOLCHAIN_VER}/gcc-arm-none-eabi-${TOOLCHAIN_VER}-x86_64-linux.tar.bz2"

STOCK_DICT="${STOCK_DICT:-$ROOT/work/stock/mcu/levelBoard.dict.json}"

mkdir -p "$WORK"

# -- toolchain ---------------------------------------------------------
TC="$WORK/gcc-arm-none-eabi-${TOOLCHAIN_VER}"
if [ ! -x "$TC/bin/arm-none-eabi-gcc" ]; then
    echo ">> fetching GCC ARM ${TOOLCHAIN_VER}"
    curl -sSL -o "$WORK/gcc-arm.tar.bz2" "$TOOLCHAIN_URL"
    tar -xjf "$WORK/gcc-arm.tar.bz2" -C "$WORK"
fi
export PATH="$TC/bin:$PATH"
arm-none-eabi-gcc --version | head -n1

# -- klipper at the base commit ----------------------------------------
SRC="$WORK/klipper"
if [ ! -d "$SRC/.git" ]; then
    echo ">> cloning upstream Klipper"
    git clone --quiet https://github.com/Klipper3d/klipper.git "$SRC"
fi
git -C "$SRC" checkout --quiet --detach "$KLIPPER_BASE"
git -C "$SRC" clean -qfdx
git -C "$SRC" checkout --quiet -- .

echo ">> applying the recovered FlashForge patch"
git -C "$SRC" apply "$HERE/klipper-6d70050-flashforge.patch"

# -- build -------------------------------------------------------------
cp "$HERE/levelBoard.config" "$SRC/.config"
( cd "$SRC" && python3 lib/kconfiglib/olddefconfig.py src/Kconfig >/dev/null )
( cd "$SRC" && make -j"$(nproc)" >/dev/null )
echo ">> built $(stat -c%s "$SRC/out/klipper.bin") bytes"

# -- gate: the dictionary must match the stock image exactly -----------
if [ ! -f "$STOCK_DICT" ]; then
    echo "   !! no stock dictionary at $STOCK_DICT" >&2
    echo "      run: ./tools/mcu-recovery/extract-dict.py \\" >&2
    echo "             work/stock/mcu/levelBoard.bin $STOCK_DICT" >&2
    exit 1
fi

exec python3 "$HERE/compare-dict.py" "$SRC/out/klipper.dict" "$STOCK_DICT"
