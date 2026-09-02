#!/usr/bin/env bash
# Rebuild the levelBoard MCU firmware from upstream Klipper plus the
# recovered FlashForge patch, and check the result against the stock image.
#
#   ./tools/mcu-recovery/build.sh [<work-dir>]
#
# Three things have to be pinned before any of this is reproducible at all:
#
#   * the version stamp.  Klipper bakes "?-<timestamp>-<hostname>" into the
#     data dictionary it embeds in the image, so two builds a second apart
#     differ.  KLIPPER_BUILD_VERSION pins it to what the stock image reports.
#   * the compiler.  The stock image names it in build_versions.
#   * zlib.  The dictionary is stored deflated, and Fedora's Python links
#     zlib-ng, whose output differs byte for byte from classic zlib at the
#     same level.  We build classic zlib and deflate through it.
#
# With those pinned the build is byte-reproducible, and the embedded
# dictionary blob comes out identical to the stock firmware's.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${1:-$ROOT/work/mcu-recovery}"

# The commit FlashForge's MCU tree is based on, and the toolchain their
# images name in build_versions.
KLIPPER_BASE=6d70050261ec3290f3c2e4015438e4910fd430d0
TOOLCHAIN_VER=10.3-2021.10
TOOLCHAIN_URL="https://developer.arm.com/-/media/Files/downloads/gnu-rm/${TOOLCHAIN_VER}/gcc-arm-none-eabi-${TOOLCHAIN_VER}-x86_64-linux.tar.bz2"

# The stock image's own version stamp, read out of its data dictionary.
export KLIPPER_BUILD_VERSION='?-20260609_102247-zhengxiaomming'

STOCK_BIN="${STOCK_BIN:-$ROOT/work/stock/mcu/levelBoard.bin}"
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

# -- classic zlib ------------------------------------------------------
if [ ! -f "$WORK/libz-classic.so" ]; then
    echo ">> building classic zlib"
    tar -xzf "$ROOT/vendor/zlib-1.3.1.tar.gz" -C "$WORK"
    ( cd "$WORK/zlib-1.3.1" && CFLAGS=-fPIC ./configure >/dev/null 2>&1 \
        && make -j"$(nproc)" >/dev/null 2>&1 \
        && cp libz.so.1.3.1 "$WORK/libz-classic.so" )
fi
export KLIPPER_ZLIB="$WORK/libz-classic.so"

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
echo ">> built $(stat -c%s "$SRC/out/klipper.bin") bytes (stock: $(stat -c%s "$STOCK_BIN" 2>/dev/null || echo '?'))"

# -- gates -------------------------------------------------------------
if [ ! -f "$STOCK_DICT" ]; then
    echo "   !! no stock dictionary at $STOCK_DICT" >&2
    echo "      run: ./tools/mcu-recovery/extract-dict.py \\" >&2
    echo "             work/stock/mcu/levelBoard.bin $STOCK_DICT" >&2
    exit 1
fi

python3 "$HERE/compare-dict.py" "$SRC/out/klipper.dict" "$STOCK_DICT"
STOCK_BIN="$STOCK_BIN" python3 "$HERE/compare-blob.py" "$SRC/out" "$STOCK_BIN"
