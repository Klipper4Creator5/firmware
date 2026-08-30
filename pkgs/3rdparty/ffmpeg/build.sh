#!/usr/bin/env bash
# ffmpeg -- one static binary that renders timelapses.
#
# NOT AUTOTOOLS: ffmpeg's configure is hand-written, rejects --host and takes
# --arch/--target-os/--cross-prefix instead, so PKG_CONFIGURE_AUTO=0.
#
# THE ENABLE LIST IS FLASHFORGE'S PLUS THE FILTERS THEY LEFT OUT. Starting
# from --disable-everything and naming each piece keeps the binary small on a
# machine with little flash; the list is exactly what moonraker-timelapse
# invokes and nothing else:
#   image2 + mjpeg/png decode   the frames wget writes
#   libx264 + mp4               the render
#   mjpeg muxer                 the preview image the component also writes
#   hflip/vflip/transpose/rotate  what a rotated or flipped webcam needs, and
#                               the whole reason this package exists
#   format/scale/null/buffer*   the filter graph's own plumbing
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin ffmpeg || exit 0
pkg_toolchain
pkg_deps
pkg_unpack "$FFMPEG_TGZ"

_sr="$PKG_SYSROOT$MODDIR"

PKG_CONFIGURE_AUTO=0

# ffmpeg's configure runs its probes with $CC, and pkg_toolchain's wrapper
# already carries the ABI flags -- but it takes the cross prefix as a string
# and builds "$cross_prefix$cc" itself, so CC must be unset here or it ends up
# looking for mips-linux-gnu-mips-linux-gnu-gcc.
unset CC CXX AR RANLIB STRIP NM OBJCOPY OBJDUMP LD

pkg_build "ffmpeg-$FFMPEG_VERSION" \
    --prefix="$MODDIR" \
    --arch=mips \
    --target-os=linux \
    --enable-cross-compile \
    --cross-prefix="$PKG_HOST-" \
    --extra-cflags="-Os -I$_sr/include" \
    --extra-ldflags="-L$_sr/lib" \
    --pkg-config-flags="--static" \
    --disable-shared --enable-static \
    --disable-doc --disable-htmlpages --disable-manpages \
    --disable-podpages --disable-txtpages \
    --disable-debug --disable-stripping \
    --disable-network --disable-iconv --disable-bzlib --disable-lzma \
    --disable-sdl2 --disable-xlib --disable-securetransport \
    --disable-autodetect \
    --disable-ffplay --disable-ffprobe \
    --disable-everything \
    --enable-gpl --enable-libx264 \
    --enable-protocol=file \
    --enable-demuxer=image2 --enable-muxer=image2 \
    --enable-decoder=mjpeg --enable-decoder=png \
    --enable-parser=mjpeg --enable-parser=png \
    --enable-encoder=libx264 --enable-encoder=mjpeg \
    --enable-muxer=mp4 --enable-muxer=mjpeg \
    --enable-bsf=h264_mp4toannexb \
    --enable-filter=format --enable-filter=scale --enable-filter=null \
    --enable-filter=buffer --enable-filter=buffersink \
    --enable-filter=hflip --enable-filter=vflip \
    --enable-filter=transpose --enable-filter=rotate \
    --enable-filter=pad --enable-filter=crop

# Ours is anvil-ffmpeg, the name moonraker.conf points at. The shim that used
# to carry that name -- and only picked between FlashForge's two trees -- is
# gone with this package.
pkg_ship "bin/ffmpeg"
pkg_end
